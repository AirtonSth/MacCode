import XCTest
import CoreModel
import AgentRuntime
import DistillCore
import Persistence
@testable import AppShell

@MainActor
final class TokenSaverAppContextTests: XCTestCase {
    private actor FakeTokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing {
        let response: [AssistantAccountUsage]
        private(set) var requests: [TokenSaverAccountUsageRefreshRequest] = []

        init(response: [AssistantAccountUsage]) {
            self.response = response
        }

        func refreshAccountUsage(_ request: TokenSaverAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            requests.append(request)
            return response
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func savePrivateSession(in context: AppContext, subscribed: Bool = true) {
        PrivateAccountSessionStore(repo: context.settingsRepo).save(PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: subscribed ? "paid@example.com" : "unpaid@example.com",
                id: subscribed ? "paid-user" : "unpaid-user",
                subscribed: subscribed
            )
        ))
    }

    func test_appContextInstallsManagedDistillSkillsWithoutProviderGlobalConfigWrites() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkills-" + UUID().uuidString

        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 2)
        let codexSkill = URL(fileURLWithPath: appSupport)
            .appendingPathComponent("AgentSkills/codex/distill/SKILL.md")
        let claudeSkill = URL(fileURLWithPath: appSupport)
            .appendingPathComponent("AgentSkills/claude/distill/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexSkill.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: appSupport).appendingPathComponent(".codex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: appSupport).appendingPathComponent(".claude").path))

        let skillText = try String(contentsOf: codexSkill)
        XCTAssertTrue(skillText.contains("source: https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md"))
        XCTAssertTrue(skillText.contains("S=state"))
        XCTAssertTrue(skillText.contains("P=proof"))
    }

    func test_tokenSaverDistillLaunchPlannerOnlyStartsForPaidEnabledInstalledModel() {
        XCTAssertEqual(
            TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
                hasPrivateAccount: false,
                isSubscribed: false,
                tokenSaverEnabled: true,
                modelValidation: .installed
            )),
            .skip(reason: "private account not signed in")
        )

        XCTAssertEqual(
            TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
                hasPrivateAccount: true,
                isSubscribed: false,
                tokenSaverEnabled: true,
                modelValidation: .installed
            )),
            .skip(reason: "subscription required")
        )

        XCTAssertEqual(
            TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
                hasPrivateAccount: true,
                isSubscribed: true,
                tokenSaverEnabled: true,
                modelValidation: TokenSaverModelValidation(state: .missing, reason: "manifest missing")
            )),
            .requireModel(reason: "manifest missing")
        )

        XCTAssertEqual(
            TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
                hasPrivateAccount: true,
                isSubscribed: true,
                tokenSaverEnabled: true,
                modelValidation: .installed
            )),
            .start
        )
    }

    func test_tokenSaverDistillServiceDoesNotAutoResolveExecutableInsideUnitTests() {
        XCTAssertNil(
            TokenSaverDistillServiceController.defaultExecutableURL(),
            "unit tests must not auto-spawn the sidecar because leaked child processes can corrupt later process-sweeper coverage"
        )
    }

    func test_appContextRefreshesTokenSaverAccountUsageFromProviderCommands() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverAccountUsage-" + UUID().uuidString
        let refresher = FakeTokenSaverAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 57, weeklyWindowDurationMinutes: 10_080, currentSessionUsedPercent: 3),
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 34, weeklyWindowDurationMinutes: 10_080, currentSessionUsedPercent: 13)
        ])
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            tokenSaverAccountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshTokenSaverAccountUsage(reason: "test")

        let didPersist = await waitUntil {
            let snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
            let claude = snapshot.providers.first { $0.provider == .claude }
            let codex = snapshot.providers.first { $0.provider == .codex }
            return claude?.weeklyUsedPercent == 57
                && claude?.currentSessionUsedPercent == 3
                && codex?.weeklyUsedPercent == 34
                && codex?.currentSessionUsedPercent == 13
        }
        XCTAssertTrue(didPersist,
                      "startup/details/periodic refresh must persist real provider weekly percentages for the Token Saver rings")
        XCTAssertEqual(context.tokenSaverAccountUsageRefreshCount, 1)
        let requests = await refresher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.codexBinary, "codex")
        XCTAssertEqual(requests.first?.claudeBinary, "claude")
    }

    func test_appContextSkipsTokenSaverAccountUsageRefreshWhenNotSignedIn() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverNoAccountUsage-" + UUID().uuidString
        let refresher = FakeTokenSaverAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 34)
        ])
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            tokenSaverAccountUsageRefresher: refresher
        )

        context.refreshTokenSaverAccountUsage(reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(context.tokenSaverAccountUsageRefreshCount, 0)
        let requests = await refresher.requests
        XCTAssertTrue(requests.isEmpty,
                      "provider limit commands must not run before a RemoteCode private account is signed in")
    }

    func test_tokenSaverAccountUsageRefreshIntervalIsFiveMinutes() {
        XCTAssertEqual(AppDelegate.tokenSaverAccountUsageRefreshInterval, 300)
    }

    func test_tokenSaverCompressionCompressesPromptAndRecordsMeasuredSavingsToDB() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverCompress-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        // Real in-process distill service (LocalDistillRuntime, no MLX needed).
        let configuration = try DistillServiceConfiguration(
            authToken: "test-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "test-token")

        let bigPrompt = (1...40)
            .map { "line \($0): a verbose instruction line that the distiller will compress away" }
            .joined(separator: "\n")
        XCTAssertGreaterThan(bigPrompt.count, 600)

        let compressed = await context.tokenSaverCompress(prompt: bigPrompt, provider: .claude)

        XCTAssertNotEqual(compressed, bigPrompt, "an enabled Token Saver with a reachable model must compress a large prompt")
        XCTAssertLessThan(compressed.count, bigPrompt.count, "compressed prompt must be smaller than the original")

        let summary = try context.tokenSaverSavingsRepo.summary()
        let claude = try XCTUnwrap(summary.savings(for: "claude"),
                                   "a measured savings row must be persisted to the local DB for the compressed run")
        XCTAssertGreaterThan(claude.savedTokens, 0)
        XCTAssertEqual(claude.runs, 1)
        XCTAssertGreaterThan(summary.averageSavedPerRun, 0, "the per-run average (média) must be computable from real data")
    }

    func test_tokenSaverCompressionIsNoOpWhenDisabledOrTooShort() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverNoop-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

        let configuration = try DistillServiceConfiguration(authToken: "t", appSupportDirectory: appSupport)
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "t")

        let bigPrompt = String(repeating: "verbose line to compress here\n", count: 40)

        // Disabled → verbatim passthrough, no DB rows.
        let disabled = await context.tokenSaverCompress(prompt: bigPrompt, provider: .claude)
        XCTAssertEqual(disabled, bigPrompt)
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)

        // Enabled but tiny prompt → below threshold, passthrough, no DB rows.
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let tiny = await context.tokenSaverCompress(prompt: "fix typo", provider: .claude)
        XCTAssertEqual(tiny, "fix typo")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)
    }

    func test_tokenSaverDistillServiceControllerStartsInjectedSidecarForPaidEnabledInstalledModel() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2PaidTokenSaverLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let executable = appSupport.appendingPathComponent("FakeRemoteCodeDistillService")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"ready","base_url":"http://127.0.0.1:18181","host":"127.0.0.1","port":18181,"pid":12345,"protocol":1,"runtime":"mlx","model_id":"samuelfaj/distill-1.7B-4bit-MLX","max_concurrent_requests":8,"max_queue_depth":64}'
        exec 1>/dev/null
        sleep 20
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: appSupport,
            executableURLResolver: { executable }
        )
        let session = PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid-user",
                subscribed: true
            )
        )

        controller.startIfEligible(
            session: session,
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )

        let ready = await waitUntil {
            if case .running = controller.status { return true }
            return false
        }
        XCTAssertTrue(ready,
                      "paid subscribed launches with Token Saver enabled and a verified model must spawn the managed sidecar")
        guard case .running(let event) = controller.status else {
            return XCTFail("expected running Token Saver sidecar status")
        }
        XCTAssertEqual(event.runtime, DistillApprovedModel.runtime)
        XCTAssertEqual(event.modelID, DistillApprovedModel.id)
        XCTAssertEqual(event.maxConcurrentRequests, 8)
        XCTAssertEqual(event.maxQueueDepth, 64)
        XCTAssertNotNil(controller.bearerToken)

        controller.stop()
    }
}
