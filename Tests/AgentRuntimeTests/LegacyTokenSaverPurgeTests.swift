import XCTest
import CoreModel
@testable import AgentRuntime

/// Uninstall paths that clean up what an earlier Token Saver build left in the
/// user's home (managed `distill` CLI, provider skills and instruction blocks,
/// command wrappers). They must keep removing only RemoteCode-owned artifacts.
final class LegacyTokenSaverPurgeTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LegacyTokenSaverPurge-\(UUID().uuidString)", isDirectory: true)
    }

    private func fakeServiceBinary(in home: URL) throws -> URL {
        let binary = home.appendingPathComponent("fake/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    func test_managedDistillPathBridgeReplacesStaleShimButKeepsUnrelatedUserFile() throws {
        let home = tempHome()
        let appSupport = tempHome()
        let installer = AgentSkillInstaller(homeDirectory: home)
        let link = installer.distillPathLinkURL()
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)

        // (a) An unrelated user `distill` on PATH must survive — RemoteCode never clobbers it.
        let userScript = "#!/bin/sh\necho not-the-distill-you-are-looking-for\n"
        try Data(userScript.utf8).write(to: link)
        _ = try installer.installDistillCLI(appSupportDirectory: appSupport)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), userScript,
                       "an unrelated user file at ~/.local/bin/distill must be left untouched")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))

        // (b) A stale external node/bun source-checkout shim must be replaced by the managed symlink.
        try FileManager.default.removeItem(at: link)
        try Data("#!/usr/bin/env bash\nexec bun ~/dev/distill/src/cli.ts \"$@\"\n".utf8).write(to: link)
        let cli = try installer.installDistillCLI(appSupportDirectory: appSupport)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), cli.path,
                       "a stale external-checkout shim must be replaced by the RemoteCode-managed CLI symlink")
    }

    func test_agentSkillInstallerUninstallDistillInstructionsRemovesOnlyManagedBlock() throws {
        let home = tempHome()
        let installer = AgentSkillInstaller(homeDirectory: home)
        let claudeInstructions = home.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.createDirectory(at: claudeInstructions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Keep this user rule.\n".utf8).write(to: claudeInstructions)

        try installer.installDistillInstructions(for: .claude)
        XCTAssertTrue(try String(contentsOf: claudeInstructions).contains(AgentSkillInstaller.distillInstructionsBeginMarker))

        XCTAssertEqual(try installer.uninstallDistillInstructions(for: .claude), .removed)

        let text = try String(contentsOf: claudeInstructions)
        XCTAssertTrue(text.contains("Keep this user rule."))
        XCTAssertFalse(text.contains(AgentSkillInstaller.distillInstructionsBeginMarker))
        XCTAssertFalse(text.contains("Always communicate with the user in `/distill` compressed language"))
    }

    func test_agentSkillInstallerUninstallRemovesDistillSkillForEachProvider() throws {
        let home = tempHome()
        let installer = AgentSkillInstaller(homeDirectory: home)
        let codexSkill = home.appendingPathComponent(".codex/skills/distill/SKILL.md")
        let claudeSkill = home.appendingPathComponent(".claude/skills/distill/SKILL.md")
        let grokSkill = home.appendingPathComponent(".grok/skills/distill/SKILL.md")

        _ = try installer.installDistillSkill(for: .codex, sourceRevision: "rev-a")
        _ = try installer.installDistillSkill(for: .claude, sourceRevision: "rev-a")
        _ = try installer.installDistillSkill(for: .grok, sourceRevision: "rev-a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexSkill.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeSkill.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: grokSkill.path))

        XCTAssertEqual(try installer.uninstallDistillSkill(for: .codex), .removed,
                       "disabling Token Saver must remove the managed /distill skill")
        XCTAssertEqual(try installer.uninstallDistillSkill(for: .claude), .removed)
        XCTAssertEqual(try installer.uninstallDistillSkill(for: .grok), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: grokSkill.path))
    }

    func test_agentSkillInstallerUninstallIsNoOpWhenSkillNotPresent() throws {
        let installer = AgentSkillInstaller(homeDirectory: tempHome())

        XCTAssertEqual(try installer.uninstallDistillSkill(for: .codex), .notPresent,
                       "uninstalling a skill that was never installed must not throw")
    }

    func test_agentSkillInstallerUninstallLeavesAUserAuthoredSkillOfTheSameNameUntouched() throws {
        let home = tempHome()
        let installer = AgentSkillInstaller(homeDirectory: home)
        // A user-authored `distill` skill that RemoteCode did NOT install (no manifest.json).
        let userSkillDir = home.appendingPathComponent(".claude/skills/distill", isDirectory: true)
        try FileManager.default.createDirectory(at: userSkillDir, withIntermediateDirectories: true)
        let userSkill = userSkillDir.appendingPathComponent("SKILL.md")
        try Data("user's own distill".utf8).write(to: userSkill)

        XCTAssertEqual(try installer.uninstallDistillSkill(for: .claude), .notPresent,
                       "uninstall must only remove skill dirs RemoteCode owns (proven by its manifest)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: userSkill.path),
                      "a user-authored skill of the same name must survive a Token Saver disable")
    }

    func test_agentSkillInstallerReinstallsAfterUninstall() throws {
        let home = tempHome()
        let installer = AgentSkillInstaller(homeDirectory: home)
        let codexSkill = home.appendingPathComponent(".codex/skills/distill/SKILL.md")

        _ = try installer.installDistillSkill(for: .codex, sourceRevision: "rev-a")
        XCTAssertEqual(try installer.uninstallDistillSkill(for: .codex), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexSkill.path))

        let reinstalled = try installer.installDistillSkill(for: .codex, sourceRevision: "rev-a")
        XCTAssertEqual(reinstalled.action, .installed,
                       "re-enabling Token Saver after a disable must write the skill back to disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexSkill.path))
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
