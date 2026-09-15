import CoreGraphics
import Foundation
import CoreModel
import ImageIO
import os

private let claudeStreamLog = Logger(subsystem: "io.remotecode.agent", category: "claude.stream")

/// Surfaces the actionable "install the Claude CLI" guidance verbatim (no error
/// prefix) when the `claude` binary is absent, since the CLI adapter is now the
/// default engine and a missing binary is the first thing a fresh user hits.
struct ClaudeCLIUnavailableError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Wire kind for control-channel user-input replies (AskUserQuestion vs elicitation vs dialog).
enum ClaudeControlUserInputKind: Sendable, Equatable {
    case askUserQuestion(toolUseID: String?)
    case elicitation
    /// CLAUDE-CLI-016: tool-driven blocking dialogs (`request_user_dialog`).
    case userDialog(dialogKind: String)
}

/// Captured at can_use_tool open so approveForSession can echo suggestions / tool name.
struct ClaudePendingPermissionMeta: Sendable, Equatable {
    var toolName: String
    /// Raw JSON array of PermissionUpdate suggestions from the CLI, if any.
    var suggestionsJSON: String?
    var toolUseID: String?
    /// CLAUDE-CLI-017: tool `input` echoed as PermissionResult.updatedInput on allow.
    var inputJSON: String?
}

// Typealiases keep Session field types short without exporting the names.
private typealias ControlUserInputKind = ClaudeControlUserInputKind
private typealias PendingPermissionMeta = ClaudePendingPermissionMeta

public final class ClaudeStreamingCLIAdapter: AgentProviderAdapter, @unchecked Sendable {
    /// A turn `result` that arrived while the CLI still had background work
    /// running. Carries `runId` so a late event can never finish a newer run.
    struct DeferredFinish {
        let status: AgentRunStatus
        let finalMessage: String?
        let providerThreadId: String?
        let runId: AgentRunID?
        /// Wall-clock when the finish was first withheld (forensics / logs only).
        let deferredAt: Date
    }

    private final class Session: @unchecked Sendable {
        let threadId: AgentThreadID
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        var model: String
        /// Set when the provider was launched through the shared helper as
        /// another macOS user; its child processes carry this uid and can only
        /// be reaped by re-entering that uid through the helper during teardown.
        let foreignUserUID: uid_t?
        let parser = ClaudeParser()
        let lineBuffer = LineBuffer()
        // Serializes the stdout readabilityHandler against finishTerminated's
        // EOF drain: nil-ing a readabilityHandler does not wait for a callback
        // already running, and LineBuffer/ClaudeParser are not thread-safe.
        // Taken BEFORE the fd read so byte order is preserved across readers.
        let stdoutReadLock = NSLock()
        let writeQueue = DispatchQueue(label: "remotecode.claude-stream.write")
        var events: [AssistantEvent] = []
        var status: AgentRunStatus = .running
        var providerThreadId: String?
        var permissionMode: AgentPermissionMode
        var reasoningEffort: AgentReasoningEffort?
        var interactionMode: AgentInteractionMode
        var activeTurnId: String?
        var completedTurnIds: [String] = []
        var inFlightToolIds = Set<String>()
        var lastAssistantUuid: String?
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var inFlightRunId: AgentRunID?
        var sawError = false
        var pendingRequestIds = Set<String>()
        var pendingUserInputIds = Set<String>()
        /// Control-channel user-input ids (AskUserQuestion / elicitation) that must
        /// answer with `control_response` rather than a freeform stdin user prompt.
        /// Tool_use-only AskUserQuestion stays in `pendingUserInputIds` alone so the
        /// corpus path that reads a user JSONL line keeps working.
        var pendingControlUserInputs: [String: ControlUserInputKind] = [:]
        /// tool_name + permission_suggestions captured at can_use_tool open so
        /// approveForSession can emit `updatedPermissions` (CLAUDE-CLI-006).
        var pendingPermissionMeta: [String: PendingPermissionMeta] = [:]
        var environment: [String: String] = [:]
        var cancellationRequested = false
        /// Advertised CLI `system/init` capabilities (interrupt_receipt_v1, …).
        var cliCapabilities = Set<String>()
        /// request_id of the in-flight host interrupt control_request, if any.
        var pendingInterruptRequestId: String?
        /// Grace-period process stop; cancelled when an interrupt receipt arrives.
        var interruptKillWorkItem: DispatchWorkItem?
        /// Prompt of the in-flight turn — needed to re-drive once after an
        /// ambient task-notification-only CLI exit (see CLAUDE-AMBIENT-TASK-RESULT).
        var lastInFlightPrompt: String?
        /// Last request used to (re)spawn this session (cwd / model / resume).
        var lastSpawnRequest: AgentRunRequest?
        /// Saw a non-terminal ambient `result` with origin.kind == task-notification.
        var ambientTaskNotificationResultSeen = false
        /// True once this logical turn already spent its one ambient-exit retry.
        var ambientResumeRetryUsed = false
        /// Foreground assistant content or a non-ambient result completed the turn.
        var sawForegroundTurnProgress = false
        /// CLAUDE-BG-LIFECYCLE: task ids the CLI reports as still running —
        /// background shells (`task_type: local_bash`) and async subagents
        /// (`local_agent`). Authoritative snapshot from
        /// `system/background_tasks_changed`; `task_started` also seeds it so a
        /// `result` that races ahead of the first snapshot still sees "busy".
        /// Non-empty ⇒ the provider is NOT idle and a turn `result` is premature.
        var pendingBackgroundTaskIds = Set<String>()
        /// Shell-detached work the CLI does NOT track: a foreground Bash tool
        /// whose command backgrounds children with `&` / `nohup` / `setsid` /
        /// `disown` (no `run_in_background`, no `task_started`). When set and the
        /// CLI pending set is empty at turn end, we prefix `[[RC_AWAITING]]` so
        /// the host's existing marker path surfaces awaiting + auto-nudge — but
        /// we do NOT defer the terminal (the CLI never auto-resumes shell-detached
        /// children; withholding would hang until the inactivity watchdog).
        ///
        /// Accepted false-positive: a turn that backgrounds a long-lived process
        /// as the deliverable (e.g. starts a dev server) is marked awaiting once;
        /// one bounded auto-nudge then clears the streak. Preferred over silently
        /// reporting orchestration threads as finished.
        var sawDetachedShellSpawn = false
        /// A turn `result` withheld because background work was still pending.
        /// Re-armed by every later `result`; only the one observed while the
        /// pending set is empty becomes the run's single terminal event.
        var deferredFinish: DeferredFinish?
        /// Liveness bound for a deferral (reset on any stream line). Guarantees a
        /// terminal state even if the CLI never resumes; on expiry the withheld
        /// finish is emitted so the awaiting-banner fallback can take over.
        var deferralWatchdog: DispatchWorkItem?
        // PERF-008 / F4: signature of the last emitted snapshot state (the state
        // fields only, reason excluded) so identical snapshots fired by
        // high-frequency tool deltas are coalesced. F4 computes this directly from
        // the structured state (a delimited string) instead of JSON-encoding the
        // whole payload dict on every delta — the payload + its JSON encode are now
        // built only when the state actually changed and will be broadcast.
        var lastSnapshotStateSignature: String?

        init(threadId: AgentThreadID,
             process: Process,
             stdinPipe: Pipe,
             stdoutPipe: Pipe,
             stderrPipe: Pipe,
             model: String,
             permissionMode: AgentPermissionMode,
             reasoningEffort: AgentReasoningEffort?,
             interactionMode: AgentInteractionMode,
             foreignUserUID: uid_t?) {
            self.threadId = threadId
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.model = model
            self.foreignUserUID = foreignUserUID
            self.permissionMode = permissionMode
            self.reasoningEffort = reasoningEffort
            self.interactionMode = interactionMode
        }
    }

    public let provider: AgentProvider = .claude
    private let binaryNameOverride: String?
    private let maxReadableEvents: Int
    private let transcriptStore: ClaudeTranscriptStore
    private let interruptGracePeriod: TimeInterval
    private let lock = NSLock()
    private var sessions: [AgentThreadID: Session] = [:]
    // UX-RESUME: set of thread IDs whose last session was killed by interruptTurn.
    // Cleared when sendTurn begins a new session for that thread. Guarded by `lock`.
    private var interruptedThreadIds: Set<AgentThreadID> = []

    /// CLAUDE-BG-LIFECYCLE: inactivity bound for a withheld finish, fully reset
    /// by stream lines. Quiet background jobs emit nothing until they end; on
    /// expiry the run still reaches a terminal state. There is intentionally
    /// **no** absolute wall-clock max: long goals / long background work that
    /// keep streaming progress must not be force-finished mid-flight.
    /// Injectable so tests can drive it in ms.
    private let deferredFinishInactivityTimeout: TimeInterval
    /// After the CLI reports idle pending tasks, wait briefly for a resume `result`
    /// (happy path). If none arrives, flush the withheld finish so Working ends.
    private let deferredFinishPostIdleTimeout: TimeInterval

    public init(
        binaryNameOverride: String? = nil,
        maxReadableEvents: Int = 5_000,
        transcriptStore: ClaudeTranscriptStore = ClaudeTranscriptStore(),
        interruptGracePeriod: TimeInterval = 2,
        deferredFinishInactivityTimeout: TimeInterval = 900,
        deferredFinishPostIdleTimeout: TimeInterval = 45
    ) {
        self.binaryNameOverride = binaryNameOverride
        self.maxReadableEvents = max(1, maxReadableEvents)
        self.transcriptStore = transcriptStore
        self.interruptGracePeriod = max(0, interruptGracePeriod)
        self.deferredFinishInactivityTimeout = max(0.01, deferredFinishInactivityTimeout)
        self.deferredFinishPostIdleTimeout = max(0.01, deferredFinishPostIdleTimeout)
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await listModelsResult().models
    }

    public func listModelsResult(
        environment: [String: String] = [:],
        cwd: String = FileManager.default.currentDirectoryPath,
        runAsUser: AgentRunAsUser? = nil
    ) async -> ModelListResult {
        await ClaudeRunner(binaryNameOverride: binaryNameOverride).listModelsResult(
            environment: environment,
            cwd: cwd,
            runAsUser: runAsUser
        )
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let session: Session
        do {
            session = try sessionFor(request: request)
        } catch AgentRunError.missingBinary(let binary) {
            // Rethrow with the full install guidance so the transcript shows an
            // actionable message instead of a bare "CLI not found in PATH".
            throw ClaudeCLIUnavailableError(message: ClaudeRunner.missingBinaryMessage(binary))
        }
        // CLAUDE-BG-LIFECYCLE: a run whose finish is withheld still owns
        // `inFlightRunId`, which would make the guard below reject the user's next
        // message. Settle the old run first so sending stays possible (and so the
        // deferral can never bleed into a newer run).
        flushDeferredFinish(session: session, reason: "new_turn")
        lock.lock()
        if session.inFlightRunId != nil {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude streaming session already has an in-flight turn")
        }
        session.onEvent = onEvent
        session.inFlightRunId = request.runId
        session.sawError = false
        session.status = .running
        session.cancellationRequested = false
        session.lastInFlightPrompt = request.providerPrompt
        session.lastSpawnRequest = request
        // Fresh user turn: clear ambient-only bookkeeping. A mid-run ambient
        // retry reuses the same Session fields without going through sendTurn.
        session.ambientTaskNotificationResultSeen = false
        session.ambientResumeRetryUsed = false
        session.sawForegroundTurnProgress = false
        // UX-RESUME: consume the interrupted flag for this thread so the
        // emission below fires exactly once per respawn, not on every turn.
        let wasInterrupted = interruptedThreadIds.remove(request.threadId) != nil
        lock.unlock()

        // UX-RESUME: when this sendTurn is spawning a fresh session after an
        // interrupt, emit a "resuming session..." providerRuntime event BEFORE
        // the standard .running status so the UI can show a transient banner.
        // needsSessionResume is a pure seam; the emit is the only side effect.
        if Self.needsSessionResume(afterInterrupt: wasInterrupted, hasPersistentSession: request.providerThreadId != nil) {
            let payload = Self.jsonString(["reason": "session_respawn"]) ?? "{}"
            let resuming = AssistantEvent.providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.stream-json.session",
                method: "claude.session.resuming",
                payloadJSON: payload,
                receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))
            onEvent(.event(resuming))
        }
        do {
            if let acceptancePermit = request.acceptancePermit {
                try acceptancePermit.withAcceptance {
                    try sendPrompt(request.providerPrompt, to: session, attachments: request.attachments)
                }
            } else {
                try sendPrompt(request.providerPrompt, to: session, attachments: request.attachments)
            }
        } catch {
            lock.lock()
            if session.inFlightRunId == request.runId {
                session.inFlightRunId = nil
                session.onEvent = nil
                session.status = .failed
            }
            lock.unlock()
            throw error
        }
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: session.process) { [weak self] in
            try? self?.interruptTurn(threadId: request.threadId)
        }
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        lock.lock()
        let session = sessions[threadId]
        // UX-RESUME: record the interrupt before any kill so the next sendTurn
        // on this thread knows to emit a "resuming session..." signal.
        if session != nil {
            interruptedThreadIds.insert(threadId)
            session?.cancellationRequested = true
        }
        let cancelQueued = session?.cliCapabilities.contains("interrupt_cancel_queued_v1") ?? false
        let ownedRunId = session?.inFlightRunId
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        // Attempt graceful interrupt via stream-json control message first.
        // This lets the Claude CLI finish writing and close cleanly, preserving
        // the warm session for potential resumption. Fall back to process kill
        // only if the stdin write fails (pipe closed, process already dead, etc.).
        // Publish pendingInterruptRequestId AND the grace-kill work item before the
        // stdin write becomes visible so a fast control_response can cancel the
        // same work item (CLAUDE-INT-002 race).
        let line = Self.controlInterruptLine(cancelQueued: cancelQueued)
        guard let requestId = Self.controlRequestId(fromInterruptLine: line), !requestId.isEmpty else {
            // Malformed interrupt payload — fall back to hard stop.
            try stopSession(threadId: threadId)
            return
        }
        // Box lets the work item re-check that *this* item is still installed
        // after DispatchWorkItem.cancel() (cancel is a no-op once running).
        final class InterruptKillBox: @unchecked Sendable {
            var item: DispatchWorkItem?
        }
        let killBox = InterruptKillBox()
        let killWork = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.lock.lock()
            // CLAUDE-INT-002: cancel() does not stop a body that already began.
            // Ownership of the pending interrupt + installed work item must still
            // match before we hard-stop; a matching receipt clears both first.
            let mappedSessionIsExact = self.sessions[threadId] === session
            let stillOwnsInterrupt = Self.shouldExecuteInterruptGraceKill(
                sessionStillCurrent: mappedSessionIsExact,
                inFlightRunId: session.inFlightRunId,
                ownedRunId: ownedRunId,
                pendingRequestId: session.pendingInterruptRequestId,
                scheduledRequestId: requestId,
                installedWorkItemIsSelf: session.interruptKillWorkItem === killBox.item
            )
            var sessionToTerminate: Session? = nil
            if stillOwnsInterrupt {
                session.interruptKillWorkItem = nil
                session.pendingInterruptRequestId = nil
            }
            // Remove the exact Session under this lock. stopSession(threadId:)
            // after unlock re-resolves by id and can terminate a later sendTurn.
            if Self.shouldRemoveSessionOnInterruptGraceKill(
                stillOwnsInterrupt: stillOwnsInterrupt,
                mappedSessionIsExact: mappedSessionIsExact
            ) {
                session.cancellationRequested = true
                self.sessions.removeValue(forKey: threadId)
                sessionToTerminate = session
            }
            self.lock.unlock()
            if let sessionToTerminate {
                self.terminate(session: sessionToTerminate, status: .cancelled)
            }
        }
        killBox.item = killWork
        lock.lock()
        session.pendingInterruptRequestId = requestId
        session.interruptKillWorkItem?.cancel()
        session.interruptKillWorkItem = killWork
        lock.unlock()
        let didSend = session.writeQueue.sync {
            (try? GuardedStdinWrite.write(line,
                                          to: session.stdinPipe.fileHandleForWriting,
                                          process: session.process,
                                          notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) })) != nil
        }
        if !didSend {
            lock.lock()
            if session.pendingInterruptRequestId == requestId {
                session.pendingInterruptRequestId = nil
            }
            if session.interruptKillWorkItem === killWork {
                session.interruptKillWorkItem?.cancel()
                session.interruptKillWorkItem = nil
            }
            lock.unlock()
            try stopSession(threadId: threadId)
            return
        }
        // Schedule only while this interrupt is still pending. A receipt that
        // arrived during the write already cleared pending + cancelled killWork.
        lock.lock()
        let stillPending = Self.shouldScheduleInterruptGraceKill(
            pendingRequestId: session.pendingInterruptRequestId,
            scheduledRequestId: requestId,
            killWorkStillInstalled: session.interruptKillWorkItem === killWork
        )
        lock.unlock()
        if stillPending {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + interruptGracePeriod,
                execute: killWork
            )
        }
    }

    /// Pure decision: should the next sendTurn emit a "resuming session..."
    /// signal? True only when the previous session for this thread was killed by
    /// an interrupt AND the new request carries a providerThreadId (so Claude
    /// CLI will resume the conversation rather than start fresh).
    ///
    /// WHY: the user must see that the next turn is respawning a fresh process
    /// linked to their existing conversation, not silently hanging.
    /// No I/O, no actor isolation. Extracted for unit testing.
    nonisolated static func needsSessionResume(afterInterrupt: Bool, hasPersistentSession: Bool) -> Bool {
        afterInterrupt && hasPersistentSession
    }

    /// Builds the stream-json user message object for CLI stdin.
    /// Empty attachments stay a single text block. Images become base64
    /// content blocks; other files become text path mentions — same shape as
    /// ClaudeAgentSDKBridge.mjs attachmentBlock (CLAUDE-CLI-009).
    nonisolated static func userPromptPayload(text: String, attachments: [AgentAttachment] = []) throws -> [String: Any] {
        try ClaudeAgentSDKBridgeAdapter.validateAttachments(attachments)
        var content: [[String: Any]] = [["type": "text", "text": text]]
        for attachment in attachments {
            content.append(try attachmentContentBlock(attachment))
        }
        // CLAUDE-CLI-015: SDKUserMessage requires parent_tool_use_id (null for
        // top-level host turns). Bridge always sets it; CLI stdin must match.
        // CLAUDE-ORIGIN-001: unattributed user lines miss human-only CLI gates
        // (ultracode, queued_turn_count). Host-typed stdin is origin.kind=human
        // and carries a uuid so reply binding and cancel_queued receipts work.
        return [
            "type": "user",
            "uuid": UUID().uuidString,
            "origin": ["kind": "human"],
            "message": [
                "role": "user",
                "content": content
            ],
            "parent_tool_use_id": NSNull()
        ]
    }

    nonisolated static func attachmentContentBlock(
        _ attachment: AgentAttachment,
        maxPixel: Int = AgentAttachmentWireImage.maxPixel,
        maxEncodedBytes: Int = AgentAttachmentWireImage.maxEncodedBytes
    ) throws -> [String: Any] {
        let mimeType = attachment.mimeType ?? ""
        let isImage = attachment.kind == .image || mimeType.hasPrefix("image/")
        if isImage {
            let supported = ["image/jpeg", "image/png", "image/gif", "image/webp"]
            guard supported.contains(mimeType) else {
                throw AgentProviderAdapterError.unsupported(
                    "Unsupported Claude image attachment type: \(mimeType.isEmpty ? "unknown" : mimeType)"
                )
            }
            let payload: AgentAttachmentWireImage.Payload
            do {
                payload = try AgentAttachmentWireImage.encode(
                    path: attachment.path,
                    mimeType: mimeType,
                    maxPixel: maxPixel,
                    maxEncodedBytes: maxEncodedBytes
                )
            } catch let error as AgentAttachmentWireImage.EncodeError {
                throw AgentProviderAdapterError.unsupported(error.description)
            }
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": payload.mediaType,
                    "data": payload.data.base64EncodedString()
                ]
            ]
        }
        return [
            "type": "text",
            "text": "[Attachment: \(attachment.displayName)]\n\(attachment.path)"
        ]
    }

    /// Builds the newline-terminated stream-json control interrupt payload.
    /// Pure builder — no I/O, no actor isolation. Extracted for unit testing.
    /// When `cancelQueued` is true (`interrupt_cancel_queued_v1`), include
    /// `cancel_queued: true` so queued turns are cancelled with the interrupt.
    nonisolated static func controlInterruptLine(cancelQueued: Bool = false) -> Data {
        // Claude CLI stream-json / Agent SDK control channel:
        // {"type":"control_request","request_id":"<uuid>","request":{"subtype":"interrupt"}}
        var request: [String: Any] = ["subtype": "interrupt"]
        if cancelQueued {
            request["cancel_queued"] = true
        }
        let payload: [String: Any] = [
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": request
        ]
        var data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        data.append(0x0A) // newline delimiter
        return data
    }

    /// request_id from a control interrupt line produced by `controlInterruptLine`.
    nonisolated static func controlRequestId(fromInterruptLine data: Data) -> String? {
        let stripped = data.last == 0x0A ? data.dropLast() : Data.SubSequence(data)
        guard let object = try? JSONSerialization.jsonObject(with: Data(stripped)) as? [String: Any],
              let requestId = object["request_id"] as? String,
              !requestId.isEmpty else { return nil }
        return requestId
    }

    /// Capabilities advertised on `system/init`. Nil when the object is not init.
    nonisolated static func initCapabilities(from object: [String: Any]?) -> Set<String>? {
        guard let object,
              (object["type"] as? String) == "system",
              (object["subtype"] as? String) == "init" else { return nil }
        let raw = object["capabilities"] as? [Any] ?? []
        return Set(raw.compactMap { $0 as? String }.filter { !$0.isEmpty })
    }

    /// Cancel the grace kill only for a successful receipt matching the pending interrupt.
    /// After a successful interrupt stdin write, schedule the grace kill only if
    /// this request is still pending and still owns the pre-installed work item.
    nonisolated static func shouldScheduleInterruptGraceKill(
        pendingRequestId: String?,
        scheduledRequestId: String,
        killWorkStillInstalled: Bool
    ) -> Bool {
        pendingRequestId == scheduledRequestId && killWorkStillInstalled
    }

        nonisolated static func shouldCancelInterruptGraceKill(
        pendingRequestId: String?,
        receiptRequestId: String?,
        receiptSuccess: Bool
    ) -> Bool {
        guard receiptSuccess,
              let pending = pendingRequestId, !pending.isEmpty,
              let receipt = receiptRequestId, receipt == pending else { return false }
        return true
    }

    /// Whether a grace-kill work item that has already begun still owns the
    /// interrupted run. False when a matching interrupt receipt cleared ownership
    /// (pending id / installed work item) before the body reached this check,
    /// or when the in-flight run is no longer the interrupted one (emitTerminal
    /// released it and a later sendTurn started a new turn on the warm session).
    nonisolated static func shouldExecuteInterruptGraceKill(
        sessionStillCurrent: Bool,
        inFlightRunId: AgentRunID?,
        ownedRunId: AgentRunID?,
        pendingRequestId: String?,
        scheduledRequestId: String,
        installedWorkItemIsSelf: Bool
    ) -> Bool {
        sessionStillCurrent
            && inFlightRunId != nil
            && inFlightRunId == ownedRunId
            && pendingRequestId == scheduledRequestId
            && installedWorkItemIsSelf
    }

    /// Remove `sessions[threadId]` only for the exact Session that still owns
    /// the interrupt, under the same lock as the ownership check. Re-resolving
    /// by threadId after unlock (`stopSession`) would terminate a later sendTurn
    /// that replaced the map entry between check and remove.
    nonisolated static func shouldRemoveSessionOnInterruptGraceKill(
        stillOwnsInterrupt: Bool,
        mappedSessionIsExact: Bool
    ) -> Bool {
        stillOwnsInterrupt && mappedSessionIsExact
    }

    /// CLAUDE-INT-002: interrupt_receipt_v1 answers with control_response before
    /// the aborted result. Drop the grace process-stop when the receipt matches.
    private func applyInterruptReceipt(
        _ receipt: ClaudeControlResponseReceipt,
        session: Session
    ) {
        lock.lock()
        let pending = session.pendingInterruptRequestId
        let shouldCancel = Self.shouldCancelInterruptGraceKill(
            pendingRequestId: pending,
            receiptRequestId: receipt.requestId,
            receiptSuccess: receipt.success
        )
        if shouldCancel {
            session.interruptKillWorkItem?.cancel()
            session.interruptKillWorkItem = nil
            session.pendingInterruptRequestId = nil
        }
        lock.unlock()
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingRequestIds.contains(requestId) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude streaming request not found: \(requestId)")
        }
        let permissionMeta = session.pendingPermissionMeta[requestId]
        lock.unlock()

        try sendPermissionResponse(
            requestId: requestId,
            response: response,
            permissionMeta: permissionMeta,
            to: session
        )
        lock.lock()
        session.pendingRequestIds.remove(requestId)
        session.pendingPermissionMeta.removeValue(forKey: requestId)
        lock.unlock()
        let resolved = AssistantEvent.requestResolved(requestId: requestId, state: Self.requestState(for: response))
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingUserInputIds.contains(requestId) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude streaming user input request not found: \(requestId)")
        }
        let controlKind = session.pendingControlUserInputs[requestId]
        lock.unlock()

        if let controlKind {
            // CLAUDE-CLI-004 / 005: control-channel AskUserQuestion + elicitation
            // must complete via control_response, not a freeform user prompt.
            let line = try Self.controlUserInputResponseLine(
                requestId: requestId,
                kind: controlKind,
                text: text,
                decision: .accept
            )
            try session.writeQueue.sync {
                try GuardedStdinWrite.write(
                    line,
                    to: session.stdinPipe.fileHandleForWriting,
                    process: session.process,
                    notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) }
                )
            }
        } else {
            // tool_use → userInput corpus path: host writes a user JSONL line.
            try sendPrompt(text, to: session)
        }
        lock.lock()
        session.pendingUserInputIds.remove(requestId)
        session.pendingControlUserInputs.removeValue(forKey: requestId)
        lock.unlock()
        let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: text)
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingUserInputIds.contains(requestId) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude streaming user input request not found: \(requestId)")
        }
        let controlKind = session.pendingControlUserInputs[requestId]
        lock.unlock()

        if let controlKind {
            // CLAUDE-CLI-004 / 005: deny / decline the control request itself.
            let line = try Self.controlUserInputResponseLine(
                requestId: requestId,
                kind: controlKind,
                text: nil,
                decision: .cancel
            )
            try session.writeQueue.sync {
                try GuardedStdinWrite.write(
                    line,
                    to: session.stdinPipe.fileHandleForWriting,
                    process: session.process,
                    notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) }
                )
            }
        } else {
            // tool_use path: interrupt the turn (legacy corpus behavior).
            lock.lock()
            let cancelQueued = session.cliCapabilities.contains("interrupt_cancel_queued_v1")
            lock.unlock()
            let line = Self.controlInterruptLine(cancelQueued: cancelQueued)
            try session.writeQueue.sync {
                try GuardedStdinWrite.write(
                    line,
                    to: session.stdinPipe.fileHandleForWriting,
                    process: session.process,
                    notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) }
                )
            }
        }
        lock.lock()
        session.pendingUserInputIds.remove(requestId)
        session.pendingControlUserInputs.removeValue(forKey: requestId)
        lock.unlock()
        let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: nil)
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        let session = sessions.removeValue(forKey: threadId)
        session?.cancellationRequested = true
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        terminate(session: session, status: .cancelled)
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Claude streaming recovery requires providerThreadId")
        }
        lock.lock()
        if let existing = sessions[request.threadId] {
            existing.providerThreadId = request.providerThreadId
            existing.onEvent = onEvent
            existing.environment = request.environment
            lock.unlock()
            seedTranscriptOutsideLock(session: existing)
            return
        }
        lock.unlock()

        let session = try sessionFor(request: request)
        lock.lock()
        session.providerThreadId = request.providerThreadId
        session.status = .completed
        session.onEvent = onEvent
        session.environment = request.environment
        lock.unlock()
        seedTranscriptOutsideLock(session: session)
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.map {
            AgentProviderSessionSummary(threadId: $0.threadId, provider: .claude, status: $0.status, providerThreadId: $0.providerThreadId)
        }
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        lock.lock()
        let session = sessions[threadId]
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        seedTranscriptOutsideLock(session: session)
        lock.lock(); defer { lock.unlock() }
        // F8: the internal buffer may transiently hold up to cap+slack events
        // (hysteresis prune); the public readable bound stays maxReadableEvents.
        return Array(session.events.suffix(maxReadableEvents))
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard let index = session.events.lastIndex(where: { Self.completedTurnId($0) == toTurnId || Self.startedTurnId($0) == toTurnId }) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("The rollback target was not found in the current session history. The session may have been reset or the checkpoint is no longer available.")
        }
        session.events = Array(session.events.prefix(through: index))
        session.completedTurnIds = session.events.compactMap(Self.completedTurnId)
        session.activeTurnId = nil
        session.inFlightToolIds.removeAll()
        lock.unlock()
        emitSessionSnapshot(session: session, reason: "thread_rolled_back")
    }

    public func stopAll() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        active.forEach { terminate(session: $0, status: .cancelled) }
    }

    public func stopAllForAppTermination() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        active.forEach { terminateImmediatelyForAppTermination(session: $0) }
    }

    public func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        session.onEvent = onEvent
        lock.unlock()
    }

    private func sessionFor(request: AgentRunRequest) throws -> Session {
        lock.lock()
        if let existing = sessions[request.threadId] {
            if Self.canReuse(existing, for: request) {
                lock.unlock()
                return existing
            }
            if existing.inFlightRunId != nil {
                lock.unlock()
                throw AgentProviderAdapterError.unsupported("Claude streaming runtime switch while a turn is in-flight")
            }
            let providerThreadId = request.providerThreadId ?? existing.providerThreadId
            guard let providerThreadId, !providerThreadId.isEmpty else {
                lock.unlock()
                throw AgentProviderAdapterError.unsupported("Claude streaming runtime switch requires providerThreadId")
            }
            sessions.removeValue(forKey: request.threadId)
            lock.unlock()
            terminate(session: existing, status: .cancelled)
            return try startNewSession(request: request.withProviderThreadId(providerThreadId))
        }
        lock.unlock()
        return try startNewSession(request: request)
    }

    private func startNewSession(request: AgentRunRequest) throws -> Session {
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? request.providerBinary! : (binaryNameOverride ?? "claude")
        // Same resolution as Auto admission: absolute Settings path, then the
        // selected run-as-user home, then the app owner. Must match
        // ProcessLocator.resolveForRunAsUser so Auto does not admit a path
        // the spawn cannot find (or refuse a path spawn would use).
        guard let path = ProcessLocator.resolveForRunAsUser(binary, runAsUser: request.runAsUser) else {
            throw ClaudeCLIUnavailableError(message: ClaudeRunner.missingBinaryMessage(binary))
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        // Route through the shared helper when a different macOS user is selected so the
        // provider reads that user's ~/.claude (their logged-in account + MCP).
        let thinkingEnvironment = ClaudeRunner.thinkingEnvironment(request.environment)
        let baseEnv = CodexRunner.processEnvironment(overrides: thinkingEnvironment, purpose: .agentTurn(.claude))
        let isForeignUser = (request.runAsUser.map { $0.uid != getuid() } == true)
        // Clear Claude's stale negative MCP-auth cache so this headless session
        // re-probes remote OAuth MCP servers (Linear, etc.) live — terminal
        // parity. Same-user only, fail-open. See ClaudeMCPAuthCacheReset.
        ClaudeMCPAuthCacheReset.resetAndLog(
            home: baseEnv["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            isForeignUser: isForeignUser,
            environment: baseEnv
        )
        let foreignUserUID: uid_t? = isForeignUser ? request.runAsUser!.uid : nil
        let askpass = isForeignUser
            ? RunAsUserProcessBootstrap.materializeAskpass(targetUser: request.runAsUser!.shortName)
            : nil
        let process = try ProviderSubprocessLauncher.makeProcess(
            provider: .claude,
            executablePath: path,
            arguments: ClaudeRunner.buildStreamingArgs(request),
            currentDirectory: request.cwd,
            environment: thinkingEnvironment,
            runAsUser: request.runAsUser,
            askpassPath: askpass
        )
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let session = Session(threadId: request.threadId,
                              process: process,
                              stdinPipe: stdinPipe,
                              stdoutPipe: stdoutPipe,
                              stderrPipe: stderrPipe,
                              model: request.model,
                              permissionMode: request.permissionMode,
                              reasoningEffort: request.reasoningEffort,
                              interactionMode: request.interactionMode,
                              foreignUserUID: foreignUserUID)
        session.environment = thinkingEnvironment
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
            session.stdoutReadLock.lock()
            defer { session.stdoutReadLock.unlock() }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in session.lineBuffer.take(data) {
                self.handleLine(line, session: session)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.handleStderr(data, session: session)
        }
        process.terminationHandler = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.finishTerminated(session)
        }

        do {
            try process.run()
            // A run-as-user launch spawns a helper child whose kernel
            // metadata this non-root app cannot read; tag it owner-anchored so
            // the spawn is not rejected by an unreadable child identity.
            try ProcessSpawnTagger.tagProcess(process, provider: .claude, foreignUserLaunch: foreignUserUID != nil)
        } catch {
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }

        lock.lock()
        sessions[request.threadId] = session
        lock.unlock()
        return session
    }

    private static func canReuse(_ session: Session, for request: AgentRunRequest) -> Bool {
        session.model == request.model
            && session.permissionMode == request.permissionMode
            && session.reasoningEffort == request.reasoningEffort
            && session.interactionMode == request.interactionMode
    }

    private func sendPrompt(_ text: String, to session: Session, attachments: [AgentAttachment] = []) throws {
        let payload = try Self.userPromptPayload(text: text, attachments: attachments)
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)
        // Census observes outbound provider-bound bytes without mutation (AC-01).
        let binding = TokenSaverCensusSeam.defaultBinding(
            trigger: "provider_outbound_user",
            provider: "claude",
            providerAdapterVersion: "cli-stream-json",
            toolShape: "user_json_line"
        )
        let sameUser = session.foreignUserUID == nil
        let toWrite = TokenSaverCensusSeam.observeProviderVisiblePayload(
            line,
            binding: binding,
            control: .noChange,
            streamKind: .completedTranscript,
            toolKind: .unknown,
            isSameUser: sameUser
        )
        try session.writeQueue.sync {
            try GuardedStdinWrite.write(toWrite,
                                        to: session.stdinPipe.fileHandleForWriting,
                                        process: session.process,
                                        notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) })
        }
    }

    private func handleLine(_ line: String, session: Session) {
        // Token Saver census (task-03): shadow-only observation of provider-visible
        // stream lines. Must not alter the line passed to the parser.
        if let lineData = line.data(using: .utf8) {
            let binding = TokenSaverCensusSeam.defaultBinding(
                trigger: "provider_stream_line",
                provider: "claude",
                providerAdapterVersion: "cli-stream-json",
                toolShape: "stream_json_line"
            )
            // Discard return: seam is identity; parser continues on original `line`.
            let sameUser = session.foreignUserUID == nil
            _ = TokenSaverCensusSeam.observeProviderVisiblePayload(
                lineData,
                binding: binding,
                control: .noChange,
                streamKind: .streaming,
                toolKind: .unknown,
                isSameUser: sameUser
            )
        }
        // F12: decode the line once and reuse the dict for uuid, runtime,
        // background tracking, and ClaudeParser.parseObject. parseLine used
        // to JSONSerialization the same bytes again at token rate.
        let interpretation = Self.interpretStreamJSONLine(line, parser: session.parser)
        let rawObject = interpretation.object
        if let assistantUuid = Self.assistantUuid(from: rawObject) {
            lock.lock()
            session.lastAssistantUuid = assistantUuid
            lock.unlock()
        }
        var armedPostIdleFlush = false
        var isBackgroundLifecycle = false
        if let rawObject {
            if let caps = Self.initCapabilities(from: rawObject) {
                lock.lock()
                session.cliCapabilities = caps
                lock.unlock()
            }
            if let receipt = ClaudeParser.controlResponseReceipt(from: rawObject) {
                applyInterruptReceipt(receipt, session: session)
            }
            // CLAUDE-BG-LIFECYCLE: keep the pending-background-work view current
            // BEFORE the parser's turn events are processed below, so a `result`
            // in this same batch is judged against the up-to-date set.
            armedPostIdleFlush = trackBackgroundWork(in: rawObject, session: session)
            isBackgroundLifecycle = Self.isBackgroundLifecycleLine(rawObject)
            // CLAUDE-AMBIENT-TASK-RESULT: remember ambient-only results so a
            // subsequent process exit can re-drive the user prompt once.
            noteAmbientOrForegroundProgress(in: rawObject, session: session)
        }
        // Re-arm deferred-finish inactivity only on real progress (bg lifecycle
        // or model/tool content). Generic system/status heartbeats must NOT
        // re-arm — that was the 97m "Working forever" class when sticky pending
        // tasks paired with periodic keepalives (absolute max used to bound it).
        // Do not clobber a post-idle short flush trackBackgroundWork just armed.
        if !armedPostIdleFlush {
            let isProgress = isBackgroundLifecycle
                || Self.isDeferralProgressLine(rawObject)
            if isProgress {
                refreshDeferralWatchdog(session: session)
            }
        }
        if let runtimeEvent = interpretation.runtimeEvent {
            emit(.event(.providerRuntime(runtimeEvent)), session: session)
        }
        let rawParsed = interpretation.parsedEvents
        // New-turn reset MUST run before shell-detach observation: the first
        // assistant line of a turn often carries both turnStarted and a Bash
        // tool_use. Resetting after tracking would wipe the detach signal.
        for event in rawParsed {
            if case .turnStarted = event {
                lock.lock()
                session.sawDetachedShellSpawn = false
                lock.unlock()
            }
        }
        if let rawObject {
            // Shell-detach signal (CLI-unowned workers): observe foreground Bash
            // tool_use commands that background children so the turn-end path can
            // stamp [[RC_AWAITING]] without deferring the terminal.
            trackDetachedShellSpawn(in: rawObject, session: session)
            // Capture control-channel meta (AskUserQuestion / elicitation /
            // permission_suggestions) before events are applied so respond paths
            // know which wire shape to write.
            trackControlChannelMeta(in: rawObject, session: session)
        }
        // Rewrite turnCompleted finalMessage BEFORE record/emit/concludeTurn so
        // both the persisted stream event (UI reload source) and the coordinator
        // nudge path see the same marked text.
        let parsed = applyingDetachedShellAwaitingMarkerIfNeeded(
            to: rawParsed,
            session: session
        )
        for event in parsed {
            record(event, session: session)
            emit(.event(event), session: session)
            if case .error(_, let recoverable) = event, !recoverable {
                lock.lock()
                if !session.cancellationRequested {
                    session.sawError = true
                }
                lock.unlock()
            }
            if case .threadStarted(_, let providerThreadId) = event {
                lock.lock()
                session.providerThreadId = providerThreadId
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "thread_started")
            }
            if case .turnStarted(let turnId) = event {
                lock.lock()
                session.activeTurnId = turnId
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "turn_started")
            }
            if case .itemStarted(let item) = event, item.type == .tool {
                lock.lock()
                session.inFlightToolIds.insert(item.id)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "tool_started")
            }
            if case .itemCompleted(let itemId, _) = event {
                lock.lock()
                session.inFlightToolIds.remove(itemId)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "tool_completed")
            }
            if case .userInputRequested(let request) = event {
                lock.lock()
                session.pendingUserInputIds.insert(request.id)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "user_input_requested")
            }
            if case .userInputResolved(let requestId, _) = event {
                lock.lock()
                session.pendingUserInputIds.remove(requestId)
                session.pendingControlUserInputs.removeValue(forKey: requestId)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "user_input_resolved")
            }
            if case .requestOpened(let request) = event {
                lock.lock()
                session.pendingRequestIds.insert(request.id)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "request_opened")
            }
            if case .requestResolved(let requestId, _) = event {
                lock.lock()
                session.pendingRequestIds.remove(requestId)
                session.pendingPermissionMeta.removeValue(forKey: requestId)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "request_resolved")
            }
            // CLAUDE-CLI-007: after ExitPlanMode → proposedPlan, interrupt so the
            // host owns Implement and the CLI cannot race into workspace mutation
            // in the same stream turn (mirrors SDK bridge awaitingPlanReviewInterrupt).
            // Only plan-mode sessions — non-plan ExitPlanMode must not get an interrupt.
            if case .proposedPlan = event {
                lock.lock()
                let isPlanSession = session.interactionMode == .plan
                let cancelQueued = session.cliCapabilities.contains("interrupt_cancel_queued_v1")
                lock.unlock()
                if isPlanSession {
                    let line = Self.controlInterruptLine(cancelQueued: cancelQueued)
                    _ = session.writeQueue.sync {
                        try? GuardedStdinWrite.write(
                            line,
                            to: session.stdinPipe.fileHandleForWriting,
                            process: session.process,
                            notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) }
                        )
                    }
                }
            }
            if case .turnCompleted(_, let finalMessage) = event {
                if case .turnCompleted(let turnId, _) = event {
                    lock.lock()
                    if !session.completedTurnIds.contains(turnId) {
                        session.completedTurnIds.append(turnId)
                    }
                    session.activeTurnId = nil
                    session.inFlightToolIds.removeAll()
                    // A real turnCompleted is never ambient (parser skips those).
                    session.sawForegroundTurnProgress = true
                    lock.unlock()
                    emitSessionSnapshot(session: session, reason: "turn_completed")
                }
                concludeTurn(finalMessage: finalMessage, session: session, allowDeferral: true)
            }
        }
    }

    /// Tracks whether the stream produced only ambient task-notification results
    /// or real foreground turn progress. Pure session mutation under `lock`.
    private func noteAmbientOrForegroundProgress(in obj: [String: Any], session: Session) {
        let type = obj["type"] as? String
        if type == "assistant" {
            lock.lock()
            session.sawForegroundTurnProgress = true
            lock.unlock()
            return
        }
        guard type == "result" else { return }
        let isError = (obj["is_error"] as? Bool) ?? ((obj["subtype"] as? String).map { $0 != "success" } ?? false)
        let resultText = obj["result"] as? String
        if !isError,
           ClaudeParser.isAmbientTaskNotificationResult(obj, resultText: resultText, hasAssistantBody: false) {
            lock.lock()
            session.ambientTaskNotificationResultSeen = true
            lock.unlock()
            return
        }
        // Non-ambient result (including errors) is real turn ownership.
        lock.lock()
        session.sawForegroundTurnProgress = true
        lock.unlock()
    }

    /// CLAUDE-BG-LIFECYCLE — the fix for "thread reads as finished while a
    /// background task or subagent is still running".
    ///
    /// The CLI ends a *turn* (`result`) as soon as the model stops talking, even
    /// when it left a background shell or an async subagent running; it then
    /// finishes that work, RESUMES the agent by itself, and emits another
    /// `result`. Treating the first `result` as the run's terminal state (and
    /// tearing down `onEvent`) reported the thread as completed and discarded the
    /// real answer that arrives later. Mirrors the Codex adapter's
    /// defer-until-provider-idle contract, using `background_tasks_changed` as
    /// the idle signal instead of Codex's thread status.
    ///
    /// Withhold the terminal while work is pending; the LAST `result` — the one
    /// observed with an empty pending set — is the single `.finished`. Deferral is
    /// skipped for a cancelled/failed turn (those are terminal regardless) and
    /// when the process is gone (`allowDeferral: false`), so pending work can
    /// never be reported as `.completed`.
    ///
    /// The heuristic `[[RC_AWAITING]]` marker + auto-nudge stay in place as the
    /// fallback for routes without these events; they cannot double-drive this
    /// route because they require a `.completed` run, which a live deferral
    /// prevents by construction.
    private func concludeTurn(finalMessage: String?, session: Session, allowDeferral: Bool) {
        lock.lock()
        let status: AgentRunStatus = session.cancellationRequested ? .cancelled : (session.sawError ? .failed : .completed)
        session.status = status
        let providerThreadId = session.providerThreadId
        let pending = session.pendingBackgroundTaskIds
        let runId = session.inFlightRunId
        // Field 2026-08-06 (Elephant Task 1): model ended with [[RC_AWAITING]] +
        // "Done" while CLI still listed sticky local_bash (CI wait). Deferral
        // withheld `.finished`, so auto-nudge + Continue (both need `.completed`)
        // never ran — Working + Awaiting forever until quiet inactivity. The
        // marker is the agent's self-declared "nudge me" contract; do not block
        // that recovery path by also deferring.
        let selfDeclaredAwaiting = Self.finalMessageSelfDeclaresAwaiting(finalMessage)
        let shouldDefer = allowDeferral
            && status == .completed
            && !pending.isEmpty
            && !selfDeclaredAwaiting
        if shouldDefer {
            // Keep the earliest deferredAt if we re-arm on a later premature result.
            let deferredAt = session.deferredFinish?.deferredAt ?? Date()
            session.deferredFinish = DeferredFinish(
                status: status,
                finalMessage: finalMessage,
                providerThreadId: providerThreadId,
                runId: runId,
                deferredAt: deferredAt
            )
        } else {
            session.deferredFinish = nil
        }
        lock.unlock()

        if shouldDefer {
            claudeStreamLog.info("claude.turn.deferred pendingTasks=\(pending.count, privacy: .public)")
            // Deliberately keep `onEvent` and `inFlightRunId` alive: the CLI is
            // still streaming on this session and will resume on its own.
            emitSessionSnapshot(session: session, reason: "background_work_pending")
            refreshDeferralWatchdog(session: session)
            return
        }
        if selfDeclaredAwaiting && !pending.isEmpty {
            claudeStreamLog.info(
                "claude.turn.not_deferred self_declared_awaiting pendingTasks=\(pending.count, privacy: .public)"
            )
        }
        emitTerminal(status: status, finalMessage: finalMessage, providerThreadId: providerThreadId, session: session)
    }

    /// True when the final message carries the background-await protocol marker.
    private static func finalMessageSelfDeclaresAwaiting(_ finalMessage: String?) -> Bool {
        guard let text = finalMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return false }
        return text.range(
            of: BackgroundAwaitContinuation.awaitingMarker,
            options: .caseInsensitive
        ) != nil
    }

    /// Emits the run's single terminal pair and releases per-run session state.
    private func emitTerminal(
        status: AgentRunStatus,
        finalMessage: String?,
        providerThreadId: String?,
        session: Session
    ) {
        lock.lock()
        session.deferralWatchdog?.cancel()
        session.deferralWatchdog = nil
        session.deferredFinish = nil
        lock.unlock()
        emit(.status(status), session: session)
        emit(.finished(status, finalMessage: finalMessage, providerThreadId: providerThreadId), session: session)
        lock.lock()
        session.inFlightRunId = nil
        session.onEvent = nil
        session.sawError = false
        session.pendingRequestIds.removeAll()
        session.pendingUserInputIds.removeAll()
        session.pendingControlUserInputs.removeAll()
        session.pendingPermissionMeta.removeAll()
        session.pendingBackgroundTaskIds.removeAll()
        session.sawDetachedShellSpawn = false
        // The interrupted run completed without a control_response receipt.
        // Drop the grace-kill so a later sendTurn cannot inherit this timer.
        session.interruptKillWorkItem?.cancel()
        session.interruptKillWorkItem = nil
        session.pendingInterruptRequestId = nil
        lock.unlock()
    }

    /// Flushes a withheld finish for `session`, if one is still valid. Used by the
    /// liveness watchdog and before a new turn reuses the session.
    private func flushDeferredFinish(session: Session, reason: String) {
        lock.lock()
        guard let deferred = session.deferredFinish,
              deferred.runId == session.inFlightRunId else {
            session.deferredFinish = nil
            session.deferralWatchdog?.cancel()
            session.deferralWatchdog = nil
            lock.unlock()
            return
        }
        lock.unlock()
        claudeStreamLog.info("claude.turn.deferred.flushed reason=\(reason, privacy: .public)")
        emitTerminal(
            status: deferred.status,
            finalMessage: deferred.finalMessage,
            providerThreadId: deferred.providerThreadId,
            session: session
        )
    }

    /// (Re)arms the deferral inactivity bound. No-op unless a finish is withheld.
    /// Only real progress lines re-arm (see call site); pure status heartbeats
    /// do not. True quiet still flushes (no absolute wall-clock max).
    private func refreshDeferralWatchdog(
        session: Session,
        inactivityOverride: TimeInterval? = nil
    ) {
        lock.lock()
        guard session.deferredFinish != nil else {
            lock.unlock()
            return
        }
        session.deferralWatchdog?.cancel()
        let inactivity = inactivityOverride ?? deferredFinishInactivityTimeout
        let delay = max(0.01, inactivity)
        let item = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.flushDeferredFinish(session: session, reason: "watchdog_inactivity")
        }
        session.deferralWatchdog = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// CLI background-task lifecycle lines that prove nested work is still live.
    private static func isBackgroundLifecycleLine(_ obj: [String: Any]?) -> Bool {
        guard let obj,
              (obj["type"] as? String) == "system",
              let subtype = obj["subtype"] as? String else { return false }
        switch subtype {
        case "background_tasks_changed", "task_started", "task_updated", "task_notification":
            return true
        default:
            return false
        }
    }

    /// Model/tool content that should keep a deferred finish alive. Excludes
    /// generic system/status keepalives and empty noise.
    private static func isDeferralProgressLine(_ obj: [String: Any]?) -> Bool {
        guard let obj, let type = obj["type"] as? String else { return false }
        switch type {
        case "assistant", "user", "content_block_start", "content_block_delta",
             "content_block_stop", "tool_progress", "tool_result", "stream_event":
            return true
        case "system":
            // init / status / heartbeat are not progress.
            let subtype = obj["subtype"] as? String
            if subtype == "status" || subtype == "heartbeat" { return false }
            // Other system subtypes (except bg lifecycle, handled separately)
            // do not re-arm by themselves.
            return false
        case "result":
            // A later result may supersede; count as progress.
            return true
        default:
            return false
        }
    }

    /// Updates the pending-background-work set from one raw stream line.
    ///
    /// `background_tasks_changed.tasks` is an authoritative snapshot, so it
    /// REPLACES the set (never merges). `task_started` seeds the set defensively
    /// for the ordering race where a `result` could precede the first snapshot,
    /// and a `task_updated` patch carrying a terminal status removes that id.
    /// When the set becomes empty while a finish is withheld, arm a short
    /// post-idle wait for a resume `result` (then flush if none arrives).
    /// Returns true when that short flush was armed (caller must not overwrite).
    @discardableResult
    private func trackBackgroundWork(in obj: [String: Any], session: Session) -> Bool {
        guard (obj["type"] as? String) == "system",
              let subtype = obj["subtype"] as? String else { return false }
        var becameIdleWithDeferred = false
        switch subtype {
        case "background_tasks_changed":
            let ids = (obj["tasks"] as? [[String: Any]])?
                .compactMap { $0["task_id"] as? String } ?? []
            lock.lock()
            session.pendingBackgroundTaskIds = Set(ids)
            becameIdleWithDeferred = session.pendingBackgroundTaskIds.isEmpty
                && session.deferredFinish != nil
            lock.unlock()
        case "task_started":
            guard let id = obj["task_id"] as? String else { return false }
            lock.lock()
            session.pendingBackgroundTaskIds.insert(id)
            lock.unlock()
        case "task_updated", "task_notification":
            guard let id = obj["task_id"] as? String else { return false }
            let status = (obj["patch"] as? [String: Any])?["status"] as? String
                ?? obj["status"] as? String
            guard let status, ["completed", "failed", "killed", "cancelled"].contains(status) else {
                return false
            }
            lock.lock()
            session.pendingBackgroundTaskIds.remove(id)
            becameIdleWithDeferred = session.pendingBackgroundTaskIds.isEmpty
                && session.deferredFinish != nil
            lock.unlock()
        default:
            return false
        }
        if becameIdleWithDeferred {
            // Happy path: CLI often emits a resume turn next. If not, flush soon
            // so "Working" does not stick after background work is already idle.
            claudeStreamLog.info("claude.turn.deferred.pending_idle arming_post_idle_flush")
            refreshDeferralWatchdog(
                session: session,
                inactivityOverride: deferredFinishPostIdleTimeout
            )
            return true
        }
        return false
    }

    /// Observes raw `assistant` lines for foreground Bash tool_use commands that
    /// shell-detach work the CLI will not track (`task_started` / lifecycle).
    /// Skips `run_in_background: true` — that path is owned by CLAUDE-BG-LIFECYCLE.
    private func trackDetachedShellSpawn(in obj: [String: Any], session: Session) {
        guard (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        for block in content {
            guard (block["type"] as? String) == "tool_use",
                  (block["name"] as? String) == "Bash",
                  let input = block["input"] as? [String: Any],
                  let command = input["command"] as? String else { continue }
            // CLI-owned background Bash is already covered by pendingBackgroundTaskIds.
            if let flag = input["run_in_background"] as? Bool, flag { continue }
            if let flag = input["run_in_background"] as? NSNumber, flag.boolValue { continue }
            if Self.bashCommandDetachesShellWork(command) {
                lock.lock()
                session.sawDetachedShellSpawn = true
                lock.unlock()
                return
            }
        }
    }

    /// When a completed turn ends with shell-detached (CLI-unowned) work and no
    /// CLI-tracked pending tasks, prefix `[[RC_AWAITING]]` on the final message.
    /// Does not defer the finish — only CLI-tracked work may withhold the terminal.
    private func applyingDetachedShellAwaitingMarkerIfNeeded(
        to events: [AssistantEvent],
        session: Session
    ) -> [AssistantEvent] {
        lock.lock()
        // Mirror concludeTurn's completed gate: never stamp cancelled/failed.
        let wouldComplete = !session.cancellationRequested && !session.sawError
        let shouldMark = wouldComplete
            && session.sawDetachedShellSpawn
            && session.pendingBackgroundTaskIds.isEmpty
        lock.unlock()
        guard shouldMark else { return events }
        return events.map { event in
            guard case .turnCompleted(let turnId, let finalMessage) = event else { return event }
            return .turnCompleted(
                turnId: turnId,
                finalMessage: Self.prefixAwaitingMarkerIfNeeded(finalMessage)
            )
        }
    }

    /// Thin forwarder to the shared CoreModel implementation (one classifier for
    /// Claude / Codex / Grok). Kept so existing call sites and tests stay stable.
    private static func prefixAwaitingMarkerIfNeeded(_ finalMessage: String?) -> String? {
        BackgroundAwaitContinuation.prefixingAwaitingMarker(finalMessage)
    }

    /// Thin forwarder to `BackgroundAwaitContinuation.commandDetachesShellWork`.
    static func bashCommandDetachesShellWork(_ command: String) -> Bool {
        BackgroundAwaitContinuation.commandDetachesShellWork(command)
    }

    private func handleStderr(_ data: Data, session: Session) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let visible = ClaudeRunner.displayableStderr(raw) else { return }
        let event = AssistantEvent.providerRuntime(ProviderStderrClassifier.runtimeEvent(
            message: visible,
            provider: .claude,
            source: "claude.stream-json.stderr"
        ))
        record(event, session: session)
        emit(.event(event), session: session)
        emit(.error("[claude stderr] " + visible), session: session)
    }

    private func finishTerminated(_ session: Session) {
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain under the lock: an in-flight readabilityHandler callback may
        // still be reading/parsing — the lock keeps LineBuffer and ClaudeParser
        // access and fd read order serialized so no final line is split or raced.
        session.stdoutReadLock.lock()
        let tail = BoundedPipeDrain.readRemaining(
            from: session.stdoutPipe.fileHandleForReading,
            maxBytes: BoundedPipeDrain.defaultStdoutMaxBytes
        )
        for line in session.lineBuffer.take(tail) + session.lineBuffer.flush() {
            handleLine(line, session: session)
        }
        session.stdoutReadLock.unlock()
        for event in session.parser.finalize() {
            handleFinalizedEvent(event, session: session)
        }

        lock.lock()
        if sessions[session.threadId] === session {
            sessions.removeValue(forKey: session.threadId)
        }
        let shouldFinish = session.inFlightRunId != nil
        // CLAUDE-AMBIENT-TASK-RESULT: after resume the CLI may dump orphan
        // task_notifications, emit origin=task-notification result, and exit
        // without processing the user prompt. One bounded re-spawn+re-prompt
        // recovers the turn (Elephant Task 1: "Did you finish?" failed empty).
        let shouldRetryAmbient = shouldFinish
            && !session.cancellationRequested
            && session.ambientTaskNotificationResultSeen
            && !session.sawForegroundTurnProgress
            && !session.ambientResumeRetryUsed
        let retryOnEvent = shouldRetryAmbient ? session.onEvent : nil
        let retryRunId = shouldRetryAmbient ? session.inFlightRunId : nil
        let retryPrompt = shouldRetryAmbient ? session.lastInFlightPrompt : nil
        let retrySpawnRequest = shouldRetryAmbient ? session.lastSpawnRequest : nil
        let retryProviderThreadId = session.providerThreadId
        let canRetryAmbient = retryOnEvent != nil
            && retryRunId != nil
            && !(retryPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && retrySpawnRequest != nil
        if canRetryAmbient,
           let onEvent = retryOnEvent,
           let runId = retryRunId,
           let prompt = retryPrompt,
           var spawnRequest = retrySpawnRequest {
            // Detach dead session ownership before spawning a replacement.
            session.deferredFinish = nil
            session.deferralWatchdog?.cancel()
            session.deferralWatchdog = nil
            session.pendingBackgroundTaskIds.removeAll()
            session.inFlightRunId = nil
            session.onEvent = nil
            lock.unlock()

            // Prefer the live resume id from the dead session.
            if let providerThreadId = retryProviderThreadId, !providerThreadId.isEmpty {
                spawnRequest = spawnRequest.withProviderThreadId(providerThreadId)
            }
            do {
                let newSession = try startNewSession(request: spawnRequest)
                lock.lock()
                newSession.onEvent = onEvent
                newSession.inFlightRunId = runId
                newSession.sawError = false
                newSession.status = .running
                newSession.cancellationRequested = false
                newSession.lastInFlightPrompt = prompt
                newSession.lastSpawnRequest = spawnRequest
                newSession.ambientTaskNotificationResultSeen = false
                newSession.ambientResumeRetryUsed = true
                newSession.sawForegroundTurnProgress = false
                if let providerThreadId = retryProviderThreadId {
                    newSession.providerThreadId = providerThreadId
                }
                lock.unlock()
                claudeStreamLog.info(
                    "claude.ambient_task_result.retry thread=\(session.threadId.value.uuidString, privacy: .public)"
                )
                // Non-fatal diagnostic so the stream shows why the CLI respawned.
                onEvent(.event(.providerRuntime(ProviderRuntimeEvent(
                    provider: .claude,
                    source: "claude.stream-json.session",
                    method: "claude.session.ambient_task_retry",
                    payloadJSON: Self.jsonString([
                        "reason": "ambient_task_notification_result",
                        "providerThreadId": retryProviderThreadId ?? ""
                    ]) ?? "{}",
                    receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
                ))))
                try sendPrompt(prompt, to: newSession, attachments: spawnRequest.attachments)
                onEvent(.status(.running))
                return
            } catch {
                onEvent(.error("Claude ambient task-notification retry failed: \(error)"))
                onEvent(.status(.failed))
                onEvent(.finished(.failed, finalMessage: nil, providerThreadId: retryProviderThreadId))
                return
            }
        }

        session.inFlightRunId = nil
        // CLAUDE-BG-LIFECYCLE: the process is gone, so a withheld finish can never
        // be resumed. Drop it — the terminal below reports cancelled/failed, never
        // `.completed`, so unresolved background work is never called done.
        session.deferredFinish = nil
        session.deferralWatchdog?.cancel()
        session.deferralWatchdog = nil
        session.pendingBackgroundTaskIds.removeAll()
        let status: AgentRunStatus = session.cancellationRequested ? .cancelled : .failed
        session.status = status
        let onEvent = session.onEvent
        let providerThreadId = session.providerThreadId
        session.onEvent = nil
        lock.unlock()
        if shouldFinish {
            if !session.cancellationRequested {
                let diagnostic: String
                if session.process.terminationReason == .uncaughtSignal {
                    diagnostic = "Claude CLI crashed with signal \(session.process.terminationStatus)."
                } else {
                    diagnostic = "Claude CLI exited with status \(session.process.terminationStatus)."
                }
                onEvent?(.error(diagnostic))
            }
            onEvent?(.status(status))
            onEvent?(.finished(status, finalMessage: nil, providerThreadId: providerThreadId))
        }
    }

    private func handleFinalizedEvent(_ event: AssistantEvent, session: Session) {
        // Same marker rewrite as handleLine so a turnCompleted that only surfaces
        // on finalize still carries [[RC_AWAITING]] for both record and concludeTurn.
        let rewritten = applyingDetachedShellAwaitingMarkerIfNeeded(to: [event], session: session)[0]
        record(rewritten, session: session)
        emit(.event(rewritten), session: session)
        guard case .turnCompleted(let turnId, let finalMessage) = rewritten else { return }

        lock.lock()
        if !session.completedTurnIds.contains(turnId) {
            session.completedTurnIds.append(turnId)
        }
        session.activeTurnId = nil
        session.inFlightToolIds.removeAll()
        lock.unlock()
        emitSessionSnapshot(session: session, reason: "turn_completed")

        // Reached only while finalizing a dead/closing stream: the CLI can no
        // longer resume, so this turn is terminal and must not be deferred.
        // Marker may still apply for a genuine `.completed` path; never for
        // cancelled/failed (gated inside applyingDetachedShellAwaitingMarkerIfNeeded).
        concludeTurn(finalMessage: finalMessage, session: session, allowDeferral: false)
    }

    private func terminate(session: Session, status: AgentRunStatus) {
        lock.lock()
        session.status = status
        if status == .cancelled { session.cancellationRequested = true }
        lock.unlock()
        settlePendingRequests(session)
        settlePendingUserInputs(session)
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if session.process.isRunning {
            ProcessTerminator.terminateTree(session.process, foreignUserUID: session.foreignUserUID)
        }
    }

    private func terminateImmediatelyForAppTermination(session: Session) {
        lock.lock()
        session.status = .cancelled
        session.cancellationRequested = true
        lock.unlock()
        settlePendingRequests(session)
        settlePendingUserInputs(session)
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if session.process.isRunning {
            ProcessTerminator.terminateTreeImmediately(session.process, foreignUserUID: session.foreignUserUID)
        }
    }

    /// Builds the newline-terminated CLI control_response for a tool approval.
    /// Pure builder — no I/O. Agent SDK PermissionResult wire:
    /// allow → behavior "allow"; deny/cancel → behavior "deny" + message.
    /// CLAUDE-CLI-006: approveForSession includes `updatedPermissions` (echo
    /// suggestions when present, else synthesize addRules for tool_name → session).
    nonisolated static func controlPermissionResponseLine(
        requestId: String,
        response: AgentProviderRequestResponse,
        toolName: String? = nil,
        permissionSuggestionsJSON: String? = nil,
        updatedInput: [String: Any]? = nil
    ) throws -> Data {
        let behavior: String
        let denyMessage: String?
        var includeSessionPermissions = false
        switch response {
        case .approve:
            behavior = "allow"
            denyMessage = nil
        case .approveForSession:
            behavior = "allow"
            denyMessage = nil
            includeSessionPermissions = true
        case .decline(let reason):
            behavior = "deny"
            denyMessage = (reason?.isEmpty == false) ? reason : "Permission denied"
        case .cancel:
            behavior = "deny"
            denyMessage = "Cancelled"
        }
        var permissionResult: [String: Any] = ["behavior": behavior]
        if let denyMessage {
            permissionResult["message"] = denyMessage
        }
        // CLAUDE-CLI-017: bridge always echoes pending.input as updatedInput on allow.
        if behavior == "allow" {
            permissionResult["updatedInput"] = updatedInput ?? [String: Any]()
        }
        if includeSessionPermissions {
            if let updated = Self.updatedPermissionsForSessionAllow(
                toolName: toolName,
                permissionSuggestionsJSON: permissionSuggestionsJSON
            ) {
                permissionResult["updatedPermissions"] = updated
            }
        }
        let payload: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestId,
                "response": permissionResult
            ] as [String: Any]
        ]
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        return line
    }

    /// PermissionUpdate[] for session-wide allow. Prefers CLI permission_suggestions;
    /// otherwise synthesizes addRules for the tool with destination session.
    nonisolated static func updatedPermissionsForSessionAllow(
        toolName: String?,
        permissionSuggestionsJSON: String?
    ) -> [[String: Any]]? {
        if let permissionSuggestionsJSON,
           let data = permissionSuggestionsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !parsed.isEmpty {
            return parsed
        }
        let name = (toolName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Tool"
        // Agent SDK PermissionUpdate addRules shape (destination: session).
        return [[
            "type": "addRules",
            "rules": [["toolName": name] as [String: Any]],
            "behavior": "allow",
            "destination": "session"
        ]]
    }

    /// Decision for control-channel user-input replies.
    enum ControlUserInputDecision: Sendable, Equatable {
        case accept
        case cancel
        case decline
    }

    /// Pure builder: control_response for AskUserQuestion (PermissionResult + answers)
    /// or elicitation (action accept/decline/cancel + content). Newline-terminated.
    nonisolated static func controlUserInputResponseLine(
        requestId: String,
        kind: ClaudeControlUserInputKind,
        text: String?,
        decision: ControlUserInputDecision
    ) throws -> Data {
        let body: [String: Any]
        switch kind {
        case .askUserQuestion(let toolUseID):
            switch decision {
            case .accept:
                body = Self.askUserQuestionPermissionResult(
                    requestId: requestId,
                    toolUseID: toolUseID,
                    text: text ?? ""
                )
            case .cancel, .decline:
                body = [
                    "behavior": "deny",
                    "message": decision == .cancel ? "Cancelled" : "Declined",
                    "toolUseID": toolUseID ?? requestId
                ]
            }
        case .elicitation:
            switch decision {
            case .accept:
                body = [
                    "action": "accept",
                    "content": Self.elicitationContent(from: text ?? "")
                ]
            case .cancel:
                body = ["action": "cancel"]
            case .decline:
                body = ["action": "decline"]
            }
        case .userDialog(let dialogKind):
            // CLAUDE-CLI-016: opaque dialog result Record; prefer parsed JSON.
            switch decision {
            case .accept:
                var result = Self.elicitationContent(from: text ?? "")
                if result["dialog_kind"] == nil {
                    result["dialog_kind"] = dialogKind
                }
                body = result
            case .cancel, .decline:
                body = [
                    "cancelled": true,
                    "dialog_kind": dialogKind
                ]
            }
        }
        let payload: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestId,
                "response": body
            ] as [String: Any]
        ]
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        return line
    }

    /// Mirrors bridge `askUserQuestionResult`: allow + updatedInput.answers (or response).
    nonisolated static func askUserQuestionPermissionResult(
        requestId: String,
        toolUseID: String?,
        text: String
    ) -> [String: Any] {
        var updatedInput: [String: Any] = [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data),
           let object = parsed as? [String: Any] {
            updatedInput["answers"] = object
        } else if !trimmed.isEmpty {
            updatedInput["response"] = text
        } else {
            updatedInput["answers"] = [String: Any]()
        }
        return [
            "behavior": "allow",
            "updatedInput": updatedInput,
            "toolUseID": toolUseID ?? requestId
        ]
    }

    /// Mirrors bridge `elicitationContent`: JSON object if parseable, else `{answer: text}`.
    nonisolated static func elicitationContent(from text: String) -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return ["answer": text]
    }

    /// CLAUDE-CLI-017: decode captured tool input JSON for PermissionResult.updatedInput.
    nonisolated static func updatedInputObject(fromJSON json: String?) -> [String: Any] {
        guard let json,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return parsed
    }

    private func sendPermissionResponse(
        requestId: String,
        response: AgentProviderRequestResponse,
        permissionMeta: PendingPermissionMeta?,
        to session: Session
    ) throws {
        // CLI stream-json control channel (Agent SDK PermissionResult shape):
        // allow:  {"type":"control_response","response":{"subtype":"success","request_id":"…","response":{"behavior":"allow"}}}
        // deny:   same envelope with behavior "deny" + required message string
        // session: allow + updatedPermissions (suggestions or synthesized addRules)
        let updatedInput = Self.updatedInputObject(fromJSON: permissionMeta?.inputJSON)
        let line = try Self.controlPermissionResponseLine(
            requestId: requestId,
            response: response,
            toolName: permissionMeta?.toolName,
            permissionSuggestionsJSON: permissionMeta?.suggestionsJSON,
            updatedInput: updatedInput
        )
        try session.writeQueue.sync {
            try GuardedStdinWrite.write(line,
                                        to: session.stdinPipe.fileHandleForWriting,
                                        process: session.process,
                                        notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) })
        }
    }

    private func settlePendingRequests(_ session: Session) {
        lock.lock()
        let requestIds = Array(session.pendingRequestIds)
        session.pendingRequestIds.removeAll()
        session.pendingPermissionMeta.removeAll()
        lock.unlock()
        for requestId in requestIds {
            let resolved = AssistantEvent.requestResolved(requestId: requestId, state: .cancelled)
            record(resolved, session: session)
            emit(.event(resolved), session: session)
        }
        emitSessionSnapshot(session: session, reason: "requests_settled")
    }

    private func settlePendingUserInputs(_ session: Session) {
        lock.lock()
        let requestIds = Array(session.pendingUserInputIds)
        session.pendingUserInputIds.removeAll()
        session.pendingControlUserInputs.removeAll()
        lock.unlock()
        for requestId in requestIds {
            let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: nil)
            record(resolved, session: session)
            emit(.event(resolved), session: session)
        }
        emitSessionSnapshot(session: session, reason: "user_inputs_settled")
    }

    /// Capture control-channel ids + permission meta from the raw stream line so
    /// respond paths know which control_response body to write (parser only emits
    /// normalized AssistantEvents and cannot carry suggestions / kind tags).
    private func trackControlChannelMeta(in rawObject: [String: Any], session: Session) {
        let type = (rawObject["type"] as? String) ?? ""
        if type == "control_request",
           let request = rawObject["request"] as? [String: Any] {
            let requestId = (rawObject["request_id"] as? String)
                ?? (rawObject["requestId"] as? String)
            guard let requestId, !requestId.isEmpty else { return }
            let subtype = (request["subtype"] as? String) ?? ""
            if subtype == "can_use_tool" {
                let toolName = (request["tool_name"] as? String)
                    ?? (request["toolName"] as? String)
                    ?? (request["name"] as? String)
                    ?? "Claude tool"
                let toolUseID = (request["tool_use_id"] as? String)
                    ?? (request["toolUseId"] as? String)
                let normalized = String(toolName.lazy.filter { $0 != "_" && $0 != "-" }).lowercased()
                if normalized == "askuserquestion" || normalized == "askuser" {
                    lock.lock()
                    session.pendingControlUserInputs[requestId] = .askUserQuestion(toolUseID: toolUseID)
                    lock.unlock()
                } else {
                    var suggestionsJSON: String?
                    if let suggestions = request["permission_suggestions"] ?? request["permissionSuggestions"],
                       JSONSerialization.isValidJSONObject(suggestions),
                       let data = try? JSONSerialization.data(withJSONObject: suggestions),
                       let s = String(data: data, encoding: .utf8) {
                        suggestionsJSON = s
                    }
                    var inputJSON: String?
                    if let input = request["input"],
                       JSONSerialization.isValidJSONObject(input),
                       let data = try? JSONSerialization.data(withJSONObject: input),
                       let s = String(data: data, encoding: .utf8) {
                        inputJSON = s
                    }
                    lock.lock()
                    session.pendingPermissionMeta[requestId] = PendingPermissionMeta(
                        toolName: toolName,
                        suggestionsJSON: suggestionsJSON,
                        toolUseID: toolUseID,
                        inputJSON: inputJSON
                    )
                    lock.unlock()
                }
            } else if subtype == "elicitation" {
                lock.lock()
                session.pendingControlUserInputs[requestId] = .elicitation
                lock.unlock()
            } else if subtype == "request_user_dialog" {
                // CLAUDE-CLI-016: must answer with control_response, not freeform stdin.
                let kind = (request["dialog_kind"] as? String)
                    ?? (request["dialogKind"] as? String)
                    ?? "dialog"
                lock.lock()
                session.pendingControlUserInputs[requestId] = .userDialog(dialogKind: kind)
                lock.unlock()
            }
            return
        }
        if type == "control_cancel_request" {
            let requestId = (rawObject["request_id"] as? String)
                ?? (rawObject["requestId"] as? String)
            guard let requestId else { return }
            lock.lock()
            session.pendingControlUserInputs.removeValue(forKey: requestId)
            session.pendingPermissionMeta.removeValue(forKey: requestId)
            lock.unlock()
        }
    }

    private func emit(_ event: AgentRunEvent, session: Session) {
        lock.lock()
        let callback = session.onEvent
        lock.unlock()
        callback?(event)
    }

    private func record(_ event: AssistantEvent, session: Session) {
        lock.lock()
        if shouldAppend(event, session: session) {
            session.events.append(event)
            pruneReadableEvents(session)
        }
        lock.unlock()
    }

    /// Seeds in-memory transcript without holding `lock` across the recursive
    /// disk enumeration in `ClaudeTranscriptStore.readSession`. The disk read is
    /// the slow part (filesystem walk of ~/.claude/projects + file reads); doing
    /// it under the adapter lock stalled every pipe-readability callback and any
    /// other adapter API. Sequence:
    ///   1. snapshot the seed inputs under the lock, then release it,
    ///   2. perform the disk read with NO lock held,
    ///   3. re-take the lock only to merge the result, re-checking the guard so a
    ///      concurrent live turn that produced a readable turn meanwhile wins
    ///      (no double-seed / no clobbering live events).
    /// Callers MUST invoke this WITHOUT holding `lock`.
    private func seedTranscriptOutsideLock(session: Session) {
        lock.lock()
        let currentEvents = session.events
        let providerThreadId = session.providerThreadId
        let environment = session.environment
        lock.unlock()

        guard Self.shouldReadTranscript(currentEvents: currentEvents, providerThreadId: providerThreadId),
              let providerThreadId else {
            return
        }
        // Disk I/O performed with the lock released.
        let transcriptEvents = transcriptStore.readSession(providerThreadId: providerThreadId, environment: environment)

        lock.lock()
        // Re-check against the latest events under the lock so a concurrent
        // live turn cannot be clobbered by a stale transcript snapshot.
        if let merged = Self.transcriptSeedMerge(currentEvents: session.events,
                                                 transcriptEvents: transcriptEvents,
                                                 maxReadableEvents: maxReadableEvents) {
            session.events = merged
        }
        lock.unlock()
    }

    /// Pure pre-read guard: should we even hit disk for this session? Disk read
    /// is wasted when the session already has a readable turn or has no provider
    /// thread to read from. No I/O, no isolation. Extracted for unit testing.
    nonisolated static func shouldReadTranscript(currentEvents: [AssistantEvent], providerThreadId: String?) -> Bool {
        guard let providerThreadId, !providerThreadId.isEmpty else { return false }
        return !hasReadableTurn(currentEvents)
    }

    /// Pure merge step: given the latest in-memory events and the events read
    /// from the transcript, return the events to assign, or nil to skip. Skips
    /// when the session already has a readable turn (a live turn won the race)
    /// or the transcript is empty. No I/O, no isolation. Extracted for unit
    /// testing the concurrent-safe merge.
    nonisolated static func transcriptSeedMerge(currentEvents: [AssistantEvent],
                                                transcriptEvents: [AssistantEvent],
                                                maxReadableEvents: Int) -> [AssistantEvent]? {
        guard !hasReadableTurn(currentEvents), !transcriptEvents.isEmpty else { return nil }
        return Array(transcriptEvents.suffix(maxReadableEvents))
    }

    private static func hasReadableTurn(_ events: [AssistantEvent]) -> Bool {
        events.contains { event in
            switch event {
            case .turnCompleted:
                return true
            case .itemDelta(_, let bodyAppend, let outputAppend, _):
                return bodyAppend?.isEmpty == false || outputAppend?.isEmpty == false
            default:
                return false
            }
        }
    }

    private func shouldAppend(_ event: AssistantEvent, session: Session) -> Bool {
        guard case .turnStarted(let turnId) = event else { return true }
        return Self.startedTurnId(session.events.last) != turnId
    }

    private static func startedTurnId(_ event: AssistantEvent?) -> String? {
        guard let event, case .turnStarted(let turnId) = event else { return nil }
        return turnId
    }

    private static func completedTurnId(_ event: AssistantEvent?) -> String? {
        guard let event, case .turnCompleted(let turnId, _) = event else { return nil }
        return turnId
    }

    // F8: amortize the prune. Without slack, once `events` reaches the cap every
    // subsequent append re-allocated a fresh `maxReadableEvents`-element array (the
    // `suffix` copy) on the stdout-readability thread — O(cap) per event past the
    // cap. Letting the internal buffer grow by `readableEventPruneSlack` before
    // trimming amortizes that copy to O(1) per appended event. The public bound is
    // unchanged: `readThread`/`readableEvents` return `suffix(maxReadableEvents)`.
    static let readableEventPruneSlack = 1_024

    private func pruneReadableEvents(_ session: Session) {
        if let trimmed = Self.prunedReadableEvents(session.events,
                                                   cap: maxReadableEvents,
                                                   slack: Self.readableEventPruneSlack) {
            session.events = trimmed
        }
    }

    /// Pure prune decision (F8): returns the trimmed events when the buffer has grown
    /// past `cap + slack`, or nil to leave it untouched so the append stays O(1).
    /// Extracted for unit testing the amortization contract.
    nonisolated static func prunedReadableEvents(_ events: [AssistantEvent], cap: Int, slack: Int) -> [AssistantEvent]? {
        guard events.count > cap + slack else { return nil }
        return Array(events.suffix(cap))
    }

    private func emitSessionSnapshot(session: Session, reason: String) {
        lock.lock()
        // PERF-008 / F4: coalesce identical snapshots. The signature is derived
        // directly from the structured state (cheap delimited string) rather than
        // by building + JSON-encoding the whole payload dict; a tool-heavy turn
        // fires this per tool/request delta on the stdout-readability thread, and
        // the vast majority coalesce away. Only when the state actually changed do
        // we build the payload and pay the JSON encode for the broadcast.
        let signature = Self.snapshotStateSignature(session: session)
        if signature == session.lastSnapshotStateSignature {
            lock.unlock()
            return
        }
        session.lastSnapshotStateSignature = signature
        let payload = Self.sessionSnapshotPayload(session: session, reason: reason)
        let providerTurnId = session.activeTurnId ?? session.completedTurnIds.last
        lock.unlock()
        guard let payloadJSON = Self.jsonString(payload) else { return }
        let event = AssistantEvent.providerRuntime(ProviderRuntimeEvent(
            provider: .claude,
            source: "claude.stream-json.session",
            method: "claude.session.snapshot",
            providerTurnId: providerTurnId,
            payloadJSON: payloadJSON,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))
        emit(.event(event), session: session)
    }

    private static func sessionSnapshotPayload(session: Session, reason: String) -> [String: Any] {
        var payload: [String: Any] = [
            "reason": reason,
            "provider": "claude",
            "model": session.model,
            "turnCount": session.completedTurnIds.count,
            "pendingApprovalRequestIds": Array(session.pendingRequestIds).sorted(),
            "pendingUserInputRequestIds": Array(session.pendingUserInputIds).sorted(),
            "inFlightToolIds": Array(session.inFlightToolIds).sorted(),
            // CLAUDE-BG-LIFECYCLE: the CLI-owned background shells / async
            // subagents still running. This is the ONLY path by which the pending
            // set leaves the adapter, so it is what lets the UI show a live
            // "N shells" chip (mirroring the CLI's own `1 shell` indicator).
            "pendingBackgroundTaskIds": Array(session.pendingBackgroundTaskIds).sorted()
        ]
        if let providerThreadId = session.providerThreadId {
            payload["providerThreadId"] = providerThreadId
            payload["resume"] = providerThreadId
        }
        if let activeTurnId = session.activeTurnId {
            payload["activeTurnId"] = activeTurnId
        }
        if let lastCompletedTurnId = session.completedTurnIds.last {
            payload["lastCompletedTurnId"] = lastCompletedTurnId
        }
        if let lastAssistantUuid = session.lastAssistantUuid {
            payload["resumeSessionAt"] = lastAssistantUuid
            payload["lastAssistantUuid"] = lastAssistantUuid
        }
        return payload
    }

    private static func snapshotStateSignature(session: Session) -> String {
        snapshotStateSignature(
            model: session.model,
            turnCount: session.completedTurnIds.count,
            pendingRequestIds: session.pendingRequestIds,
            pendingUserInputIds: session.pendingUserInputIds,
            inFlightToolIds: session.inFlightToolIds,
            pendingBackgroundTaskIds: session.pendingBackgroundTaskIds,
            providerThreadId: session.providerThreadId,
            activeTurnId: session.activeTurnId,
            lastCompletedTurnId: session.completedTurnIds.last,
            lastAssistantUuid: session.lastAssistantUuid
        )
    }

    /// F4: a cheap, collision-free signature of the snapshot state used to coalesce
    /// identical snapshots without building or JSON-encoding the payload dict. Mirrors
    /// the broadcast-relevant fields of `sessionSnapshotPayload` (everything except the
    /// per-call `reason`); the id sets are sorted for set-order stability and joined
    /// with a unit separator that cannot appear in provider ids. Pure + nonisolated for
    /// unit testing. O(pending + inFlight), NOT O(turnCount).
    nonisolated static func snapshotStateSignature(
        model: String,
        turnCount: Int,
        pendingRequestIds: Set<String>,
        pendingUserInputIds: Set<String>,
        inFlightToolIds: Set<String>,
        // Defaulted so existing call sites (and the perf-helper tests) are
        // unaffected; the adapter always passes the live set.
        pendingBackgroundTaskIds: Set<String> = [],
        providerThreadId: String?,
        activeTurnId: String?,
        lastCompletedTurnId: String?,
        lastAssistantUuid: String?
    ) -> String {
        [
            model,
            String(turnCount),
            pendingRequestIds.sorted().joined(separator: ","),
            pendingUserInputIds.sorted().joined(separator: ","),
            inFlightToolIds.sorted().joined(separator: ","),
            // Load-bearing: without the pending set in the signature, a snapshot
            // whose ONLY change is background work is coalesced away — which is
            // why `background_work_pending` never once reached the DB.
            pendingBackgroundTaskIds.sorted().joined(separator: ","),
            providerThreadId ?? "",
            activeTurnId ?? "",
            lastCompletedTurnId ?? "",
            lastAssistantUuid ?? ""
        ].joined(separator: "\u{1F}")
    }

#if DEBUG
    static var streamJSONDecodeCountForTesting = 0
#endif

    static func jsonObject(from line: String) -> [String: Any]? {
#if DEBUG
        streamJSONDecodeCountForTesting += 1
#endif
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Decode once, then runtime + parser events. handleLine uses this so
    /// uuid / lifecycle / fromJSONObject / parseObject share one JSONSerialization.
    static func interpretStreamJSONLine(
        _ line: String,
        parser: ClaudeParser
    ) -> (
        object: [String: Any]?,
        runtimeEvent: ProviderRuntimeEvent?,
        parsedEvents: [AssistantEvent]
    ) {
        let object = jsonObject(from: line)
        return (
            object,
            object.flatMap {
                ProviderRuntimeEvent.fromJSONObjectIfNeeded($0, provider: .claude, source: "claude.stream-json")
            },
            object.map { parser.parseObject($0) } ?? []
        )
    }

    private static func assistantUuid(from object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let uuid = object["uuid"] as? String, !uuid.isEmpty { return uuid }
        if let message = object["message"] as? [String: Any] {
            if let uuid = message["uuid"] as? String, !uuid.isEmpty { return uuid }
            if let uuid = message["id"] as? String, !uuid.isEmpty { return uuid }
        }
        return nil
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func requestState(for response: AgentProviderRequestResponse) -> AssistantRequestState {
        switch response {
        case .approve, .approveForSession:
            return .approved
        case .decline:
            return .declined
        case .cancel:
            return .cancelled
        }
    }

}

/// Caps provider-visible image attachment bytes. Original files stay on disk.
/// ImageIO thumbnail matches `AgentAttachmentThumbnailLoader` (max-pixel,
/// no source cache, transform-aware) at a 2048px provider-vision budget.
enum AgentAttachmentWireImage {
    static let maxPixel = 2048
    static let maxEncodedBytes = 5 * 1_024 * 1_024
    static let jpegQualities: [Double] = [0.85, 0.70, 0.55, 0.40, 0.25]

    struct Payload: Equatable {
        let data: Data
        let mediaType: String
        let originalByteCount: Int
        let downsampled: Bool
    }

    enum EncodeError: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case exceedsCap(originalBytes: Int, encodedBytes: Int, capBytes: Int, maxPixel: Int)

        var description: String {
            switch self {
            case .unreadable(let path):
                return "Unable to decode image attachment for the provider wire (original kept on disk): \(path)"
            case .exceedsCap(let originalBytes, let encodedBytes, let capBytes, let maxPixel):
                return "Image attachment exceeds the \(capBytes) byte wire cap after \(maxPixel)px downsample (\(encodedBytes) encoded bytes from \(originalBytes) original). Original file kept on disk."
            }
        }
    }

    static func encode(
        path: String,
        mimeType: String,
        maxPixel: Int = maxPixel,
        maxEncodedBytes: Int = maxEncodedBytes
    ) throws -> Payload {
        let url = URL(fileURLWithPath: path)
        guard let originalByteCount = fileSizeBytes(at: path), originalByteCount > 0 else {
            throw EncodeError.unreadable(path)
        }
        let maxPixel = max(1, maxPixel)
        let maxEncodedBytes = max(1, maxEncodedBytes)
        let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        )
        let dimensions = source.flatMap(Self.dimensions(of:))
        let withinByteCap = originalByteCount <= maxEncodedBytes
        let withinPixelCap = dimensions.map { max($0.width, $0.height) <= maxPixel } ?? true
        if withinByteCap && withinPixelCap {
            let data = try readBounded(url: url, maxEncodedBytes: maxEncodedBytes, originalByteCount: originalByteCount)
            return Payload(
                data: data,
                mediaType: mimeType,
                originalByteCount: originalByteCount,
                downsampled: false
            )
        }

        guard let source,
              let cgImage = thumbnail(from: source, maxPixel: maxPixel) else {
            throw EncodeError.unreadable(path)
        }

        var lastEncodedCount = 0
        for quality in jpegQualities {
            guard let encoded = encodeJPEG(cgImage, quality: quality) else { continue }
            lastEncodedCount = encoded.count
            if encoded.count <= maxEncodedBytes {
                return Payload(
                    data: encoded,
                    mediaType: "image/jpeg",
                    originalByteCount: originalByteCount,
                    downsampled: true
                )
            }
        }
        throw EncodeError.exceedsCap(
            originalBytes: originalByteCount,
            encodedBytes: lastEncodedCount,
            capBytes: maxEncodedBytes,
            maxPixel: maxPixel
        )
    }

    private static func fileSizeBytes(at path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return nil }
        let value = size.intValue
        return value > 0 ? value : nil
    }

    private static func readBounded(url: URL, maxEncodedBytes: Int, originalByteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxEncodedBytes + 1) ?? Data()
        guard data.count <= maxEncodedBytes else {
            throw EncodeError.exceedsCap(
                originalBytes: originalByteCount,
                encodedBytes: data.count,
                capBytes: maxEncodedBytes,
                maxPixel: maxPixel
            )
        }
        return data
    }

    private static func dimensions(
        of source: CGImageSource
    ) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
        width > 0,
        height > 0 else {
            return nil
        }
        return (width, height)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        )
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private extension AgentRunRequest {
    func withProviderThreadId(_ providerThreadId: String) -> AgentRunRequest {
        AgentRunRequest(
            runId: runId,
            threadId: threadId,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            cwd: cwd,
            prompt: prompt,
            userMessageContent: userMessageContent,
            attachments: attachments,
            providerThreadId: providerThreadId,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: interactionMode,
            providerBinary: providerBinary,
            environment: environment,
            extraArgs: extraArgs
        )
    }
}
