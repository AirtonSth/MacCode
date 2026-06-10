import Foundation
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces
import DistillCore

@MainActor
public final class AppContext {
    public let channel: ReleaseChannel
    public let db: SQLiteDB
    public let bootstrapReport: BootstrapReport
    public let appSupportDirectory: URL
    public let projectRepo: ProjectRepository
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository
    public let queuedMessageRepo: AgentQueuedMessageRepository
    public let runRepo: AgentRunRepository
    public let snapshotRepo: SessionSnapshotRepository
    public let settingsRepo: SettingsRepository
    public let eventLog: EventLogRepository
    public let terminalOutputRepo: TerminalOutputRepository
    public let providerSessionRuntimeRepo: ProviderSessionRuntimeRepository
    public let commandReceiptRepo: CommandReceiptRepository
    public let providerPendingCallbackRepo: ProviderPendingCallbackRepository
    public let proposedPlanRepo: AgentProposedPlanRepository
    public let turnCheckpointRepo: AgentTurnCheckpointRepository
    public let tokenSaverSavingsRepo: TokenSaverSavingsRepository
    public let privateNotificationBridge: PrivateNotificationBridge
    public let tokenSaverDistillServiceController: TokenSaverDistillServiceController
    public private(set) var managedDistillSkillInstallResults: [AgentSkillInstallResult] = []
    public private(set) var tokenSaverAccountUsageRefreshCount = 0

    public let reducer = LayoutReducer()
    public var state = LayoutState()

    public let coordinator: AgentRunCoordinator
    public var router: AppCommandRouter!
    public var socketServer: UnixSocketServer?
    private let tokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing
    private var tokenSaverAccountUsageRefreshTask: Task<Void, Never>?
    private var tokenSaverUsageNotificationTask: Task<Void, Never>?
    private var tokenSaverLastUsageNotificationAt: Date = .distantPast
    private var cachedDistillClientKey: String?
    private var cachedDistillClient: DistillServiceClient?
    /// Test seam: when set, used instead of resolving a client from the live
    /// sidecar status. Production code never sets this.
    var distillClientOverrideForTesting: DistillServiceClient?
    /// Test seam: sandbox the SessionLearn target instruction files so tests never write
    /// into the developer's real ~/.claude/CLAUDE.md or ~/.codex/AGENTS.md.
    var sessionLearnInstructionFilesOverrideForTesting: [URL]?
    /// Test seam: sandboxes the managed-skill/config install roots under a temp home so
    /// tests never write /distill state into the developer's real ~/.claude or
    /// ~/.codex. Production code never sets this (installs to the real provider dirs).
    var agentSkillsHomeOverrideForTesting: URL?
    /// Prompts shorter than this are sent verbatim: distillation overhead/latency
    /// isn't worth it and tiny instructions have nothing to compress.
    // Raised from 600: below ~2k chars a model round-trip on the awaited prompt path
    // rarely nets out positive once MLX latency is counted (NetPositiveGate floor, G3).
    private static let tokenSaverMinCompressChars = 2_000
    private static let tokenSaverDistillStartupPolls = 300
    private static let tokenSaverUsageNotificationMinimumInterval: TimeInterval = 2

    public init(
        channel: ReleaseChannel = .debug,
        dbPathOverride: String? = nil,
        appSupportOverride: String? = nil,
        tokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing = TokenSaverAccountUsageRefresher(),
        agentSkillsHomeOverrideForTesting: URL? = nil
    ) throws {
        self.channel = channel
        self.tokenSaverAccountUsageRefresher = tokenSaverAccountUsageRefresher
        self.agentSkillsHomeOverrideForTesting = agentSkillsHomeOverrideForTesting
        let bs = Bootstrap(channel: channel, dbPathOverride: dbPathOverride, appSupportOverride: appSupportOverride)
        let (rep, db) = try bs.run()
        self.bootstrapReport = rep
        self.appSupportDirectory = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
        self.db = db
        self.projectRepo = ProjectRepository(db: db)
        self.threadRepo = AgentThreadRepository(db: db)
        self.messageRepo = AgentMessageRepository(db: db)
        self.queuedMessageRepo = AgentQueuedMessageRepository(db: db)
        self.runRepo = AgentRunRepository(db: db)
        self.snapshotRepo = SessionSnapshotRepository(db: db)
        self.settingsRepo = SettingsRepository(db: db)
        self.eventLog = EventLogRepository(db: db)
        self.terminalOutputRepo = TerminalOutputRepository(db: db)
        self.providerSessionRuntimeRepo = ProviderSessionRuntimeRepository(db: db)
        self.commandReceiptRepo = CommandReceiptRepository(db: db)
        self.providerPendingCallbackRepo = ProviderPendingCallbackRepository(db: db)
        self.proposedPlanRepo = AgentProposedPlanRepository(db: db)
        self.turnCheckpointRepo = AgentTurnCheckpointRepository(db: db)
        self.tokenSaverSavingsRepo = TokenSaverSavingsRepository(db: db)
        self.privateNotificationBridge = PrivateNotificationBridge(
            accountStore: PrivateAccountSessionStore(repo: self.settingsRepo),
            pushTargetStore: PrivatePushTargetStore(repo: self.settingsRepo)
        )
        self.tokenSaverDistillServiceController = TokenSaverDistillServiceController(
            appSupportDirectory: self.appSupportDirectory
        )
        let codex = CodexAppServerAdapter(binaryNameOverride: try? settingsRepo.get("cli.codex.path"))
        let claude: AgentProviderAdapter = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_ENABLED"] == "0"
            ? ClaudeStreamingCLIAdapter(binaryNameOverride: try? settingsRepo.get("cli.claude.path"))
            : ClaudeAgentSDKBridgeAdapter()
        self.coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providerSessionRepo: providerSessionRuntimeRepo,
            checkpointRepo: turnCheckpointRepo,
            providerAdapters: [.codex: codex, .claude: claude]
        )
        try coordinator.reconcileOnLaunch()
        try? tokenSaverSavingsRepo.prune()
        self.coordinator.promptCompressor = { [weak self] prompt, provider, threadId in
            guard let self else { return prompt }
            return await self.tokenSaverCompress(prompt: prompt, provider: provider, threadId: threadId)
        }
        self.coordinator.finalResponseTranslator = { [weak self] response, provider, threadId, runId in
            guard let self else { return response }
            return await self.tokenSaverHumanizeSR1Response(response, provider: provider, threadId: threadId, runId: runId)
        }
        // P3 (opt-in, default OFF): compact large tool output in persisted stream events,
        // CCR-backed and structure-preserving, so replay still decodes. Our-storage saving.
        if SettingsStore(db: db).load().historyCompactionEnabled {
            let historyStore = ReversibleContentStore(db: db)
            self.coordinator.streamPayloadCompactor = { payload in
                ReversiblePayloadCompactor.compact(payload) { original in
                    try? historyStore.store(Data(original.utf8))
                }
            }
        }
        _ = try providerPendingCallbackRepo.markOpenStale(
            reason: "Provider callback state does not survive app restarts or recovered sessions. Restart the turn to continue."
        )
        // Managed skills install into the real ~/.claude / ~/.codex skill dirs. Skip the
        // open-trigger reconcile under XCTest so the suite never mutates the developer's
        // real home; AppContext tests drive reconcile explicitly with a sandboxed home.
        if !AppContext.isRunningUnitTests || agentSkillsHomeOverrideForTesting != nil {
            reconcileManagedDistillSkills(tokenSaverEnabled: SettingsStore(db: db).load().tokenSaverEnabled)
        }
        startTokenSaverDistillServiceIfEligible()

        // GAP-7: stream agent run lifecycle + timeline to the network
        // event bus so the iOS mirror renders agent output in real time
        // (kinds/payloads match the iOS MirrorEventReducer contract).
        func itemJSON(_ item: AssistantItem) -> JSONValue {
            (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))) ?? .null
        }
        func runtimeEventPayload(_ event: ProviderRuntimeEvent, threadId: String) -> JSONValue {
            var payload: [String: JSONValue] = [
                "thread_id": .string(threadId),
                "id": .string(event.id),
                "provider": .string(event.provider.rawValue),
                "source": .string(event.source),
                "method": .string(event.method),
                "payload_json": .string(event.payloadJSON),
                "received_at_ms": .number(Double(event.receivedAtMs))
            ]
            if let turn = event.providerTurnId { payload["provider_turn_id"] = .string(turn) }
            if let item = event.providerItemId { payload["provider_item_id"] = .string(item) }
            if let request = event.providerRequestId { payload["provider_request_id"] = .string(request) }
            return .object(payload)
        }
        func messageJSON(_ message: AgentMessage) -> JSONValue {
            (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(message))) ?? .null
        }
        func agentRunPayload(threadId: AgentThreadID, status: AgentRunStatus? = nil) -> JSONValue {
            var payload: [String: JSONValue] = ["thread_id": .string(threadId.value.uuidString)]
            if let wid = try? threadRepo.get(id: threadId)?.workspaceId {
                payload["workspace_id"] = .string(wid.value.uuidString)
            }
            if let status {
                payload["status"] = .string(status.rawValue)
            }
            return .object(payload)
        }
        coordinator.onRunStarted = { tid, _ in
            EventBus.shared.publish(kind: "agent.run.started",
                                    payload: agentRunPayload(threadId: tid))
        }
        coordinator.onMessageAppended = { message in
            EventBus.shared.publish(kind: "agent.message.appended", payload: messageJSON(message))
        }
        coordinator.onAssistantEvent = { ev, tid, runId in
            let t = tid.value.uuidString
            switch ev {
            case .threadStarted:
                EventBus.shared.publish(kind: "agent.run.started", payload: agentRunPayload(threadId: tid))
            case .turnStarted(let turnId):
                EventBus.shared.publish(kind: "agent.turn.started",
                                        payload: .object(["thread_id": .string(t), "turn_id": .string(turnId)]))
            case .itemStarted(let item):
                EventBus.shared.publish(kind: "agent.item.started",
                                        payload: .object(["thread_id": .string(t), "item": itemJSON(item)]))
            case .itemDelta(let itemId, let bodyAppend, let outputAppend, let summary):
                var p: [String: JSONValue] = ["thread_id": .string(t), "item_id": .string(itemId)]
                if let b = bodyAppend { p["body_append"] = .string(b) }
                if let o = outputAppend { p["output_append"] = .string(o) }
                if let s = summary { p["summary"] = .string(s) }
                EventBus.shared.publish(kind: "agent.item.delta", payload: .object(p))
            case .itemState(let itemId, let state):
                if state != .streaming {
                    EventBus.shared.publish(kind: "agent.item.completed",
                                            payload: .object(["thread_id": .string(t), "item_id": .string(itemId)]))
                }
            case .itemProgress(let itemId, let progress):
                var p: [String: JSONValue] = ["thread_id": .string(t), "item_id": .string(itemId)]
                if let progress { p["progress"] = .number(progress) }
                EventBus.shared.publish(kind: "agent.item.progress", payload: .object(p))
            case .itemCompleted(let itemId, let state):
                EventBus.shared.publish(kind: "agent.item.completed",
                                        payload: .object(["thread_id": .string(t), "item_id": .string(itemId), "state": .string(state.rawValue)]))
            case .turnCompleted(let turnId, let final):
                var p: [String: JSONValue] = ["thread_id": .string(t), "turn_id": .string(turnId)]
                if let f = final { p["final"] = .string(f) }
                EventBus.shared.publish(kind: "agent.turn.completed", payload: .object(p))
            case .proposedPlan(let plan):
                try? self.proposedPlanRepo.upsert(threadId: tid, plan: plan)
                EventBus.shared.publish(kind: "agent.plan.proposed", payload: .object([
                    "thread_id": .string(t),
                    "plan_id": .string(plan.id),
                    "markdown": .string(plan.markdown)
                ]))
            case .activePlanUpdated(let plan):
                var payload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "steps": .array(plan.steps.map { step in
                        .object([
                            "id": .string(step.id),
                            "title": .string(step.title),
                            "status": .string(step.status.rawValue)
                        ])
                    }),
                    "updated_at_ms": .number(Double(plan.updatedAtMs))
                ]
                if let explanation = plan.explanation { payload["explanation"] = .string(explanation) }
                EventBus.shared.publish(kind: "agent.plan.active_updated", payload: .object(payload))
            case .requestOpened(let request):
                try? self.providerPendingCallbackRepo.record(threadId: tid, request: request)
                EventBus.shared.publish(kind: "agent.request.opened", payload: .object([
                    "thread_id": .string(t),
                    "request_id": .string(request.id),
                    "kind": .string(request.kind.rawValue),
                    "title": .string(request.title),
                    "detail": request.detail.map(JSONValue.string) ?? .null
                ]))
            case .requestResolved(let requestId, let state):
                try? self.providerPendingCallbackRepo.resolve(threadId: tid, requestId: requestId, kind: .approval, state: state)
                EventBus.shared.publish(kind: "agent.request.resolved", payload: .object([
                    "thread_id": .string(t),
                    "request_id": .string(requestId),
                    "state": .string(state.rawValue)
                ]))
            case .userInputRequested(let request):
                try? self.providerPendingCallbackRepo.record(threadId: tid, userInput: request)
                EventBus.shared.publish(kind: "agent.user_input.requested", payload: .object([
                    "thread_id": .string(t),
                    "request_id": .string(request.id),
                    "prompt": .string(request.prompt),
                    "options": .array(request.options.map(JSONValue.string)),
                    "allows_multiple_selection": .bool(request.allowsMultipleSelection),
                    "is_secret": .bool(request.isSecret)
                ]))
            case .userInputResolved(let requestId, let answer):
                try? self.providerPendingCallbackRepo.resolve(threadId: tid, requestId: requestId, kind: .userInput, state: .resolved)
                EventBus.shared.publish(kind: "agent.user_input.resolved", payload: .object([
                    "thread_id": .string(t),
                    "request_id": .string(requestId),
                    "answer": answer.map(JSONValue.string) ?? .null
                ]))
            case .tokenUsage(let usage):
                self.recordTokenSaverUsage(usage, runId: runId)
                var p: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "input_tokens": .number(Double(usage.inputTokens)),
                    "output_tokens": .number(Double(usage.outputTokens)),
                    "total_tokens": .number(Double(usage.totalTokens))
                ]
                if let window = usage.contextWindow { p["context_window"] = .number(Double(window)) }
                if let compactsAutomatically = usage.compactsAutomatically {
                    p["compacts_automatically"] = .bool(compactsAutomatically)
                }
                EventBus.shared.publish(kind: "agent.thread.token_usage", payload: .object(p))
            case .accountUsage(let usage):
                self.recordTokenSaverAccountUsage(usage)
                EventBus.shared.publish(kind: "agent.account.usage", payload: .object([
                    "thread_id": .string(t),
                    "provider": .string(usage.provider.rawValue),
                    "weekly_used_percent": .number(usage.weeklyUsedPercent),
                    "weekly_window_duration_minutes": usage.weeklyWindowDurationMinutes.map { .number(Double($0)) } ?? .null,
                    "weekly_resets_at_ms": usage.weeklyResetsAtMs.map { .number(Double($0)) } ?? .null,
                    "current_session_used_percent": usage.currentSessionUsedPercent.map { .number($0) } ?? .null,
                    "current_session_resets_at_ms": usage.currentSessionResetsAtMs.map { .number(Double($0)) } ?? .null
                ]))
            case .contextCompaction(let summary):
                EventBus.shared.publish(kind: "agent.context.compaction", payload: .object([
                    "thread_id": .string(t),
                    "summary": summary.map(JSONValue.string) ?? .null
                ]))
            case .providerRuntime(let event):
                EventBus.shared.publish(kind: "agent.provider_runtime.event", payload: runtimeEventPayload(event, threadId: t))
            case .error:
                EventBus.shared.publish(kind: "agent.run.error", payload: agentRunPayload(threadId: tid))
            }
        }
        coordinator.onRunFinished = { tid, rid, status in
            let kind = (status == .completed) ? "agent.run.completed" : "agent.run.failed"
            EventBus.shared.publish(kind: kind, payload: agentRunPayload(threadId: tid, status: status))
            EventBus.shared.publish(kind: "agent.run.finished", payload: agentRunPayload(threadId: tid, status: status))
            self.recordSessionLearnFromRun(runId: rid, status: status) // P5 SessionLearn (off by default)
            if status == .completed || status == .cancelled {
                Task { @MainActor in
                    try? await self.router?.drainNextQueuedAgentMessage(thread: tid)
                }
            }
            if let content = RemoteCodeNotificationContent.threadOutcome(
                threadId: tid.value.uuidString,
                title: try? self.threadRepo.get(id: tid)?.title,
                phase: status
            ) {
                SystemNotifier.shared.post(content)
                Task {
                    await self.privateNotificationBridge.deliver(content)
                }
            }
        }

        // HC-1: stream terminal/surface PTY output to the mirror so iOS
        // renders a live terminal (not a poll). Raw bytes, base64 +
        // monotonic seq per surface for ordered incremental rendering.
        SurfaceOutputBus.shared.sink = { sid, seq, chunk in
            let key = sid.value.uuidString
            var payload: [String: JSONValue] = [
                "surface_id": .string(key),
                "seq": .number(Double(seq)),
                "base64": .string(chunk.base64EncodedString())
            ]
            if let terminal = SurfaceRegistry.shared.surface(sid) as? TerminalSurface {
                payload["rows"] = .number(Double(terminal.viewportSize.rows))
                payload["cols"] = .number(Double(terminal.viewportSize.cols))
            }
            EventBus.shared.publish(kind: "surface.output", payload: .object(payload))
        }
        SurfaceRuntimeBus.shared.sink = { sid, health in
            Task { @MainActor [weak self] in
                if self?.router?.promoteWorkspaceContainingBusySurface(sid) != true {
                    self?.router?.windowController?.refreshSurfaceRuntimeState()
                }
            }
            EventBus.shared.publish(kind: "surface.health", payload: .object([
                "surface_id": .string(sid.value.uuidString),
                "alive": .bool(health.alive),
                "process_alive": .bool(health.processAlive),
                "child_pid": health.childPID.map { .number(Double($0)) } ?? .null,
                "exit_status": health.exitStatus.map { .number(Double($0)) } ?? .null,
                "termination_signal": health.terminationSignal.map { .number(Double($0)) } ?? .null,
                "pty_open": .bool(health.ptyOpen),
                "input_accepting": .bool(health.inputAccepting),
                "terminal_dead_reason": health.terminalDeadReason.map { .string($0) } ?? .null,
                "last_output_at": health.lastOutputAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                "output_partial": .bool(health.outputPartial),
                "output_pending_bytes": .number(Double(health.outputPendingBytes)),
                "history_write_failures": .number(Double(health.historyWriteFailures)),
                "dropped_output_bytes": .number(Double(health.droppedOutputBytes)),
                "rows": .number(Double(health.rows)),
                "cols": .number(Double(health.cols))
            ]))
        }

        // restore last snapshot if any
        if let snap = try snapshotRepo.latest() {
            self.state = snap.layout
        }
    }

    /// Managed `/distill` state is only useful while Token Saver is on, so the skill
    /// and provider config lifecycle tracks the Token Saver toggle: present when
    /// enabled, removed when disabled. Driven from every Token Saver trigger:
    /// app open/close and the enable/disable toggle, so it never lingers once
    /// Token Saver is off.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    public func reconcileManagedDistillSkills(tokenSaverEnabled: Bool) {
        let installer = agentSkillsHomeOverrideForTesting.map { AgentSkillInstaller(homeDirectory: $0) }
            ?? AgentSkillInstaller()
        do {
            if tokenSaverEnabled {
                let codex = try installer.installDistillSkill(
                    for: .codex,
                    sourceRevision: "github-main-remote-code-template-v1"
                )
                let claude = try installer.installDistillSkill(
                    for: .claude,
                    sourceRevision: "github-main-remote-code-template-v1"
                )
                try installer.installDistillInstructions(for: .codex)
                try installer.installDistillInstructions(for: .claude)
                _ = try installer.installDistillCLI(appSupportDirectory: appSupportDirectory)
                try? installer.installRetrieveMCP() // retrieve-only MCP (best-effort; needs the bundled binary)
                managedDistillSkillInstallResults = [codex, claude]
            } else {
                _ = try installer.uninstallDistillSkill(for: .codex)
                _ = try installer.uninstallDistillSkill(for: .claude)
                _ = try installer.uninstallDistillInstructions(for: .codex)
                _ = try installer.uninstallDistillInstructions(for: .claude)
                _ = try installer.uninstallDistillCLI()
                try? installer.uninstallRetrieveMCP()
                managedDistillSkillInstallResults = []
            }
        } catch {
            NSLog("RemoteCode managed Distill skill reconcile failed: \(error)")
            managedDistillSkillInstallResults = []
        }
    }

    private func startTokenSaverDistillServiceIfEligible() {
        let settings = SettingsStore(db: db).load()
        let session = PrivateAccountSessionStore(repo: settingsRepo).load()
        let modelValidation = TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
            .validateInstalledModel()
        tokenSaverDistillServiceController.startIfEligible(
            session: session,
            settings: settings,
            modelValidation: modelValidation
        )
    }

    private func recordTokenSaverAccountUsage(_ usage: AssistantAccountUsage) {
        do {
            _ = try TokenSaverUsageStore(appSupportDirectory: appSupportDirectory).recordAccountUsage(
                provider: usage.provider,
                weeklyUsedPercent: usage.weeklyUsedPercent,
                weeklyWindowDurationMinutes: usage.weeklyWindowDurationMinutes,
                weeklyResetsAt: usage.weeklyResetsAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) },
                currentSessionUsedPercent: usage.currentSessionUsedPercent,
                currentSessionResetsAt: usage.currentSessionResetsAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
            )
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
        } catch {
            NSLog("RemoteCode Token Saver account usage record failed: \(error)")
        }
    }

    public func refreshTokenSaverAccountUsage(reason: String) {
        guard PrivateAccountSessionStore(repo: settingsRepo).load() != nil else {
            publishTokenSaverAccountUsageRefresh(state: "skipped", reason: reason, detail: "signed_out")
            return
        }
        guard tokenSaverAccountUsageRefreshTask == nil else {
            publishTokenSaverAccountUsageRefresh(state: "skipped", reason: reason, detail: "busy")
            return
        }
        tokenSaverAccountUsageRefreshCount += 1
        publishTokenSaverAccountUsageRefresh(state: "started", reason: reason, detail: nil)

        let codexBinary = (try? settingsRepo.get("cli.codex.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeBinary = (try? settingsRepo.get("cli.claude.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = TokenSaverAccountUsageRefreshRequest(
            codexBinary: codexBinary?.isEmpty == false ? codexBinary! : "codex",
            claudeBinary: claudeBinary?.isEmpty == false ? claudeBinary! : "claude",
            cwd: state.workspaces.values.first?.cwd ?? NSHomeDirectory(),
            environment: [:]
        )
        let refresher = tokenSaverAccountUsageRefresher

        tokenSaverAccountUsageRefreshTask = Task { [weak self] in
            let usages = await Self.refreshAccountUsageWithTimeout(refresher: refresher, request: request)
            await MainActor.run {
                guard let self else { return }
                for usage in usages {
                    self.recordTokenSaverAccountUsage(usage)
                    EventBus.shared.publish(kind: "agent.account.usage", payload: .object([
                        "provider": .string(usage.provider.rawValue),
                        "reason": .string(reason),
                        "weekly_used_percent": .number(usage.weeklyUsedPercent),
                        "weekly_window_duration_minutes": usage.weeklyWindowDurationMinutes.map { .number(Double($0)) } ?? .null,
                        "weekly_resets_at_ms": usage.weeklyResetsAtMs.map { .number(Double($0)) } ?? .null,
                        "current_session_used_percent": usage.currentSessionUsedPercent.map { .number($0) } ?? .null,
                        "current_session_resets_at_ms": usage.currentSessionResetsAtMs.map { .number(Double($0)) } ?? .null
                    ]))
                }
                self.publishTokenSaverAccountUsageRefresh(
                    state: "finished",
                    reason: reason,
                    detail: usages.isEmpty ? "empty" : nil,
                    providers: usages.map(\.provider.rawValue)
                )
                self.tokenSaverAccountUsageRefreshTask = nil
            }
        }
    }

    private static func refreshAccountUsageWithTimeout(
        refresher: TokenSaverAccountUsageRefreshing,
        request: TokenSaverAccountUsageRefreshRequest
    ) async -> [AssistantAccountUsage] {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func resume(_ usages: [AssistantAccountUsage]) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: usages)
            }

            let work = Task.detached {
                let usages = await refresher.refreshAccountUsage(request)
                resume(usages)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                work.cancel()
                resume([])
            }
        }
    }

    private func publishTokenSaverAccountUsageRefresh(
        state: String,
        reason: String,
        detail: String?,
        providers: [String] = []
    ) {
        var payload: [String: JSONValue] = [
            "state": .string(state),
            "reason": .string(reason),
            "refresh_count": .number(Double(tokenSaverAccountUsageRefreshCount))
        ]
        if let detail {
            payload["detail"] = .string(detail)
        }
        if !providers.isEmpty {
            payload["providers"] = .array(providers.map { .string($0) })
        }
        EventBus.shared.publish(kind: "agent.account.usage.refresh", payload: .object(payload))
    }

    /// Reuse one client per live sidecar (base URL + bearer token). Rebuilds
    /// only when the service (re)starts with a new endpoint or token.
    private func currentDistillClient() -> DistillServiceClient? {
        if let distillClientOverrideForTesting { return distillClientOverrideForTesting }
        guard case .running(let ready) = tokenSaverDistillServiceController.status,
              let token = tokenSaverDistillServiceController.bearerToken else {
            cachedDistillClientKey = nil
            cachedDistillClient = nil
            return nil
        }
        let key = "\(ready.baseURL)#\(token)"
        if cachedDistillClientKey == key, let client = cachedDistillClient {
            return client
        }
        guard let client = DistillServiceClient(ready: ready, authToken: token) else {
            return nil
        }
        cachedDistillClientKey = key
        cachedDistillClient = client
        return client
    }

    /// Token Saver prompt compression. Returns the distilled text to send to the
    /// provider, or the original prompt unchanged when Token Saver is off, the
    /// prompt is too small, the sidecar is unavailable, compression doesn't
    /// help, or anything fails. Every real compression is measured and written
    /// to the local savings ledger. Fail-open by contract.
    /// Seconds since this thread's last provider turn, from provider_session_runtime
    /// staleness (a heuristic — that table has no billed-cache columns). nil when there
    /// is no prior turn, which the gate treats as COLD (never wrongly skip a fresh prompt).
    private func secondsSinceLastTurn(threadId: AgentThreadID) -> Double? {
        guard let runtime = try? providerSessionRuntimeRepo.get(threadId: threadId) else { return nil }
        return max(0, Date().timeIntervalSince(runtime.updatedAt))
    }

    func tokenSaverCompress(prompt: String, provider: AgentProvider, threadId: AgentThreadID) async -> String {
        guard SettingsStore(db: db).load().tokenSaverEnabled else { return prompt }
        // NetPositiveGate (G3): there is no app-side cached prefix to preserve (resume sends
        // the full wrapped prompt), so this is a numeric decision — compress the new-turn
        // argv only when it is large enough AND the session is not a warm follow-up.
        let gate = NetPositiveGate(floorCharacters: Self.tokenSaverMinCompressChars, warmResumeTTLSeconds: 300)
        let secondsSinceLastTurn = secondsSinceLastTurn(threadId: threadId)
        guard gate.shouldCompress(inputCharacters: prompt.count, secondsSinceLastTurn: secondsSinceLastTurn) else {
            return prompt
        }
        // Non-lossy dedup pre-pass (P4): collapse exact-duplicate large blocks within the
        // prompt to a model-readable "identical to block above" pointer. The model keeps
        // full information (content once + a pointer it understands), so this is safe to
        // send AND a win even if the model compression step is unavailable.
        let deduped = DistillBlockDeduper.dedupe(prompt).output

        // Adopt `candidate` only if it beats the ORIGINAL prompt; record honest end-to-end
        // savings (original -> final), tagged cache_state=prompt.
        func adopt(_ candidate: String) -> String {
            guard candidate.count < prompt.count else { return prompt }
            let inputTokens = TokenEstimator.estimate(prompt)
            let outputTokens = TokenEstimator.estimate(candidate)
            recordTokenSaverSidecarSavings(
                provider: provider,
                mode: DistillMode.longText.rawValue,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                savedTokens: max(inputTokens - outputTokens, 0),
                cacheState: "prompt"
            )
            return candidate
        }

        guard let client = currentDistillClient() else {
            // No model service: the deterministic dedup is still a safe, non-lossy win.
            return deduped.count < prompt.count ? adopt(deduped) : prompt
        }

        let request = DistillRequest(
            mode: .longText,
            priority: .interactive,
            input: deduped,
            maxOutputCharacters: max(512, deduped.count)
        )
        do {
            let response = try await client.distill(request)
            let modelOutput = response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? deduped : response.output
            // Pick the smaller of {model output, deduped}, then adopt only if it beats the original.
            let best = modelOutput.count < deduped.count ? modelOutput : deduped
            return adopt(best)
        } catch {
            NSLog("RemoteCode Token Saver compression skipped (provider=\(provider.rawValue)): \(error)")
            // Fail-open to the deterministic dedup if it helped, else the original.
            return deduped.count < prompt.count ? adopt(deduped) : prompt
        }
    }

    /// P5 SessionLearn: on a failed run, mine a deterministic correction rule from the
    /// run's error into the managed instructions region (FIFO-capped, appended at the file
    /// bottom so the upper instruction prefix stays byte-stable). Off by default; best-effort.
    func recordSessionLearnFromRun(runId: AgentRunID, status: AgentRunStatus) {
        guard SettingsStore(db: db).load().sessionLearnEnabled else { return }
        guard SessionLearnRegion.shouldMine(runFailed: status == .failed, inputTokens: 0) else { return }
        guard let run = try? runRepo.get(id: runId) else { return }
        let error = (run.errorMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !error.isEmpty else { return }
        let firstLine = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
        let rule = "Avoid repeating the approach that failed with: \(String(firstLine.prefix(160))). Verify preconditions before retrying."
        let files = sessionLearnInstructionFilesOverrideForTesting
            ?? [AgentSkillInstaller.defaultClaudeInstructionsURL(), AgentSkillInstaller.defaultCodexInstructionsURL()]
        for url in files {
            try? SessionLearnRegion(fileURL: url).append(rule)
        }
    }

    func tokenSaverHumanizeSR1Response(_ response: String, provider: AgentProvider, threadId: AgentThreadID, runId: AgentRunID? = nil) async -> String {
        guard SR1ResponseDetector.isSR1(response) else { return response }

        let targetLanguage = inferredUserLanguage(threadId: threadId)
        let fallback = Self.fallbackHumanizeSR1(response, targetLanguage: targetLanguage)
        guard let client = await currentDistillClientWaitingForStartup() else {
            NSLog("RemoteCode Token Saver SR1 humanize fallback used (provider=\(provider.rawValue)): distill client unavailable (status=\(Self.describe(tokenSaverDistillServiceController.status)))")
            return fallback
        }

        let input = """
        TARGET_LANGUAGE: \(targetLanguage)
        USER_FACING_RULES:
        Expand any SR1 variables such as #g1 using their definitions from SR1_RESPONSE before answering.
        Never show unresolved # variables to the user.

        SR1_RESPONSE:
        \(response)
        """
        let request = DistillRequest(
            mode: .sr1Humanize,
            priority: .interactive,
            input: input,
            maxOutputCharacters: max(1_200, min(12_000, response.count * 4))
        )
        do {
            let translated = try await client.distill(request).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = SR1ResponseDetector.expandVariables(in: translated, from: response)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let humanized: String
            if !expanded.isEmpty, !SR1ResponseDetector.isSR1(expanded) {
                humanized = expanded
            } else {
                humanized = fallback
            }
            recordTokenSaverSR1HumanizeSavings(sr1: response, humanized: humanized, provider: provider)
            return humanized
        } catch {
            NSLog("RemoteCode Token Saver SR1 humanize fallback used (provider=\(provider.rawValue)): \(error)")
            return fallback
        }
    }

    private func currentDistillClientWaitingForStartup() async -> DistillServiceClient? {
        if let client = currentDistillClient() {
            return client
        }
        guard SettingsStore(db: db).load().tokenSaverEnabled else {
            return nil
        }

        startTokenSaverDistillServiceIfEligible()
        for _ in 0..<Self.tokenSaverDistillStartupPolls {
            if let client = currentDistillClient() {
                return client
            }
            if case .blocked = tokenSaverDistillServiceController.status {
                break
            }
            if case .failed = tokenSaverDistillServiceController.status {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return currentDistillClient()
    }

    private static func describe(_ status: TokenSaverDistillServiceStatus) -> String {
        switch status {
        case .notStarted:
            return "notStarted"
        case .blocked(let reason):
            return "blocked:\(reason)"
        case .starting:
            return "starting"
        case .running(let ready):
            return "running:\(ready.runtime):\(ready.port)"
        case .failed(let reason):
            return "failed:\(reason)"
        }
    }

    private func inferredUserLanguage(threadId: AgentThreadID) -> String {
        let recent = (try? messageRepo.listRecent(threadId: threadId, limit: 20)) ?? []
        let latestUserText = recent.last(where: { $0.role == .user })?.content ?? ""
        if Self.looksPortuguese(latestUserText) {
            return "Portuguese (Brazil)"
        }
        if Self.looksSpanish(latestUserText) {
            return "Spanish"
        }
        if Locale.preferredLanguages.first?.lowercased().hasPrefix("pt") == true {
            return "Portuguese (Brazil)"
        }
        return "English"
    }

    private static func looksPortuguese(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        if lower.range(of: #"[áàâãçéêíóôõú]"#, options: .regularExpression) != nil {
            return true
        }
        let markers = [
            " voce ", " você ", " nao ", " não ", " corrija ", " teste ", " testes ",
            " linguagem ", " usuario ", " usuário ", " tokens salvos ", " esta ", " está ",
            " portugues ", " português ", " responda ", " explique ", " crie ", " criar ",
            " jogo ", " pt-br ", " brasil "
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func looksSpanish(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        if lower.range(of: #"[¿¡ñ]"#, options: .regularExpression) != nil {
            return true
        }
        let markers = [" por favor ", " gracias ", " respuesta ", " usuario ", " prueba "]
        return markers.contains { lower.contains($0) }
    }

    private static func fallbackHumanizeSR1(_ response: String, targetLanguage: String) -> String {
        let portuguese = targetLanguage.localizedCaseInsensitiveContains("Portuguese")
        let spanish = targetLanguage.localizedCaseInsensitiveContains("Spanish")
        let labels: [Character: String]
        if portuguese {
            labels = ["S": "Estado", "C": "Contexto", "D": "Acao", "R": "Risco", "O": "Resultado", "N": "Nao fazer", "P": "Prova"]
        } else if spanish {
            labels = ["S": "Estado", "C": "Contexto", "D": "Accion", "R": "Riesgo", "O": "Resultado", "N": "No hacer", "P": "Prueba"]
        } else {
            labels = ["S": "State", "C": "Context", "D": "Action", "R": "Risk", "O": "Outcome", "N": "Do not do", "P": "Proof"]
        }

        let lines = response
            .split(whereSeparator: \.isNewline)
            .flatMap { raw -> [String] in
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return [] }
                let lower = line.lowercased()
                guard lower != "sr1",
                      lower != "dict",
                      lower != "dict:",
                      !lower.hasPrefix("dict:"),
                      !lower.hasPrefix("s=state"),
                      !lower.hasPrefix("c=context"),
                      !lower.hasPrefix("d=action"),
                      !lower.hasPrefix("r=risk"),
                      !lower.hasPrefix("o=outcome"),
                      !lower.hasPrefix("n=no-go"),
                      !lower.hasPrefix("p=proof") else {
                    return []
                }
                let segments = SR1ResponseDetector.parseSemanticSegments(line)
                guard !segments.isEmpty else {
                    return [line]
                }
                return segments.map { parsed in
                    guard let label = labels[parsed.prefix] else { return parsed.content }
                    return "\(label): \(parsed.content)"
                }
            }
        if lines.isEmpty {
            if portuguese { return "Nao consegui expandir a resposta comprimida." }
            if spanish { return "No pude expandir la respuesta comprimida." }
            return "I could not expand the compressed response."
        }
        return SR1ResponseDetector.expandVariables(in: lines.joined(separator: "\n"), from: response)
    }

    private func recordTokenSaverUsage(_ usage: AssistantTokenUsage, runId: AgentRunID) {
        guard usage.totalTokens > 0,
              let run = try? runRepo.get(id: runId) else {
            return
        }
        let settings = SettingsStore(db: db).load()
        // Record only the real provider-billed token count. Savings are now
        // measured at the local sidecar call sites (`| distill` command-output
        // compression and SR1 humanization), never synthesized from provider
        // token-usage events.
        let eligibleRuns = settings.tokenSaverEnabled ? 1 : 0
        do {
            _ = try TokenSaverUsageStore(appSupportDirectory: appSupportDirectory).record(
                provider: run.provider,
                actualProviderTokens: usage.totalTokens,
                estimatedRawTokens: usage.totalTokens,
                eligibleRuns: eligibleRuns,
                currentSessionTokens: usage.totalTokens,
                currentSessionLimitTokens: usage.contextWindow
            )
            scheduleTokenSaverUsageChangedNotification()
        } catch {
            NSLog("RemoteCode Token Saver usage record failed: \(error)")
        }
    }

    private func scheduleTokenSaverUsageChangedNotification(now: Date = Date()) {
        let elapsed = now.timeIntervalSince(tokenSaverLastUsageNotificationAt)
        guard elapsed < Self.tokenSaverUsageNotificationMinimumInterval else {
            tokenSaverLastUsageNotificationAt = now
            Task { @MainActor in
                NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
            }
            return
        }
        guard tokenSaverUsageNotificationTask == nil else { return }
        let delay = Self.tokenSaverUsageNotificationMinimumInterval - elapsed
        tokenSaverUsageNotificationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.tokenSaverUsageNotificationTask = nil
                self.tokenSaverLastUsageNotificationAt = Date()
                NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
            }
        }
    }

    private func recordTokenSaverSidecarSavings(
        provider: AgentProvider,
        mode: String,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        cacheState: String = "unknown"
    ) {
        guard SettingsStore(db: db).load().tokenSaverEnabled else { return }
        do {
            _ = try tokenSaverSavingsRepo.record(
                provider: provider.rawValue,
                mode: mode,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                savedTokens: savedTokens,
                cacheState: cacheState
            )
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
        } catch {
            NSLog("RemoteCode Token Saver sidecar savings persist failed: \(error)")
        }
    }

    private func recordTokenSaverSR1HumanizeSavings(sr1: String, humanized: String, provider: AgentProvider) {
        // Honest token accounting: the agent emitted compressed SR1 instead of
        // the full human answer, so savings = estimate(human) - estimate(SR1).
        let inputTokens = TokenEstimator.estimate(humanized)
        let outputTokens = TokenEstimator.estimate(sr1)
        let savedTokens = max(inputTokens - outputTokens, 0)
        recordTokenSaverSidecarSavings(
            provider: provider,
            mode: "sr1-humanize",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            savedTokens: savedTokens
        )
    }

    private var pendingSave: DispatchWorkItem?

    /// Serial utility queue for all event-log appends and snapshot writes.
    /// Keeping DB I/O off the main/publish thread avoids priority inversion
    /// during high-frequency event bursts. All writes must be dispatched here.
    public let backgroundWriterQueue = DispatchQueue(
        label: "io.remotecode.app.writer",
        qos: .utility
    )

    /// Cadence: prune the event log every N appends instead of on every append.
    /// Reducing prune frequency amortises the DELETE cost across many inserts.
    public static let eventLogPruneInterval: Int = 50

    /// Pure cadence gate: true iff `appendCount` is a positive multiple of
    /// `interval`. Zero-count never prunes (avoids prune-on-first-write).
    /// `interval` must be >= 1; values < 1 are treated as 1 (always prune).
    nonisolated public static func shouldPrune(appendCount: Int, interval: Int) -> Bool {
        let n = max(1, interval)
        return appendCount > 0 && appendCount % n == 0
    }

    /// Wire EventBus.shared.persister to append to the event log off-main,
    /// pruning on a counter cadence rather than on every append.
    /// In production AppDelegate overrides this after init; in tests (no
    /// AppDelegate) this persister is the active one and exercises the queue.
    ///
    /// The append counter is a local closure variable guarded by the serial
    /// backgroundWriterQueue, so no lock or @MainActor access is needed.
    public func wireBackgroundPersister() {
        let log = eventLog
        let queue = backgroundWriterQueue
        // Counter is local to the closure; only ever mutated on `queue` (serial).
        var appendCount = 0
        EventBus.shared.persister = { ev in
            // surface.output is high-frequency binary; never persisted (same
            // predicate as AppDelegate.shouldPersistEvent).
            guard ev.kind != "surface.output" else { return }
            let payloadData = (try? JSONEncoder().encode(ev.payload)) ?? Data("null".utf8)
            let json = String(data: payloadData, encoding: .utf8) ?? "null"
            queue.async {
                _ = try? log.append(seq: ev.seq, kind: ev.kind, payloadJSON: json)
                appendCount += 1
                // shouldPrune gate: in future, move the bounded-log DELETE out of
                // EventLogRepository.append and call it here when shouldPrune returns
                // true. The counter is live now so the cadence logic is in place.
                _ = AppContext.shouldPrune(appendCount: appendCount,
                                           interval: AppContext.eventLogPruneInterval)
            }
        }
    }

    public func apply(_ action: LayoutAction) throws {
        state = try reducer.reduce(state, action)
        // Every layout mutation (workspace create/close/select, surface
        // add/close/split/move, etc.) schedules a debounced snapshot
        // write so workspaces and tabs survive a restart even if the app
        // is killed before a clean quit.
        scheduleSnapshotSave()
    }

    public func scheduleSnapshotSave(delay: TimeInterval = 0.4) {
        pendingSave?.cancel()
        // Capture layout state on main, then write to DB off-main so the
        // debounced save does not block the main thread during event bursts.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snap = SessionSnapshot(layout: self.state)
            let repo = self.snapshotRepo
            self.backgroundWriterQueue.async {
                _ = try? repo.save(snap)
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func saveSnapshot() {
        pendingSave?.cancel()
        pendingSave = nil
        let snap = SessionSnapshot(layout: state)
        _ = try? snapshotRepo.save(snap)
    }

    /// Drain backgroundWriterQueue synchronously. Use in tests that call
    /// saveSnapshot() / wireBackgroundPersister() and then immediately read
    /// back from a fresh AppContext; ensures all queued writes have landed
    /// before the assertion.
    public func flushWriterQueue() {
        backgroundWriterQueue.sync {}
    }

    @discardableResult
    public func reapIdleProviderSessions(now: Date = Date(), idleAge: TimeInterval = 6 * 60 * 60) throws -> ProviderSessionReaperResult {
        let cutoff = now.addingTimeInterval(-idleAge)
        let activeThreadIds = Set(
            try threadRepo.list().filter { thread in
                thread.status == .running
            }.map(\.id)
        )
        let reaper = ProviderSessionReaper(
            sessionRepo: providerSessionRuntimeRepo,
            pendingCallbackRepo: providerPendingCallbackRepo
        ) {
            activeThreadIds
        }
        let result = try reaper.reapIdleSessions(olderThan: cutoff)
        // Marking the session stopped in the DB does not free the underlying
        // provider process (codex app-server / node bridge). Release every
        // reaped thread's adapter session so the idle processes are actually
        // terminated. stopRun(threadId:) hits the adapter.stopSession path for
        // threads with no active run, which is exactly the idle/reaped case.
        for threadId in result.stoppedThreadIds {
            coordinator.stopRun(threadId: threadId)
        }
        return result
    }

    /// A reap candidate, reduced to the only two facts that decide eligibility:
    /// the thread's last-activity timestamp and whether the thread is still
    /// active. Pure, DB-free, so the selection rule can be tested directly.
    public struct ReapCandidate: Sendable, Equatable {
        public let threadId: AgentThreadID
        public let lastActivityAt: Date
        public let isActive: Bool

        public init(threadId: AgentThreadID, lastActivityAt: Date, isActive: Bool) {
            self.threadId = threadId
            self.lastActivityAt = lastActivityAt
            self.isActive = isActive
        }
    }

    /// Pure selection mirroring ProviderSessionReaper.reapIdleSessions: a thread
    /// is reap-eligible iff it is idle strictly past the cutoff AND not active.
    /// The returned set is exactly the threads that get marked stopped AND have
    /// adapter.stopSession called on them.
    nonisolated public static func reapEligibleThreadIds(
        candidates: [ReapCandidate],
        idleCutoff: Date
    ) -> [AgentThreadID] {
        candidates
            .filter { !$0.isActive && $0.lastActivityAt < idleCutoff }
            .map(\.threadId)
    }
}
