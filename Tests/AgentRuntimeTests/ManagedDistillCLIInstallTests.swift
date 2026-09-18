import XCTest
@testable import AgentRuntime
import CoreModel

final class ManagedDistillCLIInstallTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-cli-\(UUID().uuidString)", isDirectory: true)
    }

    func test_installCreatesNativeSymlink_notAPythonScript() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let binary = home.appendingPathComponent("fake/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary-content-not-python".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let installer = AgentSkillInstaller(homeDirectory: home)
        let url = try installer.installDistillCLI(appSupportDirectory: home, serviceBinaryURL: binary)

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        XCTAssertEqual(dest, binary.path, "managed distill is a symlink to the native binary")

        let content = try Data(contentsOf: url) // follows symlink
        XCTAssertFalse(String(decoding: content, as: UTF8.self).contains("#!/usr/bin/env python3"), "N1: no Python shebang")

        let result = try installer.uninstallDistillCLI()
        XCTAssertEqual(result, .removed)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
    }

    func test_ensureDistillCLI_repairsMissingAndDanglingLinks_forAnyUserHome() throws {
        // WHY: automatic reinstall must work under any user's home (not only the
        // developer who first enabled Token Saver). Missing + dangling must heal.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let distill = installer.distillCLIURL()

        // Missing → create
        XCTAssertFalse(installer.isDistillCLIHealthy())
        _ = try installer.ensureDistillCLI(serviceBinaryURL: binary)
        XCTAssertTrue(installer.isDistillCLIHealthy())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: distill.path), binary.path)

        // Dangling (target deleted) → reinstall to a live binary
        let deadTarget = home.appendingPathComponent("fake/RemoteCodeDistillService-dead")
        try FileManager.default.createDirectory(at: deadTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dead".utf8).write(to: deadTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deadTarget.path)
        try? FileManager.default.removeItem(at: distill)
        try FileManager.default.createSymbolicLink(at: distill, withDestinationURL: deadTarget)
        try FileManager.default.removeItem(at: deadTarget)
        XCTAssertFalse(installer.isDistillCLIHealthy())
        _ = try installer.ensureDistillCLI(serviceBinaryURL: binary)
        XCTAssertTrue(installer.isDistillCLIHealthy())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: distill.path), binary.path)

        // Idempotent healthy path
        _ = try installer.ensureDistillCLI(serviceBinaryURL: binary)
        XCTAssertTrue(installer.isDistillCLIHealthy())
    }

    func test_ensureDistillCLI_recoversBinaryFromExistingManagedWrappers() throws {
        // WHY: after an app relocate, Bundle.main may not resolve but wrappers
        // still point at the live service — reinstall distill from those links.
        // Prefer an unresolvable explicit path so resolution falls through to
        // managed-wrapper recovery (not Bundle.main / SwiftPM on the host).
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: binDir.appendingPathComponent("git"),
            withDestinationURL: binary
        )
        XCTAssertFalse(installer.isDistillCLIHealthy())
        // Non-executable preferred forces wrapper recovery on this installer home.
        let bogus = home.appendingPathComponent("missing/RemoteCodeDistillService")
        let url = try installer.ensureDistillCLI(serviceBinaryURL: bogus)
        XCTAssertTrue(installer.isDistillCLIHealthy())
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        XCTAssertEqual(
            URL(fileURLWithPath: dest).resolvingSymlinksInPath().path,
            binary.resolvingSymlinksInPath().path,
            "must recover from git wrapper when preferred binary is dead"
        )
    }

    func test_installGrokPreToolPipeHook_isRemovedWhenTokenSaverOff() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installGrokPreToolPipeHook()
        let url = installer.grokPreToolPipeHookURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let hooks = try XCTUnwrap(object?["hooks"] as? [String: Any])
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(pre.first?["matcher"] as? String, "Bash|run_terminal_command|run_terminal_cmd")
        let handlers = try XCTUnwrap(pre.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(
            handlers.first?["command"] as? String,
            AgentSkillInstaller.grokPreToolPipeHookCommand(distillPath: installer.distillCLIURL().path)
        )
        XCTAssertEqual(try installer.uninstallGrokPreToolPipeHook(), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try installer.uninstallGrokPreToolPipeHook(), .notPresent)
    }

    func test_installGrokPostToolUseHook_writesReplacementHookAndUninstalls() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installGrokPostToolUseHook()
        let url = installer.grokPostToolUseHookURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let hooks = try XCTUnwrap(object?["hooks"] as? [String: Any])
        let post = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(
            post.first?["matcher"] as? String,
            "read_file|list_dir|web_fetch",
            "only shapes verified against grok's own result shapes may be rewritten"
        )
        XCTAssertNil(hooks["PreToolUse"], "the output hook must not carry the shell pipe lane")
        let handlers = try XCTUnwrap(post.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(
            handlers.first?["command"] as? String,
            AgentSkillInstaller.grokPostToolUseHookCommand(distillPath: installer.distillCLIURL().path)
        )
        XCTAssertEqual(handlers.first?["timeout"] as? Int, 45)
        XCTAssertEqual(try installer.uninstallGrokPostToolUseHook(), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try installer.uninstallGrokPostToolUseHook(), .notPresent)
    }

    func test_installCommandWrappers_alwaysInstallsDistillBesideWrappers() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installCommandWrappers(serviceBinaryURL: binary)
        XCTAssertTrue(installed.contains("distill"))
        XCTAssertTrue(installer.isDistillCLIHealthy())
    }

    func test_installResolvesRealBuiltBinaryWhenNotProvided() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let url = try installer.installDistillCLI(appSupportDirectory: home) // nil => resolveServiceBinary
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        XCTAssertTrue(dest.hasSuffix("RemoteCodeDistillService"), "resolves the real built service binary")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest), "the resolved target is an executable")
    }

    func test_resolveServiceBinaryFindsSwiftPMPlatformTripleBuildDirectory() throws {
        let root = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent(".build/arm64-apple-macosx/debug/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let original = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(original) }

        XCTAssertEqual(
            AgentSkillInstaller.resolveServiceBinary()?.resolvingSymlinksInPath().path,
            binary.resolvingSymlinksInPath().path,
            "SwiftPM on modern macOS places executable products under .build/<platform-triple>/debug, not .build/debug"
        )
    }

    func test_uninstallRemovesLegacyPythonScript() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let url = installer.distillCLIURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Simulate a pre-native managed Python CLI carrying our markers.
        let legacy = "#!/usr/bin/env python3\n\(AgentSkillInstaller.distillCLIBeginMarker)\nprint('x')\n\(AgentSkillInstaller.distillCLIEndMarker)\n"
        try Data(legacy.utf8).write(to: url)
        let result = try installer.uninstallDistillCLI()
        XCTAssertEqual(result, .removed, "legacy Python CLI is cleaned up on uninstall (migration)")
    }

    // MARK: - RTK transparent command wrappers

    private func fakeServiceBinary(in home: URL) throws -> URL {
        let binary = home.appendingPathComponent("fake/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    func test_installCommandWrappers_symlinksExistingCommandsToServiceBinary() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)

        let installed = try installer.installCommandWrappers(serviceBinaryURL: binary)
        // Exact-output commands still pass through the global interceptor;
        // CommandWrapPolicy is responsible for preserving their raw output.
        XCTAssertTrue(installed.contains("ls"))
        let lsLink = home.appendingPathComponent(".remote-code/bin/ls")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: lsLink.path), binary.path)
        for command in ["cat", "sed", "rg"] {
            XCTAssertTrue(installed.contains(command))
            let link = home.appendingPathComponent(".remote-code/bin/\(command)")
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                binary.path
            )
        }
        // Idempotent: a second install keeps the same links, no throw.
        XCTAssertEqual(Set(try installer.installCommandWrappers(serviceBinaryURL: binary)), Set(installed))

        let removed = try installer.uninstallCommandWrappers(serviceBinaryURL: binary)
        XCTAssertTrue(removed.contains("ls"))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: lsLink.path))
    }

    func test_installCommandWrappers_coversAnArbitraryExecutableOutsideTheCatalog() throws {
        // WHY: every executable visible to an admitted provider must reach the
        // shared interceptor; catalog membership cannot be the coverage boundary.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let arbitrary = "true"
        XCTAssertFalse(WrappedCommandCatalog.commands.contains(arbitrary))

        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installCommandWrappers(serviceBinaryURL: binary)
        XCTAssertTrue(installed.contains(arbitrary), "(arbitrary) must be wired even though it is not catalog-listed")

        let link = home.appendingPathComponent(".remote-code/bin/\(arbitrary)")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            binary.path
        )
    }

    func test_installCommandWrappers_coversExecutableOnlyInEffectiveProviderPath() throws {
        // WHY: project-local tools can be absent from the GUI app PATH but present
        // in the admitted provider/workspace environment.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let workspaceBin = home.appendingPathComponent("workspace-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceBin, withIntermediateDirectories: true)
        let command = "workspace-report"
        let executable = workspaceBin.appendingPathComponent(command)
        try Data("#!/bin/sh\necho workspace\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installCommandWrappers(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [workspaceBin.path]
        )

        XCTAssertTrue(installed.contains(command))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: home.appendingPathComponent(".remote-code/bin/\(command)").path
            ),
            binary.path
        )
    }

    func test_installCommandWrappers_reconcilesLegacyExactOutputSymlinksToServiceInterceptor() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let legacyBinary = home.appendingPathComponent("legacy/RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: legacyBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy-binary".utf8).write(to: legacyBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyBinary.path)
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // Simulate older install that wrapped sed/rg/cat.
        for legacy in ["sed", "rg", "cat"] {
            try FileManager.default.createSymbolicLink(
                at: binDir.appendingPathComponent(legacy),
                withDestinationURL: legacyBinary
            )
        }
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installCommandWrappers(serviceBinaryURL: binary)
        for legacy in ["sed", "rg", "cat"] {
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: binDir.appendingPathComponent(legacy).path
                ),
                binary.path,
                "legacy exact-output wrapper \(legacy) must use the current service interceptor"
            )
        }
    }

    func test_installCommandWrappers_neverShadowsAMissingCommand() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installCommandWrappers(serviceBinaryURL: binary)
        // Only commands that actually resolve on the system are wrapped; a wrapper is never
        // created for an absent command (which would then fail with "command not found").
        for command in installed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".remote-code/bin/\(command)").path))
        }
    }

    func test_uninstallCommandWrappers_leavesAUserOwnedFileUntouched() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // A real (non-symlink) file the user placed at our managed path for `ls`.
        let userFile = binDir.appendingPathComponent("ls")
        try Data("not ours".utf8).write(to: userFile)
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.uninstallCommandWrappers()
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path), "a non-symlink we did not create must never be removed")
    }

    func test_installCommandWrappers_prunesStrayShebangInterpreterWrappers() throws {
        // WHY: a leftover `node`/`env` Distill symlink on the agent PATH makes
        // Homebrew Codex (`#!/usr/bin/env node`) start the sidecar instead of Node.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        for stray in ["node", "env"] {
            try FileManager.default.createSymbolicLink(
                at: binDir.appendingPathComponent(stray),
                withDestinationURL: binary
            )
        }
        let claude = binDir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: binary)
        let userFile = binDir.appendingPathComponent("mine")
        try Data("user-owned".utf8).write(to: userFile)

        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installCommandWrappers(serviceBinaryURL: binary)

        for stray in ["node", "env"] {
            XCTAssertNil(
                try? FileManager.default.destinationOfSymbolicLink(
                    atPath: binDir.appendingPathComponent(stray).path
                ),
                "stray \(stray) Distill wrapper must be unlinked so shebang lookup finds the real binary"
            )
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: claude.path),
            binary.path,
            "always-on provider proxies must survive wrapper reconcile"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
        XCTAssertFalse(
            installer.reservedManagedBinBasenames(includingCommandWrappers: true).contains("node")
        )
    }

    func test_installCommandWrappers_prunesStrayNodeWrapperPointingAtAnotherDistillBuild() throws {
        // WHY: production leftovers point at dist/RemoteCode.app/.../RemoteCodeDistillService
        // while reconcile may resolve a different build. Ownership is the target name.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let otherBuild = home.appendingPathComponent("old-app/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: otherBuild.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("other-build".utf8).write(to: otherBuild)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: otherBuild.path)
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: binDir.appendingPathComponent("node"),
            withDestinationURL: otherBuild
        )
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installCommandWrappers(serviceBinaryURL: binary)
        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: binDir.appendingPathComponent("node").path
            )
        )
    }

    func test_uninstallCommandWrappers_prunesStrayWrappersButKeepsProviderProxies() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: binDir.appendingPathComponent("node"),
            withDestinationURL: binary
        )
        try FileManager.default.createSymbolicLink(
            at: binDir.appendingPathComponent("claude"),
            withDestinationURL: binary
        )
        try FileManager.default.createSymbolicLink(
            at: binDir.appendingPathComponent("ls"),
            withDestinationURL: binary
        )
        let installer = AgentSkillInstaller(homeDirectory: home)
        let removed = try installer.uninstallCommandWrappers(serviceBinaryURL: binary)
        XCTAssertTrue(removed.contains("node"))
        XCTAssertTrue(removed.contains("ls"))
        XCTAssertFalse(removed.contains("claude"))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: binDir.appendingPathComponent("node").path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: binDir.appendingPathComponent("claude").path),
            binary.path
        )
    }
}
