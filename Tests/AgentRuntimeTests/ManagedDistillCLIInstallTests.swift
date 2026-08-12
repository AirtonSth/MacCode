import XCTest
@testable import AgentRuntime

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
        // ls exists on every macOS system and is compressible; cat is exact-output and must not wrap.
        XCTAssertTrue(installed.contains("ls"))
        XCTAssertFalse(installed.contains("cat"))
        XCTAssertFalse(installed.contains("sed"))
        XCTAssertFalse(installed.contains("rg"))
        let lsLink = home.appendingPathComponent(".remote-code/bin/ls")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: lsLink.path), binary.path)
        // Idempotent: a second install keeps the same links, no throw.
        XCTAssertEqual(Set(try installer.installCommandWrappers(serviceBinaryURL: binary)), Set(installed))

        let removed = try installer.uninstallCommandWrappers(serviceBinaryURL: binary)
        XCTAssertTrue(removed.contains("ls"))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: lsLink.path))
    }

    func test_installCommandWrappers_discoversEveryEligiblePathCommand() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let systemBin = home.appendingPathComponent("system-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: systemBin, withIntermediateDirectories: true)
        for command in ["custom-build-tool", "npx", "rg", "sed", "shasum", "sha256sum", "vim", "less", "codex"] {
            let url = systemBin.appendingPathComponent(command)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let installer = AgentSkillInstaller(homeDirectory: home)

        let installed = try installer.installCommandWrappers(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [systemBin.path]
        )

        XCTAssertTrue(installed.contains("custom-build-tool"))
        XCTAssertTrue(installed.contains("npx"))
        for excluded in ["rg", "sed", "shasum", "sha256sum", "vim", "less", "codex"] {
            XCTAssertFalse(installed.contains(excluded), excluded)
            XCTAssertNil(
                try? FileManager.default.destinationOfSymbolicLink(
                    atPath: home.appendingPathComponent(".remote-code/bin/\(excluded)").path
                )
            )
        }
    }

    func test_installCommandWrappers_removesLegacyExactOutputSymlinks() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // Simulate older install that wrapped sed/rg/cat.
        for legacy in ["sed", "rg", "cat"] {
            try FileManager.default.createSymbolicLink(
                at: binDir.appendingPathComponent(legacy),
                withDestinationURL: binary
            )
        }
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installCommandWrappers(serviceBinaryURL: binary)
        for legacy in ["sed", "rg", "cat"] {
            XCTAssertNil(
                try? FileManager.default.destinationOfSymbolicLink(
                    atPath: binDir.appendingPathComponent(legacy).path
                ),
                "legacy exact-output wrapper \(legacy) must be unlinked on install"
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

    func test_installCommandWrappers_reconcileRemovesStaleManagedWrapperAndPreservesForeignSymlink() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let systemBin = home.appendingPathComponent("system-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: systemBin, withIntermediateDirectories: true)
        let staleName = "stale-tool"
        let currentName = "current-tool"
        for name in [staleName, currentName] {
            let url = systemBin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installCommandWrappers(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [systemBin.path]
        )
        let managedBin = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        let foreignTarget = home.appendingPathComponent("foreign-tool")
        try Data("foreign".utf8).write(to: foreignTarget)
        let foreignLink = managedBin.appendingPathComponent("foreign-alias")
        try FileManager.default.createSymbolicLink(at: foreignLink, withDestinationURL: foreignTarget)
        try FileManager.default.removeItem(at: systemBin.appendingPathComponent(staleName))

        _ = try installer.installCommandWrappers(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [systemBin.path]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: managedBin.appendingPathComponent(staleName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedBin.appendingPathComponent(currentName).path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: foreignLink.path),
            foreignTarget.path,
            "reconciliation must not overwrite a foreign symlink in the managed directory"
        )
    }

    func test_installCommandWrappers_retargetsOlderRemoteCodeServiceSymlink() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let oldBinary = home.appendingPathComponent("old/RemoteCodeDistillService")
        let newBinary = home.appendingPathComponent("new/RemoteCodeDistillService")
        for binary in [oldBinary, newBinary] {
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("binary".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let systemBin = home.appendingPathComponent("system-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: systemBin, withIntermediateDirectories: true)
        let command = systemBin.appendingPathComponent("custom-tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let link = home.appendingPathComponent(".remote-code/bin/custom-tool")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: oldBinary)

        _ = try installer.installCommandWrappers(
            serviceBinaryURL: newBinary,
            searchDirectoriesOverride: [systemBin.path]
        )

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            newBinary.path,
            "an older managed service link must retarget during install"
        )
    }

    func test_installCommandWrappers_reconcileRemovesStaleLinkToOlderRemoteCodeService() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let oldBinary = home.appendingPathComponent("old/RemoteCodeDistillService")
        let newBinary = home.appendingPathComponent("new/RemoteCodeDistillService")
        for binary in [oldBinary, newBinary] {
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("binary".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let systemBin = home.appendingPathComponent("system-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: systemBin, withIntermediateDirectories: true)
        for name in ["current-tool", "stale-tool"] {
            let command = systemBin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: command)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        }
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installCommandWrappers(
            serviceBinaryURL: oldBinary,
            searchDirectoriesOverride: [systemBin.path]
        )
        try FileManager.default.removeItem(at: systemBin.appendingPathComponent("stale-tool"))

        _ = try installer.installCommandWrappers(
            serviceBinaryURL: newBinary,
            searchDirectoriesOverride: [systemBin.path]
        )

        let managedBin = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: managedBin.appendingPathComponent("stale-tool").path),
            "reconciliation must remove a disappeared command even when its link targets an older service binary"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: managedBin.appendingPathComponent("current-tool").path
            ),
            newBinary.path
        )
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
}
