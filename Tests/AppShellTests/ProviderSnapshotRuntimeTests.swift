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

    func test_forceQueuedMessageDrainsOnceWhenProviderBecomesIdleAfterTimeoutAcrossProviders() async throws {
        // WHY: stopRun publishes the host-side cancellation before a native
        // provider necessarily becomes idle. The first drain can therefore see
        // a live adapter session; Force still owes exactly one later start.
        for provider in AgentProvider.allCases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }

            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            ctx.queueDrainProviderIdleTimeout = 0.05
            let sleeper = QueueDrainTestSleeper()
            ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let runner = DelayedCancelQueueRunner(provider: provider)
            ctx.coordinator.replaceProvider(provider, runner: runner)
            let workspace = try router.createWorkspace(
                name: "delayed-force-\(provider.rawValue)",
                cwd: workspaceDir.path
            )
            let thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "delayed force \(provider.rawValue)",
                provider: provider,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "existing turn",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            _ = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "later",
                attachments: [],
                interactionMode: .default
            )
            let forced = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "force exactly once",
                attachments: [],
                interactionMode: .default
            )
            let failures = QueueFailureCounter(threadId: thread.id)
            let drained = QueueEventSignal(
                threadId: thread.id,
                kind: "agent.message.queue.drained"
            )
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
                failures.record($0)
                drained.record($0)
            }
            defer { EventBus.shared.unsubscribe(subscription) }

            let result = try await router.forceAgentQueuedMessageNow(id: forced.id)
            XCTAssertEqual(result.status, .queued)
            await sleeper.advanceNext(threadId: thread.id)
            await failures.waitForCount(1)
            runner.finishRun(ordinal: 1, status: .cancelled)
            await runner.waitForStartCount(2)
            await drained.waitForCount(1)
            XCTAssertEqual(runner.startCount, 2,
                           "\(provider.rawValue) Force must retry after delayed provider idle and start once")
            XCTAssertEqual(
                try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
                ["later"],
                "\(provider.rawValue) must acknowledge only the forced queue row"
            )
            XCTAssertEqual(
                try ctx.messageRepo.list(threadId: thread.id)
                    .filter { $0.role == .user && $0.content == "force exactly once" }.count,
                1,
                "\(provider.rawValue) delayed cancellation must not duplicate the forced user message"
            )
            XCTAssertEqual(runner.startCount, 2,
                           "\(provider.rawValue) must remain at exactly one forced restart after settling")
            XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["later"])
            XCTAssertEqual(
                try ctx.messageRepo.list(threadId: thread.id)
                    .filter { $0.role == .user && $0.content == "force exactly once" }.count,
                1
            )
            XCTAssertEqual(failures.count, 1,
                           "\(provider.rawValue) must emit one timeout status while continuing the late-idle watcher")
            ctx.coordinator.stopRun(threadId: thread.id)
        }
    }

    func test_normalQueuedMessageWaitsPastTimeoutWithoutFalseFailureAndDrainsOnceAcrossProviders() async throws {
        // WHY: the queue timeout describes delayed stop recovery, not normal
        // queue residence. A legitimately running turn may exceed it without
        // making the durable follow-up unsafe or showing a false failure.
        for provider in AgentProvider.allCases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            ctx.queueDrainProviderIdleTimeout = 0.02
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let runner = DelayedCancelQueueRunner(provider: provider, cancellationDelay: nil)
            ctx.coordinator.replaceProvider(provider, runner: runner)
            let sleeper = QueueDrainTestSleeper()
            ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
            let workspace = try router.createWorkspace(
                name: "normal-queue-\(provider.rawValue)",
                cwd: workspaceDir.path
            )
            let thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "normal queue \(provider.rawValue)",
                provider: provider,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "legitimately long turn",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            let failures = QueueFailureCounter(threadId: thread.id)
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
                failures.record($0)
            }
            defer { EventBus.shared.unsubscribe(subscription) }

            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "ordinary queued follow-up",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            await sleeper.advanceNext(threadId: thread.id)

            XCTAssertEqual(failures.count, 0,
                           "\(provider.rawValue) normal queue residence must not look like stop failure")
            XCTAssertEqual(runner.startCount, 1)
            XCTAssertEqual(
                try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
                ["ordinary queued follow-up"]
            )
            XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

            let drained = QueueDrainAsyncSignal()
            let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
                guard $0.kind == "agent.message.queue.drained",
                      $0.payload.objectValue?["thread_id"]?.stringValue == thread.id.value.uuidString else {
                    return
                }
                Task { await drained.signal() }
            }
            defer { EventBus.shared.unsubscribe(drainedSubscription) }
            runner.finishRun(ordinal: 1, status: .completed)
            await drained.wait()

            XCTAssertEqual(runner.startCount, 2)
            XCTAssertEqual(failures.count, 0)
            XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
            XCTAssertEqual(
                try ctx.messageRepo.list(threadId: thread.id)
                    .filter { $0.role == .user && $0.content == "ordinary queued follow-up" }.count,
                1,
                "\(provider.rawValue) normal completion must drain the queued intent exactly once"
            )
            runner.finishRun(ordinal: 2, status: .completed)
        }
    }

    func test_forceQueueNeverIdlePreservesIntentWithSingleTimeoutFailureAcrossProviders() async throws {
        // WHY: a provider that ignores cancellation must not trigger repeated
        // drain attempts, emit a false terminal failure, or consume the row.
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }

        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 0.05
        let sleeper = QueueDrainTestSleeper()
        ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: provider, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(provider, runner: runner)
        let workspace = try router.createWorkspace(name: "never-idle", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "never idle",
            provider: provider,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let forced = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "preserve after timeout",
            attachments: [],
            interactionMode: .default
        )
        let failures = QueueFailureCounter(threadId: thread.id)
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { failures.record($0) }
        defer { EventBus.shared.unsubscribe(subscription) }

        _ = try await router.forceAgentQueuedMessageNow(id: forced.id)
        await sleeper.advanceNext(threadId: thread.id)
        await failures.waitForCount(1)

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["preserve after timeout"])
        XCTAssertEqual(
            try ctx.messageRepo.list(threadId: thread.id)
                .filter { $0.role == .user && $0.content == "preserve after timeout" }.count,
            0
        )

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["preserve after timeout"])
      }
    }

    func test_terminalRunWithNoQueuedRowsSkipsNeverIdleWaitAcrossProviders() async throws {
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 0.02
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: provider, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(provider, runner: runner)
        let workspace = try router.createWorkspace(name: "empty-queue", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "empty queue",
            provider: provider,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let failures = QueueFailureCounter(threadId: thread.id)
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            failures.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "terminal without follow-up",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        ctx.coordinator.stopRun(threadId: thread.id)

        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
        XCTAssertEqual(failures.count, 0)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
      }
    }

    func test_enqueueAfterTerminalCallbackCoalescesLateIdleDrainAcrossProviders() async throws {
        // WHY: a host terminal callback can run before a follow-up is enqueued
        // while the native provider session remains live. The enqueue path must
        // arm the one waiter that the earlier empty-queue callback skipped.
        for provider in AgentProvider.allCases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            ctx.queueDrainProviderIdleTimeout = 0.05
            let sleeper = QueueDrainTestSleeper()
            ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let runner = DelayedCancelQueueRunner(provider: provider, cancellationDelay: nil)
            ctx.coordinator.replaceProvider(provider, runner: runner)
            let workspace = try router.createWorkspace(
                name: "late-enqueue-\(provider.rawValue)",
                cwd: workspaceDir.path
            )
            let thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "late enqueue \(provider.rawValue)",
                provider: provider,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "existing turn",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            let failures = QueueFailureCounter(threadId: thread.id)
            let drained = QueueEventSignal(
                threadId: thread.id,
                kind: "agent.message.queue.drained"
            )
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
                failures.record($0)
                drained.record($0)
            }
            defer { EventBus.shared.unsubscribe(subscription) }

            ctx.coordinator.stopRun(threadId: thread.id)
            XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0,
                           "the terminal callback must skip a waiter when no queued intent exists yet")

            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "late first",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "late second",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1,
                           "\(provider.rawValue) repeated enqueue must coalesce to one waiter")

            await sleeper.advanceNext(threadId: thread.id)
            await failures.waitForCount(1)
            XCTAssertEqual(failures.count, 1,
                           "\(provider.rawValue) one waiter may publish only one delayed-idle status")
            runner.finishRun(ordinal: 1, status: .cancelled)
            await runner.waitForStartCount(2)
            await drained.waitForCount(1)
            XCTAssertEqual(runner.startCount, 2)
            XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text), ["late second"])

            runner.finishRun(ordinal: 2, status: .completed)
            await runner.waitForStartCount(3)
            await drained.waitForCount(2)
            XCTAssertEqual(runner.startCount, 3)
            runner.finishRun(ordinal: 3, status: .completed)

            XCTAssertFalse(ctx.coordinator.hasProviderSession(threadId: thread.id))
            XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
            XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(
                try ctx.messageRepo.list(threadId: thread.id)
                    .filter { $0.role == .user && ($0.content == "late first" || $0.content == "late second") }.count,
                2,
                "\(provider.rawValue) must dispatch each late intent exactly once"
            )
        }
    }

    func test_cancellingFinalQueuedRowCancelsLateIdleWaiter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 0.5
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "cancel-waiter", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "cancel waiter",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        ctx.coordinator.stopRun(threadId: thread.id)
        let queued = try await router.sendAgentMessage(
            thread: thread.id,
            text: "cancel me",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        _ = try router.cancelAgentQueuedMessage(id: try XCTUnwrap(queued.queuedMessage?.id))

        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
        runner.finishRun(ordinal: 1, status: .cancelled)
    }

    func test_queueDrainWaiterImmediatelyDrainsWhenProviderIsAlreadyIdle() async throws {
        // WHY: provider state can become idle between the enqueue decision and
        // waiter installation. The waiter itself must own that second check.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "already-idle", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "already idle",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "drain after idle transition",
            attachments: [],
            interactionMode: .default
        )
        let drained = QueueEventSignal(
            threadId: thread.id,
            kind: "agent.message.queue.drained"
        )
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            drained.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        await runner.waitForStartCount(1)
        await drained.waitForCount(1)
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
        runner.finishRun(ordinal: 1, status: .completed)
    }

    func test_cancelledWaiterCannotRemoveImmediateReplacementGeneration() async throws {
        // WHY: cancellation resumes the old task asynchronously. Its cleanup
        // must not remove a new waiter installed for an immediate re-enqueue.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 1
        let sleeper = QueueDrainTestSleeper()
        ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "waiter-generation", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "waiter generation",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let first = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "cancel first generation",
            attachments: [],
            interactionMode: .default
        )
        let drained = QueueEventSignal(
            threadId: thread.id,
            kind: "agent.message.queue.drained"
        )
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            drained.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        await sleeper.waitForRequestCount(1, threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        _ = try router.cancelAgentQueuedMessage(id: first.id)
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "replacement generation",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        await sleeper.waitForRequestCount(2, threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1,
                       "old cancellation cleanup must be token-checked")
        runner.finishRun(ordinal: 1, status: .cancelled)
        await runner.waitForStartCount(2)
        await drained.waitForCount(1)
        XCTAssertEqual(runner.startCount, 2)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
        runner.finishRun(ordinal: 2, status: .completed)
    }

    func test_backgroundProviderFinishSerializesWithQueueCancelAndReenqueue() async throws {
        // WHY: provider completion callbacks are not main-thread-affine. Their
        // queue recovery must serialize with a simultaneous user cancellation
        // and replacement enqueue without duplicating or losing the waiter.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "background-finish", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "background finish",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let cancelled = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "cancelled queued turn",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        let drained = QueueEventSignal(
            threadId: thread.id,
            kind: "agent.message.queue.drained"
        )
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            drained.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        let finishTask = Task.detached {
            runner.finishRun(ordinal: 1, status: .cancelled)
        }
        _ = try router.cancelAgentQueuedMessage(id: cancelled.id)
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "replacement queued turn",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        await finishTask.value
        await runner.waitForStartCount(2)
        await drained.waitForCount(1)
        XCTAssertFalse(runner.lastFinishWasMainThread)
        XCTAssertEqual(runner.startCount, 2)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty)
        XCTAssertEqual(
            try ctx.messageRepo.list(threadId: thread.id)
                .filter { $0.role == .user && $0.content == "replacement queued turn" }.count,
            1
        )
        runner.finishRun(ordinal: 2, status: .completed)
    }

    func test_deleteThreadSuppressesQueuedDrainBeforeAwaitingProviderTermination() async throws {
        // WHY: thread deletion awaits provider shutdown. A terminal callback in
        // that window must not observe idle and start durable queued work.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: 0.05)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "delete-no-drain", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "delete no drain",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must never start",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        try await router.deleteAgentThread(thread: thread.id)

        XCTAssertEqual(runner.startCount, 1,
                       "deletion shutdown must not start the queued follow-up")
        XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_overlappingQueueDrainSuppressionLeasesRearmOnlyAfterFinalRelease() async throws {
        // WHY: UI and RPC deletion can overlap for the same thread. Releasing
        // either owner must not rearm queued work while the other still owns
        // destructive shutdown.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "overlapping-delete", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "overlapping delete",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must remain suppressed",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)

        let firstLease = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        let secondLease = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainSuppressedThreadCountForTesting, 1)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)

        ctx.releaseQueueDrainSuppression(threadId: thread.id, lease: firstLease)
        XCTAssertEqual(ctx.queueDrainSuppressedThreadCountForTesting, 1)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)

        ctx.releaseQueueDrainSuppression(threadId: thread.id, lease: secondLease)
        XCTAssertEqual(ctx.queueDrainSuppressedThreadCountForTesting, 0)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)
        _ = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        runner.finishRun(ordinal: 1, status: .cancelled)
    }

    func test_deletionAwaitsInFlightQueueDrainBeforeRemovingThread() async throws {
        // WHY: cancellation alone is not a barrier. A waiter that already
        // entered drain must finish observing cancellation before destructive
        // deletion can remove its thread or start queued work afterward.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "delete-drain-barrier", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "delete drain barrier",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must not start after delete",
            attachments: [],
            interactionMode: .default
        )
        let barrier = QueueDrainAsyncBarrier()
        ctx.queueDrainBeforeDispatchForTesting = { await barrier.enterAndWait() }
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        runner.finishRun(ordinal: 1, status: .completed)
        await barrier.waitUntilEntered()

        let suppression = QueueDrainAsyncSignal()
        ctx.queueDrainSuppressionAcquiredForTesting = {
            guard $0 == thread.id else { return }
            await suppression.signal()
        }
        let deletion = Task { try await router.deleteAgentThread(thread: thread.id) }
        await suppression.wait()
        XCTAssertNotNil(try ctx.threadRepo.get(id: thread.id),
                        "deletion must await the in-flight waiter cancellation barrier")
        await barrier.release()
        try await deletion.value

        XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_agentAppDeletionSuppressesQueueAfterPreflightBeforeProviderStart() async throws {
        // WHY: queue dispatch awaits provider preflight after its outer guards.
        // Deletion suppression acquired during that suspension must still win at
        // the actual start boundary, release the prepared lease, and preserve
        // the queued intent in the completed deletion's undo snapshot.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "post-preflight-delete", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "post preflight delete",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
        )
        surface.viewModel.selectThread(thread.id)
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "preserve across delete",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let failures = QueueFailureCounter(threadId: thread.id)
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            failures.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        let barrier = QueueDrainAsyncBarrier()
        router.queueDispatchBeforeProviderStartForTesting = { await barrier.enterAndWait() }
        runner.finishRun(ordinal: 1, status: .completed)
        await barrier.waitUntilEntered()

        let suppression = QueueDrainAsyncSignal()
        ctx.queueDrainSuppressionAcquiredForTesting = {
            guard $0 == thread.id else { return }
            await suppression.signal()
        }
        let deletion = Task { await surface.viewModel.deleteThread(thread.id) }
        await suppression.wait()
        XCTAssertNotNil(try ctx.threadRepo.get(id: thread.id))
        await barrier.release()
        let deleted = await deletion.value
        XCTAssertTrue(deleted)

        XCTAssertEqual(runner.startCount, 1,
                       "suppression after preflight must prevent queued provider start")
        XCTAssertEqual(failures.count, 0,
                       "deliberate suppression cancellation must not report a queue failure")
        XCTAssertNil(try ctx.threadRepo.get(id: thread.id),
                     "the deletion owner must complete after the cancelled drain exits")
        XCTAssertTrue(surface.viewModel.undoLastThreadDeletion())
        XCTAssertEqual(
            try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
            ["preserve across delete"],
            "pre-start cancellation must release the prepared lease before deletion snapshots it"
        )
    }

    func test_agentAppBulkDeletionSuppressesEveryThreadBeforeAwaitingStuckDrain() async throws {
        // WHY: bulk deletion must not await thread A's already-entered drain
        // before protecting idle thread B; B can become idle during that wait.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "bulk-delete-barrier", cwd: workspaceDir.path)
        let threads = try (0..<2).map { index in
            try router.createAgentThread(
                workspace: workspace.id,
                title: "bulk \(index)",
                provider: .claude,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
        }
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
        )
        for (index, thread) in threads.enumerated() {
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "running \(index)",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "recover \(index)",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
        }

        let barrier = QueueDrainAsyncBarrier()
        router.queueDispatchBeforeProviderStartForTesting = { await barrier.enterAndWait() }
        runner.finishRun(ordinal: 1, status: .completed)
        await barrier.waitUntilEntered()

        let allSuppressed = QueueDrainAsyncSignal()
        ctx.queueDrainSuppressionAcquiredForTesting = { _ in await allSuppressed.signal() }
        let deletion = Task {
            await surface.viewModel.deleteThreads(Set(threads.map(\.id)))
        }
        await allSuppressed.wait()

        XCTAssertEqual(
            ctx.queueDrainSuppressedThreadCountForTesting,
            2,
            "both leases must exist before bulk deletion awaits A's stuck waiter"
        )
        runner.finishRun(ordinal: 2, status: .completed)
        XCTAssertEqual(runner.startCount, 2,
                       "B becoming idle while A is stuck must not start B's queued prompt")

        await barrier.release()
        let deleted = await deletion.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(runner.startCount, 2)
        XCTAssertTrue(surface.viewModel.undoLastThreadDeletion())
        for (index, thread) in threads.enumerated() {
            XCTAssertEqual(
                try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
                ["recover \(index)"]
            )
        }
    }

    func test_routerBulkDeletionStartsEveryStopTogetherAndPreservesAllRowsWhenOneFails() async throws {
        // WHY: bulk deletion is one transaction from the user's perspective.
        // Every provider gets the same shutdown window, and a partial shutdown
        // must not partially delete the durable thread set.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(
            name: "concurrent bulk stop",
            cwd: workspaceDir.path
        )
        let threads = try (0..<2).map { index in
            try router.createAgentThread(
                workspace: workspace.id,
                title: "bulk stop \(index)",
                provider: .claude,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
        }
        let stopBarrier = ConcurrentBulkStopBarrier()
        let runner = ConcurrentBulkStopRunner(
            failingThreadId: threads[1].id,
            barrier: stopBarrier
        )
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        ctx.coordinator.gracefulStopTimeout = 0.05
        ctx.coordinator.hardStopTimeout = 0.15
        for thread in threads {
            _ = try await router.sendAgentMessage(
                thread: thread.id,
                text: "running",
                provider: nil,
                model: nil,
                permissionMode: nil,
                reasoningEffort: nil
            )
        }

        let deletion = Task { () -> Error? in
            do {
                try await router.deleteAgentThreads(threads.map(\.id))
                return nil
            } catch {
                return error
            }
        }
        await stopBarrier.waitUntilEntered(2)

        for thread in threads {
            XCTAssertNotNil(
                try ctx.threadRepo.get(id: thread.id),
                "no row may be deleted while any member of the batch is still stopping"
            )
        }
        stopBarrier.releaseAll(2)

        let failure = await deletion.value
        XCTAssertNotNil(failure, "one unconfirmed provider termination must fail the whole batch")
        for thread in threads {
            XCTAssertNotNil(
                try ctx.threadRepo.get(id: thread.id),
                "a failed batch must preserve every selected thread row"
            )
        }
    }

    func test_applicationTerminationBlocksDrainAlreadyAtDispatchBarrier() async throws {
        // WHY: app termination is synchronous and cannot await waiter tasks.
        // Its gate must make a waiter already inside drain abandon dispatch as
        // soon as that waiter resumes.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "quit-drain-barrier", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "quit drain barrier",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must remain queued at quit",
            attachments: [],
            interactionMode: .default
        )
        let barrier = QueueDrainAsyncBarrier()
        ctx.queueDrainBeforeDispatchForTesting = { await barrier.enterAndWait() }
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        runner.finishRun(ordinal: 1, status: .completed)
        await barrier.waitUntilEntered()

        let cancelledWaiters = ctx.prepareForApplicationTermination()
        await barrier.release()
        for waiter in cancelledWaiters {
            await waiter.value
        }

        XCTAssertEqual(runner.startCount, 1)
        XCTAssertEqual(
            try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.text),
            ["must remain queued at quit"]
        )
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_hundredLateIdleWaitersScheduleOneDeadlineAndZeroPeriodicPolls() async throws {
        // WHY: queue recovery is provider-idle driven. One hundred live threads
        // may each own one warning deadline, but must schedule zero periodic
        // MainActor/SQLite poll wakeups.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        ctx.queueDrainProviderIdleTimeout = 1_000
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let sleeper = QueueDrainTestSleeper()
        ctx.queueDrainSleepForTesting = { try await sleeper.sleep(threadId: $0, duration: $1) }
        let workspace = try router.createWorkspace(name: "causal-idle-scale", cwd: workspaceDir.path)
        var threads: [AgentThread] = []
        for index in 1...100 {
            let thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "causal \(index)",
                provider: .claude,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            threads.append(thread)
            _ = try await ctx.coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .claude,
                model: "test-model",
                cwd: workspaceDir.path,
                prompt: "long turn \(index)"
            ))
            _ = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "queued \(index)",
                attachments: [],
                interactionMode: .default
            )
            ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        }

        for thread in threads {
            await sleeper.waitForRequestCount(1, threadId: thread.id)
            let intervals = await sleeper.requestedIntervals(threadId: thread.id)
            XCTAssertEqual(intervals, [.seconds(1_000)],
                           "each thread may schedule one warning deadline and no periodic polls")
        }
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 100)
        _ = await ctx.acquireQueueDrainSuppressions(threadIds: threads.map(\.id))
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_agentAppDeleteThreadSuppressesQueuedDrainBeforeAwaitingProviderTermination() async throws {
        // WHY: the macOS Agent App owns a direct delete path in addition to the
        // router RPC. Both must suppress terminal-triggered queue drain before
        // awaiting provider shutdown or deletion can start work it is deleting.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: 0.05)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "agent-app-delete-no-drain", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Agent App delete no drain",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
        )
        surface.viewModel.selectThread(thread.id)
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "must never start from Agent App deletion",
            attachments: [],
            interactionMode: .default
        )

        let deleted = await surface.viewModel.deleteThread(thread.id)

        XCTAssertTrue(deleted)
        XCTAssertEqual(runner.startCount, 1,
                       "Agent App deletion shutdown must not start the queued follow-up")
        XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0)
    }

    func test_applicationTerminationSynchronouslyFlushesUsageAndCancelsQueueWaiters() async throws {
        // WHY: NSApplication termination does not await unstructured tasks.
        // Durable usage and queue-waiter cancellation must both finish before
        // the synchronous notification callback returns.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = DelayedCancelQueueRunner(provider: .claude, cancellationDelay: nil)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(name: "termination-flush", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "termination flush",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let started = try await router.sendAgentMessage(
            thread: thread.id,
            text: "existing turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let runId = try XCTUnwrap(started.runId)
        ctx.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(
                inputTokens: 321,
                outputTokens: 0,
                totalTokens: 321
            )),
            thread.id,
            runId
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "queued at quit",
            attachments: [],
            interactionMode: .default
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1)

        ctx.prepareForApplicationTermination()

        let usage = TokenSaverUsageStore(appSupportDirectory: ctx.appSupportDirectory).load()
        XCTAssertEqual(
            usage.providers.first { $0.provider == .claude }?.actualProviderTokens,
            321,
            "termination must persist pending usage before returning"
        )
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0,
                       "termination must cancel queue waiters before returning")
        runner.finishRun(ordinal: 1, status: .cancelled)
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

    func test_claudeSDKTerminalCallbackDrainsAndAcknowledgesNextQueueRowExactlyOnce() async throws {
        // WHY: AppContext starts queued work from the provider terminal callback.
        // The real Claude SDK adapter must already report the resident session
        // idle at that edge so the next row starts and is acknowledged without
        // scheduler yields, sleeps, or a later lifecycle event.
        guard ProcessLocator.resolve("node") != nil else {
            throw XCTSkip("node not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-sdk-causal-drain-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        let bridge = root.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = root.appendingPathComponent("commands.jsonl")
        let releaseFIFO = root.appendingPathComponent("release-first-turn")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        try Self.causalQueueFakeClaudeBridge(
            commandLogPath: commandLog.path,
            releaseFIFOPath: releaseFIFO.path
        ).write(to: bridge, atomically: true, encoding: .utf8)
        let mkfifo = Process()
        mkfifo.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        mkfifo.arguments = [releaseFIFO.path]
        try mkfifo.run()
        mkfifo.waitUntilExit()
        XCTAssertEqual(mkfifo.terminationStatus, 0)

        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        ctx.coordinator.replaceProviderAdapter(.claude, adapter: adapter)
        defer { adapter.stopAll() }
        let workspace = try router.createWorkspace(
            name: "Claude SDK causal drain",
            cwd: workspaceDir.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Claude SDK causal drain",
            provider: .claude,
            model: "sonnet",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        let first = try await router.sendAgentMessage(
            thread: thread.id,
            text: "hold the first turn",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(first.status, .started)
        let queuedResult = try await router.sendAgentMessage(
            thread: thread.id,
            text: "drain exactly once",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(queuedResult.status, .queued)
        let queued = try XCTUnwrap(queuedResult.queuedMessage)

        let drained = QueueDrainAsyncSignal()
        let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            guard $0.kind == "agent.message.queue.drained",
                  $0.payload.objectValue?["queued_message_id"]?.stringValue
                    == queued.id.value.uuidString else {
                return
            }
            Task { await drained.signal() }
        }
        defer { EventBus.shared.unsubscribe(drainedSubscription) }

        try await Task.detached {
            let handle = try FileHandle(forWritingTo: releaseFIFO)
            try handle.write(contentsOf: Data([0x31]))
            try handle.close()
        }.value
        await drained.wait()

        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id))
        let turnCommands = try Self.loggedClaudeBridgeCommands(
            at: commandLog,
            type: "rc_turn"
        )
        XCTAssertEqual(turnCommands.count, 2,
                       "the first turn and one queued turn must be the only provider writes")
        let prompts = turnCommands.compactMap { $0["prompt"] as? String }
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].hasSuffix("User request:\nhold the first turn"))
        XCTAssertTrue(prompts[1].hasSuffix("User request:\ndrain exactly once"))
    }

    func test_drainQueue_definiteStartFailureRequeuesForOneExplicitRetry() async throws {
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

        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.id), [queued.id],
                       "a definite pre-write failure must preserve the queue intent")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
        XCTAssertEqual(try ctx.messageRepo.list(threadId: thread.id).filter { $0.role == .user }.count, 1)
        let failedRun = try XCTUnwrap(ctx.runRepo.get(id: AgentRunID(queued.id.value)))
        XCTAssertEqual(failedRun.status, .failed,
                       "the visible failed run must explain the failed start without deleting the unaccepted queue intent")
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastRunId,
            failedRun.id,
            "start-failure persistence must retain the run-bound evidence needed if the host crashes before queue acknowledgement"
        )
        XCTAssertEqual(failing.startCount, 1,
                       "the same-call cleanup must not replay a failed provider start")

        do {
            _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
            XCTFail("the explicit retry must surface the provider failure")
        } catch {}
        XCTAssertEqual(failing.startCount, 2,
                       "Force must retry the definitely unaccepted prompt exactly once per action")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
    }

    func test_forceQueue_requeuesDefiniteFailureButPreservesAmbiguousTimeout() async throws {
        let startErrors: [(label: String, error: Error, claimsWrite: Bool, expectedState: AgentQueuedMessageDispatchState)] = [
            ("failure", AgentRunError.spawnFailed("intentional queue-start failure"), false, .queued),
            ("timeout", CodexAppServerError.requestTimedOut(method: "turn/start", timeout: 30), true, .prepared)
        ]

        for provider in AgentProvider.allCases {
          for startError in startErrors {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let workspace = try router.createWorkspace(name: "queue-force-\(startError.label)", cwd: workspaceDir.path)
            var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: provider, model: "test-model", permissionMode: .supervised, reasoningEffort: .medium)
            thread.status = .failed
            try ctx.threadRepo.upsert(thread)
            let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "one recovery surface", attachments: [], interactionMode: .default)
            let failing = ThrowingStartRunner(
                provider: provider,
                error: startError.error,
                claimAcceptanceBeforeThrow: startError.claimsWrite
            )
            ctx.coordinator.replaceProvider(provider, runner: failing)

            do {
                _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
                XCTFail("provider \(startError.label) must fail")
            } catch {}

            XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.id), [queued.id],
                           "same-call \(startError.label) is not positive provider acceptance evidence")
            XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, startError.expectedState)
            XCTAssertEqual(try ctx.messageRepo.list(threadId: thread.id).filter { $0.role == .user }.count, 1)
            XCTAssertEqual(try ctx.runRepo.get(id: AgentRunID(queued.id.value))?.status, .failed)
            XCTAssertEqual(failing.startCount, 1)
          }
        }
    }

    func test_grokPromptWriteFailurePersistsCanonicalStartFailureAndPreparedQueueAcrossRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let peer = try PromptWriteFailureGrokPeer(root: root.appendingPathComponent("peer"))
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        ctx.coordinator.replaceProviderAdapter(
            .grok,
            adapter: GrokACPAdapter(binaryNameOverride: peer.path)
        )
        let workspace = try router.createWorkspace(name: "grok-write-failure", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "grok write failure",
            provider: .grok,
            model: "account-live-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "preserve exact prompt",
            attachments: [],
            interactionMode: .default
        )

        do {
            _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
            XCTFail("the real ACP prompt write must fail")
        } catch {}

        let runId = AgentRunID(queued.id.value)
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastEventKind,
            "run.start_failed"
        )
        XCTAssertEqual(try ctx.runRepo.get(id: runId)?.status, .failed)
        let launchCountBeforeRecovery = peer.launchCount

        await router.reconcileQueuedAgentMessagesOnLaunch()

        XCTAssertEqual(peer.launchCount, launchCountBeforeRecovery + 1,
                       "relaunch reconciliation must retry a definitely rejected prompt once")
        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queued.id)?.text, "preserve exact prompt")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
    }

    func test_routerCoordinatorPreservesRevokedAcceptancePermitToEveryProviderWire() async throws {
        // WHY: queued requests are rebuilt inside AgentRunCoordinator. The
        // runtime-only permit must survive that copy or the real provider write
        // boundary silently receives nil and suppression cannot win.
        for provider in AgentProvider.allCases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("provider-permit-\(provider.rawValue)-\(UUID().uuidString)", isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let peer = try ProviderAcceptanceProbePeer(provider: provider, root: root.appendingPathComponent("peer"))
            let concrete: AgentProviderAdapter
            switch provider {
            case .codex:
                concrete = CodexAppServerAdapter(binaryNameOverride: peer.path)
            case .claude:
                concrete = ClaudeStreamingCLIAdapter(binaryNameOverride: peer.path)
            case .grok:
                concrete = GrokACPAdapter(binaryNameOverride: peer.path)
            }
            let revoking = RevokingAcceptanceAdapter(inner: concrete)
            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            ctx.coordinator.replaceProviderAdapter(provider, adapter: revoking)
            let workspace = try router.createWorkspace(
                name: "permit \(provider.rawValue)",
                cwd: workspaceDir.path
            )
            var thread = try router.createAgentThread(
                workspace: workspace.id,
                title: "permit \(provider.rawValue)",
                provider: provider,
                model: "account-live-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            thread.status = .failed
            try ctx.threadRepo.upsert(thread)
            let descriptor = try router.createSurface(
                workspace: workspace.id,
                type: .agentApp,
                paneID: nil,
                title: "Agent App"
            )
            let surface = try XCTUnwrap(
                SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
            )
            surface.viewModel.selectThread(thread.id)
            let queued = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "must not cross \(provider.rawValue) wire",
                attachments: [],
                interactionMode: .default
            )

            await surface.viewModel.forceQueuedMessageNow(queued)

            XCTAssertTrue(revoking.sawAcceptancePermit,
                          "local macOS Force must delegate through router/coordinator and preserve the \(provider.rawValue) permit")
            XCTAssertEqual(peer.acceptedPromptCount, 0,
                           "\(provider.rawValue) must receive no prompt bytes after revocation")
            XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
            XCTAssertEqual(
                try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastEventKind,
                "run.start_failed"
            )
            concrete.stopAll()
        }
    }

    func test_localAgentAppForceCannotCrossDeleteBulkOrTerminationSuppressionAcrossProviders() async throws {
        let destructiveActions = ["delete", "bulk", "termination"]
        for provider in AgentProvider.allCases {
            for action in destructiveActions {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("local-force-\(provider.rawValue)-\(action)-\(UUID().uuidString)", isDirectory: true)
                let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
                try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                defer { closeAndUnregisterAllSurfaces() }
                let peer = try ProviderAcceptanceProbePeer(
                    provider: provider,
                    root: root.appendingPathComponent("peer")
                )
                let concrete: AgentProviderAdapter
                switch provider {
                case .codex:
                    concrete = CodexAppServerAdapter(binaryNameOverride: peer.path)
                case .claude:
                    concrete = ClaudeStreamingCLIAdapter(binaryNameOverride: peer.path)
                case .grok:
                    concrete = GrokACPAdapter(binaryNameOverride: peer.path)
                }
                let ctx = try AppContext(
                    channel: .debug,
                    appSupportOverride: root.appendingPathComponent("support").path
                )
                let router = AppCommandRouter(context: ctx)
                ctx.router = router
                ctx.coordinator.replaceProviderAdapter(provider, adapter: concrete)
                let workspace = try router.createWorkspace(
                    name: "local force \(provider.rawValue) \(action)",
                    cwd: workspaceDir.path
                )
                var thread = try router.createAgentThread(
                    workspace: workspace.id,
                    title: action,
                    provider: provider,
                    model: "account-live-model",
                    permissionMode: .supervised,
                    reasoningEffort: .medium
                )
                thread.status = .failed
                try ctx.threadRepo.upsert(thread)
                let descriptor = try router.createSurface(
                    workspace: workspace.id,
                    type: .agentApp,
                    paneID: nil,
                    title: "Agent App"
                )
                let surface = try XCTUnwrap(
                    SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
                )
                surface.viewModel.selectThread(thread.id)
                let queued = try ctx.queuedMessageRepo.enqueue(
                    threadId: thread.id,
                    text: "must not survive \(action)",
                    attachments: [],
                    interactionMode: .default
                )
                let barrier = QueueDrainAsyncBarrier()
                router.queueDispatchBeforeProviderStartForTesting = {
                    await barrier.enterAndWait()
                }
                let force = Task {
                    await surface.viewModel.forceQueuedMessageNow(queued)
                }
                await barrier.waitUntilEntered()

                var terminationWaiters: [Task<Void, Never>] = []
                switch action {
                case "delete":
                    let deleted = await surface.viewModel.deleteThread(thread.id)
                    XCTAssertTrue(deleted)
                case "bulk":
                    let deleted = await surface.viewModel.deleteThreads([thread.id])
                    XCTAssertTrue(deleted)
                default:
                    terminationWaiters = ctx.prepareForApplicationTermination()
                }

                await barrier.release()
                await force.value
                for waiter in terminationWaiters { await waiter.value }
                XCTAssertEqual(
                    peer.acceptedPromptCount,
                    0,
                    "\(provider.rawValue) local Force must not cross \(action) suppression"
                )
                concrete.stopAll()
            }
        }
    }

    func test_localAgentAppPostClaimPreHandleForceSettlesBeforeDeleteBulkOrTerminationCompletes() async throws {
        // WHY: once the physical write claims acceptance, invalidation cannot
        // revoke it. Destructive flows must stop promptly, then await both that
        // claimed write and coordinator handle registration before they delete
        // durable state or certify termination.
        for action in ["delete", "bulk", "termination"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("post-claim-\(action)-\(UUID().uuidString)", isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            defer { closeAndUnregisterAllSurfaces() }
            let ctx = try AppContext(
                channel: .debug,
                appSupportOverride: root.appendingPathComponent("support").path
            )
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let startBarrier = PostClaimPreHandleStartBarrier()
            let runner = PostClaimPreHandleRunner(barrier: startBarrier)
            ctx.coordinator.replaceProvider(.claude, runner: runner)
            let workspace = try router.createWorkspace(
                name: "post claim \(action)",
                cwd: workspaceDir.path
            )
            var thread = try router.createAgentThread(
                workspace: workspace.id,
                title: action,
                provider: .claude,
                model: "test-model",
                permissionMode: .supervised,
                reasoningEffort: .medium
            )
            thread.status = .failed
            try ctx.threadRepo.upsert(thread)
            let descriptor = try router.createSurface(
                workspace: workspace.id,
                type: .agentApp,
                paneID: nil,
                title: "Agent App"
            )
            let surface = try XCTUnwrap(
                SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface
            )
            surface.viewModel.selectThread(thread.id)
            let queued = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "claimed before \(action)",
                attachments: [],
                interactionMode: .default
            )
            let force = Task {
                await surface.viewModel.forceQueuedMessageNow(queued)
            }
            await startBarrier.waitUntilClaimed()

            switch action {
            case "delete":
                let stopIssued = QueueDrainAsyncSignal()
                ctx.queueDrainSuppressionAcquiredForTesting = {
                    guard $0 == thread.id else { return }
                    await stopIssued.signal()
                }
                let deletion = Task {
                    await surface.viewModel.deleteThread(thread.id)
                }
                await stopIssued.wait()
                XCTAssertNotNil(
                    try ctx.threadRepo.get(id: thread.id),
                    "delete must wait while the claimed write has no provider handle"
                )
                startBarrier.releaseWrite()
                let deleted = await deletion.value
                XCTAssertTrue(deleted)
                XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
            case "bulk":
                let stopIssued = QueueDrainAsyncSignal()
                ctx.queueDrainSuppressionAcquiredForTesting = {
                    guard $0 == thread.id else { return }
                    await stopIssued.signal()
                }
                let deletion = Task {
                    await surface.viewModel.deleteThreads([thread.id])
                }
                await stopIssued.wait()
                XCTAssertNotNil(
                    try ctx.threadRepo.get(id: thread.id),
                    "bulk delete must preserve every row until the claimed start settles"
                )
                startBarrier.releaseWrite()
                let deleted = await deletion.value
                XCTAssertTrue(deleted)
                XCTAssertNil(try ctx.threadRepo.get(id: thread.id))
            default:
                let terminationWaiters = ctx.prepareForApplicationTermination()
                XCTAssertNotNil(
                    try ctx.threadRepo.get(id: thread.id),
                    "termination must return waiters for a claimed pre-handle write"
                )
                startBarrier.releaseWrite()
                for waiter in terminationWaiters {
                    await waiter.value
                }
            }

            await startBarrier.waitUntilCancelled()
            await force.value
            XCTAssertEqual(startBarrier.physicalWriteCount, 1)
            XCTAssertGreaterThanOrEqual(startBarrier.cancelCount, 1)
        }
    }

    func test_secondForceDuringPostClaimPreHandleStartKeepsFirstOwnerAndQueueIntent() async throws {
        // WHY: a claimed provider write has durable `.pending` state before its
        // adapter session/handle exists. A second Force must queue behind that
        // owner, not claim a second write or replace coordinator ownership.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-claim-second-force-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let startBarrier = PostClaimPreHandleStartBarrier()
        let runner = PostClaimPreHandleRunner(barrier: startBarrier)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let workspace = try router.createWorkspace(
            name: "post claim second Force",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "second Force",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let first = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "first pending owner",
            attachments: [],
            interactionMode: .default
        )
        let second = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "second preserved intent",
            attachments: [],
            interactionMode: .default
        )

        let firstForce = Task {
            try? await router.forceAgentQueuedMessageNow(id: first.id)
        }
        await startBarrier.waitUntilClaimed()

        let secondResult = try await router.forceAgentQueuedMessageNow(id: second.id)
        XCTAssertEqual(secondResult.status, .queued)
        XCTAssertEqual(secondResult.queuedMessage?.id, second.id)
        XCTAssertTrue(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastRunId,
            AgentRunID(first.id.value),
            "the first claimed run must retain pending provider ownership"
        )
        XCTAssertEqual(startBarrier.claimCount, 1,
                       "the second Force must not reach a second physical write")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: second.id)?.state, .queued)
        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: second.id)?.text, "second preserved intent")

        let secondDrained = QueueDrainAsyncSignal()
        let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            guard $0.kind == "agent.message.queue.drained",
                  $0.payload.objectValue?["queued_message_id"]?.stringValue
                    == second.id.value.uuidString else {
                return
            }
            Task { await secondDrained.signal() }
        }
        defer { EventBus.shared.unsubscribe(drainedSubscription) }
        startBarrier.releaseWrite()
        _ = await firstForce.value
        await startBarrier.waitUntilCancelled()
        await secondDrained.wait()
        XCTAssertEqual(startBarrier.claimCount, 2,
                       "the preserved second intent must drain only after the first owner settles")
        XCTAssertEqual(startBarrier.physicalWriteCount, 2)
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: second.id))
        ctx.coordinator.stopRun(threadId: thread.id)
    }

    func test_secondForceDuringOnRunPreparedPendingWindowStopsFirstOwnerAndDrains() async throws {
        // WHY: durable `.pending` is exposed before the adapter session and
        // physical-write helper exist. Pending ownership must already be
        // registered so Force interrupts that first owner instead of attempting
        // a competing start during the onRunPrepared suspension.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-second-force-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let startBarrier = PostClaimPreHandleStartBarrier()
        ctx.coordinator.replaceProvider(
            .claude,
            runner: PostClaimPreHandleRunner(barrier: startBarrier)
        )
        let preparedBarrier = QueueDrainAsyncBarrier()
        let originalOnRunPrepared = ctx.coordinator.onRunPrepared
        ctx.coordinator.onRunPrepared = { request, prompt in
            await originalOnRunPrepared?(request, prompt)
            await preparedBarrier.enterAndWait()
        }
        let workspace = try router.createWorkspace(
            name: "prepared second Force",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "prepared second Force",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let first = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "durable pending owner",
            attachments: [],
            interactionMode: .default
        )
        let second = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "force during prepared callback",
            attachments: [],
            interactionMode: .default
        )

        let firstForce = Task {
            try? await router.forceAgentQueuedMessageNow(id: first.id)
        }
        await preparedBarrier.waitUntilEntered()

        XCTAssertTrue(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.status, .pending)
        XCTAssertEqual(try ctx.runRepo.get(id: AgentRunID(first.id.value))?.status, .pending)
        XCTAssertEqual(startBarrier.claimCount, 0,
                       "the adapter write helper must not exist yet at this seam")

        let secondResult = try await router.forceAgentQueuedMessageNow(id: second.id)
        XCTAssertEqual(secondResult.status, .queued)
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: second.id)?.state, .queued)
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: thread.id)?.lastRunId,
            AgentRunID(first.id.value),
            "the first durable pending run must retain ownership"
        )

        let secondDrained = QueueDrainAsyncSignal()
        let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            guard $0.kind == "agent.message.queue.drained",
                  $0.payload.objectValue?["queued_message_id"]?.stringValue
                    == second.id.value.uuidString else {
                return
            }
            Task { await secondDrained.signal() }
        }
        defer { EventBus.shared.unsubscribe(drainedSubscription) }
        await preparedBarrier.release()
        _ = await firstForce.value
        await startBarrier.waitUntilClaimed()
        XCTAssertEqual(startBarrier.claimCount, 1)
        XCTAssertEqual(
            startBarrier.physicalWriteCount,
            0,
            "the invalidated first owner must stop before claiming a provider write"
        )
        startBarrier.releaseWrite()
        await secondDrained.wait()

        XCTAssertEqual(startBarrier.claimCount, 1,
                       "only the second intent may claim a provider write after the first owner settles")
        XCTAssertEqual(startBarrier.physicalWriteCount, 1)
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: second.id))
        ctx.coordinator.stopRun(threadId: thread.id)
    }

    func test_earlyAdmissionFailureCompletesConcurrentTerminationWithoutProviderWrite() async throws {
        // WHY: pending ownership is registered before provider admission. If
        // admission throws before sendTurn, a destructive waiter must observe
        // that failed completion rather than waiting five seconds for a handle
        // that can never exist. The prepared queue intent must roll back safely.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-failure-stop-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        ctx.coordinator.hardStopTimeout = 0.25
        let admissionBarrier = QueueDrainAsyncBarrier()
        ctx.coordinator.providerAdmissionCheck = { _, _ in
            await admissionBarrier.enterAndWait()
            throw NSError(
                domain: "ProviderSnapshotRuntimeTests.Admission",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "intentional admission rejection"]
            )
        }
        let workspace = try router.createWorkspace(
            name: "admission failure stop",
            cwd: workspaceDir.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "admission failure stop",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "preserve before provider admission",
            attachments: [],
            interactionMode: .default
        )

        let force = Task {
            do {
                _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
                return false
            } catch {
                return true
            }
        }
        await admissionBarrier.waitUntilEntered()

        XCTAssertTrue(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
        XCTAssertNil(runner.lastRequest)
        XCTAssertNil(try ctx.runRepo.get(id: AgentRunID(queued.id.value)))

        let terminationFinished = QueueDrainAsyncSignal()
        let termination = Task {
            do {
                try await ctx.coordinator.stopAndAwaitTermination(threadId: thread.id)
                await terminationFinished.signal()
                return true
            } catch {
                await terminationFinished.signal()
                return false
            }
        }
        for _ in 0..<1_000 {
            if try ctx.threadRepo.get(id: thread.id)?.status == .cancelled { break }
            await Task.yield()
        }
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.status, .cancelled,
                       "the concurrent termination task must reach the pending owner before admission is released")
        let terminationCompletedBeforeRelease = await terminationFinished.isSignalled
        XCTAssertFalse(terminationCompletedBeforeRelease)

        let releasedAt = ContinuousClock.now
        await admissionBarrier.release()
        let forceFailed = await force.value
        let terminationSucceeded = await termination.value
        XCTAssertTrue(forceFailed)
        XCTAssertTrue(terminationSucceeded,
                      "an early admission failure must complete termination without a hard timeout")
        XCTAssertLessThan(releasedAt.duration(to: .now), .milliseconds(200))

        XCTAssertFalse(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertNil(runner.lastRequest,
                     "provider admission failure must not cross the physical write boundary")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
        XCTAssertEqual(
            try ctx.queuedMessageRepo.get(id: queued.id)?.text,
            "preserve before provider admission"
        )
        XCTAssertNil(try ctx.runRepo.get(id: AgentRunID(queued.id.value)))
        XCTAssertTrue(try ctx.messageRepo.list(threadId: thread.id).isEmpty)
    }

    func test_pendingAdmissionTerminationUsesOneDeadlineAndPreservesDurableIntent() async throws {
        // WHY: provider admission may never resume. Destructive callers still
        // need one bounded shutdown deadline, and timeout must preserve both the
        // thread and its queued user intent instead of deleting unconfirmed work.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-admission-timeout-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        ctx.coordinator.gracefulStopTimeout = 0.02
        ctx.coordinator.hardStopTimeout = 0.12
        let admissionBarrier = QueueDrainAsyncBarrier()
        ctx.coordinator.providerAdmissionCheck = { _, _ in
            await admissionBarrier.enterAndWait()
        }
        let workspace = try router.createWorkspace(
            name: "pending admission timeout",
            cwd: workspaceDir.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "pending admission timeout",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "preserve across admission timeout",
            attachments: [],
            interactionMode: .default
        )
        let force = Task {
            do {
                _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
                return false
            } catch {
                return true
            }
        }
        await admissionBarrier.waitUntilEntered()

        let startedAt = ContinuousClock.now
        let deletionError = await Task { () -> Error? in
            do {
                try await router.deleteAgentThread(thread: thread.id)
                return nil
            } catch {
                return error
            }
        }.value

        XCTAssertEqual((deletionError as NSError?)?.code, 504)
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1),
                          "the pending-start wait must consume the same hard-stop deadline")
        XCTAssertNotNil(try ctx.threadRepo.get(id: thread.id),
                        "timeout cannot authorize destructive thread deletion")
        XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: queued.id),
                        "timeout must preserve the queued user intent")
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
        XCTAssertNil(runner.lastRequest,
                     "an admission timeout must not cross the provider write boundary")

        let cleanupSuppression = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        defer {
            ctx.releaseQueueDrainSuppression(
                threadId: thread.id,
                lease: cleanupSuppression
            )
        }
        await admissionBarrier.release()
        let forceFailed = await force.value
        XCTAssertTrue(forceFailed)
        XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .queued)
        XCTAssertFalse(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
    }

    func test_secondForceBeforePendingPersistenceStopsFirstWithoutProviderWrite() async throws {
        // WHY: pending ownership exists before the run/thread pending rows. A
        // second Force in that window must stop the first launch causally before
        // it claims a provider write, while keeping both user intents durable.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-persist-second-force-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = CompletingAcceptanceCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let admissionBarrier = QueueDrainAsyncBarrier()
        ctx.coordinator.providerAdmissionCheck = { _, _ in
            await admissionBarrier.enterAndWait()
        }
        let workspace = try router.createWorkspace(
            name: "pre persist second Force",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "pre persist second Force",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let first = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "first pre-persistence owner",
            attachments: [],
            interactionMode: .default
        )
        let second = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "second Force owner",
            attachments: [],
            interactionMode: .default
        )
        let firstForce = Task {
            do {
                _ = try await router.forceAgentQueuedMessageNow(id: first.id)
                return false
            } catch {
                return true
            }
        }
        await admissionBarrier.waitUntilEntered()

        XCTAssertTrue(ctx.coordinator.hasPendingProviderStart(threadId: thread.id))
        XCTAssertNil(try ctx.runRepo.get(id: AgentRunID(first.id.value)))
        XCTAssertTrue(runner.acceptedRunIDs.isEmpty)
        let secondResult = try await router.forceAgentQueuedMessageNow(id: second.id)
        XCTAssertEqual(secondResult.status, .queued)
        XCTAssertEqual(secondResult.queuedMessage?.id, second.id)

        let cleanupSuppression = await ctx.acquireQueueDrainSuppression(threadId: thread.id)
        await admissionBarrier.release()
        let firstForceFailed = await firstForce.value
        XCTAssertTrue(firstForceFailed)

        XCTAssertTrue(runner.acceptedRunIDs.isEmpty,
                       "the invalidated first launch must never claim a provider write")
        XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: first.id))
        XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: second.id))

        let secondDrained = QueueDrainAsyncSignal()
        let drainedSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            guard $0.kind == "agent.message.queue.drained",
                  $0.payload.objectValue?["queued_message_id"]?.stringValue
                    == second.id.value.uuidString else {
                return
            }
            Task { await secondDrained.signal() }
        }
        defer { EventBus.shared.unsubscribe(drainedSubscription) }

        ctx.releaseQueueDrainSuppression(
            threadId: thread.id,
            lease: cleanupSuppression
        )
        await secondDrained.wait()

        XCTAssertEqual(
            runner.acceptedRunIDs,
            [AgentRunID(second.id.value)],
            "releasing suppression must start the forced second intent exactly once"
        )
        XCTAssertNotNil(
            try ctx.queuedMessageRepo.get(id: first.id),
            "the invalidated first intent must remain durable for explicit recovery"
        )
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: second.id))
    }

    func test_continueRejectsPendingProviderStartBeforePersistence() async throws {
        // WHY: Continue must not race an admitted-but-not-yet-persisted launch
        // and create a second provider turn while durable status still looks idle.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-pending-start-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.claude, runner: runner)
        let admissionBarrier = QueueDrainAsyncBarrier()
        ctx.coordinator.providerAdmissionCheck = { _, _ in
            await admissionBarrier.enterAndWait()
        }
        let workspace = try router.createWorkspace(
            name: "continue pending start",
            cwd: workspaceDir.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "continue pending start",
            provider: .claude,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let initialStart = Task {
            do {
                _ = try await router.sendAgentMessage(
                    thread: thread.id,
                    text: "pending admission",
                    provider: nil,
                    model: nil,
                    permissionMode: nil,
                    reasoningEffort: nil
                )
                return false
            } catch {
                return true
            }
        }
        await admissionBarrier.waitUntilEntered()

        do {
            _ = try await router.continueAgentRun(thread: thread.id)
            XCTFail("Continue must reject pending provider ownership")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("active run"))
        }
        XCTAssertTrue(try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty,
                      "Continue must not enqueue an empty recovery prompt")
        XCTAssertNil(runner.lastRequest)

        ctx.coordinator.stopRun(threadId: thread.id)
        await admissionBarrier.release()
        let initialStartFailed = await initialStart.value
        XCTAssertTrue(initialStartFailed)
        XCTAssertNil(runner.lastRequest,
                     "the stopped pending launch must not reach the provider writer")
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

    func test_forceDispatchedQueueRowFinishesCleanupBeforeBusyThreadHandling() async throws {
        // WHY: dispatched is positive provider-start evidence. The recovery
        // action is ack-only even while that same provider run remains busy;
        // routing through Force promotion would try to interrupt or replay it.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("force-dispatched-busy-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(
            name: "force dispatched busy",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "force dispatched busy",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .running
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "provider already accepted",
            attachments: [],
            interactionMode: .default
        )
        let normalNext = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "normal next",
            attachments: [],
            interactionMode: .default
        )
        let forcedNext = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "forced next",
            attachments: [],
            interactionMode: .default
        )
        let lease = try XCTUnwrap(
            ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "accepted-provider-start")
        )
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        XCTAssertTrue(try ctx.queuedMessageRepo.markDispatched(lease, runId: runId))
        ctx.deferQueuePromotion(
            id: forcedNext.id,
            after: queued.id,
            threadId: thread.id
        )

        let result = try await router.forceAgentQueuedMessageNow(id: queued.id)

        XCTAssertEqual(result.status, .started)
        XCTAssertEqual(result.runId, runId)
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id))
        XCTAssertNil(runner.lastRequest,
                     "Finish cleanup must not call the provider or replay dispatched work")
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.status, .running,
                       "ack-only cleanup must not stop the already accepted provider run")
        XCTAssertEqual(
            try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.id),
            [forcedNext.id, normalNext.id],
            "dispatched cleanup must preserve the user's deferred Force priority"
        )
    }

    func test_automaticDispatchedRecoveryConsumesDeferredForceBeforeNextProviderWrite() async throws {
        // WHY: the automatic recovery path must consume the same owner-bound
        // promotion as the manual Finish cleanup action.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-dispatched-force-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(
            name: "automatic dispatched force",
            cwd: workspaceDir.path
        )
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "automatic dispatched force",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        let owner = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "accepted owner",
            attachments: [],
            interactionMode: .default
        )
        let normalNext = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "normal next",
            attachments: [],
            interactionMode: .default
        )
        let forcedNext = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "forced next",
            attachments: [],
            interactionMode: .default
        )
        let lease = try XCTUnwrap(
            ctx.queuedMessageRepo.claim(id: owner.id, leaseId: "accepted-owner")
        )
        let ownerRunId = AgentRunID(owner.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: ownerRunId))
        XCTAssertTrue(try ctx.queuedMessageRepo.markDispatched(lease, runId: ownerRunId))
        ctx.deferQueuePromotion(
            id: forcedNext.id,
            after: owner.id,
            threadId: thread.id
        )

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertEqual(runner.lastRequest?.runId, AgentRunID(forcedNext.id.value),
                       "automatic recovery must write only the deferred forced intent next")
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: owner.id))
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: forcedNext.id))
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).map(\.id), [normalNext.id])
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

    func test_forceQueuedMessagePreservesAmbiguousPreparedEvidenceBeforeBusyThread() async throws {
        // WHY: Force must not let a stale busy projection turn any ambiguous
        // start diagnostic into an acknowledgement or a replay.
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: provider)
        ctx.coordinator.replaceProvider(provider, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-force-busy-prepared", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: provider, model: "test-model", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .running
        try ctx.threadRepo.upsert(thread)
        let ambiguousEvidence: [(kind: String, status: AgentRunStatus)] = [
            ("run.pending", .pending),
            ("threadStarted(codex-thread-1)", .pending),
            ("run.start_failed", .failed),
            ("run.start_timeout", .failed)
        ]
        for (index, evidence) in ambiguousEvidence.enumerated() {
            let queued = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "do not preempt ambiguity \(index)",
                attachments: [],
                interactionMode: .default
            )
            let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "interrupted-start-\(index)"))
            let runId = AgentRunID(queued.id.value)
            XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
            try ctx.runRepo.upsert(AgentRun(
                id: runId,
                threadId: thread.id,
                provider: provider,
                model: "test-model",
                status: evidence.status
            ))
            try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
                threadId: thread.id,
                provider: provider,
                status: evidence.status,
                lastRunId: runId,
                lastEventKind: evidence.kind
            ))

            do {
                _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
                XCTFail("Force must fail loud while \(evidence.kind) leaves provider acceptance unconfirmed")
            } catch let error as JSONRPCError {
                XCTAssertTrue(error.message.contains("remains queued"),
                              "prepared \(evidence.kind) ambiguity must win over the stale busy-thread projection")
            }

            XCTAssertEqual(try ctx.queuedMessageRepo.dispatch(id: queued.id)?.state, .prepared)
        }
        XCTAssertNil(runner.lastRequest,
                     "Force must not stop/replay a prepared message before its prior start is resolved")
      }
    }

    func test_drainQueue_relaunchAcknowledgesPreparedHeadWithExistingRunWithoutProviderReplay() async throws {
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = RequestCaptureRunner(provider: provider)
        ctx.coordinator.replaceProvider(provider, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-existing-run", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: provider, model: "test-model", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .failed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "already represented by run", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        var failedRun = AgentRun(id: runId, threadId: thread.id, provider: provider, model: "test-model", status: .failed)
        failedRun.finishedAt = Date()
        failedRun.errorMessage = "provider start outcome retained"
        try ctx.runRepo.upsert(failedRun)
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: provider,
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
    }

    func test_drainQueueDoesNotUseLaterRunSessionEvidenceForPreparedEarlierRun() async throws {
        // WHY: provider-session diagnostics are thread-scoped. Without the
        // matching run id, a later turn's run.started can silently delete an
        // earlier prompt that crashed before provider acceptance.
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "queue-run-evidence", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(workspace: workspace.id, title: "queue", provider: provider, model: "test-model", permissionMode: .supervised, reasoningEffort: .medium)
        thread.status = .interrupted
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "run A must remain", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: queued.id, leaseId: "dead-process"))
        let runA = AgentRunID(queued.id.value)
        let runB = AgentRunID()
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runA))
        try ctx.runRepo.upsert(AgentRun(id: runA, threadId: thread.id, provider: provider, model: "test-model", status: .pending))
        var completedB = AgentRun(id: runB, threadId: thread.id, provider: provider, model: "test-model", status: .completed)
        completedB.finishedAt = Date()
        try ctx.runRepo.upsert(completedB)
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: provider,
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
    }

    func test_drainQueue_postAcceptMarkDispatchedFailureStillAcknowledgesWithoutReplay() async throws {
        // WHY: after acceptancePermit.accepted, markDispatched can return false
        // (CAS race / lease drift). The old path threw with providerStartConfirmed
        // true and left a sticky prepared head while the agent was already running.
        // finalizeQueueDispatchAfterProviderStart must fall back to
        // acknowledgePreparedWithRunEvidence without a second provider write.
      for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { closeAndUnregisterAllSurfaces() }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ConcurrentPreparedAckRunner(
            provider: provider,
            queuedMessageRepo: ctx.queuedMessageRepo
        )
        ctx.coordinator.replaceProvider(provider, runner: runner)
        let workspace = try router.createWorkspace(name: "queue-mark-fail", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "queue",
            provider: provider,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .completed
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "accept then CAS-lose",
            attachments: [],
            interactionMode: .default
        )

        try await router.drainNextQueuedAgentMessage(thread: thread.id)

        XCTAssertEqual(runner.startCount, 1, "provider must start exactly once")
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id),
                     "post-accept markDispatched failure must still drain the prepared head")
        XCTAssertEqual(try ctx.runRepo.get(id: AgentRunID(queued.id.value))?.status, .running)
      }
    }

    private static func causalQueueFakeClaudeBridge(
        commandLogPath: String,
        releaseFIFOPath: String
    ) -> String {
        """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const commandLog = '\(commandLogPath)';
        const releaseFIFO = '\(releaseFIFOPath)';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        let turn = 0;
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        function finishTurn(ordinal) {
          write({
            type: 'result',
            subtype: 'success',
            is_error: false,
            result: 'DONE_' + ordinal,
            session_id: 'sdk-causal-queue'
          });
        }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const command = JSON.parse(line);
          fs.appendFileSync(commandLog, JSON.stringify(command) + '\\n');
          if (command.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-causal-queue' });
          } else if (command.type === 'rc_turn') {
            turn += 1;
            if (turn === 1) {
              const gate = fs.createReadStream(releaseFIFO);
              gate.once('data', () => {
                gate.close();
                finishTurn(turn);
              });
            } else {
              finishTurn(turn);
            }
          } else if (command.type === 'rc_close') {
            process.exit(0);
          }
        }
        """
    }

    private static func loggedClaudeBridgeCommands(
        at url: URL,
        type: String
    ) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else {
                    return nil
                }
                return object
            }
            .filter { ($0["type"] as? String) == type }
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
    let error: Error
    let claimAcceptanceBeforeThrow: Bool
    private let lock = NSLock()
    private var starts = 0
    init(
        provider: AgentProvider,
        error: Error = AgentRunError.spawnFailed("intentional queue-start failure"),
        claimAcceptanceBeforeThrow: Bool = false
    ) {
        self.provider = provider
        self.error = error
        self.claimAcceptanceBeforeThrow = claimAcceptanceBeforeThrow
    }
    var startCount: Int { lock.withLock { starts } }
    func listModels() async -> [AgentModelDescriptor] { [] }
    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.withLock { starts += 1 }
        if claimAcceptanceBeforeThrow, let acceptancePermit = request.acceptancePermit {
            try acceptancePermit.withAcceptance { throw error }
        }
        throw error
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

/// Accepts the provider write, then deletes the matching prepared queue row so
/// the caller's subsequent `markDispatched` CAS returns false — proving the
/// post-accept finalize fallback path.
private final class ConcurrentPreparedAckRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    let queuedMessageRepo: AgentQueuedMessageRepository
    private let lock = NSLock()
    private var starts = 0

    init(provider: AgentProvider, queuedMessageRepo: AgentQueuedMessageRepository) {
        self.provider = provider
        self.queuedMessageRepo = queuedMessageRepo
    }

    var startCount: Int { lock.withLock { starts } }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock { starts += 1 }
        guard let acceptancePermit = request.acceptancePermit else {
            throw AgentRunAcceptanceError.cancelled
        }
        try acceptancePermit.withAcceptance {
            _ = try queuedMessageRepo.acknowledgePreparedWithRunEvidence(
                id: AgentQueuedMessageID(request.runId.value),
                runId: request.runId
            )
        }
        // Leave the run non-terminal so post-accept recovery is visible while
        // the provider turn is still considered live.
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class CompletingAcceptanceCaptureRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var capturedRunIDs: [AgentRunID] = []

    init(provider: AgentProvider) {
        self.provider = provider
    }

    var acceptedRunIDs: [AgentRunID] {
        lock.withLock { capturedRunIDs }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        guard let acceptancePermit = request.acceptancePermit else {
            throw AgentRunAcceptanceError.cancelled
        }
        try acceptancePermit.withAcceptance {
            lock.withLock { capturedRunIDs.append(request.runId) }
        }
        Task.detached {
            onEvent(.status(.completed))
            onEvent(.finished(
                .completed,
                finalMessage: "accepted",
                providerThreadId: request.providerThreadId
            ))
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

private final class DelayedCancelQueueRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var starts = 0
    private var callbacks: [Int: @Sendable (AgentRunEvent) -> Void] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishWasMainThread = true
    private let finishOnCancel: Bool

    init(provider: AgentProvider, cancellationDelay: TimeInterval? = nil) {
        self.provider = provider
        self.finishOnCancel = cancellationDelay != nil
    }

    var startCount: Int {
        lock.withLock { starts }
    }
    var lastFinishWasMainThread: Bool {
        lock.withLock { finishWasMainThread }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let ordinal = lock.withLock { () -> Int in
            starts += 1
            callbacks[starts] = onEvent
            let ready = startWaiters.filter { $0.0 <= starts }
            startWaiters.removeAll { $0.0 <= starts }
            ready.forEach { $0.1.resume() }
            return starts
        }
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) {
            guard ordinal == 1, self.finishOnCancel else { return }
            self.finishRun(ordinal: ordinal, status: .cancelled)
        }
    }

    func waitForStartCount(_ count: Int) async {
        if lock.withLock({ starts >= count }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard starts < count else { return true }
                startWaiters.append((count, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func finishRun(ordinal: Int, status: AgentRunStatus) {
        guard let callback = lock.withLock({
            finishWasMainThread = Thread.isMainThread
            return callbacks.removeValue(forKey: ordinal)
        }) else { return }
        callback(.status(status))
        callback(.finished(status, finalMessage: nil, providerThreadId: "delayed-session"))
    }
}

private final class ConcurrentBulkStopRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .claude
    private let failingThreadId: AgentThreadID
    private let barrier: ConcurrentBulkStopBarrier

    init(failingThreadId: AgentThreadID, barrier: ConcurrentBulkStopBarrier) {
        self.failingThreadId = failingThreadId
        self.barrier = barrier
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) {
            self.barrier.enterAndBlock(threadId: request.threadId)
            guard request.threadId != self.failingThreadId else { return }
            onEvent(.status(.cancelled))
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
        }
    }
}

private final class PostClaimPreHandleRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .claude
    private let barrier: PostClaimPreHandleStartBarrier

    init(barrier: PostClaimPreHandleStartBarrier) {
        self.barrier = barrier
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        guard let acceptancePermit = request.acceptancePermit else {
            throw AgentRunAcceptanceError.cancelled
        }
        try acceptancePermit.withAcceptance {
            barrier.claimAndBlockPhysicalWrite()
        }
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) {
            self.barrier.recordCancellation()
            onEvent(.status(.cancelled))
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
        }
    }
}

private final class PostClaimPreHandleStartBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let writeRelease = DispatchSemaphore(value: 0)
    private var claimed = false
    private var claims = 0
    private var writes = 0
    private var cancellations = 0
    private var claimWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    var physicalWriteCount: Int { lock.withLock { writes } }
    var claimCount: Int { lock.withLock { claims } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func claimAndBlockPhysicalWrite() {
        let claim = lock.withLock { () -> (Int, [CheckedContinuation<Void, Never>]) in
            claimed = true
            claims += 1
            let waiters = claimWaiters
            claimWaiters.removeAll()
            return (claims, waiters)
        }
        claim.1.forEach { $0.resume() }
        if claim.0 == 1 {
            writeRelease.wait()
        }
        lock.withLock { writes += 1 }
    }

    func waitUntilClaimed() async {
        if lock.withLock({ claimed }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard !claimed else { return true }
                claimWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseWrite() {
        writeRelease.signal()
    }

    func recordCancellation() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            cancellations += 1
            let waiters = cancellationWaiters
            cancellationWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func waitUntilCancelled() async {
        if lock.withLock({ cancellations > 0 }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard cancellations == 0 else { return true }
                cancellationWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private final class ConcurrentBulkStopBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var enteredThreadIds = Set<AgentThreadID>()
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func enterAndBlock(threadId: AgentThreadID) {
        let entry = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            guard enteredThreadIds.insert(threadId).inserted else { return (false, []) }
            let count = enteredThreadIds.count
            let ready = waiters.filter { $0.0 <= count }.map(\.1)
            waiters.removeAll { $0.0 <= count }
            return (true, ready)
        }
        guard entry.0 else { return }
        entry.1.forEach { $0.resume() }
        releaseSemaphore.wait()
    }

    func waitUntilEntered(_ expected: Int) async {
        if lock.withLock({ enteredThreadIds.count >= expected }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard enteredThreadIds.count < expected else { return true }
                waiters.append((expected, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseAll(_ count: Int) {
        for _ in 0..<count {
            releaseSemaphore.signal()
        }
    }
}

private final class QueueFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let threadId: String
    private var value = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(threadId: AgentThreadID) {
        self.threadId = threadId.value.uuidString
    }

    var count: Int { lock.withLock { value } }

    func record(_ event: EventBus.Event) {
        guard event.kind == "agent.message.queue.failed",
              event.payload.objectValue?["thread_id"]?.stringValue == threadId else { return }
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            value += 1
            let ready = waiters.filter { $0.0 <= value }.map(\.1)
            waiters.removeAll { $0.0 <= value }
            return ready
        }
        ready.forEach { $0.resume() }
    }

    func waitForCount(_ count: Int) async {
        if lock.withLock({ value >= count }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard value < count else { return true }
                waiters.append((count, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private final class QueueEventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let threadId: String
    private let kind: String
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(threadId: AgentThreadID, kind: String) {
        self.threadId = threadId.value.uuidString
        self.kind = kind
    }

    func record(_ event: EventBus.Event) {
        guard event.kind == kind,
              event.payload.objectValue?["thread_id"]?.stringValue == threadId else { return }
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            count += 1
            let ready = waiters.filter { $0.0 <= count }.map(\.1)
            waiters.removeAll { $0.0 <= count }
            return ready
        }
        ready.forEach { $0.resume() }
    }

    func waitForCount(_ expected: Int) async {
        if lock.withLock({ count >= expected }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard count < expected else { return true }
                waiters.append((expected, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private actor QueueDrainAsyncSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    var isSignalled: Bool { signalled }
}

private actor QueueDrainTestSleeper {
    private struct PendingSleep {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Duration, Error>
    }

    private var elapsedByThread: [AgentThreadID: Duration] = [:]
    private var intervalsByThread: [AgentThreadID: [Duration]] = [:]
    private var pendingByThread: [AgentThreadID: PendingSleep] = [:]
    private var requestWaiters: [AgentThreadID: [(Int, CheckedContinuation<Void, Never>)]] = [:]
    private var cancelledSleepIDs = Set<UUID>()

    func sleep(threadId: AgentThreadID, duration: Duration) async throws -> Duration {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || cancelledSleepIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                intervalsByThread[threadId, default: []].append(duration)
                pendingByThread[threadId] = PendingSleep(
                    id: id,
                    duration: duration,
                    continuation: continuation
                )
                resumeSatisfiedRequestWaiters(threadId: threadId)
            }
        } onCancel: {
            Task { await self.cancel(threadId: threadId, sleepID: id) }
        }
    }

    func advanceNext(threadId: AgentThreadID) async {
        if pendingByThread[threadId] == nil {
            await waitForRequestCount(
                intervalsByThread[threadId, default: []].count + 1,
                threadId: threadId
            )
        }
        guard let pending = pendingByThread.removeValue(forKey: threadId) else { return }
        let elapsed = elapsedByThread[threadId, default: .zero] + pending.duration
        elapsedByThread[threadId] = elapsed
        pending.continuation.resume(returning: elapsed)
    }

    func waitForRequestCount(_ count: Int, threadId: AgentThreadID) async {
        guard intervalsByThread[threadId, default: []].count < count else { return }
        await withCheckedContinuation {
            requestWaiters[threadId, default: []].append((count, $0))
        }
    }

    func requestedIntervals(threadId: AgentThreadID) -> [Duration] {
        intervalsByThread[threadId, default: []]
    }

    private func cancel(threadId: AgentThreadID, sleepID: UUID) {
        guard let pending = pendingByThread[threadId], pending.id == sleepID else {
            cancelledSleepIDs.insert(sleepID)
            return
        }
        pendingByThread.removeValue(forKey: threadId)
        pending.continuation.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedRequestWaiters(threadId: AgentThreadID) {
        let count = intervalsByThread[threadId, default: []].count
        let waiters = requestWaiters.removeValue(forKey: threadId) ?? []
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if waiter.0 <= count {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        if !remaining.isEmpty {
            requestWaiters[threadId] = remaining
        }
    }
}

private actor QueueDrainAsyncBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class PromptWriteFailureGrokPeer {
    let root: URL
    let path: String
    private let launchCountPath: String

    var launchCount: Int {
        ((try? String(contentsOfFile: launchCountPath, encoding: .utf8)) ?? "").count
    }

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("grok")
        launchCountPath = root.appendingPathComponent("launch-count").path
        let source = #"""
        #!/bin/sh
        printf x >> "COUNT_PATH"
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
          if printf '%s' "$line" | grep -q '"method":"initialize"'; then
            printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":true},"sessionCapabilities":{}}}}\n' "$id"
          elif printf '%s' "$line" | grep -q '"method":"session.*new"'; then
            exec 0<&-
            printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"session-fixed","models":{"currentModelId":"account-live-model","availableModels":[{"modelId":"account-live-model","name":"Live"}]},"modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"}]}}}\n' "$id"
            exec tail -f "COUNT_PATH" >/dev/null
          fi
        done
        """#
            .replacingOccurrences(of: "COUNT_PATH", with: launchCountPath)
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        path = script.path
    }
}

private final class RevokingAcceptanceAdapter: AgentProviderAdapter, @unchecked Sendable {
    private let inner: AgentProviderAdapter
    private let lock = NSLock()
    private var sawPermit = false

    init(inner: AgentProviderAdapter) {
        self.inner = inner
    }

    var provider: AgentProvider { inner.provider }
    var forkSafety: AgentProviderForkSafety { inner.forkSafety }
    var sawAcceptancePermit: Bool { lock.withLock { sawPermit } }

    func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety {
        inner.forkSafety(threadId: threadId)
    }

    func listModels() async -> [AgentModelDescriptor] { await inner.listModels() }

    func startSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try await revokeAndSend(request, onEvent: onEvent)
    }

    func sendTurn(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try await revokeAndSend(request, onEvent: onEvent)
    }

    private func revokeAndSend(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        if let permit = request.acceptancePermit {
            lock.withLock { sawPermit = true }
            permit.invalidate()
        }
        return try await inner.sendTurn(request, onEvent: onEvent)
    }

    func interruptTurn(threadId: AgentThreadID) throws {
        try inner.interruptTurn(threadId: threadId)
    }

    func respondToRequest(
        threadId: AgentThreadID,
        requestId: String,
        response: AgentProviderRequestResponse
    ) async throws {
        try await inner.respondToRequest(threadId: threadId, requestId: requestId, response: response)
    }

    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        try inner.respondToUserInput(threadId: threadId, requestId: requestId, text: text)
    }

    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        try inner.cancelUserInput(threadId: threadId, requestId: requestId)
    }

    func stopSession(threadId: AgentThreadID) throws {
        try inner.stopSession(threadId: threadId)
    }

    func recoverSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {
        try await inner.recoverSession(request, onEvent: onEvent)
    }

    func listSessions() -> [AgentProviderSessionSummary] { inner.listSessions() }
    func hasSession(threadId: AgentThreadID) -> Bool { inner.hasSession(threadId: threadId) }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        try await inner.readThread(threadId: threadId)
    }
    func forkThread(threadId: AgentThreadID) async throws -> String {
        try await inner.forkThread(threadId: threadId)
    }
    func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        try await inner.forkThread(request)
    }
    func compensateFork(
        _ request: AgentProviderForkRequest,
        providerChildThreadId: String
    ) async throws {
        try await inner.compensateFork(request, providerChildThreadId: providerChildThreadId)
    }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        try await inner.rollbackThread(threadId: threadId, toTurnId: toTurnId)
    }
    func stopAll() { inner.stopAll() }
    func stopAllForAppTermination() { inner.stopAllForAppTermination() }
    func streamEvents(
        threadId: AgentThreadID,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) throws {
        try inner.streamEvents(threadId: threadId, onEvent: onEvent)
    }
}

private final class ProviderAcceptanceProbePeer {
    let path: String
    private let markerPath: String

    var acceptedPromptCount: Int {
        ((try? String(contentsOfFile: markerPath, encoding: .utf8)) ?? "").count
    }

    init(provider: AgentProvider, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        markerPath = root.appendingPathComponent("accepted-prompts").path
        let script = root.appendingPathComponent(provider.rawValue)
        let source: String
        switch provider {
        case .codex:
            source = """
            #!/usr/bin/env python3
            import json, pathlib, sys
            marker = pathlib.Path(\(String(reflecting: markerPath)))
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                if method == "initialize":
                    result = {"userAgent": "permit-probe"}
                elif method == "thread/start":
                    result = {"thread": {"id": "codex-thread", "turns": [], "status": {"state": "idle"}}}
                elif method == "turn/start":
                    marker.write_text("x")
                    result = {"turn": {"id": "codex-turn"}}
                else:
                    result = {}
                print(json.dumps({"id": message["id"], "result": result}), flush=True)
            """
        case .claude:
            source = """
            #!/usr/bin/env python3
            import json, pathlib, sys
            marker = pathlib.Path(\(String(reflecting: markerPath)))
            print(json.dumps({"type":"system","subtype":"init","session_id":"claude-thread"}), flush=True)
            for line in sys.stdin:
                if line.strip():
                    marker.write_text("x")
            """
        case .grok:
            source = """
            #!/usr/bin/env python3
            import json, pathlib, sys
            marker = pathlib.Path(\(String(reflecting: markerPath)))
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                if method == "initialize":
                    result = {"protocolVersion":1,"agentCapabilities":{"loadSession":True,"promptCapabilities":{"image":False,"audio":False,"embeddedContext":True},"sessionCapabilities":{}}}
                elif method == "session/new":
                    result = {"sessionId":"grok-thread","models":{"currentModelId":"account-live-model","availableModels":[{"modelId":"account-live-model","name":"Live"}]},"modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"}]}}
                elif method == "session/prompt":
                    marker.write_text("x")
                    result = {"stopReason":"end_turn"}
                else:
                    result = {}
                print(json.dumps({"jsonrpc":"2.0","id":message["id"],"result":result}), flush=True)
            """
        }
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        path = script.path
    }
}
