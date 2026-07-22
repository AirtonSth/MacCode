import XCTest
@testable import AppShell
@testable import CoreModel
@testable import AgentRuntime
@testable import Persistence
@testable import SocketServer
@testable import Surfaces

@MainActor
final class ProviderSnapshotRuntimeTests: XCTestCase {
    private static let ownershipLedger = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-snapshot-tests-\(UUID().uuidString).json")

    override func setUp() {
        super.setUp()
        ProviderProcessOwnership.shared.configure(fileURL: Self.ownershipLedger)
    }

    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    /// WHY: Auto admission and sudo -u spawn must resolve the same Claude binary
    /// for a foreign run-as-user (Settings absolute path + target home).
    func test_resolveProviderBinaryPathUsesForeignRunAsUserHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-runas-probe-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = bin.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: claude.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let foreign = AgentRunAsUser(
            generatedUID: "test-foreign",
            shortName: "airtonempat",
            uid: 1501,
            gid: 20,
            homePath: root.path,
            fullName: "Airton"
        )
        // Only foreign when uid differs from process owner.
        XCTAssertNotEqual(foreign.uid, getuid())
        let path = AppCommandRouter.resolveProviderBinaryPath(binary: "claude", runAsUser: foreign)
        XCTAssertEqual(path, claude.path)
        // Absolute Settings path under another home stays usable for foreign run-as-user.
        XCTAssertEqual(
            AppCommandRouter.resolveProviderBinaryPath(binary: claude.path, runAsUser: foreign),
            claude.path
        )

        let current = AgentRunAsUser.current()
        let env = AppCommandRouter.probeEnvironment(
            base: ["PATH": "/usr/bin"],
            provider: .claude,
            runAsUser: foreign
        )
        XCTAssertEqual(env["HOME"], root.path, "foreign probe must force HOME to the target user")
        let currentEnv = AppCommandRouter.probeEnvironment(
            base: ["PATH": "/usr/bin"],
            provider: .claude,
            runAsUser: current
        )
        XCTAssertNil(currentEnv["HOME"], "current-user probe must not rewrite HOME")
    }

    func test_claudeLegacyFallbackPresentationFailsClosed() throws {
        let presentation = ClaudeProviderRuntimePresentation.resolve(
            agentSDKEnabled: false,
            probeAdvisory: "Update available."
        )

        XCTAssertEqual(presentation.interactionModes, [.default])
        XCTAssertEqual(presentation.permissionModes, [.supervised])
        let capabilities = try XCTUnwrap(presentation.capabilities)
        XCTAssertFalse(capabilities.supportsAttachments)
        XCTAssertFalse(capabilities.supportsApprovals)
        XCTAssertFalse(capabilities.supportsUserInput)
        XCTAssertTrue(capabilities.supportsStreaming,
                      "the legacy CLI still streams assistant text even though agent tools are disabled")
        XCTAssertTrue(presentation.advisory?.contains("Degraded text-only fallback") == true)
        XCTAssertTrue(presentation.advisory?.contains("Update available.") == true,
                      "degraded-state copy must preserve an independent CLI update warning")
    }

    func test_grokSkillsRootUsesGrokHomeAsTheConfigRoot() {
        XCTAssertEqual(
            AppCommandRouter.providerSkillsRoot(
                provider: .grok,
                environment: ["GROK_HOME": "/opt/team-grok", "HOME": "/Users/example"],
                defaultHome: "/Users/fallback"
            ).path,
            "/opt/team-grok/skills",
            "GROK_HOME already names the Grok config root; appending .grok again makes configured skills unreachable"
        )
    }

    func test_grokSkillsRootFallsBackToHomeDotGrok() {
        XCTAssertEqual(
            AppCommandRouter.providerSkillsRoot(
                provider: .grok,
                environment: ["HOME": "/Users/example"],
                defaultHome: "/Users/fallback"
            ).path,
            "/Users/example/.grok/skills",
            "without GROK_HOME, Grok skills must follow the CLI default under HOME/.grok/skills"
        )
    }

    func test_providerSnapshotsAdvertiseForkOnlyWhenExactProviderProtocolProbesPass() async throws {
        // WHY: generic provider capabilities or the presence of thread/fork are
        // insufficient. The selected Codex executable must prove marker, list,
        // parent-attribution, and delete compensation schema before UI exposure.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router

        var probedBinary = ""
        var probedEnvironment: [String: String] = [:]
        router.codexForkProtocolSupportProbe = { binary, environment in
            probedBinary = binary
            probedEnvironment = environment
            return true
        }
        router.claudeForkProtocolSupportProbe = { true }
        let supported = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(supported.first { $0.provider == .codex })
        XCTAssertTrue(codex.effectiveCapabilities.supportsFork)
        XCTAssertTrue(codex.slashCommands.contains("/fork"))
        XCTAssertEqual(probedBinary, codex.binaryPath ?? "",
                       "fork support must be probed against the exact executable advertised by the snapshot")
        XCTAssertEqual(probedEnvironment, [:])
        let claude = try XCTUnwrap(supported.first { $0.provider == .claude })
        XCTAssertTrue(claude.effectiveCapabilities.supportsFork,
                      "Claude fork is exposed only after the pinned bridge and installed SDK declaration probe succeeds")
        XCTAssertFalse(try XCTUnwrap(supported.first { $0.provider == .grok }).effectiveCapabilities.supportsFork)

        router.codexForkProtocolSupportProbe = { _, _ in false }
        router.claudeForkProtocolSupportProbe = { false }
        let unsupported = await router.listAgentProviderSnapshots()
        let oldCodex = try XCTUnwrap(unsupported.first { $0.provider == .codex })
        XCTAssertFalse(oldCodex.effectiveCapabilities.supportsFork,
                       "older or partial Codex schemas must fail closed")
        XCTAssertFalse(oldCodex.slashCommands.contains("/fork"))
        let oldClaude = try XCTUnwrap(unsupported.first { $0.provider == .claude })
        XCTAssertFalse(oldClaude.effectiveCapabilities.supportsFork,
                       "missing or mismatched Claude SDK fork declarations must fail closed")
    }

    func test_grokProviderSnapshotAndComposerDiscoverPhysicalSkillUnderGrokHome() async throws {
        // WHY: GROK_HOME already is Grok's config root. A path-only assertion
        // misses regressions where discovery or composer plumbing still reads
        // GROK_HOME/.grok/skills or labels a Grok skill as Codex-owned.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let grokHome = dir.appendingPathComponent("grok-home", isDirectory: true)
        let skillDir = grokHome.appendingPathComponent("skills/team-research", isDirectory: true)
        let wrongSkillDir = grokHome.appendingPathComponent(".grok/skills/wrong-root", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrongSkillDir, withIntermediateDirectories: true)
        try "# Team Research\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# Wrong Root\n".write(to: wrongSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let fakeGrok = dir.appendingPathComponent("fake-grok")
        try #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'grok-test 0.2.101\n'
          exit 0
        fi
        if [ "$1" = "models" ]; then
          printf 'You are logged in with test\n'
          exit 0
        fi
        if [ "$1" = "agent" ] && [ "$2" = "stdio" ]; then
          while IFS= read -r line; do
            id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
            if printf '%s' "$line" | grep -q '"method":"initialize"'; then
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"embeddedContext":true}}}}\n' "$id"
            elif printf '%s' "$line" | grep -q '"method":"session.*new"'; then
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"skills-session","models":{"currentModelId":"grok-4.5","availableModels":[{"modelId":"grok-4.5","name":"Grok 4.5"}]}}}\n' "$id"
            fi
          done
          exit 0
        fi
        exit 1
        """#.write(to: fakeGrok, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGrok.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "grok-team",
            "provider": "grok",
            "displayName": "Grok Team",
            "binaryPath": "\(fakeGrok.path)",
            "homePath": "\(grokHome.path)",
            "enabled": true
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let grok = try XCTUnwrap(snapshots.first { $0.id == "grok-team" })
        XCTAssertEqual(grok.environmentKeys, ["GROK_HOME"])
        XCTAssertEqual(grok.skills, ["team-research"],
                       "only <GROK_HOME>/skills must feed Grok composer skills")

        let suggestions = AgentComposerSuggestions.suggestions(
            for: "$team-r",
            snapshot: grok,
            localSlashCommands: []
        )
        XCTAssertEqual(suggestions.map(\.insertText), ["$team-research "])
        XCTAssertEqual(suggestions.first?.subtitle, "Grok Team skill")
    }

    func test_grokProviderSnapshotUsesACPNegotiatedModesAndCapabilities() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeGrok = dir.appendingPathComponent("fake-grok")
        try #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'grok 9.9.9\n'
          exit 0
        fi
        if [ "$1" = "models" ]; then
          printf 'You are logged in with test\n'
          exit 0
        fi
        if [ "$1" = "agent" ] && [ "$2" = "stdio" ]; then
          while IFS= read -r line; do
            id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
            if printf '%s' "$line" | grep -q '"method":"initialize"'; then
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":true},"sessionCapabilities":{}}}}\n' "$id"
            elif printf '%s' "$line" | grep -q '"method":"session.*new"'; then
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"snapshot-session","models":{"currentModelId":"grok-negotiated","availableModels":[{"modelId":"grok-negotiated","name":"Grok Negotiated"}]},"modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"plan","name":"Plan"},{"id":"bypassPermissions","name":"Full access"}]}}}\n' "$id"
            fi
          done
          exit 0
        fi
        exit 1
        """#.write(to: fakeGrok, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGrok.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("cli.grok.path", fakeGrok.path)

        let snapshots = await router.listAgentProviderSnapshots()
        let grok = try XCTUnwrap(snapshots.first { $0.provider == .grok })

        XCTAssertEqual(grok.models.map(\.id), ["grok-negotiated"])
        XCTAssertEqual(grok.interactionModes, [.default, .plan])
        XCTAssertEqual(grok.effectivePermissionModes, [.supervised, .fullAccess])
        XCTAssertTrue(grok.effectiveCapabilities.supportsPlanReview)
        XCTAssertTrue(grok.effectiveCapabilities.supportsAttachments)
        XCTAssertTrue(grok.effectiveCapabilities.supportsApprovals)
        XCTAssertFalse(grok.effectiveCapabilities.supportsUserInput)
        XCTAssertTrue(grok.slashCommands.contains("/plan"))
        XCTAssertEqual(grok.modelDiscoverySource, .live)
        XCTAssertFalse(grok.modelListIsFallback)
        XCTAssertNotNil(grok.modelDiscoveryCacheKey,
                        "the snapshot must retain the opaque binary/account discovery identity")
    }

    func test_providerSnapshotsUseConfiguredBinaryAndExposeVersion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'codex-test 9.9.9\\n'
          exit 0
        fi
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then
          printf 'Logged in using ChatGPT\\n'
          exit 0
        fi
        exit 1
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("cli.codex.path", fakeCodex.path)

        let snapshots = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(snapshots.first { $0.provider == .codex })

        XCTAssertTrue(codex.installed)
        XCTAssertEqual(codex.version, "codex-test 9.9.9",
                       "provider cards must probe the configured binary path so settings, install state, and version state stay aligned")
        XCTAssertEqual(codex.authenticated, true,
                       "provider cards must include auth state from the configured Codex binary instead of waiting for a failed run")
    }

    func test_providerSnapshotsPreferCodexAppServerModelDiscoveryWhenAvailable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        try """
        #!/usr/bin/env python3
        import json, os, sys
        if len(sys.argv) > 1 and sys.argv[1] == "--version":
            print("codex-test 9.9.9")
            raise SystemExit(0)
        if len(sys.argv) > 2 and sys.argv[1:3] == ["login", "status"]:
            print("Logged in using ChatGPT")
            raise SystemExit(0)
        if len(sys.argv) > 1 and sys.argv[1] == "--help":
            print("Commands:\\n  exec\\n  review")
            raise SystemExit(0)
        if len(sys.argv) > 1 and sys.argv[1] == "app-server":
            for line in sys.stdin:
                msg = json.loads(line)
                method = msg.get("method")
                if method == "initialize":
                    print(json.dumps({"id": msg["id"], "result": {
                        "userAgent": "codex-test/9.9.9",
                        "codexHome": os.environ.get("CODEX_HOME"),
                        "platformFamily": "unix",
                        "platformOs": "macos"
                    }}), flush=True)
                elif method == "initialized":
                    pass
                elif method == "model/list":
                    print(json.dumps({"id": msg["id"], "result": {"data": [{
                        "model": "gpt-5.7-codex",
                        "displayName": "GPT-5.7 Codex",
                        "supportedReasoningEfforts": [
                            {"reasoningEffort": "low"},
                            {"reasoningEffort": "medium"},
                            {"reasoningEffort": "high"}
                        ],
                        "defaultReasoningEffort": "medium",
                        "additionalSpeedTiers": ["fast"],
                        "modelContextWindow": 512000
                    }]}}), flush=True)
            raise SystemExit(0)
        raise SystemExit(1)
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-dynamic",
            "provider": "codex",
            "displayName": "Codex Dynamic",
            "binaryPath": "\(fakeCodex.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(snapshots.first { $0.id == "codex-dynamic" })
        let model = try XCTUnwrap(codex.models.first)

        XCTAssertEqual(model.id, "gpt-5.7-codex",
                       "Codex provider snapshots should prefer app-server model/list discovery over static fallback models when available")
        XCTAssertEqual(model.supportedReasoningEfforts, [.low, .medium, .high])
        XCTAssertEqual(model.supportsServiceTier, true)
        XCTAssertEqual(model.contextWindowTokens, 512_000)
        XCTAssertEqual(codex.environmentKeys, ["CODEX_HOME"])
    }

    func test_providerSnapshotsCacheRuntimeProbesPerBinaryAndHome() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("codex-home", isDirectory: true)
        let skillDir = home.appendingPathComponent("skills/sam-review-code", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "# Review\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        let probeCount = dir.appendingPathComponent("probe-count")
        try """
        #!/bin/sh
        if [ "$CODEX_HOME" != "\(home.path)" ]; then
          exit 1
        fi
        if [ "$1" = "--version" ]; then
          printf 'v' >> "\(probeCount.path)"
          printf 'codex-test 9.9.9\\nUpdate available: codex-test 10.0.0\\n'
          exit 0
        fi
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then
          printf 'a' >> "\(probeCount.path)"
          printf 'Logged in using ChatGPT\\nLogged in as work@example.com\\n'
          exit 0
        fi
        if [ "$1" = "--help" ]; then
          printf 'h' >> "\(probeCount.path)"
          cat <<'EOF'
        Usage: codex [OPTIONS] <COMMAND>

        Commands:
          exec      Run Codex non-interactively
          review    Run a code review
          help      Print help
        EOF
          exit 0
        fi
        exit 1
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-work",
            "provider": "codex",
            "displayName": "Codex Work",
            "binaryPath": "\(fakeCodex.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let first = await router.listAgentProviderSnapshots()
        let second = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(second.first { $0.id == "codex-work" })

        XCTAssertEqual(codex.version, "codex-test 9.9.9")
        XCTAssertEqual(codex.updateState, "update_available")
        XCTAssertEqual(codex.advisory, "Update available: codex-test 10.0.0")
        XCTAssertEqual(codex.statusDetail, "Update available: codex-test 10.0.0")
        XCTAssertEqual(codex.authenticated, true)
        XCTAssertEqual(codex.accountLabel, "work@example.com")
        XCTAssertEqual(codex.accountAuthMethod, "ChatGPT",
                       "provider snapshots must carry richer account auth metadata through the same instance-scoped probe cache as auth labels")
        XCTAssertFalse(codex.slashCommands.contains("/review"),
                       "provider --help lists CLI subcommands, not interactive slash commands; snapshots must not surface them as composer suggestions")
        XCTAssertEqual(codex.skills, ["sam-review-code"],
                       "provider snapshots must discover Codex skills from the selected CODEX_HOME so composer suggestions reflect the active provider instance")
        let count = try String(contentsOf: probeCount, encoding: .utf8)
        XCTAssertEqual(count, "av",
                       "provider cards reload frequently; version/auth probes must be cached per binary/home, and CLI help must not be probed for slash-command suggestions")
        XCTAssertEqual(first.count, second.count)
    }

    func test_providerSnapshotsDiscoverClaudeSkillsFromInstanceHome() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("claude-home", isDirectory: true)
        let skillDir = home.appendingPathComponent(".claude/skills/team-plan", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "# Team Plan\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let fakeClaude = dir.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'claude-test 2.1.0\\n'
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          printf 'Logged in as claude@example.com\\n'
          exit 0
        fi
        exit 1
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "claude-team",
            "provider": "claude",
            "displayName": "Claude Team",
            "binaryPath": "\(fakeClaude.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let claude = try XCTUnwrap(snapshots.first { $0.id == "claude-team" })

        XCTAssertEqual(claude.binaryPath, fakeClaude.path)
        XCTAssertEqual(claude.version, "claude-test 2.1.0",
                       "the provider card must publish the version from the exact Claude executable configured for SDK query execution")
        XCTAssertEqual(claude.skills, ["team-plan"],
                       "provider snapshots must discover Claude skills from the selected HOME/.claude/skills so Claude composer suggestions do not show Codex-home skills")
    }

    func test_providerSnapshotsGateClaudeModelsByInstalledVersion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fakeClaude = dir.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'Claude Code 1.5.0\\n'
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          printf 'Logged in as claude@example.com\\n'
          exit 0
        fi
        exit 1
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "claude-old",
            "provider": "claude",
            "displayName": "Claude Old",
            "binaryPath": "\(fakeClaude.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let claude = try XCTUnwrap(snapshots.first { $0.id == "claude-old" })

        XCTAssertEqual(claude.models.map(\.id), ["fable", "opus", "sonnet", "haiku"],
                       "provider snapshots must use versionless Claude Code model aliases when the dynamic Anthropic Models API is unavailable")
        XCTAssertEqual(claude.models.first?.supportedReasoningEfforts, AgentReasoningEffort.claudeSupportedCases,
                       "alias fallback Claude models must preserve the full Claude effort picker (incl. Max + Ultracode) on macOS and iOS")
    }

    func test_agentSurfaceRefreshesCurrentProviderModelsOnStartup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeClaude = dir.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'Claude Code 2.1.156\\n'
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          printf 'Logged in as claude@example.com\\n'
          exit 0
        fi
        exit 1
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("cli.claude.path", fakeClaude.path)
        let workspace = try router.createWorkspace(name: "startup-models", cwd: dir.path)
        let descriptor = try router.createSurface(workspace: workspace.id, type: .agentApp, paneID: nil, title: "Agent App")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface)
        defer { closeAndUnregisterAllSurfaces() }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if surface.viewModel.providerSnapshots.contains(where: {
                $0.provider == .claude && $0.models.contains { $0.id == "opus" }
            }) {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(surface.viewModel.providerSnapshots.contains(where: {
            $0.provider == .claude && $0.models.contains { $0.id == "opus" }
        }), "opening a macOS Agent App surface must refresh provider snapshots immediately so the model menu sees current Claude aliases without waiting for a manual retry")
    }

    func test_providerUpdateRunsSerializedForSelectedInstance() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        let started = dir.appendingPathComponent("started")
        try """
        #!/bin/sh
        if [ "$1" = "update" ] && [ "$CODEX_HOME" = "\(home.path)" ]; then
          printf started > "\(started.path)"
          sleep 1
          printf 'updated codex\\n'
          exit 0
        fi
        exit 7
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-work",
            "provider": "codex",
            "displayName": "Codex Work",
            "binaryPath": "\(fakeCodex.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let first = Task { try await router.updateAgentProvider(provider: .codex, providerInstanceId: "codex-work") }
        while !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        do {
            _ = try await router.updateAgentProvider(provider: .codex, providerInstanceId: "codex-work")
            XCTFail("second update should be rejected while provider update is already running")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32041)
        }

        let value = try await first.value
        guard case .object(let payload) = value else { return XCTFail("expected update payload") }
        XCTAssertEqual(payload["ok"], .bool(true))
        XCTAssertEqual(payload["provider_instance_id"], .string("codex-work"))
        XCTAssertEqual(payload["stdout"], .string("updated codex\n"),
                       "provider update actions must use the selected provider instance environment and serialize duplicate update starts")
    }

    func test_providerUpdateFailureReleasesLockForRetry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = dir.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fakeCodex = dir.appendingPathComponent("fake-codex")
        let attempts = dir.appendingPathComponent("attempts")
        try """
        #!/bin/sh
        count=0
        if [ -f "\(attempts.path)" ]; then
          count=$(cat "\(attempts.path)")
        fi
        count=$((count + 1))
        printf "$count" > "\(attempts.path)"
        if [ "$1" = "update" ] && [ "$CODEX_HOME" = "\(home.path)" ] && [ "$count" = "1" ]; then
          printf 'network unavailable\\n' >&2
          exit 7
        fi
        if [ "$1" = "update" ] && [ "$CODEX_HOME" = "\(home.path)" ]; then
          printf 'updated after retry\\n'
          exit 0
        fi
        exit 8
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let ctx = try AppContext(channel: .debug, appSupportOverride: dir.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-work",
            "provider": "codex",
            "displayName": "Codex Work",
            "binaryPath": "\(fakeCodex.path)",
            "homePath": "\(home.path)",
            "enabled": true
          }
        ]
        """)

        let failed = try await router.updateAgentProvider(provider: .codex, providerInstanceId: "codex-work")
        guard case .object(let failedPayload) = failed else { return XCTFail("expected failed update payload") }
        XCTAssertEqual(failedPayload["ok"], .bool(false))
        XCTAssertEqual(failedPayload["status"], .number(7))
        XCTAssertEqual(failedPayload["stderr"], .string("network unavailable\n"))

        let retried = try await router.updateAgentProvider(provider: .codex, providerInstanceId: "codex-work")
        guard case .object(let retriedPayload) = retried else { return XCTFail("expected retried update payload") }
        XCTAssertEqual(retriedPayload["ok"], .bool(true))
        XCTAssertEqual(retriedPayload["stdout"], .string("updated after retry\n"),
                       "provider update failure must report the provider-native error and release the serialized update lock so users can retry after fixing the CLI/network state")
    }

    func test_providerInstanceConfigExposesSnapshotsAndRoutesRunIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let fakeBinary = "/usr/bin/env"
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "codex-work",
            "provider": "codex",
            "displayName": "Codex Work",
            "binaryPath": "\(fakeBinary)",
            "homePath": "\(codexHome.path)",
            "accentColor": "#125A9C",
            "enabled": true,
            "env": {"REMOTE_CODE_INSTANCE": "work"}
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let codex = try XCTUnwrap(snapshots.first { $0.id == "codex-work" })
        XCTAssertEqual(codex.displayName, "Codex Work")
        XCTAssertEqual(codex.binaryPath, fakeBinary)
        XCTAssertEqual(codex.homePath, codexHome.path)
        XCTAssertEqual(codex.environmentKeys, ["CODEX_HOME", "REMOTE_CODE_INSTANCE"],
                       "provider snapshots must show which instance-scoped environment keys isolate account/session state without leaking values")

        let capture = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: capture)
        let workspace = try router.createWorkspace(name: "instance", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "instance",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            providerInstanceId: "codex-work"
        )

        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "check isolation",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        let request = try XCTUnwrap(capture.lastRequest)
        XCTAssertEqual(request.providerInstanceId, "codex-work")
        XCTAssertEqual(request.providerBinary, fakeBinary)
        XCTAssertEqual(request.environment["CODEX_HOME"], codexHome.path)
        XCTAssertEqual(request.environment["REMOTE_CODE_INSTANCE"], "work")
    }

    func test_sendOnStartedThreadToleratesMismatchedProviderInstanceIdAndKeepsLockedInstance() async throws {
        // A thread is locked to one of several configured provider instances. A
        // mirror client (iOS/macOS) can re-derive its provider-instance id from the
        // provider snapshot list and end up forwarding a DIFFERENT, still-valid
        // instance id than the one the thread is bound to. Once the thread has
        // started, a message-send carrying that mismatched id must NOT be rejected
        // with the provider-instance lock (-32013): the user must always be able to
        // send, and the run must stay on the thread's original locked instance —
        // never silently hop to the forwarded one. This reproduces the field bug
        // "Provider instance is locked once the thread has started" that blocked
        // sending from the mobile mirror.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        let homeA = root.appendingPathComponent("codex-a", isDirectory: true)
        let homeB = root.appendingPathComponent("codex-b", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let fakeBinary = "/usr/bin/env"
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {"id":"codex-a","provider":"codex","displayName":"Codex A","binaryPath":"\(fakeBinary)","homePath":"\(homeA.path)","enabled":true,"env":{"REMOTE_CODE_INSTANCE":"a"}},
          {"id":"codex-b","provider":"codex","displayName":"Codex B","binaryPath":"\(fakeBinary)","homePath":"\(homeB.path)","enabled":true,"env":{"REMOTE_CODE_INSTANCE":"b"}}
        ]
        """)

        let capture = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: capture)
        let workspace = try router.createWorkspace(name: "instance-lock", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "locked",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            providerInstanceId: "codex-b"
        )
        XCTAssertEqual(thread.providerInstanceId, "codex-b")

        // Mark the thread "started" so its provider/instance are locked host-side.
        try ctx.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "first"))
        try ctx.messageRepo.append(AgentMessage(threadId: thread.id, role: .assistant, content: "reply"))

        // Mirror client forwards the OTHER (still-valid) instance id on the started
        // thread. Before the fix this threw -32013; now the send must proceed.
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "second message",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            interactionMode: nil,
            modelSelection: nil,
            providerInstanceId: "codex-a"
        )

        let request = try XCTUnwrap(capture.lastRequest)
        XCTAssertEqual(request.providerInstanceId, "codex-b",
                       "a started-thread send must run on the thread's locked instance, never the mismatched id the client forwarded")
        XCTAssertEqual(request.environment["CODEX_HOME"], homeB.path,
                       "the run must stay isolated to the locked instance's home, proving the forwarded instance did not take effect")
        XCTAssertEqual(request.environment["REMOTE_CODE_INSTANCE"], "b")
    }

    func test_providerInstanceConfigRoutesClaudeHomeThroughProcessHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let fakeBinary = "/usr/bin/env"
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "claude-personal",
            "provider": "claude",
            "displayName": "Claude Personal",
            "binaryPath": "\(fakeBinary)",
            "homePath": "\(claudeHome.path)",
            "enabled": true,
            "env": {"REMOTE_CODE_INSTANCE": "personal"}
          }
        ]
        """)

        let snapshots = await router.listAgentProviderSnapshots()
        let claude = try XCTUnwrap(snapshots.first { $0.id == "claude-personal" })
        XCTAssertEqual(claude.environmentKeys, ["HOME", "REMOTE_CODE_INSTANCE"],
                       "Claude Code stores account/session state under HOME; provider instances must isolate HOME instead of an ignored config-only variable")

        let capture = RequestCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: capture)
        let workspace = try router.createWorkspace(name: "claude-instance", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "claude instance",
            provider: .claude,
            model: "claude-opus-4-7",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            providerInstanceId: "claude-personal"
        )

        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "check claude isolation",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        let request = try XCTUnwrap(capture.lastRequest)
        XCTAssertEqual(request.providerInstanceId, "claude-personal")
        XCTAssertEqual(request.providerBinary, fakeBinary)
        XCTAssertEqual(request.environment["HOME"], claudeHome.path)
        XCTAssertNil(request.environment["CLAUDE_CONFIG_DIR"],
                     "Claude provider isolation should follow Claude Code's HOME-based state model")
        XCTAssertEqual(request.environment["REMOTE_CODE_INSTANCE"], "personal")
    }

    func test_tokenSaverEnabledAddsClaudeSDKPostToolUseHookEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let support = root.appendingPathComponent("support", isDirectory: true)
        let ctx = try AppContext(channel: .debug, appSupportOverride: support.path)
        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        let router = AppCommandRouter(context: ctx)
        ctx.router = router

        let capture = RequestCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: capture)
        let workspace = try router.createWorkspace(name: "claude-token-saver-hook", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "claude token saver hook",
            provider: .claude,
            model: "claude-opus-4-7",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "check post tool hook env",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        let request = try XCTUnwrap(capture.lastRequest)
        XCTAssertEqual(request.environment["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
        XCTAssertEqual(
            request.environment["REMOTE_CODE_DISTILL_STATE_PATH"],
            support.appendingPathComponent("Distill", isDirectory: true).appendingPathComponent("DistillCLIState.json").path,
            "Claude SDK PostToolUse hook must read the same bearer-protected sidecar state as the managed distill CLI"
        )
    }

    func test_stopAgentRunCancelsCoordinatorThreadRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = BlockingCancelRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "stop", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "stop",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        _ = try await router.sendAgentMessage(thread: thread.id,
                                              text: "wait",
                                              provider: nil,
                                              model: nil,
                                              permissionMode: nil,
                                              reasoningEffort: nil)
        try router.stopAgentRun(thread: thread.id)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if runner.cancelled, try ctx.threadRepo.get(id: thread.id)?.status == .cancelled {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(runner.cancelled,
                      "agent.run.stop must reach the active provider handle instead of returning a no-op success")
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.status, .cancelled,
                       "stopped runs must update persisted thread status so macOS and iOS leave running state")
    }

    func test_terminalPersistenceRetainsRunBoundQueueRecoveryEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        ctx.coordinator.replaceProvider(.codex, runner: RequestCaptureRunner(provider: .codex))
        let workspace = try router.createWorkspace(name: "terminal-run-evidence", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "terminal run evidence",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        let result = try await router.sendAgentMessage(
            thread: thread.id,
            text: "finish immediately",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let runId = try XCTUnwrap(result.runId)
        let deadline = Date().addingTimeInterval(2)
        while try ctx.runRepo.get(id: runId)?.status != .completed, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastRunId, runId,
                       "terminal persistence must not erase the run id required to reconcile a prepared queue row after a crash")
        XCTAssertEqual(try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastEventKind, "run.finished")
    }

    func test_sendAgentMessageStartsPendingNewThreadInsteadOfQueueing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "pending-start", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "New thread",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        let result = try await router.sendAgentMessage(thread: thread.id,
                                                       text: "count to 10",
                                                       provider: nil,
                                                       model: nil,
                                                       permissionMode: nil,
                                                       reasoningEffort: nil)

        XCTAssertEqual(result.status, .started,
                       "a freshly-created pending Agent thread must start its first provider run; queuing here leaves iOS waiting forever")
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id), [],
                       "the first prompt in a new iOS thread must not be stored as an editable follow-up queue item")
        XCTAssertEqual(runner.lastRequest?.prompt, "count to 10")
    }

    func test_sendAgentMessageQueuesWhenAdapterTurnOutlivesPersistedThreadStatus() async throws {
        // WHY: mirror/RPC sends do not share the macOS surface's in-memory run
        // projection. The adapter's running session must still route the message
        // into the durable queue instead of creating a duplicate failed turn.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let adapter = OneShotProviderAdapter(runner: BlockingCancelRunner(provider: .codex))
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        let workspace = try router.createWorkspace(name: "orphaned-live-turn", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "orphaned live turn",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5.5",
            cwd: workspaceDir.path,
            prompt: "existing turn"
        )) { _ in }

        let result = try await router.sendAgentMessage(
            thread: thread.id,
            text: "queue from mirror exactly once",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        XCTAssertEqual(result.status, .queued)
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["queue from mirror exactly once"])
        XCTAssertTrue(try ctx.messageRepo.list(threadId: thread.id).isEmpty,
                      "adapter-busy RPC sends must not persist a duplicate user bubble")
        adapter.stopAll()
    }

    func test_drainQueueWaitsWhenAdapterTurnOutlivesPersistedThreadStatus() async throws {
        // WHY: lifecycle reconciliation can observe stale persisted status while
        // the adapter still owns a turn. It must not claim or dispatch the queue
        // head until that provider turn is actually idle.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let (ctx, router, adapter, thread) = try await makeLiveAdapterRouterFixture(root: root)
        var staleThread = thread
        staleThread.status = .completed
        try ctx.threadRepo.upsert(staleThread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "wait for the live turn",
            attachments: [],
            interactionMode: .default
        )

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "wait for the live turn")
        let dispatch = try XCTUnwrap(ctx.queuedMessageRepo.dispatch(id: queued.id))
        XCTAssertEqual(dispatch.state, .queued,
                       "busy-provider drain must not claim or prepare the queue head")
        XCTAssertNil(dispatch.runId)
        XCTAssertTrue(try ctx.messageRepo.list(threadId: thread.id).isEmpty)
        adapter.stopAll()
    }

    func test_forceQueuedMessageTreatsLiveAdapterSessionAsActive() async throws {
        // WHY: Force must promote the requested item and stop the real provider
        // turn even when persisted thread status has already become stale.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let (ctx, router, adapter, thread) = try await makeLiveAdapterRouterFixture(root: root)
        var staleThread = thread
        staleThread.status = .completed
        try ctx.threadRepo.upsert(staleThread)
        _ = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "later", attachments: [], interactionMode: .default)
        let forced = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "force first", attachments: [], interactionMode: .default)

        let result = try await router.forceAgentQueuedMessageNow(id: forced.id)

        XCTAssertEqual(result.status, .queued)
        XCTAssertEqual(result.queuedMessage?.id, forced.id)
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["force first", "later"])
        adapter.stopAll()
    }

    func test_continueRejectsLiveAdapterSessionWithoutQueueingEmptyPrompt() async throws {
        // WHY: Continue is a recovery action, not a message. If the provider is
        // still live it must fail as already active, never enqueue an empty turn.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let (ctx, router, adapter, thread) = try await makeLiveAdapterRouterFixture(root: root)
        var staleThread = thread
        staleThread.status = .interrupted
        try ctx.threadRepo.upsert(staleThread)

        do {
            _ = try await router.continueAgentRun(thread: thread.id)
            XCTFail("Continue must reject a still-live provider turn")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("active run"))
        }

        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty,
                      "Continue must not turn its empty recovery prompt into a queue item")
        adapter.stopAll()
    }

    func test_drainQueue_startFailureAcknowledgesIntentAfterDurableFailedRunWithoutReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "queue-retry", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "retry exactly once", attachments: [], interactionMode: .default)
        let failing = ThrowingStartRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: failing)

        do {
            try await router.drainNextQueuedAgentMessage(thread: thread.id)
            XCTFail("provider start must fail")
        } catch {}

        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty,
                      "once the deterministic failed run is durable, the queue intent is redundant and must be acknowledged without provider replay")
        XCTAssertEqual(try ctx.messageRepo.list(threadId: thread.id).filter { $0.role == .user }.count, 1)
        let failedRun = try XCTUnwrap(ctx.runRepo.get(id: AgentRunID(queued.id.value)))
        XCTAssertEqual(failedRun.status, .failed,
                       "the visible failed run must own Retry/Continue after the queue intent is acknowledged")
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastRunId,
            failedRun.id,
            "start-failure persistence must retain the run-bound evidence needed if the host crashes before queue acknowledgement"
        )
        XCTAssertEqual(failing.startCount, 1,
                       "onRunFinished queue draining must not replay a provider start already represented by the deterministic failed run")
    }

    func test_forceQueue_startFailureLeavesOnlyDurableFailedRunRecoverySurface() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "queue-force-retry", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "one recovery surface", attachments: [], interactionMode: .default)
        let failing = ThrowingStartRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: failing)

        do {
            _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
            XCTFail("provider start must fail")
        } catch {}

        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty,
                      "Force must acknowledge the redundant queue row after the deterministic failed run is durable")
        XCTAssertEqual(try ctx.messageRepo.list(threadId: thread.id).filter { $0.role == .user }.count, 1)
        XCTAssertEqual(try ctx.runRepo.get(id: AgentRunID(queued.id.value))?.status, .failed)
        XCTAssertEqual(failing.startCount, 1)
    }

    func test_drainQueue_relaunchAcknowledgesDispatchedHeadWithoutProviderReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-relaunch", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "already dispatched", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        XCTAssertTrue(try ctx.queuedMessageRepo.markDispatched(lease, runId: runId))

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertNil(runner.lastRequest,
                     "relaunch recovery must acknowledge durable dispatched proof without invoking the provider")
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id))
    }

    func test_drainQueue_relaunchRequeuesPreparedHeadWhenNoRunExistsAndStartsExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-ambiguous", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        let head = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "ambiguous", attachments: [], interactionMode: .default)
        _ = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "later", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: head.id, leaseId: "dead-process"))
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: AgentRunID(head.id.value)))

        await router.reconcileQueuedAgentMessagesOnLaunch()

        XCTAssertEqual(runner.lastRequest?.runId.value, head.id.value,
                       "absence of the deterministic run row proves provider start was never reached and permits one retry")
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["later"],
                       "safe relaunch recovery must drain the original head without skipping the later row")
    }

    func test_drainQueue_relaunchKeepsPreparedHeadWhenProviderStartWasNeverConfirmed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-pending-start", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .interrupted
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "must remain visible", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        try ctx.runRepo.upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .pending))
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .pending,
            lastRunId: runId,
            lastEventKind: "run.pending"
        ))

        do {
            try await router.drainNextQueuedAgentMessage(
                thread: thread.id,
                recoverPreparedFromPriorProcess: true
            )
            XCTFail("launch recovery must fail loud while provider acceptance is unconfirmed")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("remains queued"),
                          "launch recovery must explain that the protected message was preserved")
        } catch {
            XCTFail("launch recovery returned an unexpected error: \(error)")
        }

        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "must remain visible",
                       "a pre-provider crash must preserve the only actionable queue intent")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared,
                       "ambiguous launch recovery must not make the message claimable or replay it")
        XCTAssertNil(runner.lastRequest,
                     "launch recovery must not replay a prepared message with ambiguous provider state")
    }

    func test_forceQueuedMessageKeepsPreparedHeadWhenProviderStartWasNeverConfirmed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-force-pending-start", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .interrupted
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "do not force replay", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        try ctx.runRepo.upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .pending))
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .pending,
            lastRunId: runId,
            lastEventKind: "run.pending"
        ))

        do {
            _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
            XCTFail("Force must fail loud while provider acceptance is unconfirmed")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("remains queued"),
                          "Force must explain that the protected message was preserved")
        } catch {
            XCTFail("Force returned an unexpected error: \(error)")
        }

        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "do not force replay",
                       "Force must not delete a queue intent that the provider may never have seen")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
        XCTAssertNil(runner.lastRequest,
                     "Force must not replay an ambiguous prepared dispatch")
    }

    func test_drainQueue_relaunchAcknowledgesPreparedHeadWithExistingRunWithoutProviderReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-existing-run", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "already represented by run", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        var failedRun = AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .failed)
        failedRun.finishedAt = Date()
        failedRun.errorMessage = "provider start outcome retained"
        try ctx.runRepo.upsert(failedRun)
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .failed,
            lastRunId: runId,
            lastEventKind: "run.started"
        ))

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertNil(runner.lastRequest,
                     "a durable matching run owns Retry/Continue; launch recovery must never invoke the provider again")
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id),
                     "the redundant prepared queue intent must be acknowledged instead of poisoning the queue head")
        XCTAssertEqual(try ctx.runRepo.get(id: runId)?.status, .failed,
                       "queue acknowledgement must preserve the visible run recovery record")
    }

    func test_drainQueueDoesNotUseLaterRunSessionEvidenceForPreparedEarlierRun() async throws {
        // WHY: provider-session diagnostics are thread-scoped. Without the
        // matching run id, a later turn's run.started can silently delete an
        // earlier prompt that crashed before provider acceptance.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "queue-run-evidence", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .interrupted
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "run A must remain", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runA = AgentRunID(queued.id.value)
        let runB = AgentRunID()
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runA))
        try ctx.runRepo.upsert(AgentRun(id: runA, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .pending))
        var completedB = AgentRun(id: runB, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed)
        completedB.finishedAt = Date()
        try ctx.runRepo.upsert(completedB)
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            lastRunId: runB,
            lastEventKind: "run.started"
        ))

        do {
            try await router.drainNextQueuedAgentMessage(thread: thread.id)
            XCTFail("later run evidence must not acknowledge the earlier prepared prompt")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("remains queued"))
        }
        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "run A must remain")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
    }

    private func makeLiveAdapterRouterFixture(
        root: URL
    ) async throws -> (AppContext, AppCommandRouter, OneShotProviderAdapter, AgentThread) {
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let adapter = OneShotProviderAdapter(runner: BlockingCancelRunner(provider: .codex))
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        let workspace = try router.createWorkspace(name: "live-adapter-fixture", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "live adapter fixture",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5.5",
            cwd: workspaceDir.path,
            prompt: "existing turn"
        )) { _ in }
        return (ctx, router, adapter, thread)
    }
}

private final class ThrowingStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var starts = 0
    init(provider: AgentProvider) { self.provider = provider }
    var startCount: Int { lock.withLock { starts } }
    func listModels() async -> [AgentModelDescriptor] { [] }
    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.withLock { starts += 1 }
        throw AgentRunError.spawnFailed("intentional queue-start failure")
    }
}

private final class RequestCaptureRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let queue = DispatchQueue(label: "RequestCaptureRunner")
    private var captured: AgentRunRequest?

    init(provider: AgentProvider) {
        self.provider = provider
    }

    var lastRequest: AgentRunRequest? {
        queue.sync { captured }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        queue.sync { captured = request }
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: "turn-1")))
            onEvent(.event(.turnCompleted(turnId: "turn-1", finalMessage: "ok")))
            onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class BlockingCancelRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var _cancelled = false

    init(provider: AgentProvider) {
        self.provider = provider
    }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        onEvent(.event(.turnStarted(turnId: "turn-blocking")))
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.lock.lock()
            self?._cancelled = true
            self?.lock.unlock()
            onEvent(.status(.cancelled))
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
        }
    }
}
