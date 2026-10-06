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

    func test_agentSkillInstallerUninstallDistillInstructionsRemovesOnlyManagedBlock() throws {
        let home = tempHome()
        let installer = AgentSkillInstaller(homeDirectory: home)
        let claudeInstructions = home.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.createDirectory(at: claudeInstructions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Keep this user rule.\n".utf8).write(to: claudeInstructions)

        try LegacyTokenSaverFixture.installDistillInstructions(installer, for: .claude)
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

        for provider in [AgentProvider.codex, .claude, .grok] {
            try LegacyTokenSaverFixture.installDistillSkill(installer, for: provider)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexSkill.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeSkill.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: grokSkill.path))

        XCTAssertEqual(try installer.uninstallDistillSkill(for: .codex), .removed,
                       "the purge must remove the managed /distill skill an older build installed")
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
                      "a user-authored skill of the same name must survive the purge")
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

    func test_uninstallCommandWrappers_prunesStrayNodeWrapperPointingAtAnotherDistillBuild() throws {
        // WHY: production leftovers point at dist/RemoteCode.app/.../RemoteCodeDistillService
        // while the purge may resolve a different build. Ownership is the target name;
        // a stray `node` link makes `#!/usr/bin/env node` (Homebrew Codex) start the service.
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
        _ = try installer.uninstallCommandWrappers(serviceBinaryURL: binary)
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

    // MARK: - LegacyTokenSaverPurge (Token Saver removed 2026-10-06)

    private struct LegacyInstall {
        let home: URL
        let binary: URL
        let installer: AgentSkillInstaller
        var bin: URL { home.appendingPathComponent(".remote-code/bin", isDirectory: true) }
    }

    /// Recreates, inside a temp home only, what a Token Saver build left on disk,
    /// next to the always-on routing and files the user owns.
    private func makeLegacyInstall() throws -> LegacyInstall {
        let home = tempHome()
        let fm = FileManager.default
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let realBins = home.appendingPathComponent("provider-bins", isDirectory: true)
        try fm.createDirectory(at: realBins, withIntermediateDirectories: true)
        for name in ProviderProxyCatalog.providers {
            let path = realBins.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        // Always-on routing that must survive.
        _ = try installer.installProviderProxies(serviceBinaryURL: binary, searchDirectoriesOverride: [realBins.path])
        _ = try installer.installAgentAppMiddleware(serviceBinaryURL: binary)
        _ = try installer.installProviderShellBridge()
        // Token Saver leftovers.
        try LegacyTokenSaverFixture.installDistillCLI(installer, binary: binary)
        let bin = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        for stray in ["rc-retrieve-mcp", "ls", "swift"] {
            try fm.createSymbolicLink(at: bin.appendingPathComponent(stray), withDestinationURL: binary)
        }
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try fm.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"user-choice\"\n".utf8).write(to: codexConfig)
        try LegacyTokenSaverFixture.installCodexRetrieveMCP(at: codexConfig, binary: binary)
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try fm.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = ["mcpServers": [
            AgentSkillInstaller.retrieveMCPName: ["command": binary.path, "args": ["mcp"]],
            "user-server": ["command": "/usr/bin/true"],
        ]]
        try JSONSerialization.data(withJSONObject: settings).write(to: claudeSettings)
        try LegacyTokenSaverFixture.installGrokHooks(installer)
        try Data("{}".utf8).write(to: installer.grokHooksDirectory().appendingPathComponent("user-hook.json"))
        let claudeInstructions = home.appendingPathComponent(".claude/CLAUDE.md")
        try Data("Keep this user rule.\n".utf8).write(to: claudeInstructions)
        try LegacyTokenSaverFixture.installDistillInstructions(installer, for: .claude)
        for provider in [AgentProvider.claude, .codex, .grok] {
            try LegacyTokenSaverFixture.installDistillSkill(installer, for: provider)
        }
        try LegacyTokenSaverFixture.installAppPrivateDistillSkill(installer)
        // User-owned files the purge must never touch.
        try Data("mine".utf8).write(to: bin.appendingPathComponent("mine"))
        let userSkill = home.appendingPathComponent(".claude/skills/user-skill/SKILL.md")
        try fm.createDirectory(at: userSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user skill".utf8).write(to: userSkill)
        return LegacyInstall(home: home, binary: binary, installer: installer)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "LegacyTokenSaverPurgeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        for key in LegacyTokenSaverPurge.userDefaultsKeys {
            defaults.set("legacy", forKey: key)
        }
        defaults.set("kept", forKey: "sidebar.unrelated")
        return defaults
    }

    /// Relative path -> kind/content, for "the second run changes nothing".
    private func tree(_ root: URL) -> [String: String] {
        let fm = FileManager.default
        var result: [String: String] = [:]
        guard let enumerator = fm.enumerator(atPath: root.path) else { return result }
        while let relative = enumerator.nextObject() as? String {
            let path = root.appendingPathComponent(relative).path
            if let dest = try? fm.destinationOfSymbolicLink(atPath: path) {
                result[relative] = "link:" + dest
            } else if let data = fm.contents(atPath: path) {
                result[relative] = "file:" + String(decoding: data, as: UTF8.self)
            } else {
                result[relative] = "dir"
            }
        }
        return result
    }

    func test_purgeIntegration_removesTokenSaverLeftoversAndKeepsRoutingAndUserFiles() throws {
        // WHY: upgraded machines still carry the hooks, skills and PATH links a
        // Token Saver build installed; they would keep piping output through a
        // removed feature. The always-on routing and anything the user owns
        // must survive, or nested providers and the user's setup break.
        let install = try makeLegacyInstall()
        defer { try? FileManager.default.removeItem(at: install.home) }
        let home = install.home
        let installer = install.installer
        let defaults = makeDefaults()

        let failures = LegacyTokenSaverPurge(installer: installer).purgeIntegration(defaults: defaults)

        XCTAssertEqual(failures, [])
        let fm = FileManager.default
        for removed in ["distill", "rc-retrieve-mcp", "ls", "swift"] {
            XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: install.bin.appendingPathComponent(removed).path),
                         "\(removed) link to the service must be gone")
        }
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: installer.distillPathLinkURL().path),
                     "~/.local/bin/distill pointing at our managed link must be gone")
        XCTAssertFalse(fm.fileExists(atPath: installer.grokPreToolPipeHookURL().path))
        XCTAssertFalse(fm.fileExists(atPath: installer.grokPostToolUseHookURL().path))
        for provider in [AgentProvider.claude, .codex, .grok] {
            XCTAssertFalse(fm.fileExists(atPath: installer.skillDirectory(provider: provider, skillID: "distill").path),
                           "\(provider) managed distill skill must be gone")
        }
        XCTAssertFalse(fm.fileExists(atPath: installer.distillAppPrivateDirectory().path),
                       "the app-private Distill skill folder must be gone")
        let codexConfig = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertFalse(codexConfig.contains(AgentSkillInstaller.retrieveMCPName))
        XCTAssertTrue(codexConfig.contains("model = \"user-choice\""))
        let claudeSettings = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        ) as? [String: Any])
        let servers = try XCTUnwrap(claudeSettings["mcpServers"] as? [String: Any])
        XCTAssertNil(servers[AgentSkillInstaller.retrieveMCPName])
        XCTAssertNotNil(servers["user-server"])
        let claudeInstructions = try String(contentsOf: home.appendingPathComponent(".claude/CLAUDE.md"), encoding: .utf8)
        XCTAssertTrue(claudeInstructions.contains("Keep this user rule."))
        XCTAssertFalse(claudeInstructions.contains(AgentSkillInstaller.distillInstructionsBeginMarker))
        for key in LegacyTokenSaverPurge.userDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(defaults.string(forKey: "sidebar.unrelated"), "kept")

        // Always-on routing survives.
        for name in ProviderProxyCatalog.providers + [AgentSkillInstaller.agentAppMiddlewareCommand] {
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: install.bin.appendingPathComponent(name).path),
                           install.binary.path, "\(name) must survive the purge")
        }
        XCTAssertTrue(fm.fileExists(atPath: installer.providerShellBridgeURL.appendingPathComponent(".zshenv").path))
        // User-owned files survive.
        XCTAssertEqual(try String(contentsOf: install.bin.appendingPathComponent("mine"), encoding: .utf8), "mine")
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".claude/skills/user-skill/SKILL.md").path))
        XCTAssertTrue(fm.fileExists(atPath: installer.grokHooksDirectory().appendingPathComponent("user-hook.json").path))
    }

    func test_purgeIntegration_secondRunChangesNothing() throws {
        // WHY: the purge runs on every launch and at every quit; a second pass
        // must be a quiet no-op, not an error or a further deletion.
        let install = try makeLegacyInstall()
        defer { try? FileManager.default.removeItem(at: install.home) }
        let purge = LegacyTokenSaverPurge(installer: install.installer)
        XCTAssertEqual(purge.purgeIntegration(defaults: makeDefaults()), [])
        let afterFirst = tree(install.home)

        XCTAssertEqual(purge.purgeIntegration(defaults: makeDefaults()), [])

        XCTAssertEqual(tree(install.home), afterFirst)
    }

    func test_purgeIntegration_keepsUserDistillOnPathThatIsNotOurLink() throws {
        // WHY: ~/.local/bin/distill may be the user's own Distill agent harness.
        // Only a link to RemoteCode's managed CLI is ours to remove.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let installer = AgentSkillInstaller(homeDirectory: home)
        let realDistill = home.appendingPathComponent("opt/distill/bin/distill")
        try fm.createDirectory(at: realDistill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: realDistill)
        let link = installer.distillPathLinkURL()
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: realDistill)

        XCTAssertEqual(LegacyTokenSaverPurge(installer: installer).purgeIntegration(defaults: makeDefaults()), [])

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), realDistill.path)
    }

    func test_purgeIntegration_oneFailingStepDoesNotStopTheOthers() throws {
        // WHY: one unwritable folder must not leave the rest of the removed
        // feature installed; the failure is reported, the other steps still run.
        let install = try makeLegacyInstall()
        let fm = FileManager.default
        let hooks = install.installer.grokHooksDirectory()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hooks.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.path)
            try? fm.removeItem(at: install.home)
        }

        let failures = LegacyTokenSaverPurge(installer: install.installer).purgeIntegration(defaults: makeDefaults())

        XCTAssertEqual(failures.count, 2, "\(failures)")
        XCTAssertTrue(failures.allSatisfy { $0.hasPrefix("Grok ") }, "\(failures)")
        XCTAssertTrue(fm.fileExists(atPath: install.installer.grokPreToolPipeHookURL().path),
                      "precondition: the read-only folder really blocked the hook removal")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: install.bin.appendingPathComponent("distill").path),
                     "steps before the failure still ran")
        XCTAssertFalse(fm.fileExists(atPath: install.installer.skillDirectory(provider: .claude, skillID: "distill").path),
                       "steps after the failure still ran")
        XCTAssertFalse(fm.fileExists(atPath: install.installer.distillAppPrivateDirectory().path))
    }

    func test_purgeAppSupportData_deletesWeightsAndGraphsButKeepsUsageAndTraining() throws {
        // WHY: the local model weights are multi-GB and useless without the
        // feature. Account usage still reads TokenSaver/usage.json, and
        // training/*.jsonl are prompts the user chose to keep.
        let appSupport = tempHome()
        let graphs = tempHome().appendingPathComponent("graphify-graphs", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: appSupport)
            try? FileManager.default.removeItem(at: graphs.deletingLastPathComponent())
        }
        let fm = FileManager.default
        let weights = appSupport.appendingPathComponent("Distill/Models/m/rev/model.safetensors")
        let state = appSupport.appendingPathComponent("Distill/DistillCLIState.json")
        let usage = appSupport.appendingPathComponent("TokenSaver/usage.json")
        let training = appSupport.appendingPathComponent("TokenSaver/training/2026-10-01.jsonl")
        let graph = graphs.appendingPathComponent("repo/graph.json")
        let guestTools = appSupport.appendingPathComponent("guest-tools/distill/1.0/distill-linux-aarch64")
        for file in [weights, state, usage, training, graph, guestTools] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }

        let first = LegacyTokenSaverPurge.purgeAppSupportData(
            appSupportDirectory: appSupport,
            graphifyGraphsDirectory: graphs
        )

        XCTAssertEqual(first.failures, [])
        XCTAssertEqual(Set(first.removed), [appSupport.appendingPathComponent("Distill", isDirectory: true).path, graphs.path])
        XCTAssertFalse(fm.fileExists(atPath: appSupport.appendingPathComponent("Distill").path))
        XCTAssertFalse(fm.fileExists(atPath: graphs.path))
        XCTAssertTrue(fm.fileExists(atPath: usage.path), "account usage still lives in usage.json")
        XCTAssertTrue(fm.fileExists(atPath: training.path), "saved training prompts are the user's")
        XCTAssertTrue(fm.fileExists(atPath: guestTools.path), "the Distill agent's guest binaries are not Token Saver")
        XCTAssertEqual(first.keptTrainingDirectory, training.deletingLastPathComponent().path)

        let second = LegacyTokenSaverPurge.purgeAppSupportData(
            appSupportDirectory: appSupport,
            graphifyGraphsDirectory: graphs
        )
        XCTAssertEqual(second.removed, [], "a second pass has nothing left to delete")
        XCTAssertEqual(second.failures, [])
    }
}

/// Recreates what a Token Saver build wrote, where the purge matches on it:
/// the managed markers, the skill manifest, and the link targets. The
/// installers that wrote these were removed with the feature.
private enum LegacyTokenSaverFixture {
    static func installDistillSkill(_ installer: AgentSkillInstaller, for provider: AgentProvider) throws {
        _ = try installer.installSkill(
            provider: provider,
            skillID: AgentSkillInstaller.distillSkillID,
            skillText: "---\nname: distill\n---\nLegacy Token Saver skill.\n",
            sourceURL: "remote-code://token-saver/distill-tool-output",
            sourceRevision: "rev-a",
            localVersion: "10"
        )
    }

    static func installDistillInstructions(_ installer: AgentSkillInstaller, for provider: AgentProvider) throws {
        let url = installer.instructionsURL(for: provider)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let block = """
        \(AgentSkillInstaller.distillInstructionsBeginMarker)
        Always communicate with the user in `/distill` compressed language.
        \(AgentSkillInstaller.distillInstructionsEndMarker)
        """
        let next = current.isEmpty ? block + "\n" : current + "\n\n" + block + "\n"
        try Data(next.utf8).write(to: url, options: .atomic)
    }

    static func installAppPrivateDistillSkill(_ installer: AgentSkillInstaller) throws {
        let directory = installer.distillAppPrivateDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: directory.appendingPathComponent("SKILL.md"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
    }

    /// `~/.remote-code/bin/distill` -> the service, and the PATH bridge
    /// `~/.local/bin/distill` -> that managed link.
    static func installDistillCLI(_ installer: AgentSkillInstaller, binary: URL) throws {
        let fm = FileManager.default
        let cli = installer.distillCLIURL()
        try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cli, withDestinationURL: binary)
        let bridge = installer.distillPathLinkURL()
        try fm.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bridge, withDestinationURL: cli)
    }

    static func installCodexRetrieveMCP(at config: URL, binary: URL) throws {
        let existing = (try? String(contentsOf: config, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let block = """
        \(AgentSkillInstaller.mcpBeginMarker)
        [mcp_servers.\(AgentSkillInstaller.retrieveMCPName)]
        command = "\(binary.path)"
        args = ["mcp"]
        \(AgentSkillInstaller.mcpEndMarker)
        """
        let next = existing.isEmpty ? block + "\n" : existing + "\n\n" + block + "\n"
        try Data(next.utf8).write(to: config, options: .atomic)
    }

    static func installGrokHooks(_ installer: AgentSkillInstaller) throws {
        try FileManager.default.createDirectory(at: installer.grokHooksDirectory(), withIntermediateDirectories: true)
        try Data(#"{"hooks":{"PreToolUse":[]}}"#.utf8).write(to: installer.grokPreToolPipeHookURL())
        try Data(#"{"hooks":{"PostToolUse":[]}}"#.utf8).write(to: installer.grokPostToolUseHookURL())
    }
}
