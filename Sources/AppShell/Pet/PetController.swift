import AppKit
import AgentRuntime
import CoreModel
import Foundation
import Persistence
import SocketServer
import Surfaces

@MainActor
public final class PetController {
    private let context: AppContext
    private let router: AppCommandRouter
    private let settingsStore: SettingsStore
    private let attentionStore: PetAttentionStore
    private let notificationRecorder: PetTerminalNotificationRecorder
    private let model: PetViewModel
    private var animationController: PetAnimationController?
    private var windowController: PetWindowController?
    private let systemMonitor = PetSystemActivityMonitor()
    private let openSettings: (PetSettingsRoute) -> Bool
    private let idleTimeoutNanoseconds: UInt64
    private let extendedReactionDurationProvider: () -> Int64
    private let companionDelayProvider: (ClosedRange<Int>) -> Int

    static let projectionWatermarkKey = "pet.event-projection-watermark.v1"

    private var reducer = PetEventReducer()
    private var eventSubscription: UUID?
    private var notificationTokens: [NSObjectProtocol] = []
    private var transientTask: Task<Void, Never>?
    private var companionTask: Task<Void, Never>?
    private var pendingCompanionCue: PetCompanionCue?
    private var attentionRefreshTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var projectionWatermark: Int64?
    private var projectionErrorMessage: String?
    private var projectionRecoveryBlocked = false
    private var lastHandledEventSequence: Int64?
    private var companionDirector = PetCompanionDirector()
    private var isScreenLocked = false
    private var previousActiveRunProjectionHandler:
        ((ActiveRunProjection, ActiveRunProjectionCause) -> Void)?
    private var installedActiveRunProjectionHandler = false
    /// Latest material progress text per active agent thread for Live Activity
    /// single-active preview (tools / assistant). Not used by the pet popover.
    private var lastUpdatePreviewByThread: [AgentThreadID: String] = [:]
    /// Host run start times for active threads. Progress republish must not
    /// wipe these — empty startedByThread maps used to drop elapsed detail.
    private var startedAtByThread: [AgentThreadID: Date] = [:]
    /// Local-LLM Live Activity descriptions, cached per card and debounced so a
    /// chatty run does not ask the model to summarize every tool line.
    private let liveActivitySummaries = LiveActivitySummaryStore()
    private var liveActivitySummaryTask: Task<Void, Never>?
    private(set) var handledEventOutOfOrderForTests = false
    private(set) var handledEventCountForTests = 0
    private(set) var lastScheduledTransientMillisecondsForTests: Int64?

    var modelForTests: PetViewModel { model }
    var windowControllerForTests: PetWindowController { windowController! }
    var animationTimerIsRunningForTests: Bool { animationController?.timerIsRunning == true }
    /// Test seam: inject host ActiveRunProjection the same path production uses
    /// after coordinator start/finish (reconciles pet work pose).
    func applyActiveRunProjectionForTests(_ projection: ActiveRunProjection) {
        applyActiveRunProjection(projection)
    }
    var hasScheduledTasksForTests: Bool {
        transientTask != nil
            || companionTask != nil
            || attentionRefreshTask != nil
            || idleTask != nil
    }
    var visualRuntimeIsLoadedForTests: Bool {
        animationController != nil && windowController != nil
    }
    var afterStartupCursorCapturedForTests: (() -> Void)?
    var destinationWindowIsKeyForTests: ((NSWindow) -> Bool)?

    public init(
        context: AppContext,
        router: AppCommandRouter,
        openSettings: @escaping (PetSettingsRoute) -> Bool,
        idleTimeoutNanoseconds: UInt64 = 600_000_000_000,
        extendedReactionDurationProvider: @escaping () -> Int64 = {
            Int64.random(in: PetCompanionDirector.extendedReactionDurationRange)
        },
        companionDelayProvider: @escaping (ClosedRange<Int>) -> Int = {
            Int.random(in: $0)
        }
    ) throws {
        self.context = context
        self.router = router
        self.openSettings = openSettings
        self.idleTimeoutNanoseconds = idleTimeoutNanoseconds
        self.extendedReactionDurationProvider = extendedReactionDurationProvider
        self.companionDelayProvider = companionDelayProvider
        self.settingsStore = SettingsStore(db: context.db)
        let settings = settingsStore.load()
        self.model = PetViewModel(settings: settings)
        self.attentionStore = PetAttentionStore(
            threadRepository: context.threadRepo,
            callbackRepository: context.providerPendingCallbackRepo,
            notificationRepository: NotificationRepository(db: context.db),
            markAgentThreadRead: { try router.markAgentThreadRead(thread: $0) },
            markNotificationRead: { try router.notificationMarkRead(id: $0) },
            workspaceNameProvider: { [weak context] workspaceID in
                context?.state.workspaces[workspaceID]?.name
            }
        )
        self.notificationRecorder = PetTerminalNotificationRecorder(
            repository: NotificationRepository(db: context.db)
        )
    }

    public func start() {
        guard eventSubscription == nil else { return }
        let subscription = EventBus.shared.subscribeFromCurrent(filter: .full) { [weak self] event in
            guard !Self.isPrefilteredNoiseKind(event.kind) else { return }
            DispatchQueue.main.async { self?.handle(event) }
        }
        eventSubscription = subscription.id
        let cursor = subscription.cursor
        projectionErrorMessage = prepareProjectionRecovery(capturedCursor: cursor)
        projectionRecoveryBlocked = projectionErrorMessage != nil
        afterStartupCursorCapturedForTests?()
        installActiveRunProjectionObserver()
        refreshActiveThreadsFromCoordinator()
        refreshAttentionNow()
        applySettings(settingsStore.load())
        if let projectionErrorMessage { model.routeError = projectionErrorMessage }

        observeSettings()
        configureSystemMonitor()
        systemMonitor.start()
        scheduleIdleTimeout()
    }

    nonisolated static func isPrefilteredNoiseKind(_ kind: String) -> Bool {
        switch kind {
        case "agent.item.delta", "agent.item.progress",
             "surface.output", "surface.output.summary",
             "agent.thread.token_usage", "agent.account.usage", "agent.account.usage.refresh",
             "fs.workspace.changed", "files.state.updated",
             "pane.resized", "pane.split", "pane.swapped",
             "surface.created", "surface.closed", "surface.focused", "surface.moved",
             "surface.reordered", "surface.renamed", "surface.updated", "window.created",
             "workspace.created", "workspace.closed", "workspace.renamed",
             "workspace.reordered", "workspace.selected", "workspace.updated":
            return true
        default:
            return false
        }
    }

    public func stop() {
        windowController?.cancelActiveDrag()
        if let eventSubscription {
            EventBus.shared.unsubscribe(eventSubscription)
        }
        eventSubscription = nil
        uninstallActiveRunProjectionObserver()
        transientTask?.cancel()
        transientTask = nil
        companionTask?.cancel()
        companionTask = nil
        pendingCompanionCue = nil
        attentionRefreshTask?.cancel()
        attentionRefreshTask = nil
        idleTask?.cancel()
        idleTask = nil
        animationController?.stop()
        windowController?.stop()
        animationController = nil
        windowController = nil
        systemMonitor.stop()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func prepareProjectionRecovery(capturedCursor: Int64) -> String? {
        do {
            let raw = try context.settingsRepo.get(Self.projectionWatermarkKey)
            guard let raw, let stored = Int64(raw) else {
                try persistProjectionWatermark(capturedCursor)
                return nil
            }

            if stored > capturedCursor {
                projectionWatermark = stored
                let durableLastSequence = try context.eventLog.lastSeq()
                guard durableLastSequence <= capturedCursor else {
                    return "Ready-item recovery is waiting for the event log."
                }
                try persistProjectionWatermark(capturedCursor)
                return nil
            }
            projectionWatermark = stored
            var scanCursor = stored
            let decoder = JSONDecoder()
            let timestampFormatter = Self.recoveryTimestampFormatter
            while scanCursor < capturedCursor {
                let rows = try context.eventLog.read(since: scanCursor, limit: 500)
                    .filter { $0.seq <= capturedCursor }
                guard !rows.isEmpty else { break }

                for row in rows {
                    if Self.isPotentialProjectionKind(row.kind) {
                        do {
                            guard let data = row.payloadJSON.data(using: .utf8) else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            let payload = try decoder.decode(JSONValue.self, from: data)
                            let event = EventBus.Event(
                                seq: row.seq,
                                kind: row.kind,
                                payload: payload,
                                ts: timestampFormatter.date(from: row.createdAt)?.timeIntervalSince1970
                                    ?? Date().timeIntervalSince1970
                            )
                            if Self.isProjectionCandidate(event) {
                                _ = try notificationRecorder.record(event: event, replaying: true)
                            }
                        } catch {
                            NSLog("Remote Code pet attention recovery failed at seq %lld: %@", row.seq, String(describing: error))
                            return "A ready item could not be restored."
                        }
                    }
                    scanCursor = row.seq
                }
                try persistProjectionWatermark(scanCursor)
                if rows.count < 500 { break }
            }
            // All persisted candidates through this launch cursor were projected.
            // Any sequence gaps are non-persisted `surface.output` noise by contract.
            try persistProjectionWatermark(capturedCursor)
            return nil
        } catch {
            NSLog("Remote Code pet projection watermark failed: %@", String(describing: error))
            return "Ready-item recovery could not be initialized."
        }
    }

    // PERF: ISO8601DateFormatter is expensive; recovery can parse hundreds of rows.
    // PetController is @MainActor, so one MainActor-isolated formatter avoids per-recovery alloc.
    private static let recoveryTimestampFormatter = ISO8601DateFormatter()

    // PERF: event-log recovery and live EventBus handling classify every
    // published kind. Array literals reallocated membership tables per event;
    // share process-wide Sets (membership contract unchanged).
    private static let potentialProjectionKinds: Set<String> = [
        "git.push", "git.deliver", "project.script.finished",
        "ssh.transfer.completed", "ssh.transfer.failed", "ssh.session.updated",
        "agent.provider.updated", "files.edit.conflict", "files.edit.saved",
        "files.edit.discarded", "files.edit.closed",
    ]
    private static let fileEditResolvedKinds: Set<String> = [
        "files.edit.saved", "files.edit.discarded", "files.edit.closed",
    ]
    private static let attentionProjectionKinds: Set<String> = [
        "notification.created", "notification.read", "notification.dismissed",
        "agent.thread.read", "agent.thread.updated", "agent.thread.deleted",
        "agent.thread.deleted_many",
    ]

    private static func isPotentialProjectionKind(_ kind: String) -> Bool {
        potentialProjectionKinds.contains(kind)
    }

    private static func isProjectionCandidate(_ event: EventBus.Event) -> Bool {
        if PetTerminalNotificationRecorder.classify(event) != nil { return true }
        if event.kind == "ssh.session.updated",
           case .object(let payload) = event.payload,
           (payload["status"]?.stringValue == "connected"
                || payload["reason"]?.stringValue == "user_requested"),
           payload["surface_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil {
            return true
        }
        guard Self.fileEditResolvedKinds.contains(event.kind),
              case .object(let payload) = event.payload,
              payload["session_id"]?.stringValue?.isEmpty == false else { return false }
        return true
    }

    private func advanceProjectionWatermark(to sequence: Int64) {
        guard !projectionRecoveryBlocked else { return }
        guard sequence > (projectionWatermark ?? -1) else { return }
        do {
            try persistProjectionWatermark(sequence)
            projectionErrorMessage = nil
        } catch {
            projectionRecoveryBlocked = true
            projectionErrorMessage = "Ready-item recovery could not be updated."
            model.routeError = projectionErrorMessage
            NSLog("Remote Code pet projection watermark write failed at seq %lld: %@", sequence, String(describing: error))
        }
    }

    private func persistProjectionWatermark(_ sequence: Int64) throws {
        try context.settingsRepo.set(Self.projectionWatermarkKey, String(sequence))
        projectionWatermark = sequence
    }

    private func ensureVisualRuntime() throws {
        guard animationController == nil, windowController == nil else { return }
        let animationController = try PetAnimationController(atlas: .bundled())
        let windowController = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: context.settingsRepo)
        )
        self.animationController = animationController
        self.windowController = windowController
        wireCallbacks(animationController: animationController, windowController: windowController)
        if let frame = animationController.currentFrame {
            model.setFrame(frame)
        }
    }

    private func wireCallbacks(
        animationController: PetAnimationController,
        windowController: PetWindowController
    ) {
        animationController.onFrame = { [weak model, weak windowController] frame in
            model?.setFrame(frame)
            windowController?.animationFrameDidChange()
        }
        animationController.onError = { [weak model] _ in
            model?.routeError = "Pet artwork could not be loaded."
        }
        windowController.onOpenItem = { [weak self] item in self?.open(item) }
        windowController.onOpenActiveThread = { [weak self] item in self?.openActive(item) }
        windowController.onMarkAllViewed = { [weak self] in self?.markAllViewed() }
        windowController.onOpenRemoteCode = { [weak self] in self?.showRemoteCode() }
        windowController.onOpenSettings = { [weak self] in
            _ = self?.openSettings(.general)
        }
        windowController.onHidePet = { [weak self] in self?.setPetEnabled(false) }
        windowController.onToggleAnimations = { [weak self] in self?.toggleAnimations() }
        windowController.onAdoptFreePosition = { [weak self] in self?.adoptFreePosition() }
        windowController.onInteraction = { [weak self] in self?.handleInteraction() }
        windowController.onDragStateChanged = { [weak self] isDragging in
            self?.handlePetDragStateChanged(isDragging)
        }
        windowController.onCareAction = { [weak self] action in
            guard let self else { return }
            self.playCompanionCue(PetCompanionDirector.careCue(
                action: action,
                returnState: self.reducer.state,
                durationMilliseconds: self.randomExtendedReactionDuration()
            ), allowsStaticReaction: true)
        }
    }

    @discardableResult
    public func togglePopoverFromKeyboard() -> Bool {
        guard model.settings.petEnabled, let windowController else { return false }
        windowController.show()
        handleInteraction()
        windowController.togglePopover()
        return true
    }

    private func configureSystemMonitor() {
        systemMonitor.onScreenLockChanged = { [weak self] locked in
            self?.handleSystemScreenLockChanged(locked)
        }
        systemMonitor.onWake = { [weak self] in
            self?.handleSystemWake()
        }
        systemMonitor.onScreenParametersChanged = { [weak self] in
            self?.windowController?.screensDidChange()
        }
        systemMonitor.onDockContentsMayHaveChanged = { [weak self] in
            self?.windowController?.screensDidChange()
        }
        systemMonitor.onAccessibilityDisplayOptionsChanged = { [weak self] in
            self?.applySettings(self?.settingsStore.load() ?? AppSettings())
        }
    }

    func handleSystemScreenLockChanged(_ locked: Bool) {
        if locked { windowController?.cancelActiveDrag() }
        isScreenLocked = locked
        animationController?.setScreenLocked(locked)
        apply(reducer.reduce(
            .screenLockChanged(isLocked: locked),
            atMilliseconds: monotonicMilliseconds()
        ))
        if !locked { scheduleIdleTimeout() }
    }

    func handleSystemWake() {
        apply(reducer.reduce(.wake, atMilliseconds: monotonicMilliseconds()))
        scheduleIdleTimeout()
    }

    private func observeSettings() {
        let settingsToken = NotificationCenter.default.addObserver(
            forName: .petSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applySettings(self.settingsStore.reload())
                self.refreshAttentionNow()
            }
        }
        let resetToken = NotificationCenter.default.addObserver(
            forName: .petResetPositionRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windowController?.resetPosition() }
        }
        notificationTokens = [settingsToken, resetToken]
    }

    private func handle(_ event: EventBus.Event) {
        handledEventCountForTests += 1
        if let lastHandledEventSequence, event.seq <= lastHandledEventSequence {
            handledEventOutOfOrderForTests = true
        }
        lastHandledEventSequence = event.seq
        let attentionProjectionChanged = Self.attentionProjectionKinds.contains(event.kind)
        let focusedSurfaceByWorkspace = context.state.workspaces.reduce(
            into: [WorkspaceID: SurfaceID]()
        ) { result, entry in
            let workspace = entry.value
            guard let paneID = workspace.focusedPaneID,
                  let surfaceID = workspace.layout.find(paneID: paneID)?.selectedSurfaceID else { return }
            result[entry.key] = surfaceID
        }
        let detachedWorkspaceIDs = Set(context.state.workspaces.keys.filter {
            router.windowController?.workspaceWindow(for: $0) != nil
        })
        let focusDestination = PetAttentionFocusPolicy.resolveDestination(
            event: event,
            mainSelectedWorkspaceID: context.state.window.selectedWorkspaceID,
            focusedSurfaceByWorkspace: focusedSurfaceByWorkspace,
            detachedWorkspaceIDs: detachedWorkspaceIDs
        )
        let destinationWindow = focusDestination.detachedWorkspaceID
            .flatMap { router.windowController?.workspaceWindow(for: $0) }
            ?? router.windowController?.window
        let shouldPersist = PetAttentionFocusPolicy.shouldPersist(
            event: event,
            isAppActive: NSApplication.shared.isActive,
            isDestinationWindowFocused: destinationWindow?.isVisible == true
                && destinationWindow?.isMiniaturized == false
                && destinationWindow?.isKeyWindow == true,
            selectedWorkspaceID: focusDestination.selectedWorkspaceID,
            focusedSurfaceID: focusDestination.focusedSurfaceID
        )
        let projectionCandidate = Self.isProjectionCandidate(event)
        var projectionChanged = false
        var projectionFailed = false
        if projectionCandidate {
            if shouldPersist {
                do {
                    _ = try notificationRecorder.record(event: event)
                    projectionChanged = true
                    advanceProjectionWatermark(to: event.seq)
                } catch {
                    projectionFailed = true
                    projectionRecoveryBlocked = true
                    projectionErrorMessage = "A ready item could not be saved."
                    NSLog("Remote Code pet attention projection failed at seq %lld: %@", event.seq, String(describing: error))
                }
            } else {
                advanceProjectionWatermark(to: event.seq)
            }
        }
        // Material agent progress → Live Activity single-active description.
        // Deltas/progress are prefiltered noise and never reach here.
        let liveActivityProgressChanged = noteLiveActivityProgress(from: event)
        guard let domainEvent = PetEventDecoder.decode(event) else {
            if projectionFailed { model.routeError = projectionErrorMessage }
            if projectionChanged || attentionProjectionChanged { scheduleAttentionRefresh() }
            if liveActivityProgressChanged { republishActiveThreadsForLiveActivity() }
            return
        }
        let reduction = reducer.reduce(domainEvent, atMilliseconds: monotonicMilliseconds())
        if case .ignored = reduction.disposition {
            // Noise, duplicate compatibility events, and explicit user disconnects
            // do not count as activity for the idle-sleep policy.
        } else {
            scheduleIdleTimeout()
        }
        apply(reduction)
        // Invariant: work/plan (laptop, hard-hat, thinking, coding…) only while the
        // blue Active badge is non-zero. EventBus can insert ghost run ids when
        // finish is missed; host coordinator Active is the sole authority.
        if Self.shouldResyncActiveRuns(after: domainEvent) {
            refreshActiveThreadsFromCoordinator()
        }
        if case .ignored = reduction.disposition {
            // Duplicate terminal compatibility events do not increment celebrations.
        } else if case .agentRunFinished(_, .completed) = domainEvent,
                  let cue = companionDirector.successCue(returnState: reducer.companionBaseState) {
            playCompanionCue(cue)
        }
        if projectionFailed { model.routeError = projectionErrorMessage }
        if projectionChanged || reduction.shouldRefreshAttention {
            scheduleAttentionRefresh()
        } else if liveActivityProgressChanged {
            republishActiveThreadsForLiveActivity()
        }
    }

    /// Capture latest human-readable progress for the Live Activity description.
    /// Returns true when the cache changed so the surface can be republished.
    @discardableResult
    private func noteLiveActivityProgress(from event: EventBus.Event) -> Bool {
        guard case .object(let payload) = event.payload,
              let threadUUID = payload["thread_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        else { return false }
        let threadID = AgentThreadID(threadUUID)
        let preview: String?
        switch event.kind {
        case "agent.item.started":
            preview = Self.itemStartedPreview(payload: payload)
        case "agent.item.delta":
            // Live assistant/tool body growth — keep single-active LA description
            // fresh without waiting for item.completed.
            preview = Self.itemDeltaPreview(payload: payload)
        case "agent.item.completed":
            preview = Self.itemCompletedPreview(payload: payload)
        case "agent.turn.completed":
            preview = Self.turnCompletedPreview(payload: payload)
        case "agent.run.started":
            preview = "Working…"
        case "agent.run.finished", "agent.run.completed", "agent.run.failed", "agent.run.cancelled":
            lastUpdatePreviewByThread.removeValue(forKey: threadID)
            return true
        default:
            return false
        }
        guard let preview,
              let redacted = PetAttentionRedactor.safeContextLabel(preview),
              !redacted.isEmpty else {
            return false
        }
        if lastUpdatePreviewByThread[threadID] == redacted { return false }
        lastUpdatePreviewByThread[threadID] = redacted
        return true
    }

    private func republishActiveThreadsForLiveActivity() {
        // Rebuild active rows so lastUpdatePreview is embedded, then push LA.
        // Prefer currently projected active thread IDs (with cached startedAt)
        // so material item/turn updates never drop elapsed or empty the list
        // when coordinator snapshot lags the projection callback.
        let projectedIDs = model.activeThreads.map(\.threadID)
        if projectedIDs.isEmpty {
            refreshActiveThreadsFromCoordinator()
            return
        }
        applyActiveThreadIDs(projectedIDs, startedByThread: startedAtByThread)
    }

    /// Merge host-provided startedAt values with the retained cache for threads
    /// that remain active. Pure so unit tests can prove progress republish does
    /// not erase elapsed anchors.
    nonisolated static func mergingStartedAtByThread(
        activeThreadIDs: [AgentThreadID],
        incoming: [AgentThreadID: Date],
        retained: [AgentThreadID: Date]
    ) -> [AgentThreadID: Date] {
        let activeSet = Set(activeThreadIDs)
        var next = retained.filter { activeSet.contains($0.key) }
        for (id, date) in incoming where activeSet.contains(id) {
            next[id] = date
        }
        return next
    }

    /// Agent App-style Live Activity line from an item.started payload.
    /// Thinking / assistant text / tool runs — never provider-runtime method ids.
    nonisolated static func itemStartedPreview(payload: [String: JSONValue]) -> String? {
        guard let item = payload["item"]?.objectValue else { return nil }
        let type = item["type"]?.stringValue ?? "tool"
        if type == "reasoning" {
            if let body = friendlyPreview(nonempty(item["body"])) { return body }
            return "Thinking…"
        }
        if type == "assistantMessage" {
            if let body = friendlyPreview(nonempty(item["body"])) { return body }
            return "Writing…"
        }
        if type == "plan" {
            return friendlyPreview(nonempty(item["summary"]) ?? nonempty(item["body"]))
        }
        // Prefer human summary; reject dotted runtime method names.
        if let summary = nonempty(item["summary"]) {
            if isProviderRuntimeNoise(summary) {
                // No user-facing summary — do not invent a generic "Running: tool"
                // line for provider telemetry methods.
                return nil
            }
            if let friendly = friendlyPreview(summary) {
                return "Running: \(friendly)"
            }
        }
        let label = activityLabel(type: type, summary: nil, body: nonempty(item["body"]))
        guard let friendly = friendlyPreview(label), !isProviderRuntimeNoise(friendly) else {
            return nil
        }
        // Skip bare type fallbacks when body/summary had no human content.
        if friendly == type || friendly == "tool" || friendly == "command" {
            if nonempty(item["body"]) == nil { return nil }
        }
        return "Running: \(friendly)"
    }

    nonisolated static func itemCompletedPreview(payload: [String: JSONValue]) -> String? {
        if let summary = friendlyPreview(nonempty(payload["summary"])) {
            return "Ran: \(summary)"
        }
        // completed often carries only item_id; keep prior cache if no text.
        if let state = payload["state"]?.stringValue, state == "failed" {
            return "Failed: tool"
        }
        return nil
    }

    /// Mid-stream body growth for the LA description (single-active, no red badge).
    /// Prefer assistant prose; ignore empty / pure runtime noise.
    nonisolated static func itemDeltaPreview(payload: [String: JSONValue]) -> String? {
        // Common shapes: { item: { type, body } } or top-level body_append.
        let item = payload["item"]?.objectValue
        let type = item?["type"]?.stringValue
            ?? payload["type"]?.stringValue
            ?? ""
        let body = nonempty(item?["body"])
            ?? nonempty(payload["body_append"])
            ?? nonempty(payload["bodyAppend"])
            ?? nonempty(payload["body"])
        guard let body, let friendly = friendlyPreview(body) else { return nil }
        if type == "assistantMessage" || type.isEmpty {
            return friendly
        }
        if type == "reasoning" {
            return friendly
        }
        // Tools: only surface when body looks human (not dotted method ids).
        if isProviderRuntimeNoise(friendly) { return nil }
        return "Running: \(friendly)"
    }

    nonisolated static func turnCompletedPreview(payload: [String: JSONValue]) -> String? {
        if let final = friendlyPreview(nonempty(payload["final"])) { return final }
        if let final = friendlyPreview(nonempty(payload["final_message"])) { return final }
        return nil
    }

    /// Drop provider-runtime telemetry ("claude runtime: …", dotted method ids).
    // PERF: dotted-id scan used CharacterSet.alphanumerics.union(…) inside
    // allSatisfy — allocating a new set for every scalar. Share one set for
    // live-activity stream previews.
    private static let providerRuntimeTokenScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-"))

    nonisolated static func isProviderRuntimeNoise(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        if lower.contains(" runtime: ") { return true }
        if lower.hasPrefix("runtime:") { return true }
        if trimmed.contains("."), !trimmed.contains(" "),
           trimmed.unicodeScalars.allSatisfy({ providerRuntimeTokenScalars.contains($0) }) {
            return true
        }
        return false
    }

    nonisolated private static func friendlyPreview(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProviderRuntimeNoise(trimmed) else { return nil }
        return String(trimmed.prefix(140))
    }

    nonisolated private static func activityLabel(type: String, summary: String?, body: String?) -> String {
        if let summary, !summary.isEmpty { return summary }
        if let body {
            let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        switch type {
        case "commandExecution": return "command"
        case "fileChange": return "file edit"
        case "webSearch": return "search"
        case "mcpToolCall", "dynamicToolCall", "collabToolCall", "tool": return "tool"
        default: return type
        }
    }

    nonisolated private static func nonempty(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    private func apply(_ reduction: PetEventReduction) {
        applyTransientTimerDirective(reduction.transientTimerDirective)
        var nextState = reduction.state
        // Hard rule: no work/plan pose without a blue Active badge. Projection
        // and EventBus can diverge; the visible Active list is authoritative.
        if model.activeThreads.isEmpty,
           reducer.activeRunCount > 0 || PetEventReducer.isWorkPose(nextState) {
            let cleared = reducer.reconcileActiveRunIDs(
                [],
                atMilliseconds: monotonicMilliseconds()
            )
            applyTransientTimerDirective(cleared.transientTimerDirective)
            nextState = cleared.state
        }
        if nextState != model.animationState {
            model.setAnimationState(nextState)
            let derived: PetAnimationState = model.count > 0 ? .waiting : .idle
            do {
                try animationController?.setState(nextState, derivedTerminalState: derived)
                model.routeError = projectionErrorMessage
            } catch {
                model.routeError = "Pet animation is unavailable."
            }
        }
        scheduleCompanionBehavior()
    }

    /// Agent lifecycle / item / companion events can arm work poses — re-check host.
    nonisolated static func shouldResyncActiveRuns(after event: PetDomainEvent) -> Bool {
        switch event {
        case .agentRunStarted, .agentRunFinished, .agentRunError,
             .agentTurnStarted, .agentItemStarted, .agentItemCompleted,
             .contextCompaction, .companionCue, .transientExpired:
            return true
        default:
            return false
        }
    }

    private func applyTransientTimerDirective(_ directive: PetTransientTimerDirective?) {
        guard let directive else { return }
        transientTask?.cancel()
        transientTask = nil
        lastScheduledTransientMillisecondsForTests = nil
        guard case .schedule(let milliseconds) = directive else { return }
        lastScheduledTransientMillisecondsForTests = milliseconds
        let nanoseconds = UInt64(max(0, milliseconds)) * 1_000_000
        transientTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.apply(self.reducer.reduce(
                    .transientExpired,
                    atMilliseconds: self.monotonicMilliseconds()
                ))
            }
        }
    }

    private func scheduleAttentionRefresh() {
        attentionRefreshTask?.cancel()
        attentionRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refreshAttentionNow() }
        }
    }

    private func refreshAttentionNow() {
        do {
            let previousCount = model.count
            let snapshot = try attentionStore.refresh(filter: attentionFilter(model.settings.petAttentionFilter))
            model.apply(snapshot: snapshot)
            model.routeError = projectionErrorMessage
            let reduction = reducer.reduce(
                .attentionHydrated(attentionHydration(from: snapshot)),
                atMilliseconds: monotonicMilliseconds()
            )
            apply(reduction)
            if let cue = companionDirector.notificationCue(
                previousCount: previousCount,
                newCount: snapshot.count,
                baseState: reduction.state
            ) {
                playCompanionCue(cue)
            }
            if snapshot.count == 0 { scheduleIdleTimeout() }
            publishLiveActivitySurface()
        } catch {
            model.routeError = "Ready items could not be loaded."
        }
    }

    /// Push pet-identical copy to the remote Live Activity (active + needs you + completed).
    ///
    /// Publishes immediately with whatever description is already available, then
    /// asks the on-device model for a better one in the background. The model is
    /// never awaited here: `submitSurface` feeds a serialized delivery mailbox,
    /// and an 8-second generation would stall every Live Activity update behind it.
    private func publishLiveActivitySurface() {
        let base = PetLiveActivityCopy.Input(
            active: model.activeThreads,
            needsYou: model.needsYouItems,
            completed: model.completedItems
        )
        guard let source = LiveActivitySummary.source(for: base) else {
            liveActivitySummaries.reset()
            context.liveActivitySyncCoordinator.submitSurface(PetLiveActivityCopy.make(base))
            return
        }
        let input = PetLiveActivityCopy.Input(
            active: base.active,
            needsYou: base.needsYou,
            completed: base.completed,
            summary: liveActivitySummaries.summary(for: source)
        )
        context.liveActivitySyncCoordinator.submitSurface(PetLiveActivityCopy.make(input))
        scheduleLiveActivitySummary(source: source, threadId: base.active.first?.threadID)
    }

    /// Generate off the publish path and republish only when the sentence is
    /// new, so a slow or unavailable model costs the Lock Screen nothing.
    private func scheduleLiveActivitySummary(
        source: LiveActivitySummary.Source,
        threadId: AgentThreadID?
    ) {
        guard liveActivitySummaries.shouldGenerate(for: source) else { return }
        liveActivitySummaryTask?.cancel()
        liveActivitySummaryTask = Task { [weak self] in
            guard let self else { return }
            let generated = await self.context.liveActivityDescriptionSummary(
                source: source,
                threadId: threadId
            )
            guard !Task.isCancelled, let generated else { return }
            self.liveActivitySummaries.store(generated, for: source)
            // Re-derive from live model state: the surface may have moved on
            // while the model was thinking, and a stale republish would rewind it.
            self.publishLiveActivitySurface()
        }
    }

    private func attentionHydration(from snapshot: PetAttentionSnapshot) -> PetAttentionHydration {
        var approvalIDs: Set<String> = []
        var questionIDs: Set<String> = []
        var fileConflictIDs: Set<String> = []
        var isReconnecting = false

        for item in snapshot.items {
            switch item.kind {
            case .callback(let kind, _):
                let reducerID: String
                if case .callback(let threadID, let requestID, _) = item.source {
                    reducerID = "\(threadID.value.uuidString):\(requestID)"
                } else {
                    reducerID = item.id
                }
                if kind == .approval {
                    approvalIDs.insert(reducerID)
                } else {
                    questionIDs.insert(reducerID)
                }
            case .notification(let category):
                if category == .fileConflict {
                    let persistedID: String
                    if case .notification(let id) = item.source {
                        persistedID = id
                    } else {
                        persistedID = item.id
                    }
                    let prefix = "pet.file-conflict."
                    fileConflictIDs.insert(
                        persistedID.hasPrefix(prefix)
                            ? String(persistedID.dropFirst(prefix.count))
                            : persistedID
                    )
                }
                if category == .serverListenerFailed || category == .sshUnexpectedDisconnect {
                    isReconnecting = true
                }
            case .agentOutcome:
                break
            }
        }

        return PetAttentionHydration(
            approvalIDs: approvalIDs,
            questionIDs: questionIDs,
            fileConflictIDs: fileConflictIDs,
            count: snapshot.count,
            isReconnecting: isReconnecting
        )
    }

    private func open(_ item: PetAttentionItem) {
        do {
            let result = try attentionStore.openAndMarkRead(itemID: item.id) { [weak self] route in
                guard let self else { return false }
                return try self.verifyAndOpen(route)
            }
            switch result {
            case .marked, .retainedBlocker:
                model.routeError = nil
                windowController?.closePopover(restoringPreviousKeyWindow: false)
                refreshAttentionNow()
            case .routeRejected:
                model.routeError = "The exact destination could not be opened. The item was kept."
            case .notFound:
                model.routeError = "Item no longer exists."
            }
        } catch {
            model.routeError = "The exact destination could not be opened. The item was kept."
        }
    }

    private func openActive(_ item: PetActiveThreadItem) {
        do {
            let opened = try verifyAndOpen(item.route)
            if opened {
                model.routeError = nil
                windowController?.closePopover(restoringPreviousKeyWindow: false)
            } else {
                model.routeError = "The exact destination could not be opened. The item was kept."
            }
        } catch {
            model.routeError = "The exact destination could not be opened. The item was kept."
        }
    }

    private func installActiveRunProjectionObserver() {
        guard !installedActiveRunProjectionHandler else { return }
        previousActiveRunProjectionHandler = context.coordinator.onActiveRunProjectionChanged
        context.coordinator.onActiveRunProjectionChanged = { [weak self] projection, cause in
            self?.previousActiveRunProjectionHandler?(projection, cause)
            DispatchQueue.main.async {
                self?.applyActiveRunProjection(projection)
            }
        }
        installedActiveRunProjectionHandler = true
    }

    private func uninstallActiveRunProjectionObserver() {
        guard installedActiveRunProjectionHandler else { return }
        context.coordinator.onActiveRunProjectionChanged = previousActiveRunProjectionHandler
        previousActiveRunProjectionHandler = nil
        installedActiveRunProjectionHandler = false
    }

    private func refreshActiveThreadsFromCoordinator() {
        let threadIDs = Array(context.coordinator.activeThreadIdsSnapshot())
        applyActiveThreadIDs(threadIDs)
        // Reconcile animation active-run set to coordinator truth (not EventBus alone).
        let hostRunIDs = Set(threadIDs.compactMap {
            context.coordinator.activeRunId(threadId: $0)?.value.uuidString
        })
        reconcilePetActiveRuns(hostRunIDs)
    }

    private func applyActiveRunProjection(_ projection: ActiveRunProjection) {
        var startedByThread: [AgentThreadID: Date] = [:]
        for run in projection.runs {
            guard let startedAt = try? context.runRepo.get(id: run.runId)?.startedAt else { continue }
            if let existing = startedByThread[run.threadId] {
                startedByThread[run.threadId] = min(existing, startedAt)
            } else {
                startedByThread[run.threadId] = startedAt
            }
        }
        applyActiveThreadIDs(projection.runs.map(\.threadId), startedByThread: startedByThread)
        // Host ActiveRunProjection is authoritative for pet work pose. Empty
        // projection clears EventBus ghost run ids that never received finished.
        let hostRunIDs = Set(projection.runs.map { $0.runId.value.uuidString })
        reconcilePetActiveRuns(hostRunIDs)
    }

    /// Push host-authoritative active run ids into the pet reducer and refresh
    /// animation. Shared by projection callbacks and coordinator snapshot refresh.
    private func reconcilePetActiveRuns(_ hostRunIDs: Set<String>) {
        let reduction = reducer.reconcileActiveRunIDs(
            hostRunIDs,
            atMilliseconds: monotonicMilliseconds()
        )
        if case .ignored = reduction.disposition {
            // reconcile never ignores
        } else {
            scheduleIdleTimeout()
        }
        apply(reduction)
    }

    private func applyActiveThreadIDs(
        _ threadIDs: [AgentThreadID],
        startedByThread: [AgentThreadID: Date] = [:]
    ) {
        // Drop progress cache for threads that are no longer active.
        let activeSet = Set(threadIDs)
        lastUpdatePreviewByThread = lastUpdatePreviewByThread.filter { activeSet.contains($0.key) }
        // Preserve startedAt across progress-only republishes (empty incoming
        // map must not clear elapsed embedded in pet detail / LA statusLine).
        startedAtByThread = Self.mergingStartedAtByThread(
            activeThreadIDs: threadIDs,
            incoming: startedByThread,
            retained: startedAtByThread
        )

        let items = PetActiveThreadProjector.items(threadIDs: threadIDs) { [weak self] threadID in
            guard let self,
                  let thread = try? self.context.threadRepo.get(id: threadID) else {
                return nil
            }
            let workspaceName = thread.workspaceId.flatMap { self.context.state.workspaces[$0]?.name }
            return (
                workspaceID: thread.workspaceId,
                workspaceName: workspaceName,
                providerName: PetActiveThreadProjector.providerLabel(thread.provider),
                threadTitle: thread.title,
                startedAt: self.startedAtByThread[threadID],
                lastUpdatePreview: self.lastUpdatePreviewByThread[threadID]
            )
        }
        model.apply(activeThreads: items)
        // User-visible Active is empty → pet must leave work/plan even if EventBus
        // still holds a ghost run id (missed finished / stale projection lag).
        if threadIDs.isEmpty, reducer.activeRunCount > 0 || PetEventReducer.isWorkPose(model.animationState) {
            reconcilePetActiveRuns([])
        }
        publishLiveActivitySurface()
    }

    private func verifyAndOpen(_ route: PetAttentionRoute) throws -> Bool {
        switch route {
        case .agentThread(let threadID, _):
            let descriptor = try router.openAgentThread(thread: threadID, markRead: false)
            guard let window = SurfaceRegistry.shared.surface(descriptor.id)?.view.window else { return false }
            return window.isVisible && !window.isMiniaturized && destinationWindowIsKey(window)
        case .surface(let surfaceID, let requestedWorkspaceID):
            let requestedStillOwnsSurface = requestedWorkspaceID.flatMap { workspaceID in
                context.state.workspaces[workspaceID]?.layout.contains(surfaceID: surfaceID) == true
                    ? workspaceID
                    : nil
            }
            guard let workspaceID = requestedStillOwnsSurface ?? context.state.workspaces.first(where: {
                $0.value.layout.contains(surfaceID: surfaceID)
            })?.key else { return false }
            guard let destinationWindow = activateDestinationWindow(for: workspaceID) else { return false }
            if router.windowController?.workspaceWindow(for: workspaceID) == nil {
                try router.selectWorkspace(workspaceID)
            }
            try router.focusSurface(workspace: workspaceID, surface: surfaceID)
            router.windowController?.flushPendingRefresh()
            router.windowController?.focusSurface(surfaceID)
            guard let workspace = context.state.workspaces[workspaceID],
                  let paneID = workspace.focusedPaneID else { return false }
            return workspace.layout.find(paneID: paneID)?.selectedSurfaceID == surfaceID
                && destinationWindow.isVisible
                && !destinationWindow.isMiniaturized
                && destinationWindowIsKey(destinationWindow)
                && SurfaceRegistry.shared.surface(surfaceID)?.view.window === destinationWindow
        case .workspace(let workspaceID):
            guard let destinationWindow = activateDestinationWindow(for: workspaceID) else { return false }
            if router.windowController?.workspaceWindow(for: workspaceID) == nil {
                try router.selectWorkspace(workspaceID)
                guard context.state.window.selectedWorkspaceID == workspaceID else { return false }
            }
            return destinationWindow.isVisible
                && !destinationWindow.isMiniaturized
                && destinationWindowIsKey(destinationWindow)
        case .settings(let settingsRoute):
            return openSettings(settingsRoute)
        }
    }

    private func activateDestinationWindow(for workspaceID: WorkspaceID) -> NSWindow? {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let detachedWindow = router.windowController?.workspaceWindow(for: workspaceID) {
            detachedWindow.makeKeyAndOrderFront(nil)
            return detachedWindow
        }
        router.windowController?.show()
        return router.windowController?.window
    }

    private func destinationWindowIsKey(_ window: NSWindow) -> Bool {
        destinationWindowIsKeyForTests?(window) ?? window.isKeyWindow
    }

    private func markAllViewed() {
        do {
            _ = try attentionStore.markAllRead()
            model.routeError = nil
            // Mark + dismiss only. Do not open Remote Code or re-present Ready for you.
            windowController?.closePopover(restoringPreviousKeyWindow: false)
            refreshAttentionNow()
        } catch {
            model.routeError = "Ready items could not be updated."
        }
    }

    private func showRemoteCode() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        router.windowController?.show()
        windowController?.closePopover(restoringPreviousKeyWindow: false)
    }

    private func toggleAnimations() {
        settingsStore.update { $0.petAnimationsEnabled.toggle() }
        applySettings(settingsStore.load())
        NotificationCenter.default.post(name: .petSettingsDidChange, object: self)
    }

    private func setPetEnabled(_ enabled: Bool) {
        settingsStore.update { $0.petEnabled = enabled }
        applySettings(settingsStore.load())
        NotificationCenter.default.post(name: .petSettingsDidChange, object: self)
    }

    private func adoptFreePosition() {
        settingsStore.update { $0.petPosition = "free" }
        model.apply(settings: settingsStore.load())
        NotificationCenter.default.post(name: .petSettingsDidChange, object: self)
    }

    private func applySettings(_ settings: AppSettings) {
        model.apply(settings: settings)
        if settings.petEnabled {
            do {
                let visualRuntimeWasLoaded = animationController != nil
                try ensureVisualRuntime()
                animationController?.setVisible(true)
                animationController?.setAnimationsEnabled(settings.petAnimationsEnabled)
                animationController?.setReducedMotion(
                    settings.petReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                )
                windowController?.applySettings(settings)
                if !visualRuntimeWasLoaded {
                    let derived: PetAnimationState = model.count > 0 ? .waiting : .idle
                    try animationController?.setState(model.animationState, derivedTerminalState: derived)
                }
                if let cue = pendingCompanionCue {
                    pendingCompanionCue = nil
                    playCompanionCue(cue)
                }
            } catch {
                model.routeError = "Pet animation is unavailable."
            }
            scheduleIdleTimeout()
            scheduleCompanionBehavior()
        } else {
            animationController?.setVisible(false)
            windowController?.applySettings(settings)
            idleTask?.cancel()
            idleTask = nil
            companionTask?.cancel()
            companionTask = nil
            pendingCompanionCue = nil
        }
    }

    private func handleInteraction() {
        apply(reducer.reduce(.interactionBegan, atMilliseconds: monotonicMilliseconds()))
        scheduleIdleTimeout()
    }

    private func handlePetDragStateChanged(_ isDragging: Bool) {
        apply(reducer.reduce(
            isDragging ? .petDragBegan : .petDragEnded,
            atMilliseconds: monotonicMilliseconds()
        ))
        scheduleIdleTimeout()
    }

    private func companionEligibility() -> PetCompanionEligibility {
        let settings = model.settings
        // Use companionBaseState (no decorative transient), not reducer.state.
        // WHY: while workingMouse/Bug/Engineer is showing, display state is not in
        // the work-base set — using reducer.state cancelled the next work countdown
        // and re-froze the laptop pose for a full 35–55s after every variant.
        //
        // activeRunCount = blue Active badge (model.activeThreads), not EventBus
        // ghost run ids. Work variants (laptop/hard-hat) must not play with zero
        // Active rows — that was the "working with no badge" stick.
        return PetCompanionEligibility(
            baseState: reducer.companionBaseState,
            attentionCount: model.count,
            activeRunCount: model.activeThreads.count,
            isVisible: windowController?.isVisible == true,
            animationsEnabled: settings.petAnimationsEnabled,
            reducedMotion: settings.petReduceMotion
                || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            screenLocked: isScreenLocked
        )
    }

    private func scheduleCompanionBehavior() {
        let eligibility = companionEligibility()
        let delayRange: ClosedRange<Int>
        if eligibility.allowsWorkCue {
            delayRange = PetCompanionDirector.workDelayRange
        } else if eligibility.allowsAmbientCue {
            delayRange = PetCompanionDirector.ambientDelayRange
        } else {
            companionTask?.cancel()
            companionTask = nil
            return
        }
        guard companionTask == nil else { return }
        let delay = companionDelayProvider(delayRange)
        companionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.companionTask = nil
                let eligibility = self.companionEligibility()
                let cue: PetCompanionCue?
                if eligibility.allowsWorkCue {
                    cue = self.companionDirector.nextWorkCue(
                        eligibility: eligibility,
                        preferredIndex: Int.random(in: 0..<3),
                        durationMilliseconds: self.randomExtendedReactionDuration()
                    )
                } else if eligibility.allowsAmbientCue {
                    cue = self.companionDirector.nextAmbientCue(
                        eligibility: eligibility,
                        preferredIndex: Int.random(in: 0..<8),
                        durationMilliseconds: self.randomExtendedReactionDuration()
                    )
                } else {
                    cue = nil
                }
                if let cue {
                    self.playCompanionCue(cue)
                } else {
                    self.scheduleCompanionBehavior()
                }
            }
        }
    }

    private func playCompanionCue(
        _ cue: PetCompanionCue,
        allowsStaticReaction: Bool = false
    ) {
        // Always re-arm the companion loop after this attempt. Early returns used
        // to leave companionTask == nil with no pending schedule during long runs.
        defer { scheduleCompanionBehavior() }

        guard model.settings.petEnabled, !isScreenLocked else { return }
        let motionAllowed = model.settings.petAnimationsEnabled
            && !model.settings.petReduceMotion
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard allowsStaticReaction || motionAllowed else { return }
        guard let animationController else {
            pendingCompanionCue = cue
            return
        }
        // Drain any cue stashed while the visual runtime was missing.
        if pendingCompanionCue != nil {
            pendingCompanionCue = nil
        }
        let alignedDuration = animationController.loopSafeDurationMilliseconds(
            for: cue.state,
            requested: cue.durationMilliseconds
        )
        // Hardening: rebind return to the live semantic base at fire time
        // (defense-in-depth; production mints return from eligibility after the delay).
        let effectiveCue = PetCompanionCue(
            state: cue.state,
            returnState: reducer.companionBaseState,
            durationMilliseconds: alignedDuration
        )
        // Avoid recursive defer double-schedule: apply → scheduleCompanionBehavior
        // already; defer also runs. scheduleCompanionBehavior is idempotent when
        // companionTask != nil, and apply may start a task first — OK.
        apply(reducer.reduce(
            .companionCue(effectiveCue),
            atMilliseconds: monotonicMilliseconds()
        ))
    }

    private func randomExtendedReactionDuration() -> Int64 {
        extendedReactionDurationProvider()
    }

    private func scheduleIdleTimeout() {
        idleTask?.cancel()
        guard model.settings.petEnabled else {
            idleTask = nil
            return
        }
        idleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.idleTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.model.count == 0, self.reducer.activeRunCount == 0 else { return }
                self.apply(self.reducer.reduce(
                    .idleTimeout,
                    atMilliseconds: self.monotonicMilliseconds()
                ))
            }
        }
    }

    private func attentionFilter(_ raw: String) -> PetAttentionFilter {
        switch raw {
        case "completed": return .completed
        case "needsYou": return .needsYou
        default: return .all
        }
    }

    private func monotonicMilliseconds() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
