import XCTest
import CoreModel
@testable import AgentRuntime

final class ProviderProxyInstallTests: XCTestCase {
    private func tempHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ProviderProxy-\(UUID().uuidString)", isDirectory: true)
    }

    private func fakeServiceBinary(in home: URL) throws -> URL {
        let binary = home.appendingPathComponent("fake/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    private func fakeProviderBins(in home: URL, names: [String]) throws -> URL {
        let dir = home.appendingPathComponent("provider-bins", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let path = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        return dir
    }

    func test_installProviderProxies_symlinksAllThreeWhenRealBinsExist() throws {
        // WHY: nested shell `grok|claude|codex` must resolve to the controller for every provider.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ProviderProxyCatalog.providers)
        let installer = AgentSkillInstaller(homeDirectory: home)

        let installed = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        XCTAssertEqual(Set(installed), Set(ProviderProxyCatalog.providers))
        for name in ProviderProxyCatalog.providers {
            let link = home.appendingPathComponent(".remote-code/bin/\(name)")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), binary.path)
        }
        // Idempotent
        XCTAssertEqual(
            Set(try installer.installProviderProxies(
                serviceBinaryURL: binary,
                searchDirectoriesOverride: [realBins.path]
            )),
            Set(installed)
        )
    }

    func test_installAgentAppMiddleware_installsOwnershipSafeRemoteCodeAlias() throws {
        // WHY: orchestrators need one provider-neutral command that always
        // enters the host Agent App pipeline.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)

        let installed = try XCTUnwrap(installer.installAgentAppMiddleware(serviceBinaryURL: binary))
        XCTAssertEqual(installed.lastPathComponent, "remote-code")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: installed.path),
            binary.path
        )
        XCTAssertEqual(
            try installer.installAgentAppMiddleware(serviceBinaryURL: binary),
            installed,
            "reconcile must be idempotent"
        )

        let replacement = home
            .appendingPathComponent("Replacement", isDirectory: true)
            .appendingPathComponent("RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: replacement.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: replacement.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: replacement.path
        )
        XCTAssertNil(
            try installer.installAgentAppMiddleware(serviceBinaryURL: replacement),
            "a same-basename target is not proof that RemoteCode owns the existing alias"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: installed.path),
            binary.path,
            "an alias whose canonical target differs from the expected service must be preserved"
        )
    }

    func test_installAgentAppMiddleware_preservesUserOwnedSymlink() throws {
        // WHY: reconciling a new bundle must never hijack an unrelated command
        // the user placed under the same managed directory.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let binDirectory = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true
        )
        let link = binDirectory.appendingPathComponent("remote-code")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/usr/local/bin/user-remote-code"
        )

        XCTAssertNil(try installer.installAgentAppMiddleware(serviceBinaryURL: binary))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            "/usr/local/bin/user-remote-code"
        )
    }

    func test_installProviderProxies_neverShadowsMissingProvider() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        // Only codex exists as a real CLI.
        let realBins = try fakeProviderBins(in: home, names: ["codex"])
        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        XCTAssertEqual(installed, ["codex"])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: home.appendingPathComponent(".remote-code/bin/grok").path
        ))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: home.appendingPathComponent(".remote-code/bin/claude").path
        ))
    }

    func test_installProviderProxies_neverClobbersUserOwnedRegularFile() throws {
        // WHY: ownership-safe install must leave a user file in managed bin untouched.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ["grok"])
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let userFile = binDir.appendingPathComponent("grok")
        try Data("user owned\n".utf8).write(to: userFile)

        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        XCTAssertFalse(installed.contains("grok"))
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "user owned\n")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: userFile.path))
    }

    func test_installProviderProxies_repairsManagedAliasFromRenamedRemoteCodeBundle() throws {
        // WHY: E2E/canary app products use names such as RemoteCodeRCW1Test.app.
        // A new live bundle must reclaim all managed aliases from that old build.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let activeBinary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ProviderProxyCatalog.providers)
        let oldContents = home
            .appendingPathComponent("RemoteCodeRCW1Test.app/Contents", isDirectory: true)
        let oldBinary = oldContents
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: oldBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old service".utf8).write(to: oldBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: oldBinary.path
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "io.remotecode.desktop.debug",
            "CFBundleExecutable": "RemoteCode",
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: oldContents.appendingPathComponent("Info.plist"))

        let installer = AgentSkillInstaller(homeDirectory: home)
        let managedBin = installer.managedCLIBinURL
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        for name in ProviderProxyCatalog.providers + [AgentSkillInstaller.agentAppMiddlewareCommand] {
            try FileManager.default.createSymbolicLink(
                at: managedBin.appendingPathComponent(name),
                withDestinationURL: oldBinary
            )
        }

        let installed = try installer.installProviderProxies(
            serviceBinaryURL: activeBinary,
            searchDirectoriesOverride: [realBins.path]
        )
        let agentApp = try XCTUnwrap(
            installer.installAgentAppMiddleware(serviceBinaryURL: activeBinary)
        )

        XCTAssertEqual(Set(installed), Set(ProviderProxyCatalog.providers))
        XCTAssertEqual(agentApp, managedBin.appendingPathComponent("remote-code"))
        for name in ProviderProxyCatalog.providers + [AgentSkillInstaller.agentAppMiddlewareCommand] {
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: managedBin.appendingPathComponent(name).path
                ),
                activeBinary.path
            )
        }
    }

    func test_installProviderProxies_repairsDanglingAliasFromRemovedCanonicalBundle() throws {
        // WHY: an app upgrade may remove the old canonical RemoteCode.app
        // before reconciliation; its now-dangling managed aliases must heal.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let activeBinary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ProviderProxyCatalog.providers)
        let removedBinary = home
            .appendingPathComponent("old/RemoteCode.app/Contents/MacOS")
            .appendingPathComponent("RemoteCodeDistillService")
        let installer = AgentSkillInstaller(homeDirectory: home)
        let managedBin = installer.managedCLIBinURL
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        for name in ProviderProxyCatalog.providers + [AgentSkillInstaller.agentAppMiddlewareCommand] {
            try FileManager.default.createSymbolicLink(
                at: managedBin.appendingPathComponent(name),
                withDestinationURL: removedBinary
            )
        }

        let installed = try installer.installProviderProxies(
            serviceBinaryURL: activeBinary,
            searchDirectoriesOverride: [realBins.path]
        )
        let agentApp = try XCTUnwrap(
            installer.installAgentAppMiddleware(serviceBinaryURL: activeBinary)
        )

        XCTAssertEqual(Set(installed), Set(ProviderProxyCatalog.providers))
        XCTAssertEqual(agentApp, managedBin.appendingPathComponent("remote-code"))
        for name in ProviderProxyCatalog.providers + [AgentSkillInstaller.agentAppMiddlewareCommand] {
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: managedBin.appendingPathComponent(name).path
                ),
                activeBinary.path
            )
        }
    }

    func test_installProviderProxies_preservesLookalikeAppWithForeignBundleIdentifier() throws {
        // WHY: an .app-shaped path and service basename alone are not proof that
        // RemoteCode owns a user's symlink in the managed directory.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let activeBinary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ["grok"])
        let foreignContents = home
            .appendingPathComponent("RemoteCodeLookalike.app/Contents", isDirectory: true)
        let foreignBinary = foreignContents
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: foreignBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("foreign service".utf8).write(to: foreignBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: foreignBinary.path
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.lookalike"],
            format: .xml,
            options: 0
        )
        try plist.write(to: foreignContents.appendingPathComponent("Info.plist"))

        let installer = AgentSkillInstaller(homeDirectory: home)
        let link = installer.managedCLIBinURL.appendingPathComponent("grok")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreignBinary)

        XCTAssertFalse(
            try installer.installProviderProxies(
                serviceBinaryURL: activeBinary,
                searchDirectoriesOverride: [realBins.path]
            ).contains("grok")
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            foreignBinary.path
        )
    }

    func test_providerProxyPreservesAndDoesNotAdvertiseForeignSameBasenameSymlink() throws {
        // WHY: executable basename is attacker-controlled and is not ownership
        // evidence for installing, advertising, or removing a provider proxy.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ["grok"])
        let foreign = home.appendingPathComponent("foreign/RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: foreign.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("foreign".utf8).write(to: foreign)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: foreign.path
        )

        let link = home.appendingPathComponent(".remote-code/bin/grok")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)

        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        XCTAssertFalse(installed.contains("grok"))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            foreign.path
        )
        XCTAssertFalse(
            try installer.uninstallProviderProxies(serviceBinaryURL: binary).contains("grok")
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            foreign.path
        )
    }

    func test_uninstallProviderProxies_removesOnlyOurSymlinks() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ProviderProxyCatalog.providers)
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        // User-owned regular file next to our links must survive uninstall.
        let userFile = home.appendingPathComponent(".remote-code/bin/user-tool")
        try Data("keep\n".utf8).write(to: userFile)

        let removed = try installer.uninstallProviderProxies(serviceBinaryURL: binary)
        XCTAssertEqual(Set(removed), Set(ProviderProxyCatalog.providers))
        for name in ProviderProxyCatalog.providers {
            XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
                atPath: home.appendingPathComponent(".remote-code/bin/\(name)").path
            ))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
    }

    func test_uninstallCommandWrappers_doesNotRemoveProviderProxies() throws {
        // WHY: removing legacy compression wrappers must not remove the provider controller.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ["claude"])
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        // Also plant a compression wrapper.
        let lsLink = home.appendingPathComponent(".remote-code/bin/ls")
        try FileManager.default.createSymbolicLink(at: lsLink, withDestinationURL: binary)

        _ = try installer.uninstallCommandWrappers(serviceBinaryURL: binary)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: lsLink.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: home.appendingPathComponent(".remote-code/bin/claude").path
            ),
            binary.path,
            "provider proxy must survive legacy wrapper uninstall"
        )
    }

    func test_processLocator_skipsManagedProviderProxyForMainLaunch() throws {
        // WHY: top-level Agent App turns must not spawn through the PATH proxy.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let managed = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        let realDir = home.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

        let proxy = managed.appendingPathComponent("codex")
        let real = realDir.appendingPathComponent("codex")
        try Data("proxy".utf8).write(to: proxy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxy.path)
        try Data("real".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        let path = "\(managed.path):\(realDir.path)"
        let resolved = ProcessLocator.resolve(
            "codex",
            environmentPath: path,
            homeDirectory: home.path
        )
        XCTAssertEqual(resolved, real.path, "ProcessLocator must skip managed provider proxy")
    }

    func test_processLocator_stillResolvesNonProviderFromManagedBin() throws {
        // WHY: managed distill/wrappers remain first for non-provider commands.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let managed = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let distill = managed.appendingPathComponent("distill")
        try Data("distill".utf8).write(to: distill)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: distill.path)

        let resolved = ProcessLocator.resolve(
            "distill",
            environmentPath: managed.path,
            homeDirectory: home.path
        )
        XCTAssertEqual(resolved, distill.path)
    }

    func test_runtimePromptAlwaysRoutesGenericCrossProviderDelegationThroughAgentApp() {
        let command = "/tmp/managed/remote-code"
        let prompt = AgentSkillInstaller.nestedAgentProviderPrompt(
            "base",
            environment: [
                "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
                "RC_REMOTE_CODE_AGENT_APP_COMMAND": command
            ]
        )

        XCTAssertTrue(prompt.contains("REMOTE_CODE_SUBAGENT_ROUTING_V1"))
        XCTAssertTrue(prompt.contains(command))
        XCTAssertTrue(prompt.contains("agent-app <codex|claude|grok>"))
        XCTAssertFalse(prompt.contains("TOKEN_SAVER_SAFETY_ABI"),
                       "subagent routing carries no Token Saver text")
    }

    func test_providerProxyInjectsRuntimeIntoAllProvidersWithoutDroppingSkillABI() {
        let environment = [
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
            "RC_REMOTE_CODE_AGENT_APP_COMMAND": "/tmp/remote-code",
            "RC_TOKEN_SAVER_DISTILL_HINT": "1"
        ]
        let grokABI = [
            "--prompt-file", "/tmp/grok-prompt",
            "--no-memory", "--no-subagents",
            "--disallowed-tools", "Agent", "--no-auto-update"
        ]
        let claudeABI = [
            "--print", "--permission-mode", "plan",
            "--tools", "Read,Glob,Grep", "--no-session-persistence",
            "--mcp-config", #"{"mcpServers":{"remotecode-bot-self-config":{"command":"RemoteCodeDistillService"}}}"#
        ]
        let codexABI = [
            "exec", "--strict-config", "--ephemeral", "--ignore-user-config",
            "--sandbox", "read-only", "-"
        ]

        let grok = AgentSkillInstaller.providerProxyArguments(
            provider: .grok, arguments: grokABI, environment: environment
        )
        let claude = AgentSkillInstaller.providerProxyArguments(
            provider: .claude, arguments: claudeABI, environment: environment
        )
        let codex = AgentSkillInstaller.providerProxyArguments(
            provider: .codex, arguments: codexABI, environment: environment
        )

        XCTAssertEqual(Array(grok.prefix(grokABI.count)), grokABI)
        XCTAssertEqual(Array(claude.prefix(claudeABI.count)), claudeABI)
        XCTAssertTrue(codex.suffix(codexABI.count).elementsEqual(codexABI))
        XCTAssertTrue(grok.contains("--rules"))
        XCTAssertTrue(claude.contains("--append-system-prompt"))
        XCTAssertEqual(Array(codex.prefix(1)), ["--config"])
        for arguments in [grok, claude, codex] {
            XCTAssertTrue(arguments.joined(separator: "\n").contains("REMOTE_CODE_SUBAGENT_ROUTING_V1"))
            XCTAssertFalse(arguments.joined(separator: "\n").contains("TOKEN_SAVER_SAFETY_ABI_V1"),
                           "a leftover Token Saver hint must not bring back the safety ABI")
            XCTAssertFalse(arguments.joined(separator: "\n").contains("| distill"),
                           "a leftover Token Saver hint must not bring back the Distill rules")
        }
    }

    func test_providerProxyNeverInjectsAdministrativeOrVersionInvocations() {
        // WHY: provider proxies also sit in front of login/status/update flows.
        // Turning inherited routing on must not change those command ABIs.
        let environment = [
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
            "RC_REMOTE_CODE_AGENT_APP_COMMAND": "/tmp/remote-code",
            "RC_TOKEN_SAVER_DISTILL_HINT": "1"
        ]
        let invocations: [(AgentProvider, [String])] = [
            (.grok, ["auth", "status"]),
            (.grok, ["auth", "--prompt-file", "/tmp/p"]),
            (.grok, ["--version"]),
            (.grok, ["--prompt-file", "/tmp/p", "--version"]),
            (.grok, ["--prompt-file", "/tmp/p", "--resume", "session-id"]),
            (.grok, ["--prompt-file", ""]),
            (.claude, ["auth", "status"]),
            (.claude, ["mcp", "--print"]),
            (.claude, ["--version"]),
            (.claude, ["--print", "--version"]),
            (.claude, ["--print", "--resume", "session-id"]),
            (.codex, ["login"]),
            (.codex, ["status"]),
            (.codex, ["mcp", "list"]),
            (.codex, ["exec", "--version"]),
            (.codex, ["exec", "resume", "session-id"])
        ]

        for (provider, original) in invocations {
            XCTAssertEqual(
                AgentSkillInstaller.providerProxyArguments(
                    provider: provider,
                    arguments: original,
                    environment: environment
                ),
                original,
                "\(provider.rawValue) administrative argv must remain unchanged"
            )
        }
    }

    func test_providerProxyMergesOnlyBeforeArgumentTerminator() throws {
        // WHY: values after `--` are prompt/user data, not provider options.
        // Runtime guidance must be inserted before the terminator without
        // reading or rewriting lookalike flags after it.
        let environment = [
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
            "RC_REMOTE_CODE_AGENT_APP_COMMAND": "/tmp/remote-code"
        ]
        let cases: [(AgentProvider, [String], String)] = [
            (.grok, [
                "--prompt-file", "/tmp/grok-prompt", "--",
                "--rules", "user prompt data"
            ], "--rules"),
            (.claude, [
                "--print", "--",
                "--append-system-prompt", "user prompt data"
            ], "--append-system-prompt"),
            (.codex, [
                "exec", "--",
                "--config", "developer_instructions=user prompt data"
            ], "--config")
        ]

        for (provider, original, injectedOption) in cases {
            let rewritten = AgentSkillInstaller.providerProxyArguments(
                provider: provider,
                arguments: original,
                environment: environment
            )
            let originalTerminator = try XCTUnwrap(original.firstIndex(of: "--"))
            let rewrittenTerminator = try XCTUnwrap(rewritten.firstIndex(of: "--"))
            XCTAssertEqual(
                Array(rewritten[rewrittenTerminator...]),
                Array(original[originalTerminator...]),
                "\(provider.rawValue) data after -- must be byte-stable"
            )
            XCTAssertTrue(rewritten[..<rewrittenTerminator].contains(injectedOption))
            XCTAssertTrue(
                rewritten[..<rewrittenTerminator]
                    .joined(separator: "\n")
                    .contains("REMOTE_CODE_SUBAGENT_ROUTING_V1")
            )
        }
    }

    func test_providerProxyDoesNotTreatOptionValuesOrPostTerminatorDataAsFlags() {
        // WHY: option-looking user data must never activate or absorb runtime
        // injection. The scanner consumes known option values and stops at `--`.
        let environment = [
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
            "RC_REMOTE_CODE_AGENT_APP_COMMAND": "/tmp/remote-code"
        ]
        let unsupported: [(AgentProvider, [String])] = [
            (.grok, ["--rules", "--prompt-file"]),
            (.grok, ["--", "--prompt-file", "/tmp/p"]),
            (.claude, ["--tools", "--print"]),
            (.claude, ["--", "--print"]),
            (.codex, ["--model", "exec", "status"]),
            (.codex, ["--", "exec"])
        ]
        for (provider, original) in unsupported {
            XCTAssertEqual(
                AgentSkillInstaller.providerProxyArguments(
                    provider: provider,
                    arguments: original,
                    environment: environment
                ),
                original
            )
        }

        let claude = [
            "--print", "--tools", "--append-system-prompt"
        ]
        let rewritten = AgentSkillInstaller.providerProxyArguments(
            provider: .claude,
            arguments: claude,
            environment: environment
        )
        XCTAssertEqual(Array(rewritten.prefix(claude.count)), claude)
        XCTAssertEqual(
            rewritten.filter { $0 == "--append-system-prompt" }.count,
            2,
            "the tools value is data; runtime must add a distinct prompt option"
        )
    }

    func test_providerProxyFailsClosedForUnknownOrAmbiguousOptions() {
        // WHY: an unknown future option may consume the next argv member. Any
        // rewrite could then attach guidance to a different turn or prompt.
        let environment = [
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
            "RC_REMOTE_CODE_AGENT_APP_COMMAND": "/tmp/remote-code"
        ]
        let unknown: [(AgentProvider, [String])] = [
            (.grok, ["--future-option", "--prompt-file", "/tmp/p"]),
            (.claude, ["--print", "--future-option", "--append-system-prompt"]),
            (.codex, ["exec", "--future-option", "--config", "developer_instructions=x", "-"])
        ]
        for (provider, original) in unknown {
            XCTAssertEqual(
                AgentSkillInstaller.providerProxyArguments(
                    provider: provider,
                    arguments: original,
                    environment: environment
                ),
                original,
                "\(provider.rawValue) unknown argv must remain byte-for-byte unchanged"
            )
        }

        let ambiguous: [(AgentProvider, [String])] = [
            (.grok, [
                "--prompt-file", "/tmp/p",
                "--rules", "first", "--rules", "second"
            ]),
            (.claude, [
                "--print",
                "--append-system-prompt", "first",
                "--append-system-prompt", "second"
            ])
        ]
        for (provider, original) in ambiguous {
            XCTAssertEqual(
                AgentSkillInstaller.providerProxyArguments(
                    provider: provider,
                    arguments: original,
                    environment: environment
                ),
                original,
                "\(provider.rawValue) duplicate prompt options are ambiguous and must not be rewritten"
            )
        }
    }

    func test_subagentTelemetryScopeKeepsHierarchyFromAlwaysOnKeys() throws {
        // WHY: Subagents is lifecycle UI, not a paid optimization. A raw custom
        // worker must attach to its real controller using only always-on keys.
        let thread = UUID()
        let root = UUID()
        let scope = try XCTUnwrap(
            RemoteCodeSubagentTelemetryScope(environment: [
                "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": thread.uuidString,
                "RC_REMOTE_CODE_ROOT_RUN_ID": root.uuidString
            ])
        )

        XCTAssertEqual(scope.threadId, AgentThreadID(thread))
        XCTAssertEqual(scope.parentRunId, AgentRunID(root))
        XCTAssertEqual(scope.parentThreadId, AgentThreadID(thread))
    }

    func test_subagentTelemetryScopePrefersAlwaysOnRootOverPaidFallback() throws {
        let thread = UUID()
        let alwaysOnRoot = UUID()
        let stalePaidRoot = UUID()
        let scope = try XCTUnwrap(
            RemoteCodeSubagentTelemetryScope(environment: [
                "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": thread.uuidString,
                "RC_REMOTE_CODE_ROOT_RUN_ID": alwaysOnRoot.uuidString,
                "RC_TOKEN_SAVER_ROOT_RUN_ID": stalePaidRoot.uuidString,
                "RC_TOKEN_SAVER_ATTEMPT_ID": stalePaidRoot.uuidString
            ])
        )

        XCTAssertEqual(scope.parentRunId, AgentRunID(alwaysOnRoot))
        XCTAssertEqual(scope.parentThreadId, AgentThreadID(thread))
    }

    func test_managedZshBridgeFollowsUserZDOTDIRRedirectAndRestoresProviderProxyPath() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let managedBin = home.appendingPathComponent(".remote-code/bin").path
        let originalZDOTDIR = home.appendingPathComponent("original", isDirectory: true)
        let redirectedZDOTDIR = home.appendingPathComponent("redirected", isDirectory: true)
        let logoutCapture = home.appendingPathComponent("logout-zdotdir.txt")
        try FileManager.default.createDirectory(
            at: originalZDOTDIR,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: redirectedZDOTDIR.appendingPathComponent("profile-bin"),
            withIntermediateDirectories: true
        )
        try Data(
            """
            export ZDOTDIR="\(redirectedZDOTDIR.path)"
            export RC_BRIDGE_ZSHENV_LOADED=1
            """.utf8
        ).write(to: originalZDOTDIR.appendingPathComponent(".zshenv"))
        try Data(
            """
            export RC_BRIDGE_ZPROFILE_LOADED=1
            export PATH="\(redirectedZDOTDIR.path)/profile-bin:/usr/bin:/bin"
            """.utf8
        ).write(to: redirectedZDOTDIR.appendingPathComponent(".zprofile"))
        try Data(
            "print -r -- \"$ZDOTDIR\" > \"\(logoutCapture.path)\"\n".utf8
        ).write(to: redirectedZDOTDIR.appendingPathComponent(".zlogout"))

        let bridge = try installer.installProviderShellBridge()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bridge.appendingPathComponent(".zlogout").path),
            "login-shell teardown must preserve the user's .zlogout contract"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lic",
            "print -r -- \"${RC_BRIDGE_ZSHENV_LOADED:-0}|${RC_BRIDGE_ZPROFILE_LOADED:-0}|$ZDOTDIR|$PATH\""
        ]
        process.environment = [
            "HOME": home.path,
            "PATH": managedBin + ":/usr/bin:/bin",
            "ZDOTDIR": bridge.path,
            "RC_REMOTE_CODE_ORIGINAL_ZDOTDIR": originalZDOTDIR.path,
            "RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR": originalZDOTDIR.path,
            "RC_REMOTE_CODE_MANAGED_ZDOTDIR": bridge.path,
            "RC_REMOTE_CODE_MANAGED_BIN": managedBin
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let result = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(result?.hasPrefix("1|1|\(bridge.path)|\(managedBin):") == true,
                      "login profiles may mutate PATH, but managed provider proxies must win afterward")
        XCTAssertTrue(result?.contains(redirectedZDOTDIR.appendingPathComponent("profile-bin").path) == true,
                      "a ZDOTDIR redirect from .zshenv must select the redirected login profile")
        XCTAssertEqual(
            try String(contentsOf: logoutCapture, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            redirectedZDOTDIR.path,
            "the user .zlogout must run with the effective redirected ZDOTDIR"
        )
    }

    func test_verifiedAgentAppMiddlewareRejectsMissingAndForeignAliases() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let service = home.appendingPathComponent("RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: service)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: service.path
        )

        XCTAssertNil(installer.verifiedAgentAppMiddlewareURL(serviceBinaryURL: service))
        let link = try XCTUnwrap(
            try installer.installAgentAppMiddleware(serviceBinaryURL: service)
        )
        XCTAssertEqual(
            installer.verifiedAgentAppMiddlewareURL(serviceBinaryURL: service),
            link
        )

        let foreign = home.appendingPathComponent("foreign/RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: foreign.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: foreign)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: foreign.path
        )
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)

        XCTAssertNil(
            installer.verifiedAgentAppMiddlewareURL(serviceBinaryURL: service),
            "a same-named foreign executable is not a managed RemoteCode launcher"
        )
    }

    func test_managedProviderAndAgentAppAliasesRepairRecognizedRelocatedBuildTargets() throws {
        // WHY: isolated builds and app upgrades relocate the native service. A
        // still-executable old RemoteCode target previously blocked all Agent App
        // delegation while ordinary turns appeared healthy.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let oldService = home
            .appendingPathComponent("old/.build/debug/RemoteCodeDistillService")
        let activeService = home
            .appendingPathComponent("new/RemoteCode.app/Contents/MacOS/RemoteCodeDistillService")
        for service in [oldService, activeService] {
            try FileManager.default.createDirectory(
                at: service.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: service)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: service.path
            )
        }
        let managedBin = installer.managedCLIBinURL
        let realProviderBin = home.appendingPathComponent("real-provider-bin")
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realProviderBin, withIntermediateDirectories: true)
        for name in ["claude", "codex", "grok"] {
            let realProvider = realProviderBin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: realProvider)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: realProvider.path
            )
        }
        for name in ["claude", "codex", "grok", AgentSkillInstaller.agentAppMiddlewareCommand] {
            try FileManager.default.createSymbolicLink(
                at: managedBin.appendingPathComponent(name),
                withDestinationURL: oldService
            )
        }

        let installed = try installer.installProviderProxies(
            serviceBinaryURL: activeService,
            searchDirectoriesOverride: [realProviderBin.path]
        )
        let agentApp = try XCTUnwrap(
            try installer.installAgentAppMiddleware(serviceBinaryURL: activeService)
        )

        XCTAssertEqual(agentApp, managedBin.appendingPathComponent("remote-code"))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: agentApp.path),
            activeService.path
        )
        XCTAssertEqual(Set(installed), Set(["claude", "codex", "grok"]))
        for provider in installed {
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: managedBin.appendingPathComponent(provider).path
                ),
                activeService.path,
                "\(provider) must follow the active artifact"
            )
        }
    }
}
