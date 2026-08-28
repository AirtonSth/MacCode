import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime
@testable import DistillCore
@testable import AppShell

/// Token Saver on must admit Distill + the global PATH interceptor for every
/// provider on Agent App threads and Bot Desk sends. PostToolUse stays Claude-only.
@MainActor
final class TokenSaverBotAgentAppInterceptorTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "rc-ts-bot-agent-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
        UserDefaults.standard.removeObject(forKey: "bots.screen")
        UserDefaults.standard.removeObject(forKey: "bots.deskRouting")
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directory = nil
    }

    static func exerciseBotToAgentAppGraphifyRequiresAuthoritativeOwningWorkspaceRecord(
        directory: String
    ) async throws {
        // WHY: Graphify resolve/ensure/query-first state is consequential host
        // work. The actual send gate must strip hostile leftovers and skip the
        // service unless the persisted owning workspace and admitted same-user
        // receipt agree exactly; caller cwd is never authority.
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let ownerRoot = (directory as NSString).appendingPathComponent("graphify-owner")
        try FileManager.default.createDirectory(atPath: ownerRoot, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "Owner", cwd: ownerRoot)
        var thread = AgentThread(
            workspaceId: workspace.id,
            title: "Owned continuation",
            provider: .codex,
            model: "test"
        )
        try context.threadRepo.upsert(thread)
        SettingsStore(db: context.db).save(AppSettings(
            tokenSaverEnabled: true,
            graphifyEnabled: true,
            graphifyAutoEnsure: true
        ))
        defer {
            GraphifyWorkspaceService.shared.enabled = false
            GraphifyWorkspaceService.shared.autoEnsure = false
        }

        let probe = BotGraphifyApplyProbe()
        router.graphifyEnvironmentApplierForTesting = { base, threadID, threadCwd, _, workspaceCwd, _ in
            probe.recordApply(threadID: threadID, threadCwd: threadCwd, workspaceCwd: workspaceCwd)
            var environment = GraphifyWorkspaceService.stripGraphifyKeys(from: base)
            environment["RC_GRAPHIFY_ENABLED"] = "1"
            environment["RC_GRAPHIFY_GRAPH_JSON"] = ownerRoot + "/graph.json"
            return (
                environment,
                GraphifyThreadWorkingSet(
                    threadId: threadID,
                    workspaceKind: "singleRepo",
                    roots: [],
                    ambiguous: false
                )
            )
        }
        router.graphifyWorkingSetPublisherForTesting = { set, threadID in
            probe.recordPublication(set: set, threadID: threadID)
        }

        func admittedEnvironment(
            for candidate: AgentThread,
            workspaceID: WorkspaceID? = nil,
            provider: AgentProvider? = nil,
            sameUser: Bool = true
        ) -> [String: String] {
            let receipt = TokenSaverExecutionReceiptSeam.admit(
                tokenSaverEnabled: true,
                sameUser: sameUser,
                sidecarAvailable: true,
                provider: provider ?? candidate.provider,
                threadId: candidate.id.value.uuidString,
                workspaceId: (workspaceID ?? candidate.workspaceId)?.value.uuidString,
                graphifyActive: true
            )
            var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
            environment["RC_GRAPHIFY_ENABLED"] = "hostile-leftover"
            environment["RC_GRAPHIFY_GRAPH_JSON"] = "/caller/graph.json"
            environment["RC_GRAPHIFY_STALE"] = "1"
            environment["RC_GRAPHIFY_UNKNOWN_FUTURE_KEY"] = "must-strip"
            return environment
        }

        func assertDenied(
            _ candidate: AgentThread,
            environment: [String: String],
            callerCwd: String = "/tmp/caller-cwd-must-not-be-used",
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let before = probe.snapshot()
            let result = await router.applyGraphifyOnSend(
                thread: candidate,
                cwd: callerCwd,
                attachments: [],
                baseEnvironment: environment
            )
            XCTAssertFalse(
                result.keys.contains(where: { $0.hasPrefix("RC_GRAPHIFY_") }),
                "all current and future Graphify keys must be stripped",
                file: file,
                line: line
            )
            XCTAssertEqual(probe.snapshot(), before, "denial must not resolve/ensure/query/publish", file: file, line: line)
        }

        let authoritative = admittedEnvironment(for: thread)
        let applied = await router.applyGraphifyOnSend(
            thread: thread,
            cwd: "/tmp/caller-cwd-must-not-be-used",
            attachments: [],
            baseEnvironment: authoritative
        )
        XCTAssertEqual(applied["RC_GRAPHIFY_ENABLED"], "1")
        XCTAssertEqual(applied["RC_GRAPHIFY_GRAPH_JSON"], ownerRoot + "/graph.json")
        XCTAssertEqual(probe.snapshot().applyThreadIDs, [thread.id.value])
        XCTAssertEqual(probe.snapshot().publishedThreadIDs, [thread.id])
        XCTAssertEqual(probe.snapshot().threadCwds, [ownerRoot])
        XCTAssertEqual(probe.snapshot().workspaceCwds, [ownerRoot])

        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = false }
        await assertDenied(thread, environment: authoritative)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        var workspaceLess = thread
        workspaceLess.workspaceId = nil
        await assertDenied(workspaceLess, environment: admittedEnvironment(for: workspaceLess))

        var missingRecord = thread
        missingRecord.workspaceId = WorkspaceID()
        await assertDenied(missingRecord, environment: admittedEnvironment(for: missingRecord))

        let staleRoot = (directory as NSString).appendingPathComponent("removed-owner")
        try FileManager.default.createDirectory(atPath: staleRoot, withIntermediateDirectories: true)
        let staleWorkspace = try router.createWorkspace(name: "Stale", cwd: staleRoot)
        var staleThread = thread
        staleThread.workspaceId = staleWorkspace.id
        try context.threadRepo.upsert(staleThread)
        try FileManager.default.removeItem(atPath: staleRoot)
        await assertDenied(staleThread, environment: admittedEnvironment(for: staleThread))

        let unresolvedRoot = (directory as NSString).appendingPathComponent("owner-is-not-a-directory")
        _ = FileManager.default.createFile(atPath: unresolvedRoot, contents: Data())
        let unresolvedWorkspace = try router.createWorkspace(name: "Unresolved", cwd: unresolvedRoot)
        var unresolvedThread = thread
        unresolvedThread.workspaceId = unresolvedWorkspace.id
        await assertDenied(unresolvedThread, environment: admittedEnvironment(for: unresolvedThread))

        await assertDenied(thread, environment: admittedEnvironment(for: thread, workspaceID: WorkspaceID()))
        await assertDenied(thread, environment: admittedEnvironment(for: thread, provider: .grok))
        let mismatchedThread = AgentThread(
            workspaceId: workspace.id,
            title: "Mismatched thread",
            provider: .codex,
            model: "test"
        )
        await assertDenied(mismatchedThread, environment: authoritative)
        await assertDenied(thread, environment: admittedEnvironment(for: thread, sameUser: false))
        await assertDenied(thread, environment: ["RC_GRAPHIFY_ENABLED": "stale-no-receipt"])

        thread.runAsUser = AgentRunAsUser(
            generatedUID: "foreign",
            shortName: "foreign",
            uid: getuid() &+ 1,
            gid: getgid(),
            homePath: "/Users/foreign"
        )
        await assertDenied(
            thread,
            environment: admittedEnvironment(for: thread, sameUser: true),
            callerCwd: ownerRoot
        )
    }

    func test_botDeskSendAdmitsDistillAndInterceptorForEveryProvider() async throws {
        // WHY: Bot Desk used to be proven only for Grok. Claude/Codex desk
        // turns must get the same DISTILL_HINT, managed PATH wrappers, and
        // interceptor as Agent App. Codex/Grok have no PostToolUse rewrite.
        let cases: [(AgentProvider, String)] = [
            (.claude, BotsViewModel.defaultModel(for: .claude)),
            (.codex, BotsViewModel.defaultModel(for: .codex)),
            (.grok, BotsViewModel.defaultModel(for: .grok)),
        ]
        for (provider, model) in cases {
            let context = try AppContext(channel: .debug, appSupportOverride: directory)
            SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
            context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
            let router = AppCommandRouter(context: context)
            context.router = router
            let runner = ControlledBotHandoffRunner(provider: provider)
            context.coordinator.replaceProvider(provider, runner: runner)
            router.rememberProviderSnapshotsForSend([
                AgentProviderSnapshotFactory.snapshot(
                    provider: provider,
                    models: [AgentModelDescriptor(id: model, label: model, provider: provider)],
                    binaryPath: "/usr/bin/true",
                    authenticated: true,
                    id: provider.rawValue
                ),
            ])
            let vm = BotsViewModel(context: context, router: router)
            let bot = try vm.create(
                name: "Piper-\(provider.rawValue)",
                title: "Scout"
            )
            vm.openDesk(bot)
            vm.deskRouting = BotDeskRouting(
                provider: provider,
                providerInstanceID: provider.rawValue,
                model: model,
                routingMode: .manual
            )
            vm.composerText = "BOT-DISTILL-\(provider.rawValue)"
            XCTAssertTrue(vm.send(), "\(provider) desk send")
            let started = await waitUntil(timeout: 5) { !runner.requests.isEmpty }
            XCTAssertTrue(started, "\(provider) bot send must reach the provider runner")
            let request = try XCTUnwrap(runner.requests.first, "\(provider)")
            assertAdmittedInterceptorEnvironment(request.environment, provider: provider, surface: "bot-desk")
            XCTAssertTrue(
                CommandWrapPolicy.isWrapped("swift")
                    && CommandWrapPolicy.isWrapped("workspace-report"),
                "\(provider) bot must share the global interceptor"
            )
            XCTAssertEqual(
                DistillServiceLaunch.argvMode(programName: "swift", arguments: ["test"]),
                .wrap(command: "swift", arguments: ["test"]),
                "\(provider) bot PATH wrapper must dispatch wrap, not HTTP"
            )
            _ = runner.finish(runID: request.runId, status: .completed, reply: "ok")
        }
    }

    func test_blockedSidecarStillAdmitsInterceptorWhenTokenSaverIsOn() async throws {
        // WHY: demand-start during Bot Desk / Agent App compress leaves the
        // Distill controller `.blocked` when no model is installed. Token Saver
        // ON must still stamp DISTILL_HINT + managed PATH; Distill fail-opens.
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        let thread = AgentThread(
            title: "blocked-sidecar",
            provider: .codex,
            model: "test",
            status: .completed
        )
        try context.threadRepo.upsert(thread)
        context.tokenSaverDistillServiceController.startIfEligible(
            session: nil,
            settings: SettingsStore(db: context.db).load(),
            modelValidation: TokenSaverModelValidation(state: .missing, reason: "manifest missing")
        )
        XCTAssertEqual(
            context.tokenSaverDistillServiceController.status.isOperationallyBlocked,
            true,
            "this regression requires the demand-start blocked state"
        )
        let env = context.tokenSaverAgentEnvironment(provider: .codex, threadId: thread.id)
        assertAdmittedInterceptorEnvironment(
            env,
            provider: .codex,
            surface: "blocked-sidecar",
            requireProviderTag: false
        )
    }

    func test_agentAppProviderEnvironmentAdmitsDistillAndInterceptorForEveryProvider() throws {
        // WHY: Agent App threads are the other surface. Admission must not
        // depend on Bot Desk send; providerEnvironment is the shared builder.
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)

        for provider in [AgentProvider.claude, .codex, .grok] {
            let thread = AgentThread(
                projectId: ProjectID(),
                workspaceId: WorkspaceID(),
                title: "agent-app-\(provider.rawValue)",
                provider: provider,
                model: "test",
                status: .completed
            )
            try context.threadRepo.upsert(thread)
            let env = router.providerEnvironment(
                provider: provider,
                instanceId: nil,
                threadId: thread.id
            )
            assertAdmittedInterceptorEnvironment(env, provider: provider, surface: "agent-app")
        }
    }

    private func assertAdmittedInterceptorEnvironment(
        _ env: [String: String],
        provider: AgentProvider,
        surface: String,
        requireProviderTag: Bool = true
    ) {
        XCTAssertEqual(
            env["RC_TOKEN_SAVER_DISTILL_HINT"],
            "1",
            "\(surface) \(provider) Distill hint"
        )
        if requireProviderTag {
            XCTAssertEqual(env["REMOTE_CODE_AGENT_PROVIDER"], provider.rawValue, "\(surface) \(provider)")
        }
        let managed = env["RC_REMOTE_CODE_MANAGED_BIN"] ?? ""
        XCTAssertFalse(managed.isEmpty, "\(surface) \(provider) managed bin")
        let path = env["PATH"] ?? ""
        XCTAssertTrue(
            path == managed || path.hasPrefix(managed + ":") || path.contains(":" + managed + ":"),
            "\(surface) \(provider) PATH must include managed wrappers: \(path)"
        )
        XCTAssertNil(env["REMOTE_CODE_WRAP_DISABLE"], "\(surface) \(provider) must not disable wrap")
        if provider == .claude {
            XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1", "\(surface) Claude PostToolUse")
        } else {
            XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "\(surface) \(provider) no PostToolUse rewrite")
        }
        let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("work", environment: env)
        XCTAssertTrue(prompt.contains("| distill"), "\(surface) \(provider) dialect")
        XCTAssertTrue(
            prompt.contains("NEVER auto-distill raw exact-output"),
            "\(surface) \(provider) exact-output still forbidden"
        )
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }
}

private final class BotGraphifyApplyProbe: @unchecked Sendable {
    struct Snapshot: Equatable {
        let applyThreadIDs: [UUID?]
        let publishedThreadIDs: [AgentThreadID?]
        let threadCwds: [String]
        let workspaceCwds: [String]
    }

    private let lock = NSLock()
    private var applyThreadIDs: [UUID?] = []
    private var publishedThreadIDs: [AgentThreadID?] = []
    private var threadCwds: [String] = []
    private var workspaceCwds: [String] = []

    func recordApply(threadID: UUID?, threadCwd: String, workspaceCwd: String) {
        lock.withLock {
            applyThreadIDs.append(threadID)
            threadCwds.append(threadCwd)
            workspaceCwds.append(workspaceCwd)
        }
    }

    func recordPublication(set _: GraphifyThreadWorkingSet, threadID: AgentThreadID?) {
        lock.withLock { publishedThreadIDs.append(threadID) }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                applyThreadIDs: applyThreadIDs,
                publishedThreadIDs: publishedThreadIDs,
                threadCwds: threadCwds,
                workspaceCwds: workspaceCwds
            )
        }
    }
}
