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
    private var cachedDistillClientKey: String?
    private var cachedDistillClient: DistillServiceClient?
    /// Test seam: when set, used instead of resolving a client from the live
    /// sidecar status. Production code never sets this.
    var distillClientOverrideForTesting: DistillServiceClient?
    /// Prompts shorter than this are sent verbatim: distillation overhead/latency
    /// isn't worth it and tiny instructions have nothing to compress.
    private static let tokenSaverMinCompressChars = 600

    public init(
        channel: ReleaseChannel = .debug,
        dbPathOverride: String? = nil,
        appSupportOverride: String? = nil,
        tokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing = TokenSaverAccountUsageRefresher()
    ) throws {
        self.channel = channel
        self.tokenSaverAccountUsageRefresher = tokenSaverAccountUsageRefresher
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
        self.coordinator.promptCompressor = { [weak self] prompt, provider in
            guard let self else { return prompt }
            return await self.tokenSaverCompress(prompt: prompt, provider: provider)
        }
        _ = try providerPendingCallbackRepo.markOpenStale(
            reason: "Provider callback state does not survive app restarts or recovered sessions. Restart the turn to continue."
        )
        installManagedDistillSkills()
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
        coordinator.onRunFinished = { tid, _, status in
            let kind = (status == .completed) ? "agent.run.completed" : "agent.run.failed"
            EventBus.shared.publish(kind: kind, payload: agentRunPayload(threadId: tid, status: status))
            EventBus.shared.publish(kind: "agent.run.finished", payload: agentRunPayload(threadId: tid, status: status))
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

    private func installManagedDistillSkills() {
        let installer = AgentSkillInstaller(appSupportDirectory: appSupportDirectory)
        do {
            managedDistillSkillInstallResults = [
                try installer.installDistillSkill(for: .codex, sourceRevision: "github-main-remote-code-template-v1"),
                try installer.installDistillSkill(for: .claude, sourceRevision: "github-main-remote-code-template-v1")
            ]
        } catch {
            NSLog("RemoteCode managed Distill skill install failed: \(error)")
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
    func tokenSaverCompress(prompt: String, provider: AgentProvider) async -> String {
        guard SettingsStore(db: db).load().tokenSaverEnabled else { return prompt }
        guard prompt.count >= Self.tokenSaverMinCompressChars else { return prompt }
        guard let client = currentDistillClient() else { return prompt }

        let request = DistillRequest(
            mode: .longText,
            priority: .interactive,
            input: prompt,
            maxOutputCharacters: max(512, prompt.count)
        )
        do {
            let response = try await client.distill(request)
            let compressed = response.output
            // Only adopt the compressed text when it is non-empty and actually
            // smaller in tokens; otherwise send the original untouched.
            guard !compressed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  response.savedTokens > 0,
                  compressed.count < prompt.count else {
                return prompt
            }
            do {
                _ = try tokenSaverSavingsRepo.record(
                    provider: provider.rawValue,
                    mode: request.mode.rawValue,
                    inputTokens: response.inputTokens,
                    outputTokens: response.outputTokens
                )
                NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
            } catch {
                NSLog("RemoteCode Token Saver savings persist failed: \(error)")
            }
            return compressed
        } catch {
            NSLog("RemoteCode Token Saver compression skipped (provider=\(provider.rawValue)): \(error)")
            return prompt
        }
    }

    private func recordTokenSaverUsage(_ usage: AssistantTokenUsage, runId: AgentRunID) {
        guard usage.totalTokens > 0,
              let run = try? runRepo.get(id: runId) else {
            return
        }
        let settings = SettingsStore(db: db).load()
        // Record only the real provider-billed token count. Savings are no
        // longer synthesised here from an assumed ratio — they are measured at
        // compression time and persisted to the token_saver_savings ledger.
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
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
        } catch {
            NSLog("RemoteCode Token Saver usage record failed: \(error)")
        }
    }

    private var pendingSave: DispatchWorkItem?

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
        let work = DispatchWorkItem { [weak self] in self?.saveSnapshot() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func saveSnapshot() {
        pendingSave?.cancel()
        pendingSave = nil
        let snap = SessionSnapshot(layout: state)
        _ = try? snapshotRepo.save(snap)
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
        return try reaper.reapIdleSessions(olderThan: cutoff)
    }
}
