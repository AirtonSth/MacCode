import Foundation
import CoreModel

public protocol CodexAppServerControlling: AnyObject, Sendable {
    func initialize(clientName: String, clientTitle: String, clientVersion: String) async throws -> CodexAppServerInitializeResult
    func openThread(for request: AgentRunRequest) async throws -> CodexAppServerThreadOpenResult
    func startTurn(providerThreadId: String, for request: AgentRunRequest) async throws -> CodexAppServerClient.JSONObject
    func interruptTurn(providerThreadId: String, turnId: String) async throws
    func readThread(providerThreadId: String, includeTurns: Bool) async throws -> CodexAppServerClient.JSONObject
    func rollbackThread(providerThreadId: String, numTurns: Int) async throws -> CodexAppServerClient.JSONObject
    func updateThreadSettings(providerThreadId: String, permissionMode: AgentPermissionMode) async throws
    func stop()
}

extension CodexAppServerClient: CodexAppServerControlling {}

public final class CodexAppServerAdapter: AgentProviderAdapter, @unchecked Sendable {
    public let provider: AgentProvider = .codex

    public typealias ClientFactory = @Sendable (
        _ request: AgentRunRequest,
        _ notificationHandler: @escaping CodexAppServerClient.NotificationHandler,
        _ serverRequestHandler: @escaping CodexAppServerClient.ServerRequestHandler
    ) throws -> CodexAppServerControlling

    private struct Session {
        var client: CodexAppServerControlling
        var providerThreadId: String
        var activeTurnId: String?
        var status: AgentRunStatus
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var interactionMode: AgentInteractionMode
        var finalAssistantMessage: String
        var completedTurnIds: [String]
        var pendingApprovals: [String: PendingApproval]
        var pendingUserInputs: [String: PendingUserInput]
        var proposedPlanBuffers: [String: String]
        var emittedProposedPlanIds: Set<String>
        var startedItemIds: Set<String>
        var streamedItemIds: Set<String>
        var permissionMode: AgentPermissionMode
    }

    private struct PendingApproval {
        let continuation: CheckedContinuation<Any?, Error>
        let turnId: String?
        let itemId: String?
        let kind: AssistantRequestKind
    }

    private struct PendingUserInput {
        let continuation: CheckedContinuation<Any?, Error>
        let turnId: String?
        let itemId: String?
        let questionIds: [String]
        let multiSelectQuestionIds: Set<String>
    }

    private let binaryNameOverride: String?
    private let clientFactory: ClientFactory
    private let lock = NSLock()
    private var sessions: [AgentThreadID: Session] = [:]

    public init(binaryNameOverride: String? = nil, clientFactory: ClientFactory? = nil) {
        self.binaryNameOverride = binaryNameOverride
        self.clientFactory = clientFactory ?? { request, notificationHandler, serverRequestHandler in
            let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? request.providerBinary!
                : (binaryNameOverride ?? "codex")
            return try CodexAppServerClient(
                binary: binary,
                arguments: ["app-server"],
                cwd: request.cwd,
                environment: request.environment,
                notificationHandler: notificationHandler,
                serverRequestHandler: serverRequestHandler
            )
        }
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await CodexRunner(binaryNameOverride: binaryNameOverride).listModels()
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let client = try clientFor(request: request, onEvent: onEvent)
        _ = try await client.initialize(clientName: "remotecode", clientTitle: "RemoteCode", clientVersion: "0.0.0")
        let opened = try await client.openThread(for: request)
        recordSession(threadId: request.threadId, client: client, providerThreadId: opened.providerThreadId, interactionMode: request.interactionMode, onEvent: onEvent, permissionMode: request.permissionMode)
        onEvent(.status(.running))
        onEvent(.event(.threadStarted(threadId: opened.providerThreadId, providerThreadId: opened.providerThreadId)))

        let turn = try await client.startTurn(providerThreadId: opened.providerThreadId, for: request)
        if let turnId = Self.turnId(from: turn), !turnId.isEmpty {
            setActiveTurn(threadId: request.threadId, turnId: turnId)
            onEvent(.event(.turnStarted(turnId: turnId)))
        }

        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.cancel(threadId: request.threadId)
        }
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        guard let snapshot = sessionSnapshot(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard let turnId = snapshot.activeTurnId else { return }
        Task {
            try? await snapshot.client.interruptTurn(providerThreadId: snapshot.providerThreadId, turnId: turnId)
        }
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) throws {
        guard let pending = removePendingApproval(threadId: threadId, requestId: requestId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let state: AssistantRequestState
        switch response {
        case .approve, .approveForSession:
            state = .approved
        case .decline:
            state = .declined
        case .cancel:
            state = .cancelled
        }
        var payload: [String: Any] = [
            "requestId": requestId,
            "decision": Self.codexDecision(response)
        ]
        if let turnId = pending.turnId { payload["turnId"] = turnId }
        if let itemId = pending.itemId { payload["itemId"] = itemId }
        emit([
            runtimeEvent(method: "item/requestApproval/decision", payload: payload),
            .requestResolved(requestId: requestId, state: state)
        ], threadId: threadId)
        if response == .approveForSession {
            setSessionPermissionMode(threadId: threadId, permissionMode: .fullAccess)
            try promoteSessionPermission(threadId: threadId, to: .fullAccess)
        }
        pending.continuation.resume(returning: ["decision": Self.codexDecision(response)])
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        guard let pending = removePendingUserInput(threadId: threadId, requestId: requestId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let answers = Self.codexAnswers(
            questionIds: pending.questionIds,
            multiSelectQuestionIds: pending.multiSelectQuestionIds,
            text: text
        )
        var payload: [String: Any] = [
            "requestId": requestId,
            "answers": answers
        ]
        if let turnId = pending.turnId { payload["turnId"] = turnId }
        if let itemId = pending.itemId { payload["itemId"] = itemId }
        emit([
            runtimeEvent(method: "item/tool/requestUserInput/answered", payload: payload),
            .userInputResolved(requestId: requestId, answer: text)
        ], threadId: threadId)
        pending.continuation.resume(returning: ["answers": answers])
    }

    public func stopSession(threadId: AgentThreadID) throws {
        guard let session = removeSession(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        settlePendingCallbacks(session: session)
        session.client.stop()
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Codex app-server recovery requires providerThreadId")
        }
        let client = try clientFor(request: request, onEvent: onEvent)
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedResult<CodexAppServerThreadOpenResult>()
        Task {
            do {
                _ = try await client.initialize(clientName: "remotecode", clientTitle: "RemoteCode", clientVersion: "0.0.0")
                let opened = try await client.openThread(for: request)
                box.set(.success(opened))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            client.stop()
            throw AgentProviderAdapterError.unsupported("Codex app-server session recovery timed out")
        }
        do {
            let opened = try box.get().get()
            recordSession(threadId: request.threadId, client: client, providerThreadId: opened.providerThreadId, interactionMode: request.interactionMode, onEvent: onEvent, permissionMode: request.permissionMode)
            if let activeTurnId = Self.recoveryActiveTurnId(from: request.extraArgs) {
                setActiveTurn(threadId: request.threadId, turnId: activeTurnId)
            }
            onEvent(.event(.threadStarted(threadId: opened.providerThreadId, providerThreadId: opened.providerThreadId)))
        } catch {
            client.stop()
            throw error
        }
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return sessions.map { threadId, session in
            AgentProviderSessionSummary(threadId: threadId, provider: .codex, status: session.status, providerThreadId: session.providerThreadId)
        }
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    public func readThread(threadId: AgentThreadID) throws -> [AssistantEvent] {
        guard let snapshot = sessionSnapshot(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedResult<CodexAppServerClient.JSONObject>()
        Task {
            do {
                let response = try await snapshot.client.readThread(providerThreadId: snapshot.providerThreadId, includeTurns: true)
                box.set(.success(response))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw AgentProviderAdapterError.unsupported("Codex app-server thread/read timed out")
        }
        let response = try box.get().get()
        mergeCompletedTurnIds(threadId: threadId, turnIds: Self.turnIds(fromThreadReadResponse: response))
        return Self.events(fromThreadReadResponse: response, providerThreadId: snapshot.providerThreadId)
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) throws {
        guard var snapshot = sessionSnapshot(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        if snapshot.completedTurnIds.firstIndex(of: toTurnId) == nil {
            _ = try? readThread(threadId: threadId)
            if let refreshed = sessionSnapshot(threadId: threadId) {
                snapshot = refreshed
            }
        }
        guard let targetIndex = snapshot.completedTurnIds.firstIndex(of: toTurnId) else {
            throw AgentProviderAdapterError.unsupported("Codex app-server rollback target is not in completed turn history: \(toTurnId)")
        }
        let numTurns = snapshot.completedTurnIds.distance(from: targetIndex, to: snapshot.completedTurnIds.endIndex) - 1
        guard numTurns > 0 else { return }
        let client = snapshot.client
        let providerThreadId = snapshot.providerThreadId
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedResult<CodexAppServerClient.JSONObject>()
        Task {
            do {
                let response = try await client.rollbackThread(providerThreadId: providerThreadId, numTurns: numTurns)
                box.set(.success(response))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw AgentProviderAdapterError.unsupported("Codex app-server thread/rollback timed out")
        }
        _ = try box.get().get()
    }

    public func stopAll() {
        lock.lock()
        let stoppedSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        stoppedSessions.forEach { session in
            settlePendingCallbacks(session: session)
            session.client.stop()
        }
    }

    public func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        guard var session = sessionSnapshot(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        session.onEvent = onEvent
        lock.lock()
        sessions[threadId] = session
        lock.unlock()
    }

    private func clientFor(request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws -> CodexAppServerControlling {
        try clientFactory(
            request,
            { [weak self] method, params in
                self?.handleNotification(method: method, params: params, threadId: request.threadId)
            },
            { [weak self] method, params in
                guard let self else {
                    throw AgentProviderAdapterError.unsupported("Codex app-server adapter was released")
                }
                return try await self.handleServerRequest(method: method, params: params, threadId: request.threadId)
            }
        )
    }

    private func handleServerRequest(method: String, params: Any?, threadId: AgentThreadID) async throws -> Any? {
        let payload = params as? [String: Any] ?? [:]
        switch method {
        case "item/commandExecution/requestApproval":
            return try await awaitApproval(method: method, payload: payload, threadId: threadId, kind: .commandExecution)
        case "item/fileRead/requestApproval":
            return try await awaitApproval(method: method, payload: payload, threadId: threadId, kind: .fileRead)
        case "item/fileChange/requestApproval":
            return try await awaitApproval(method: method, payload: payload, threadId: threadId, kind: .fileChange)
        case "item/tool/requestUserInput":
            return try await awaitUserInput(method: method, payload: payload, threadId: threadId)
        default:
            emit([runtimeEvent(method: method, payload: payload)], threadId: threadId)
            throw AgentProviderAdapterError.unsupported("Unhandled Codex app-server request: \(method)")
        }
    }

    private func awaitApproval(method: String, payload: [String: Any], threadId: AgentThreadID, kind: AssistantRequestKind) async throws -> Any? {
        if sessionPermissionMode(threadId: threadId) == .fullAccess {
            emit([runtimeEvent(method: method, payload: payload)], threadId: threadId)
            return ["decision": "acceptForSession"]
        }
        let requestId = UUID().uuidString
        let turnId = string(payload, "turnId")
            ?? string(payload, "turn_id")
            ?? Self.nestedString(payload, objectKey: "turn", field: "id")
            ?? activeTurnId(threadId: threadId)
        let itemId = string(payload, "itemId")
            ?? string(payload, "item_id")
            ?? Self.nestedString(payload, objectKey: "item", field: "id")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            recordPendingApproval(threadId: threadId, requestId: requestId, pending: PendingApproval(
                continuation: continuation,
                turnId: turnId,
                itemId: itemId,
                kind: kind
            ))
            emit([
                runtimeEvent(method: method, payload: payload),
                .requestOpened(AssistantPendingRequest(
                    id: requestId,
                    turnId: turnId,
                    kind: kind,
                    title: Self.approvalTitle(for: kind),
                    detail: Self.approvalDetailString(from: payload),
                    createdAtMs: now
                ))
            ], threadId: threadId)
        }
    }

    private func promoteSessionPermission(threadId: AgentThreadID, to mode: AgentPermissionMode) throws {
        guard let snapshot = sessionSnapshot(threadId: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedResult<Void>()
        Task {
            do {
                try await snapshot.client.updateThreadSettings(providerThreadId: snapshot.providerThreadId, permissionMode: mode)
                box.set(.success(()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw AgentProviderAdapterError.unsupported("Codex app-server thread/settings/update timed out")
        }
        try box.get().get()
    }

    private func awaitUserInput(method: String, payload: [String: Any], threadId: AgentThreadID) async throws -> Any? {
        let requestId = UUID().uuidString
        let turnId = string(payload, "turnId")
            ?? string(payload, "turn_id")
            ?? Self.nestedString(payload, objectKey: "turn", field: "id")
            ?? activeTurnId(threadId: threadId)
        let itemId = string(payload, "itemId")
            ?? string(payload, "item_id")
            ?? Self.nestedString(payload, objectKey: "item", field: "id")
        let questions = Self.userInputQuestions(from: payload)
        let questionIds = questions.compactMap { string($0, "id") }
        let prompt = Self.userInputPrompt(from: questions)
        let options = Self.userInputOptions(from: questions)
        let allowsMultipleSelection = Self.userInputAllowsMultipleSelection(payload: payload, questions: questions)
        let isSecret = Self.userInputIsSecret(questions)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            recordPendingUserInput(threadId: threadId, requestId: requestId, pending: PendingUserInput(
                continuation: continuation,
                turnId: turnId,
                itemId: itemId,
                questionIds: questionIds.isEmpty ? [requestId] : questionIds,
                multiSelectQuestionIds: allowsMultipleSelection ? Set(questionIds.isEmpty ? [requestId] : questionIds) : []
            ))
            emit([
                runtimeEvent(method: method, payload: payload),
                .userInputRequested(AssistantUserInputRequest(
                    id: requestId,
                    turnId: turnId,
                    prompt: prompt,
                    options: options,
                    allowsMultipleSelection: allowsMultipleSelection,
                    isSecret: isSecret,
                    createdAtMs: now
                ))
            ], threadId: threadId)
        }
    }

    private func handleNotification(method: String, params: Any?, threadId: AgentThreadID) {
        let payload = params as? [String: Any] ?? [:]
        var events: [AssistantEvent] = [runtimeEvent(method: method, payload: payload)]
        var finished: AgentRunEvent?
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func appendCompletedTool(summary: String, output: String?) {
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "\(summary.lowercased().replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: summary,
                output: output?.nilIfEmpty,
                startedAtMs: now,
                finishedAtMs: now
            )))
        }
        switch method {
        case "thread/started":
            if let providerThreadId = string(payload, "threadId") ?? (payload["thread"] as? [String: Any]).flatMap({ string($0, "id") }) {
                events.append(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId))
            }
        case "error":
            let error = payload["error"] as? [String: Any] ?? payload
            let message = string(error, "message") ?? string(payload, "message") ?? Self.jsonString(error) ?? "Codex error"
            let details = string(error, "additionalDetails") ?? string(error, "additional_details")
            let full = [message, details].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
            events.append(.error(message: full.nilIfEmpty ?? "Codex error", recoverable: (payload["willRetry"] as? Bool) == true))
        case "thread/status/changed", "thread.status.changed":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "thread-status-\(string(payload, "threadId") ?? providerThreadId(threadId: threadId) ?? threadId.value.uuidString)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Thread status changed",
                output: Self.threadStatusDetail(from: payload),
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "turn/started":
            if let turnId = string(payload, "turnId") ?? (payload["turn"] as? [String: Any]).flatMap({ string($0, "id") }) {
                setActiveTurn(threadId: threadId, turnId: turnId)
                events.append(.turnStarted(turnId: turnId))
            }
        case "hook/started", "hook.started", "hook/completed", "hook.completed":
            let hook = payload["hook"] as? [String: Any] ?? payload["summary"] as? [String: Any] ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(hook, "id") ?? string(payload, "hookRunId") ?? string(payload, "hook_run_id") ?? "hook-\(UUID().uuidString)"
            let completed = method.contains("completed")
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: completed ? Self.itemState(for: string(hook, "status")) : .streaming,
                summary: completed ? "Hook completed" : "Hook started",
                output: Self.hookDetail(from: hook),
                startedAtMs: now,
                finishedAtMs: completed ? now : nil
            )))
        case "item/started", "item.started":
            let item = (payload["item"] as? [String: Any]) ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(item, "id") ?? string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let rawType = string(item, "type") ?? string(payload, "type") ?? "unknown"
            if rawType == "userMessage" { break }
            if markStartedItem(threadId: threadId, turnId: turnId, itemId: itemId) {
                events.append(.itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: turnId,
                    type: Self.assistantItemType(for: rawType),
                    state: .streaming,
                    summary: Self.summary(for: item, type: rawType),
                    startedAtMs: now
                )))
            }
        case "item/autoApprovalReview/started", "item.autoApprovalReview.started", "item/autoApprovalReview/completed", "item.autoApprovalReview.completed":
            let review = payload["review"] as? [String: Any] ?? payload["autoApprovalReview"] as? [String: Any] ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? string(review, "id") ?? "auto-approval-\(UUID().uuidString)"
            let completed = method.contains("completed")
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .review,
                state: completed ? Self.itemState(for: string(review, "status")) : .streaming,
                summary: "Auto approval review",
                output: Self.approvalReviewDetail(from: review),
                startedAtMs: now,
                finishedAtMs: completed ? now : nil
            )))
        case "item/completed", "item.completed":
            let item = (payload["item"] as? [String: Any]) ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(item, "id") ?? string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let rawType = string(item, "type") ?? string(payload, "type") ?? "unknown"
            if rawType == "userMessage" { break }
            let itemType = Self.assistantItemType(for: rawType)
            let summary = Self.summary(for: item, type: rawType)
            if rawType == "plan",
               let body = Self.body(for: item, type: rawType),
               let markdown = Self.proposedPlanMarkdown(in: body) ?? body.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
               markProposedPlanEmitted(threadId: threadId, planId: itemId) {
                events.append(.proposedPlan(AssistantProposedPlan(id: itemId, turnId: turnId.isEmpty ? nil : turnId, markdown: markdown)))
            }
            if itemType == .contextCompaction {
                events.append(.itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: turnId,
                    type: .contextCompaction,
                    state: .completed,
                    summary: summary,
                    startedAtMs: now,
                    finishedAtMs: now
                )))
                events.append(.contextCompaction(summary: summary))
            } else if Self.isRawResponseItemType(rawType) {
                events.append(.itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: turnId,
                    type: itemType,
                    state: .completed,
                    summary: summary,
                    startedAtMs: now,
                    finishedAtMs: now
                )))
            }
            if let body = Self.body(for: item, type: rawType), !body.isEmpty,
               itemType != .assistantMessage || !hasStreamedItem(threadId: threadId, turnId: turnId, itemId: itemId) {
                events.append(.itemDelta(
                    itemId: itemId,
                    bodyAppend: itemType == .assistantMessage ? body : nil,
                    outputAppend: itemType == .assistantMessage ? nil : body,
                    summary: summary
                ))
            }
            events.append(.itemCompleted(itemId: itemId, finalState: Self.itemState(for: string(item, "status"))))
        case "item/agentMessage/delta", "item.agentMessage.delta":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            ensureAssistantItem(threadId: threadId, turnId: turnId, itemId: itemId, now: now, events: &events)
            let delta = string(payload, "delta") ?? string(payload, "text") ?? ""
            appendFinalMessage(threadId: threadId, delta: delta)
            markStreamedItem(threadId: threadId, turnId: turnId, itemId: itemId)
            events.append(.itemDelta(itemId: itemId, bodyAppend: delta, outputAppend: nil, summary: nil))
        case "command/exec/outputDelta", "command.exec.outputDelta":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? string(payload, "commandId") ?? string(payload, "command_id") ?? "command-exec-\(UUID().uuidString)"
            let delta = string(payload, "delta") ?? string(payload, "text") ?? string(payload, "output") ?? Self.decodedBase64String(payload["deltaBase64"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Command output"))
        case "process/outputDelta", "process.outputDelta":
            let itemId = string(payload, "processHandle") ?? string(payload, "process_handle") ?? "process-\(UUID().uuidString)"
            let stream = string(payload, "stream") ?? "output"
            let delta = string(payload, "delta") ?? string(payload, "text") ?? Self.decodedBase64String(payload["deltaBase64"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Process \(stream)"))
        case "process/exited", "process.exited":
            let itemId = string(payload, "processHandle") ?? string(payload, "process_handle") ?? "process-\(UUID().uuidString)"
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let exitCode = Self.int(payload["exitCode"]) ?? Self.int(payload["exit_code"]) ?? 0
            let output = [string(payload, "stdout"), string(payload, "stderr")].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .commandExecution,
                state: exitCode == 0 ? .completed : .failed,
                summary: "Process exited \(exitCode)",
                output: output.nilIfEmpty,
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "item/commandExecution/outputDelta", "item/commandExecution/terminalInteraction":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let delta = string(payload, "delta") ?? string(payload, "text") ?? string(payload, "output") ?? Self.jsonString(payload["interaction"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Command output"))
        case "item/fileChange/outputDelta", "item/fileChange/patchUpdated":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let delta = string(payload, "delta") ?? string(payload, "text") ?? string(payload, "patch") ?? Self.jsonString(payload["changes"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "File change"))
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .reasoning, state: .streaming, summary: "Reasoning", startedAtMs: now)))
            let delta = string(payload, "delta") ?? string(payload, "text") ?? Self.jsonString(payload["summary"]) ?? ""
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Reasoning"))
        case "item/mcpToolCall/progress":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? UUID().uuidString
            events.append(.itemProgress(itemId: itemId, progress: Self.double(payload["progress"]) ?? Self.double(payload["percent"])))
        case "item/plan/delta", "turn.proposed.delta", "turn/proposed/delta":
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? "plan-\(turnId)"
            let delta = string(payload, "delta") ?? string(payload, "text") ?? ""
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .plan, state: .streaming, summary: "Plan", startedAtMs: now)))
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: delta, summary: "Plan"))
            let buffered = appendProposedPlanDelta(threadId: threadId, planId: itemId, delta: delta)
            if let markdown = Self.proposedPlanMarkdown(in: buffered),
               markProposedPlanEmitted(threadId: threadId, planId: itemId) {
                events.append(.proposedPlan(AssistantProposedPlan(id: itemId, turnId: turnId.isEmpty ? nil : turnId, markdown: markdown)))
            }
        case "turn.proposed.completed", "turn/proposed/completed":
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let planId = string(payload, "planId") ?? string(payload, "plan_id") ?? "plan-\(turnId)"
            let buffered = proposedPlanBuffer(threadId: threadId, planId: planId)
            if let markdown = Self.proposedPlanMarkdown(from: payload, fallback: buffered),
               markProposedPlanEmitted(threadId: threadId, planId: planId) {
                events.append(.proposedPlan(AssistantProposedPlan(id: planId, turnId: turnId.isEmpty ? nil : turnId, markdown: markdown)))
            }
        case "turn/plan/updated", "turn.plan.updated":
            if let plan = Self.activePlan(from: payload, now: now) {
                events.append(.activePlanUpdated(plan))
            }
        case "thread/goal/updated", "thread.goal.updated":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "goal-\(string(payload, "threadId") ?? providerThreadId(threadId: threadId) ?? threadId.value.uuidString)"
            let detail = Self.goalDetail(from: payload)
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Goal updated",
                startedAtMs: now,
                finishedAtMs: now
            )))
            events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: detail, summary: "Goal updated"))
        case "thread/goal/cleared", "thread.goal.cleared":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "goal-cleared-\(string(payload, "threadId") ?? providerThreadId(threadId: threadId) ?? threadId.value.uuidString)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Goal cleared",
                output: "Goal cleared",
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "turn/diff/updated", "turn.diff.updated":
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = "turn-diff-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let diff = string(payload, "diff") ?? Self.jsonString(payload["changes"]) ?? ""
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .fileChange,
                state: .completed,
                summary: "Turn diff updated",
                startedAtMs: now,
                finishedAtMs: now
            )))
            if !diff.isEmpty {
                events.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: diff, summary: "Turn diff updated"))
            }
        case "serverRequest/resolved", "serverRequest.resolved":
            if let requestId = string(payload, "requestId") ?? string(payload, "request_id") {
                events.append(.requestResolved(requestId: requestId, state: .resolved))
            }
        case "thread/tokenUsage/updated", "thread.token-usage.updated":
            if let usage = Self.tokenUsage(from: payload) {
                events.append(.tokenUsage(usage))
            }
        case "thread/compacted", "thread.compacted", "thread.state.changed":
            let state = string(payload, "state")
            if method != "thread.state.changed" || state == "compacted" {
                let summary = string(payload, "summary") ?? string(payload, "detail") ?? "Context compacted"
                let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
                let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? "context-compaction-\(turnId.isEmpty ? UUID().uuidString : turnId)"
                events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .contextCompaction, state: .completed, summary: summary, startedAtMs: now, finishedAtMs: now)))
                events.append(.contextCompaction(summary: summary))
            }
        case "warning", "guardianWarning":
            let message = string(payload, "message") ?? string(payload, "summary") ?? Self.jsonString(payload) ?? "Codex warning"
            appendCompletedTool(summary: method == "guardianWarning" ? "Codex guardian warning" : "Codex warning", output: message)
        case "configWarning", "deprecationNotice":
            let summary = string(payload, "summary") ?? (method == "configWarning" ? "Codex config warning" : "Codex deprecation notice")
            let details = string(payload, "details") ?? string(payload, "path")
            appendCompletedTool(summary: summary, output: details)
        case "account/updated", "account.updated":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "account-updated-\(UUID().uuidString)"
            let detail = [
                string(payload, "authMode").map { "Auth: \($0)" },
                string(payload, "planType").map { "Plan: \($0)" }
            ].compactMap { $0 }.joined(separator: "\n")
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "Account updated", output: detail.nilIfEmpty, startedAtMs: now, finishedAtMs: now)))
        case "account/rateLimits/updated", "account.rateLimits.updated":
            if let warning = Self.rateLimitWarning(from: payload) {
                appendCompletedTool(summary: "Codex rate limit", output: warning)
            }
        case "mcpServer/oauthLogin/completed", "mcpServer.startupStatus.updated", "mcpServer/startupStatus/updated":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "serverName") ?? string(payload, "server_name") ?? string(payload, "serverId") ?? "mcp-server-\(UUID().uuidString)"
            let status = string(payload, "status") ?? string(payload, "state") ?? "completed"
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .mcpToolCall, state: status == "failed" ? .failed : .completed, summary: "MCP server status", output: Self.jsonString(payload), startedAtMs: now, finishedAtMs: now)))
        case "model/rerouted", "model.rerouted":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "model-rerouted-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let reason = string(payload, "reason") ?? "unknown"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Model rerouted",
                output: "Model rerouted: \(reason)",
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "model/verification", "model.verification":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "model-verification-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let verification = Self.joinedStrings(payload["verifications"]) ?? string(payload, "verification") ?? "verified"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .completed,
                summary: "Model verification",
                output: "Model verification: \(verification)",
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "remoteControl/status/changed", "remoteControl.status.changed":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "remote-control-\(string(payload, "environmentId") ?? UUID().uuidString)"
            let status = string(payload, "status") ?? "unknown"
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "Remote control status", output: status, startedAtMs: now, finishedAtMs: now)))
        case "thread/realtime/started", "thread.realtime.started":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "realtimeSessionId") ?? string(payload, "realtime_session_id") ?? "realtime-\(UUID().uuidString)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .tool,
                state: .streaming,
                summary: "Realtime session started",
                output: Self.realtimeDetail(from: payload),
                startedAtMs: now
            )))
        case "thread/realtime/itemAdded", "thread.realtime.item-added":
            let item = payload["item"] as? [String: Any] ?? payload
            let turnId = string(payload, "turnId") ?? string(payload, "turn_id") ?? activeTurnId(threadId: threadId) ?? ""
            let itemId = string(item, "id") ?? string(payload, "itemId") ?? string(payload, "item_id") ?? "realtime-item-\(UUID().uuidString)"
            let rawType = string(item, "type") ?? string(payload, "type") ?? "realtime"
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: Self.assistantItemType(for: rawType),
                state: .completed,
                summary: "Realtime item added",
                output: Self.body(for: item, type: rawType) ?? Self.jsonString(item),
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "thread/realtime/transcript/delta", "thread.realtime.transcript.delta":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? string(payload, "responseId") ?? string(payload, "response_id") ?? "realtime-transcript-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let delta = string(payload, "delta") ?? string(payload, "text") ?? ""
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, state: .streaming, summary: "Realtime transcript", startedAtMs: now)))
            events.append(.itemDelta(itemId: itemId, bodyAppend: delta, outputAppend: nil, summary: "Realtime transcript"))
        case "thread/realtime/transcript/done", "thread.realtime.transcript.done":
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? string(payload, "responseId") ?? string(payload, "response_id") ?? "realtime-transcript-\(UUID().uuidString)"
            if let text = string(payload, "text") ?? string(payload, "transcript"), !text.isEmpty {
                events.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: "Realtime transcript"))
            }
            events.append(.itemCompleted(itemId: itemId, finalState: .completed))
        case "thread/realtime/outputAudio/delta", "thread.realtime.audio.delta":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "itemId") ?? string(payload, "item_id") ?? string(payload, "responseId") ?? string(payload, "response_id") ?? "realtime-audio-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let audio = string(payload, "audio") ?? string(payload, "delta") ?? string(payload, "audioDelta") ?? string(payload, "audio_delta") ?? ""
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .streaming, summary: "Realtime audio", output: audio, startedAtMs: now)))
        case "thread/realtime/sdp", "thread.realtime.sdp":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "realtimeSessionId") ?? string(payload, "realtime_session_id") ?? "realtime-sdp-\(UUID().uuidString)"
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "Realtime SDP", output: string(payload, "sdp") ?? Self.jsonString(payload), startedAtMs: now, finishedAtMs: now)))
        case "thread/realtime/error", "thread.realtime.error":
            let message = string(payload, "message") ?? (payload["error"] as? [String: Any]).flatMap { string($0, "message") } ?? "Realtime error"
            events.append(.error(message: "Codex realtime error: \(message)", recoverable: true))
        case "thread/realtime/closed", "thread.realtime.closed":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = string(payload, "realtimeSessionId") ?? string(payload, "realtime_session_id") ?? "realtime-closed-\(UUID().uuidString)"
            let reason = string(payload, "reason") ?? string(payload, "message") ?? "closed"
            events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "Realtime session closed", output: reason, startedAtMs: now, finishedAtMs: now)))
        case "fs/changed", "fs.changed":
            let turnId = activeTurnId(threadId: threadId) ?? ""
            let itemId = "fs-changed-\(turnId.isEmpty ? UUID().uuidString : turnId)"
            let paths = Self.joinedStrings(payload["changedPaths"]) ?? Self.joinedStrings(payload["paths"]) ?? Self.jsonString(payload["changedPaths"]) ?? ""
            events.append(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: .fileChange,
                state: .completed,
                summary: "Filesystem changed",
                output: paths,
                startedAtMs: now,
                finishedAtMs: now
            )))
        case "turn/completed", "turn.completed":
            let turnId = string(payload, "turnId") ?? (payload["turn"] as? [String: Any]).flatMap({ string($0, "id") }) ?? activeTurnId(threadId: threadId) ?? ""
            let final = Self.turnCompletedFinalMessage(from: payload) ?? finalMessage(threadId: threadId)
            if let markdown = Self.proposedPlanMarkdown(in: final) ?? planModeFinalMarkdown(threadId: threadId, final: final) {
                let planId = "plan-\(turnId)"
                if markProposedPlanEmitted(threadId: threadId, planId: planId) {
                    events.append(.proposedPlan(AssistantProposedPlan(id: planId, turnId: turnId.isEmpty ? nil : turnId, markdown: markdown)))
                }
            }
            events.append(.turnCompleted(turnId: turnId, finalMessage: final.isEmpty ? nil : final))
            finished = .finished(.completed, finalMessage: final.isEmpty ? nil : final, providerThreadId: providerThreadId(threadId: threadId))
            markFinished(threadId: threadId, status: .completed, turnId: turnId)
        default:
            break
        }
        emit(events, threadId: threadId)
        if let finished {
            sessionSnapshot(threadId: threadId)?.onEvent?(finished)
        }
    }

    private func runtimeEvent(method: String, payload: [String: Any]) -> AssistantEvent {
        Self.runtimeEvent(method: method, payload: payload)
    }

    private static func runtimeEvent(method: String, payload: [String: Any]) -> AssistantEvent {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .codex,
            source: "codex.app-server",
            method: method,
            providerTurnId: Self.providerTurnId(from: payload),
            providerItemId: Self.providerItemId(from: payload),
            providerRequestId: Self.providerRequestId(from: payload),
            payloadJSON: String(data: data, encoding: .utf8) ?? "{}",
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    private func ensureAssistantItem(threadId: AgentThreadID, turnId: String, itemId: String, now: Int64, events: inout [AssistantEvent]) {
        guard markStartedItem(threadId: threadId, turnId: turnId, itemId: itemId) else { return }
        events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, state: .streaming, startedAtMs: now)))
    }

    private func markStartedItem(threadId: AgentThreadID, turnId: String, itemId: String) -> Bool {
        let key = "\(turnId):\(itemId)"
        lock.lock()
        let alreadyStarted = sessions[threadId]?.startedItemIds.contains(key) ?? false
        if !alreadyStarted {
            sessions[threadId]?.startedItemIds.insert(key)
        }
        lock.unlock()
        return !alreadyStarted
    }

    private func markStreamedItem(threadId: AgentThreadID, turnId: String, itemId: String) {
        let key = "\(turnId):\(itemId)"
        lock.lock()
        sessions[threadId]?.streamedItemIds.insert(key)
        lock.unlock()
    }

    private func hasStreamedItem(threadId: AgentThreadID, turnId: String, itemId: String) -> Bool {
        let key = "\(turnId):\(itemId)"
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.streamedItemIds.contains(key) ?? false
    }

    private func emit(_ events: [AssistantEvent], threadId: AgentThreadID) {
        let onEvent = sessionSnapshot(threadId: threadId)?.onEvent
        for event in events {
            onEvent?(.event(event))
        }
    }

    private func settlePendingCallbacks(session: Session) {
        let onEvent = session.onEvent
        for (requestId, pending) in session.pendingApprovals {
            onEvent?(.event(.requestResolved(requestId: requestId, state: .cancelled)))
            pending.continuation.resume(returning: ["decision": "cancel"])
        }
        for (requestId, pending) in session.pendingUserInputs {
            onEvent?(.event(.userInputResolved(requestId: requestId, answer: nil)))
            pending.continuation.resume(returning: ["answers": Self.codexAnswers(
                questionIds: pending.questionIds,
                multiSelectQuestionIds: pending.multiSelectQuestionIds,
                text: ""
            )])
        }
    }

    private func cancel(threadId: AgentThreadID) {
        guard let session = removeSession(threadId: threadId) else { return }
        let turnId = session.activeTurnId
        settlePendingCallbacks(session: session)
        if let turnId {
            Task {
                try? await session.client.interruptTurn(providerThreadId: session.providerThreadId, turnId: turnId)
                session.client.stop()
            }
        } else {
            session.client.stop()
        }
        session.onEvent?(.status(.cancelled))
        session.onEvent?(.finished(.cancelled, finalMessage: nil, providerThreadId: session.providerThreadId))
    }

    private func recordSession(threadId: AgentThreadID, client: CodexAppServerControlling, providerThreadId: String, interactionMode: AgentInteractionMode, onEvent: @escaping @Sendable (AgentRunEvent) -> Void, permissionMode: AgentPermissionMode) {
        lock.lock()
        sessions[threadId] = Session(
            client: client,
            providerThreadId: providerThreadId,
            activeTurnId: nil,
            status: .running,
            onEvent: onEvent,
            interactionMode: interactionMode,
            finalAssistantMessage: "",
            completedTurnIds: [],
            pendingApprovals: [:],
            pendingUserInputs: [:],
            proposedPlanBuffers: [:],
            emittedProposedPlanIds: [],
            startedItemIds: [],
            streamedItemIds: [],
            permissionMode: permissionMode
        )
        lock.unlock()
    }

    private func sessionSnapshot(threadId: AgentThreadID) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]
    }

    private func planModeFinalMarkdown(threadId: AgentThreadID, final: String) -> String? {
        let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard sessions[threadId]?.interactionMode == .plan else { return nil }
        return trimmed
    }

    private func removeSession(threadId: AgentThreadID) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return sessions.removeValue(forKey: threadId)
    }

    private func setActiveTurn(threadId: AgentThreadID, turnId: String) {
        lock.lock()
        sessions[threadId]?.activeTurnId = turnId
        lock.unlock()
    }

    private func activeTurnId(threadId: AgentThreadID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.activeTurnId
    }

    private func providerThreadId(threadId: AgentThreadID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.providerThreadId
    }

    private func sessionPermissionMode(threadId: AgentThreadID) -> AgentPermissionMode? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.permissionMode
    }

    private func setSessionPermissionMode(threadId: AgentThreadID, permissionMode: AgentPermissionMode) {
        lock.lock()
        sessions[threadId]?.permissionMode = permissionMode
        lock.unlock()
    }

    private func appendFinalMessage(threadId: AgentThreadID, delta: String) {
        lock.lock()
        sessions[threadId]?.finalAssistantMessage += delta
        lock.unlock()
    }

    private func finalMessage(threadId: AgentThreadID) -> String {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.finalAssistantMessage ?? ""
    }

    private func markFinished(threadId: AgentThreadID, status: AgentRunStatus, turnId: String?) {
        lock.lock()
        sessions[threadId]?.status = status
        sessions[threadId]?.activeTurnId = nil
        if let turnId, !turnId.isEmpty, sessions[threadId]?.completedTurnIds.contains(turnId) == false {
            sessions[threadId]?.completedTurnIds.append(turnId)
        }
        lock.unlock()
    }

    private func mergeCompletedTurnIds(threadId: AgentThreadID, turnIds: [String]) {
        guard !turnIds.isEmpty else { return }
        lock.lock()
        if var session = sessions[threadId] {
            for turnId in turnIds where !session.completedTurnIds.contains(turnId) {
                session.completedTurnIds.append(turnId)
            }
            sessions[threadId] = session
        }
        lock.unlock()
    }

    private func recordPendingApproval(threadId: AgentThreadID, requestId: String, pending: PendingApproval) {
        lock.lock()
        sessions[threadId]?.pendingApprovals[requestId] = pending
        lock.unlock()
    }

    private func removePendingApproval(threadId: AgentThreadID, requestId: String) -> PendingApproval? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.pendingApprovals.removeValue(forKey: requestId)
    }

    private func recordPendingUserInput(threadId: AgentThreadID, requestId: String, pending: PendingUserInput) {
        lock.lock()
        sessions[threadId]?.pendingUserInputs[requestId] = pending
        lock.unlock()
    }

    private func removePendingUserInput(threadId: AgentThreadID, requestId: String) -> PendingUserInput? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.pendingUserInputs.removeValue(forKey: requestId)
    }

    private func appendProposedPlanDelta(threadId: AgentThreadID, planId: String, delta: String) -> String {
        lock.lock()
        sessions[threadId]?.proposedPlanBuffers[planId, default: ""] += delta
        let buffered = sessions[threadId]?.proposedPlanBuffers[planId] ?? delta
        lock.unlock()
        return buffered
    }

    private func proposedPlanBuffer(threadId: AgentThreadID, planId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId]?.proposedPlanBuffers[planId]
    }

    private func markProposedPlanEmitted(threadId: AgentThreadID, planId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard sessions[threadId]?.emittedProposedPlanIds.contains(planId) == false else { return false }
        sessions[threadId]?.emittedProposedPlanIds.insert(planId)
        return true
    }

    private func string(_ payload: [String: Any], _ key: String) -> String? {
        payload[key] as? String
    }

    private static func codexDecision(_ response: AgentProviderRequestResponse) -> String {
        switch response {
        case .approve:
            return "accept"
        case .approveForSession:
            return "acceptForSession"
        case .decline:
            return "decline"
        case .cancel:
            return "cancel"
        }
    }

    private static func approvalTitle(for kind: AssistantRequestKind) -> String {
        switch kind {
        case .fileRead:
            return "File read approval"
        case .fileChange:
            return "File change approval"
        case .commandExecution:
            return "Command approval"
        default:
            return "Provider approval"
        }
    }

    private static func codexAnswers(
        questionIds: [String],
        multiSelectQuestionIds: Set<String> = [],
        text: String
    ) -> [String: [String: [String]]] {
        let answersById = splitUserInputAnswers(questionIds: questionIds, text: text)
        return Dictionary(uniqueKeysWithValues: questionIds.map { id in
            let answer = answersById[id] ?? text
            return (id, ["answers": multiSelectQuestionIds.contains(id) ? splitMultiSelectAnswer(answer) : [answer]])
        })
    }

    private static func splitMultiSelectAnswer(_ text: String) -> [String] {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }

    private static func splitUserInputAnswers(questionIds: [String], text: String) -> [String: String] {
        guard questionIds.count > 1 else {
            return questionIds.first.map { [$0: text] } ?? [:]
        }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var mapped: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let rawKey = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard questionIds.contains(rawKey), !value.isEmpty else { continue }
            mapped[rawKey] = value
        }
        if !mapped.isEmpty { return mapped }
        guard lines.count == questionIds.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(questionIds, lines))
    }

    private static func detailString(from payload: [String: Any]) -> String? {
        for key in ["command", "commandLine", "cmd", "path", "file", "summary"] {
            if let value = payload[key] as? String, !value.isEmpty { return value }
            if let values = payload[key] as? [String], !values.isEmpty { return values.joined(separator: " ") }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func approvalDetailString(from payload: [String: Any]) -> String? {
        for candidate in approvalPayloadCandidates(from: payload) {
            var fields: [(String, String)] = []
            if let command = approvalValue(candidate, keys: ["command", "commandLine", "cmd"]) {
                fields.append(("Command", command))
            }
            if let cwd = approvalValue(candidate, keys: ["cwd", "workingDirectory", "working_directory"]) {
                fields.append(("Cwd", cwd))
            }
            if let file = approvalValue(candidate, keys: ["path", "file"]) {
                fields.append(("File", file))
            }
            if let reason = approvalValue(candidate, keys: ["reason", "description", "summary"]) {
                fields.append(("Reason", reason))
            }
            if let changes = approvalValue(candidate, keys: ["changes", "patch"]) {
                fields.append(("Changes", changes))
            }
            if fields.count == 1 { return fields[0].1 }
            if !fields.isEmpty {
                return fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            }
        }
        return detailString(from: payload)
    }

    private static func realtimeDetail(from payload: [String: Any]) -> String? {
        let values = [
            string(payload, "realtimeSessionId").map { "Session: \($0)" },
            string(payload, "model").map { "Model: \($0)" },
            string(payload, "voice").map { "Voice: \($0)" }
        ].compactMap { $0 }
        return values.isEmpty ? jsonString(payload) : values.joined(separator: "\n")
    }

    private static func approvalPayloadCandidates(from payload: [String: Any]) -> [[String: Any]] {
        var candidates = [payload]
        for key in ["approval", "request", "action", "item", "command", "fileChange"] {
            if let nested = payload[key] as? [String: Any] {
                candidates.append(nested)
            }
        }
        return candidates
    }

    private static func approvalValue(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let values = payload[key] as? [String], !values.isEmpty {
                return values.joined(separator: " ")
            }
            if let object = payload[key] as? [String: Any], let json = jsonString(object) {
                return json
            }
            if let array = payload[key] as? [Any], let json = jsonString(array) {
                return json
            }
        }
        return nil
    }

    private static func nestedString(_ payload: [String: Any], objectKey: String, field: String) -> String? {
        guard let object = payload[objectKey] as? [String: Any] else { return nil }
        return string(object, field)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        if let value = value as? Int { return value != 0 }
        return nil
    }

    private static func recoveryActiveTurnId(from extraArgs: [String]) -> String? {
        let prefix = "remotecode.recovery.activeTurnId="
        return extraArgs.compactMap { arg -> String? in
            guard arg.hasPrefix(prefix) else { return nil }
            let value = String(arg.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.first
    }

    private static func userInputPrompt(from questions: [[String: Any]]) -> String {
        let prompts = questions.compactMap { question -> String? in
            let header = question["header"] as? String
            let text = question["question"] as? String
            return [header, text]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ": ")
        }
        return prompts.isEmpty ? "Provider requested input." : prompts.joined(separator: "\n")
    }

    private static func userInputQuestions(from payload: [String: Any]) -> [[String: Any]] {
        for candidate in userInputPayloadCandidates(from: payload) {
            if let questions = candidate["questions"] as? [[String: Any]], !questions.isEmpty {
                return questions
            }
            if let question = candidate["question"] as? [String: Any] {
                return [question]
            }
            if let prompt = string(candidate, "prompt") ?? string(candidate, "question") {
                var question: [String: Any] = ["question": prompt]
                for key in ["id", "header", "options", "allowsMultipleSelection", "allowsMultiple", "multiple", "multiSelect", "isSecret", "secret", "sensitive", "inputType", "input_type", "type", "control"] {
                    if let value = candidate[key] {
                        question[key] = value
                    }
                }
                return [question]
            }
        }
        return []
    }

    private static func userInputPayloadCandidates(from payload: [String: Any]) -> [[String: Any]] {
        var candidates = [payload]
        for key in ["request", "input", "tool", "item", "params"] {
            if let nested = payload[key] as? [String: Any] {
                candidates.append(nested)
            }
        }
        return candidates
    }

    private static func userInputAllowsMultipleSelection(payload: [String: Any], questions: [[String: Any]]) -> Bool {
        let keys = ["allowsMultipleSelection", "allowsMultiple", "multiple", "multiSelect", "allows_multiple_selection", "allows_multiple", "multi_select"]
        for candidate in userInputPayloadCandidates(from: payload) + questions {
            for key in keys where boolValue(candidate[key]) == true {
                return true
            }
        }
        return false
    }

    private static func userInputOptions(from questions: [[String: Any]]) -> [String] {
        questions.flatMap { question -> [String] in
            guard let options = question["options"] as? [[String: Any]] else { return [] }
            return options.compactMap { $0["label"] as? String }
        }
    }

    private static func userInputIsSecret(_ questions: [[String: Any]]) -> Bool {
        questions.contains { question in
            if boolValue(question["isSecret"]) == true || boolValue(question["secret"]) == true || boolValue(question["sensitive"]) == true {
                return true
            }
            let raw = [
                string(question, "inputType"),
                string(question, "input_type"),
                string(question, "type"),
                string(question, "control")
            ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return raw.contains("password") || raw.contains("secret") || raw.contains("token")
        }
    }

    private static func turnId(from response: CodexAppServerClient.JSONObject) -> String? {
        if let turn = response["turn"] as? [String: Any], let id = turn["id"] as? String {
            return id
        }
        return response["turnId"] as? String ?? response["turn_id"] as? String
    }

    private static func events(fromThreadReadResponse response: CodexAppServerClient.JSONObject, providerThreadId: String) -> [AssistantEvent] {
        let thread = response["thread"] as? [String: Any] ?? response
        let threadId = string(thread, "id") ?? string(thread, "threadId") ?? providerThreadId
        var events: [AssistantEvent] = [.threadStarted(threadId: threadId, providerThreadId: threadId)]
        if let usage = tokenUsage(from: thread) {
            events.append(.tokenUsage(usage))
        }
        if string(thread, "state") == "compacted" {
            events.append(.contextCompaction(summary: string(thread, "summary") ?? "Context compacted"))
        }
        let turns = thread["turns"] as? [[String: Any]] ?? []
        for turn in turns {
            guard let turnId = string(turn, "id") else { continue }
            events.append(runtimeEvent(method: "thread/read.turn", payload: ["turn": turn]))
            events.append(.turnStarted(turnId: turnId))
            let startedAtMs = milliseconds(fromSeconds: turn["startedAt"]) ?? Int64(Date().timeIntervalSince1970 * 1000)
            let items = turn["items"] as? [[String: Any]] ?? []
            var finalMessage: String?
            for item in items {
                events.append(runtimeEvent(method: "thread/read.item", payload: ["turnId": turnId, "item": item]))
                events.append(contentsOf: Self.events(fromThreadItem: item, turnId: turnId, startedAtMs: startedAtMs))
                if string(item, "type") == "plan",
                   let body = body(for: item, type: "plan"),
                   let markdown = proposedPlanMarkdown(in: body) {
                    let planId = string(item, "id") ?? "plan-\(turnId)"
                    events.append(.proposedPlan(AssistantProposedPlan(id: planId, turnId: turnId, markdown: markdown)))
                }
                if string(item, "type") == "agentMessage",
                   let text = body(for: item, type: "agentMessage"),
                   !text.isEmpty {
                    finalMessage = text
                }
            }
            let status = string(turn, "status") ?? ""
            if status == "completed" || status == "failed" || status == "cancelled" || finalMessage != nil {
                events.append(.turnCompleted(turnId: turnId, finalMessage: finalMessage))
            }
        }
        return events
    }

    private static func turnIds(fromThreadReadResponse response: CodexAppServerClient.JSONObject) -> [String] {
        let thread = response["thread"] as? [String: Any] ?? response
        let turns = thread["turns"] as? [[String: Any]] ?? []
        return turns.compactMap { string($0, "id") }
    }

    private static func turnCompletedFinalMessage(from payload: [String: Any]) -> String? {
        for candidate in turnCompletedPayloadCandidates(from: payload) {
            if let text = stringBodyFallback(for: candidate)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            if let items = candidate["items"] as? [[String: Any]] {
                for item in items.reversed() {
                    let type = string(item, "type") ?? ""
                    if assistantItemType(for: type) == .assistantMessage,
                       let text = body(for: item, type: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        return text
                    }
                }
            }
        }
        return nil
    }

    private static func turnCompletedPayloadCandidates(from payload: [String: Any]) -> [[String: Any]] {
        var candidates = [payload]
        for key in ["turn", "message", "response", "result"] {
            if let nested = payload[key] as? [String: Any] {
                candidates.append(nested)
            }
        }
        return candidates
    }

    private static func events(fromThreadItem item: [String: Any], turnId: String, startedAtMs: Int64) -> [AssistantEvent] {
        let id = string(item, "id") ?? UUID().uuidString
        let type = string(item, "type") ?? "unknown"
        if type == "userMessage" { return [] }
        let itemType = assistantItemType(for: type)
        let state = itemState(for: string(item, "status"))
        let summary = summary(for: item, type: type)
        var events: [AssistantEvent] = [
            .itemStarted(item: AssistantItem(
                id: id,
                turnId: turnId,
                type: itemType,
                state: state == .completed ? .streaming : state,
                summary: summary,
                startedAtMs: startedAtMs
            ))
        ]
        if let body = body(for: item, type: type), !body.isEmpty {
            if itemType == .assistantMessage {
                events.append(.itemDelta(itemId: id, bodyAppend: body, outputAppend: nil, summary: summary))
            } else {
                events.append(.itemDelta(itemId: id, bodyAppend: nil, outputAppend: body, summary: summary))
            }
        }
        events.append(.itemCompleted(itemId: id, finalState: state))
        if type == "contextCompaction" {
            events.append(.contextCompaction(summary: summary))
        }
        return events
    }

    private static func assistantItemType(for type: String) -> AssistantItemType {
        switch type {
        case "agentMessage", "message": return .assistantMessage
        case "plan": return .plan
        case "reasoning", "reasoning_text", "summary_text": return .reasoning
        case "commandExecution", "local_shell_call", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output": return .commandExecution
        case "fileChange": return .fileChange
        case "mcpToolCall", "mcp_call": return .mcpToolCall
        case "dynamicToolCall", "imageGeneration": return .dynamicToolCall
        case "collabAgentToolCall": return .collabToolCall
        case "webSearch", "web_search_call", "tool_search_call", "tool_search_output", "search", "open_page", "find_in_page": return .webSearch
        case "imageView", "image_generation_call", "input_image": return .imageView
        case "enteredReviewMode", "exitedReviewMode": return .review
        case "contextCompaction", "context_compaction", "compaction", "compaction_trigger": return .contextCompaction
        default: return .tool
        }
    }

    private static func isRawResponseItemType(_ type: String) -> Bool {
        [
            "message", "reasoning", "reasoning_text", "summary_text",
            "local_shell_call", "function_call", "function_call_output",
            "custom_tool_call", "custom_tool_call_output", "mcp_call",
            "web_search_call", "tool_search_call", "tool_search_output",
            "search", "open_page", "find_in_page",
            "image_generation_call", "input_image",
            "context_compaction", "compaction", "compaction_trigger"
        ].contains(type)
    }

    private static func itemState(for status: String?) -> AssistantItemState {
        switch status {
        case "completed", "succeeded", "success": return .completed
        case "failed": return .failed
        case "cancelled", "canceled": return .cancelled
        default: return .streaming
        }
    }

    private static func summary(for item: [String: Any], type: String) -> String? {
        switch type {
        case "userMessage":
            return "User message"
        case "hookPrompt":
            return "Hook prompt"
        case "agentMessage", "message":
            return "Assistant message"
        case "plan":
            return "Plan"
        case "reasoning", "reasoning_text", "summary_text":
            return joinedStrings(item["summary"]) ?? "Reasoning"
        case "commandExecution", "local_shell_call":
            return string(item, "command") ?? string(item, "status")
        case "function_call", "custom_tool_call":
            return string(item, "name") ?? string(item, "call_id") ?? "Tool call"
        case "function_call_output", "custom_tool_call_output":
            return string(item, "call_id") ?? "Tool output"
        case "fileChange":
            if let changes = item["changes"] as? [[String: Any]] {
                return "\(changes.count) file change\(changes.count == 1 ? "" : "s")"
            }
            return "File change"
        case "mcpToolCall", "mcp_call":
            return [string(item, "server"), string(item, "tool"), string(item, "name")].compactMap { $0 }.joined(separator: ".")
        case "dynamicToolCall", "collabAgentToolCall":
            return string(item, "tool")
        case "webSearch", "web_search_call", "tool_search_call", "tool_search_output", "search", "open_page", "find_in_page":
            return string(item, "query") ?? string(item, "url") ?? string(item, "status") ?? "Web search"
        case "imageView":
            return string(item, "path")
        case "imageGeneration", "image_generation_call", "input_image":
            return string(item, "status") ?? "Image generation"
        case "enteredReviewMode", "exitedReviewMode":
            return "Review"
        case "contextCompaction", "context_compaction", "compaction", "compaction_trigger":
            return "Context compaction"
        default:
            return type
        }
    }

    private static func body(for item: [String: Any], type: String) -> String? {
        switch type {
        case "userMessage":
            return joinedStrings(item["content"]) ?? stringBodyFallback(for: item)
        case "hookPrompt":
            return joinedStrings(item["fragments"]) ?? stringBodyFallback(for: item)
        case "agentMessage", "message", "plan":
            return string(item, "text")
                ?? joinedStrings(item["content"])
                ?? string(item, "planMarkdown")
                ?? string(item, "plan_markdown")
                ?? string(item, "markdown")
        case "reasoning", "reasoning_text", "summary_text":
            return joinedStrings(item["content"]) ?? stringBodyFallback(for: item)
        case "commandExecution", "local_shell_call":
            return string(item, "aggregatedOutput") ?? string(item, "command") ?? stringBodyFallback(for: item)
        case "fileChange":
            return jsonString(item["changes"]) ?? stringBodyFallback(for: item)
        case "mcpToolCall", "mcp_call":
            return jsonString(item["result"]) ?? (item["error"] as? [String: Any]).flatMap { string($0, "message") } ?? stringBodyFallback(for: item)
        case "function_call", "custom_tool_call":
            return jsonString(item["arguments"]) ?? string(item, "arguments") ?? stringBodyFallback(for: item)
        case "function_call_output", "custom_tool_call_output":
            return joinedStrings(item["output"]) ?? stringBodyFallback(for: item)
        case "dynamicToolCall":
            return jsonString(item["contentItems"]) ?? stringBodyFallback(for: item)
        case "collabAgentToolCall":
            return jsonString(item["agentsStates"]) ?? stringBodyFallback(for: item)
        case "webSearch", "web_search_call", "tool_search_call", "tool_search_output", "search", "open_page", "find_in_page":
            return jsonString(item["action"]) ?? stringBodyFallback(for: item)
        case "imageView":
            return string(item, "path") ?? stringBodyFallback(for: item)
        case "imageGeneration", "image_generation_call", "input_image":
            return string(item, "result") ?? stringBodyFallback(for: item)
        case "enteredReviewMode", "exitedReviewMode":
            return string(item, "review") ?? stringBodyFallback(for: item)
        default:
            return stringBodyFallback(for: item) ?? jsonString(item)
        }
    }

    private static func stringBodyFallback(for item: [String: Any]) -> String? {
        for key in ["finalMessage", "final_message", "final", "answer", "text", "message", "output", "content", "result", "summary", "details", "detail", "path", "url", "query"] {
            if let value = joinedStrings(item[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func joinedStrings(_ value: Any?) -> String? {
        if let values = value as? [String] {
            return values.joined(separator: "\n")
        }
        if let values = value as? [[String: Any]] {
            let strings = values.compactMap { value -> String? in
                for key in ["text", "message", "content", "output", "summary"] {
                    if let text = joinedStrings(value[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        return text
                    }
                }
                return jsonString(value)
            }
            return strings.isEmpty ? nil : strings.joined(separator: "\n")
        }
        return value as? String
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func milliseconds(fromSeconds value: Any?) -> Int64? {
        if let value = value as? Double { return Int64(value * 1000) }
        if let value = value as? Int { return Int64(value * 1000) }
        return nil
    }

    private static func proposedPlanMarkdown(from payload: [String: Any], fallback: String?) -> String? {
        for key in ["planMarkdown", "plan_markdown", "markdown", "text"] {
            if let markdown = string(payload, key), !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return proposedPlanMarkdown(in: markdown) ?? markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let fallback else { return nil }
        return proposedPlanMarkdown(in: fallback) ?? fallback.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func proposedPlanMarkdown(in text: String) -> String? {
        guard let start = text.range(of: "<proposed_plan>"),
              let end = text.range(of: "</proposed_plan>", range: start.upperBound..<text.endIndex) else { return nil }
        let markdown = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return markdown.isEmpty ? nil : markdown
    }

    private static func activePlan(from payload: [String: Any], now: Int64) -> AssistantActivePlan? {
        let update = payload["update"] as? [String: Any]
        let rawSteps = payload["plan"] as? [[String: Any]]
            ?? payload["steps"] as? [[String: Any]]
            ?? update?["plan"] as? [[String: Any]]
            ?? update?["steps"] as? [[String: Any]]
        guard let rawSteps, !rawSteps.isEmpty else { return nil }
        let steps = rawSteps.enumerated().compactMap { index, raw -> AssistantPlanStep? in
            let title = string(raw, "step") ?? string(raw, "title") ?? string(raw, "text") ?? string(raw, "content") ?? ""
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let statusRaw = string(raw, "status") ?? "pending"
            let status = AssistantPlanStepStatus(rawValue: statusRaw)
                ?? (statusRaw == "inProgress" ? .inProgress : .pending)
            let id = string(raw, "id") ?? "\(index)-\(trimmed)"
            return AssistantPlanStep(id: id, title: trimmed, status: status)
        }
        guard !steps.isEmpty else { return nil }
        return AssistantActivePlan(
            explanation: string(payload, "explanation") ?? update.flatMap { string($0, "explanation") },
            steps: steps,
            updatedAtMs: now
        )
    }

    private static func providerTurnId(from payload: [String: Any]) -> String? {
        string(payload, "turnId")
            ?? string(payload, "turn_id")
            ?? nestedString(payload, objectKey: "turn", field: "id")
    }

    private static func providerItemId(from payload: [String: Any]) -> String? {
        string(payload, "itemId")
            ?? string(payload, "item_id")
            ?? nestedString(payload, objectKey: "item", field: "id")
    }

    private static func providerRequestId(from payload: [String: Any]) -> String? {
        string(payload, "requestId")
            ?? string(payload, "request_id")
            ?? nestedString(payload, objectKey: "request", field: "id")
    }

    private static func tokenUsage(from payload: [String: Any]) -> AssistantTokenUsage? {
        let container = payload["tokenUsage"] as? [String: Any] ?? payload["usage"] as? [String: Any] ?? payload
        let last = container["last"] as? [String: Any]
        let total = container["total"] as? [String: Any]
        let source = last ?? total ?? container
        let input = int(source["inputTokens"]) ?? int(source["input_tokens"]) ?? 0
        let output = int(source["outputTokens"]) ?? int(source["output_tokens"]) ?? 0
        let totalTokens = int(source["totalTokens"]) ?? int(source["total_tokens"]) ?? int(container["usedTokens"]) ?? (input + output)
        guard totalTokens > 0 || input > 0 || output > 0 else { return nil }
        let contextWindow = int(container["modelContextWindow"]) ?? int(container["contextWindow"]) ?? int(container["maxTokens"])
        return AssistantTokenUsage(inputTokens: input, outputTokens: output, totalTokens: totalTokens, contextWindow: contextWindow, compactsAutomatically: true)
    }

    private static func goalDetail(from payload: [String: Any]) -> String {
        let goal = payload["goal"] as? [String: Any] ?? payload
        var lines: [String] = []
        if let objective = string(goal, "objective") {
            lines.append("Objective: \(objective)")
        }
        if let status = string(goal, "status") {
            lines.append("Status: \(status)")
        }
        if let tokensUsed = int(goal["tokensUsed"]) ?? int(goal["tokens_used"]) {
            if let tokenBudget = int(goal["tokenBudget"]) ?? int(goal["token_budget"]) {
                lines.append("Tokens: \(tokensUsed) / \(tokenBudget)")
            } else {
                lines.append("Tokens: \(tokensUsed)")
            }
        }
        if let seconds = int(goal["timeUsedSeconds"]) ?? int(goal["time_used_seconds"]) {
            lines.append("Time: \(seconds)s")
        }
        return lines.joined(separator: "\n").nilIfEmpty ?? (jsonString(goal) ?? "Goal updated")
    }

    private static func rateLimitWarning(from payload: [String: Any]) -> String? {
        let rateLimits = payload["rateLimits"] as? [String: Any] ?? payload["rate_limits"] as? [String: Any] ?? payload
        let snapshot = rateLimits["primary"] as? [String: Any] ?? rateLimits
        let reached = string(rateLimits, "rateLimitReachedType") ?? string(rateLimits, "rate_limit_reached_type")
        let limitName = string(rateLimits, "limitName") ?? string(rateLimits, "limit_name") ?? string(snapshot, "name")
        let reset = string(snapshot, "resetsAt") ?? string(snapshot, "resets_at")
        guard reached != nil || limitName != nil || reset != nil else { return nil }
        var message = "Codex rate limit update"
        if let reached { message += ": \(reached)" }
        if let limitName { message += " (\(limitName))" }
        if let reset { message += " resets \(reset)" }
        return message
    }

    private static func threadStatusDetail(from payload: [String: Any]) -> String {
        let status = payload["status"] as? [String: Any] ?? payload
        let type = string(status, "type") ?? string(payload, "status") ?? "unknown"
        let flags = joinedStrings(status["activeFlags"]) ?? joinedStrings(status["active_flags"])
        return [type, flags.map { "Flags: \($0)" }].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
    }

    private static func hookDetail(from payload: [String: Any]) -> String? {
        let entries = payload["entries"] as? [[String: Any]]
        let entryText = entries?.compactMap { string($0, "text") }.joined(separator: "\n")
        let parts = [
            string(payload, "eventName").map { "Event: \($0)" },
            string(payload, "handlerType").map { "Handler: \($0)" },
            string(payload, "status").map { "Status: \($0)" },
            string(payload, "statusMessage"),
            entryText
        ]
        return parts.compactMap { $0?.nilIfEmpty }.joined(separator: "\n").nilIfEmpty
    }

    private static func approvalReviewDetail(from payload: [String: Any]) -> String? {
        let parts = [
            string(payload, "status").map { "Status: \($0)" },
            string(payload, "riskLevel").map { "Risk: \($0)" },
            string(payload, "userAuthorization").map { "User authorization: \($0)" },
            string(payload, "rationale")
        ]
        return parts.compactMap { $0?.nilIfEmpty }.joined(separator: "\n").nilIfEmpty
    }

    private static func decodedBase64String(_ value: Any?) -> String? {
        guard let encoded = value as? String,
              let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ payload: [String: Any], _ key: String) -> String? {
        payload[key] as? String
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> Result<Value, Error> {
        lock.lock(); defer { lock.unlock() }
        guard let result else {
            throw AgentProviderAdapterError.unsupported("Codex app-server thread/read returned no result")
        }
        return result
    }
}
