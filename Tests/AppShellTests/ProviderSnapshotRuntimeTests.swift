import XCTest
@testable import AppShell
@testable import CoreModel
@testable import AgentRuntime
@testable import SocketServer
@testable import Surfaces

@MainActor
final class ProviderSnapshotRuntimeTests: XCTestCase {
    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
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
        XCTAssertTrue(codex.slashCommands.contains("/review"))
        XCTAssertEqual(codex.skills, ["sam-review-code"],
                       "provider snapshots must discover Codex skills from the selected CODEX_HOME so composer suggestions reflect the active provider instance")
        let count = try String(contentsOf: probeCount, encoding: .utf8)
        XCTAssertEqual(count, "avh",
                       "provider cards reload frequently; runtime CLI probes must be cached per binary/home so repeated refreshes do not keep spawning Codex or Claude and stall the app")
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

        XCTAssertEqual(claude.models.map(\.id), ["opus", "sonnet", "haiku"],
                       "provider snapshots must use versionless Claude Code model aliases when the dynamic Anthropic Models API is unavailable")
        XCTAssertEqual(claude.models.first?.supportedReasoningEfforts, AgentReasoningEffort.supportedCases,
                       "alias fallback models must preserve thinking controls on macOS and iOS")
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
