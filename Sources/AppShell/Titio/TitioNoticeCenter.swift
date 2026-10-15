import CoreModel
import Foundation
import os
import Persistence
import SocketServer

private let titioNoticeLog = Logger(subsystem: "io.remotecode.app", category: "titio-notices")

// MARK: - Seams

/// A cancellable timer from `TitioNoticeScheduling`.
public protocol TitioNoticeTimer: AnyObject, Sendable {
    func cancel()
}

/// Timer seam: production uses `DispatchTitioNoticeScheduler`; tests inject a
/// manual clock so the §4 windows are deterministic.
public protocol TitioNoticeScheduling: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TitioNoticeTimer
}

private final class DispatchTitioNoticeTimer: TitioNoticeTimer, @unchecked Sendable {
    private let item: DispatchWorkItem
    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

public struct DispatchTitioNoticeScheduler: TitioNoticeScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TitioNoticeTimer {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return DispatchTitioNoticeTimer(item: item)
    }
}

/// Titio, its Notifications conversation and that conversation's thread.
public struct TitioInboxTarget: Equatable, Sendable {
    public var botID: BotID
    public var conversationID: BotConversationID
    public var threadID: AgentThreadID

    public init(botID: BotID, conversationID: BotConversationID, threadID: AgentThreadID) {
        self.botID = botID
        self.conversationID = conversationID
        self.threadID = threadID
    }
}

/// The legacy banner (and push) a hook would have posted. Decisions and
/// alerts that cannot post as a Titio message within
/// `TitioNoticeTiming.legacyFallbackAfter` post it instead (fail loud, §3.6).
public struct TitioNoticeLegacyDelivery: Sendable {
    public var content: RemoteCodeNotificationContent
    public var pushes: Bool

    public init(content: RemoteCodeNotificationContent, pushes: Bool) {
        self.content = content
        self.pushes = pushes
    }
}

/// What the pet speech bubble shows for a new notice (stage 4 renders it).
public struct TitioNoticeSpeech: Equatable, Sendable {
    public static let maxCharacters = 90
    public var text: String
    public var urgency: TitioNoticeUrgency
    public var messageID: AgentMessageID
    public var botID: BotID
    public var conversationID: BotConversationID
}

/// The inputs of the §16 language rule.
public struct TitioNoticeLanguageInputs: Sendable {
    public var lastUserText: String?
    public var preferredLanguages: [String]

    public init(lastUserText: String?, preferredLanguages: [String]) {
        self.lastUserText = lastUserText
        self.preferredLanguages = preferredLanguages
    }
}

/// Push binding for the §8 data map. `profileID` comes from
/// `BotAttentionPushBindingStore.unique(hostID:)`.
public struct TitioNoticePushBinding: Sendable, Equatable {
    public var profileID: String?
    public var hostID: String?

    public init(profileID: String?, hostID: String?) {
        self.profileID = profileID
        self.hostID = hostID
    }
}

/// The inbox counters every post publishes (`titio_inbox`, §8).
public struct TitioInboxSnapshot: Equatable, Sendable {
    public var botID: BotID
    public var conversationID: BotConversationID
    public var threadID: AgentThreadID
    public var unreadCount: Int
    public var openDecisions: Int
    public var lastPreview: String?
    public var lastAt: Date?

    /// The `titio_inbox` wire object (`bot.updated`, later `bot.list`).
    public var wireObject: JSONValue {
        var object: [String: JSONValue] = [
            "conversation_id": .string(conversationID.value.uuidString.lowercased()),
            "thread_id": .string(threadID.value.uuidString.lowercased()),
            "unread_count": .number(Double(unreadCount)),
            "open_decisions": .number(Double(openDecisions)),
        ]
        object["last_preview"] = lastPreview.map(JSONValue.string) ?? .null
        object["last_at"] = lastAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
        return .object(object)
    }
}

/// One written (or rewritten) inbox message, after its commit.
public struct TitioNoticePostedMessage: Sendable {
    public var message: AgentMessage
    public var bodyRevision: Int
    public var target: TitioInboxTarget
    /// The conversation row as persisted with its new unread/attention state.
    public var conversation: BotConversation?
    public var isRewrite: Bool
}

/// The outcome of `TitioNoticeCenter.act` (§7). Navigation is answered by the
/// center itself; consequential actions go to the installed executor.
public enum TitioNoticeActOutcome: Equatable, Sendable {
    /// No ledger row owns this message (e.g. a card an LLM wrote itself).
    case notFound
    /// The option index is outside the stored card.
    case invalidOption
    /// A navigation option: the route is the push userInfo shape, so clients
    /// reuse `AppDelegate.routeFromNotification` / iOS `routeIntent(from:)`.
    case navigate(route: [String: String])
    /// The notice was already resolved or claimed.
    case alreadyResolved
    /// Claimed and started; Titio's result message reports the outcome.
    case accepted
    /// No executor is installed for consequential actions yet.
    case unsupported
}

/// Executes a claimed consequential card action (approve, answer, continue…).
/// Installed by the act stage; until then the center answers `.unsupported`
/// and never claims a row it cannot execute.
protocol TitioNoticeActionExecuting: AnyObject, Sendable {
    func execute(record: TitioNoticeRecord, optionIndex: Int, option: TitioNoticeCardOption) async -> TitioNoticeActOutcome
}

/// Every side effect outside the ledger. Production wiring lives in
/// `AppContext.makeTitioNoticeHooks`; tests pass fakes.
public struct TitioNoticeHooks: Sendable {
    /// Ensures Titio, its inbox conversation and thread. Nil while one of them
    /// cannot be created (the rows stay pending and retry with backoff).
    public var resolveInbox: @Sendable (TitioNoticeLanguage) async -> TitioInboxTarget?
    /// The Mac desk shows the inbox and its window is key.
    public var isInboxViewed: @Sendable (TitioInboxTarget) async -> Bool
    /// A Titio run is active in the inbox thread (info waits, §4).
    public var isTitioRunActive: @Sendable (TitioInboxTarget) -> Bool
    public var languageInputs: @Sendable () -> TitioNoticeLanguageInputs
    /// `agent.message.appended`, the desk repaint and the peer projection.
    public var messagePosted: @Sendable (TitioNoticePostedMessage) async -> Void
    /// `bot.updated` for Titio with `titio_inbox`.
    public var inboxChanged: @Sendable (TitioInboxSnapshot) async -> Void
    /// Mac banner (`SystemNotifier.post`).
    public var postBanner: @Sendable (RemoteCodeNotificationContent) -> Void
    /// iOS push (`PrivateNotificationBridge.deliver`).
    public var deliverPush: @Sendable (RemoteCodeNotificationContent) async -> Void
    public var pushBinding: @Sendable () -> TitioNoticePushBinding
    /// Workspace display name for pet/terminal events (MainActor state).
    public var workspaceName: @Sendable (WorkspaceID) async -> String?
    /// A successful pet/terminal event whose destination the user is looking
    /// at (`PetAttentionFocusPolicy`): no notice (§2). Failures never are.
    public var isFocusedSuccess: @Sendable (EventBus.Event) async -> Bool

    public init(
        resolveInbox: @escaping @Sendable (TitioNoticeLanguage) async -> TitioInboxTarget?,
        isInboxViewed: @escaping @Sendable (TitioInboxTarget) async -> Bool = { _ in false },
        isTitioRunActive: @escaping @Sendable (TitioInboxTarget) -> Bool = { _ in false },
        languageInputs: @escaping @Sendable () -> TitioNoticeLanguageInputs = {
            TitioNoticeLanguageInputs(lastUserText: nil, preferredLanguages: Locale.preferredLanguages)
        },
        messagePosted: @escaping @Sendable (TitioNoticePostedMessage) async -> Void = { _ in },
        inboxChanged: @escaping @Sendable (TitioInboxSnapshot) async -> Void = { _ in },
        postBanner: @escaping @Sendable (RemoteCodeNotificationContent) -> Void = { _ in },
        deliverPush: @escaping @Sendable (RemoteCodeNotificationContent) async -> Void = { _ in },
        pushBinding: @escaping @Sendable () -> TitioNoticePushBinding = { TitioNoticePushBinding(profileID: nil, hostID: nil) },
        workspaceName: @escaping @Sendable (WorkspaceID) async -> String? = { _ in nil },
        isFocusedSuccess: @escaping @Sendable (EventBus.Event) async -> Bool = { _ in false }
    ) {
        self.resolveInbox = resolveInbox
        self.isInboxViewed = isInboxViewed
        self.isTitioRunActive = isTitioRunActive
        self.languageInputs = languageInputs
        self.messagePosted = messagePosted
        self.inboxChanged = inboxChanged
        self.postBanner = postBanner
        self.deliverPush = deliverPush
        self.pushBinding = pushBinding
        self.workspaceName = workspaceName
        self.isFocusedSuccess = isFocusedSuccess
    }
}

// MARK: - Center

/// Titio's notice hub (hub spec §3–§6): ledger ingest, the urgency scheduler,
/// one-transaction flush into the inbox conversation, post-commit fan-out
/// (event, desk, `bot.updated`, banner, push, pet speech), startup catch-up,
/// backoff with the legacy fallback, source resolution and retention.
///
/// Every command runs in arrival order on this actor (a single consumer of an
/// `AsyncStream`), so a resolution can never overtake the ingest it resolves,
/// and the ledger's SQLite work never runs on the MainActor. Only the hooks
/// hop to the MainActor (desk repaint, inbox resolution, pet).
public actor TitioNoticeCenter {
    enum Command {
        case ingest(TitioNoticeFact, TitioNoticeLegacyDelivery?)
        case sourceResolved(String, TitioNoticeResolution)
        case startup
        case timer(TimerID)
        case markRead
        case directReply(DirectReply)
        case botAttentionChanged
        case petEvent(EventBus.Event)
        case barrier(CheckedContinuation<Void, Never>)
    }

    enum TimerID: Hashable {
        case info(UInt64)
        case flap(String, UInt64)
        case retry(UInt64)
        case fallback(String, UInt64)
        case attention(UInt64)
    }

    struct DirectReply: Sendable {
        var botID: BotID
        var conversationID: BotConversationID
        var runID: AgentRunID
        var text: String
        var messageID: AgentMessageID?
    }

    // Dependencies
    private let repo: TitioNoticeRepository
    private let messageRepo: AgentMessageRepository
    private let botStore: BotStore
    private let hooks: TitioNoticeHooks
    private let scheduler: TitioNoticeScheduling
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private nonisolated let continuation: AsyncStream<Command>.Continuation
    private nonisolated let startedBox = TitioNoticeLockedBox(false)
    private nonisolated let speechBox = TitioNoticeLockedBox<(@Sendable (TitioNoticeSpeech) -> Void)?>(nil)
    private nonisolated let executorBox = TitioNoticeLockedBox<TitioNoticeActionExecuting?>(nil)
    private nonisolated let eventSubscription = TitioNoticeLockedBox<UUID?>(nil)

    // Scheduler state (actor-isolated)
    private var cachedTarget: TitioInboxTarget?
    private var infoKeys: [String] = []
    private var infoFirstAt: Date?
    private var infoGeneration: UInt64 = 0
    private var infoTimer: TitioNoticeTimer?
    private var holdStartedAt: Date?
    private var flapTimers: [String: (UInt64, TitioNoticeTimer)] = [:]
    private var retryAttempt = 0
    private var retryGeneration: UInt64 = 0
    private var retryTimer: TitioNoticeTimer?
    private var legacy: [String: TitioNoticeLegacyDelivery] = [:]
    private var fallbackTimers: [String: (UInt64, TitioNoticeTimer)] = [:]
    private var fallbackPosted = Set<String>()
    private var attentionGeneration: UInt64 = 0
    private var attentionTimer: TitioNoticeTimer?
    private var timerSerial: UInt64 = 0

    /// The events that re-run the bot-attention projector (§5).
    static let botAttentionEventKinds: Set<String> = ["bots.attention.changed", "bot.attention.updated"]
    /// Debounce for the bot-attention projector (§5).
    static let attentionDebounce: TimeInterval = 0.15
    /// While a Titio run holds info, re-check this often (capped by `titioRunHold`).
    static let holdPollInterval: TimeInterval = 2

    public init(
        db: SQLiteDB,
        botStore: BotStore,
        hooks: TitioNoticeHooks,
        scheduler: TitioNoticeScheduling = DispatchTitioNoticeScheduler(),
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.repo = TitioNoticeRepository(db: db)
        self.messageRepo = AgentMessageRepository(db: db)
        self.botStore = botStore
        self.hooks = hooks
        self.scheduler = scheduler
        self.now = now
        self.timeZone = timeZone
        var made: AsyncStream<Command>.Continuation!
        let stream = AsyncStream<Command>(bufferingPolicy: .unbounded) { made = $0 }
        self.continuation = made
        Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.handle(command)
            }
        }
    }

    deinit {
        continuation.finish()
        if let id = eventSubscription.value { EventBus.shared.unsubscribe(id) }
    }

    // MARK: Public entry points (nonisolated, ordered)

    /// The §5 hook gate: the hub delivers only once started (app launch) and
    /// while the kill switch is on. Otherwise every hook keeps today's code.
    public nonisolated func isEnabled(_ settings: AppSettings) -> Bool {
        startedBox.value && settings.titioNotificationsEnabled
    }

    public nonisolated var isStarted: Bool { startedBox.value }

    /// Starts delivery: catch-up flush, banner re-post, retention, and the
    /// EventBus subscriptions (pet/terminal events, bot attention).
    public nonisolated func start(subscribeToEvents: Bool = true) {
        guard startedBox.exchange(true) == false else { return }
        if subscribeToEvents {
            let kinds = PetController.potentialProjectionKinds.union(Self.botAttentionEventKinds)
            let id = EventBus.shared.subscribeFromCurrent { [weak self] event in
                guard kinds.contains(event.kind) else { return }
                self?.handleEvent(event)
            }.id
            eventSubscription.value = id
        }
        continuation.yield(.startup)
        continuation.yield(.botAttentionChanged)
    }

    public nonisolated func ingest(_ fact: TitioNoticeFact, legacy: TitioNoticeLegacyDelivery? = nil) {
        continuation.yield(.ingest(fact, legacy))
    }

    /// The source resolved on its own (§6): a pending row is dropped (a
    /// flap-held alert as `flap`); a posted row is resolved and its message
    /// rewritten in place with a status line (no new message).
    public nonisolated func sourceResolved(key: String, reason: TitioNoticeResolution = .elsewhere) {
        continuation.yield(.sourceResolved(key, reason))
    }

    /// Titio's own reply: only a direct banner/push (title "Titio", body =
    /// first line of the reply), never a notice (§2).
    public nonisolated func postDirectReplyBanner(
        botID: BotID,
        conversationID: BotConversationID,
        runID: AgentRunID,
        text: String,
        messageID: AgentMessageID?
    ) {
        continuation.yield(.directReply(DirectReply(
            botID: botID, conversationID: conversationID, runID: runID, text: text, messageID: messageID
        )))
    }

    /// The inbox was opened on the Mac: unread count to 0, conversation read.
    public nonisolated func markInboxRead() {
        continuation.yield(.markRead)
    }

    /// Pet speech dispatch (stage 4 wires the pet).
    public nonisolated func setOnSpeech(_ handler: (@Sendable (TitioNoticeSpeech) -> Void)?) {
        speechBox.value = handler
    }

    nonisolated func installActionExecutor(_ executor: TitioNoticeActionExecuting?) {
        executorBox.value = executor
    }

    nonisolated func handleEvent(_ event: EventBus.Event) {
        if Self.botAttentionEventKinds.contains(event.kind) {
            continuation.yield(.botAttentionChanged)
        } else {
            continuation.yield(.petEvent(event))
        }
    }

    /// Waits until every command sent before this call has been handled.
    public func idle() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            continuation.yield(.barrier(waiter))
        }
    }

    /// A card tap (§7 steps 1–2). Navigation answers here without changing
    /// state; consequential actions go to the installed executor, which claims
    /// the row itself. Without an executor nothing is claimed (`unsupported`).
    public func act(messageID: String, optionIndex: Int) async -> TitioNoticeActOutcome {
        let record: TitioNoticeRecord?
        do {
            record = try repo.notice(messageID: messageID.uppercased()) ?? repo.notice(messageID: messageID)
        } catch {
            titioNoticeLog.error("titio.notice.act_lookup_failed error=\(String(describing: error), privacy: .public)")
            return .notFound
        }
        guard let record, let options = record.actions else { return .notFound }
        guard options.indices.contains(optionIndex) else { return .invalidOption }
        let option = options[optionIndex]
        if option.action.isNavigation {
            return .navigate(route: Self.navigationRoute(for: option.action, record: record, target: cachedTarget))
        }
        switch record.state {
        case .posted, .awaitingReply: break
        case .pending, .acting, .resolved, .dropped: return .alreadyResolved
        }
        guard let executor = executorBox.value else { return .unsupported }
        return await executor.execute(record: record, optionIndex: optionIndex, option: option)
    }

    // MARK: Command handling

    private func handle(_ command: Command) async {
        switch command {
        case .ingest(let fact, let legacyDelivery):
            await handleIngest(fact, legacy: legacyDelivery)
        case .sourceResolved(let key, let reason):
            await handleSourceResolved(key: key, reason: reason)
        case .startup:
            await handleStartup()
        case .timer(let id):
            await handleTimer(id)
        case .markRead:
            await handleMarkRead()
        case .directReply(let reply):
            await handleDirectReply(reply)
        case .botAttentionChanged:
            scheduleAttentionPass()
        case .petEvent(let event):
            await handlePetEvent(event)
        case .barrier(let waiter):
            waiter.resume()
        }
    }

    private func handleIngest(_ fact: TitioNoticeFact, legacy legacyDelivery: TitioNoticeLegacyDelivery?) async {
        let record: TitioNoticeRecord?
        do {
            record = try repo.ingest(fact)
        } catch {
            titioNoticeLog.error("titio.notice.ingest_failed key=\(fact.key, privacy: .public) error=\(String(describing: error), privacy: .public)")
            if let legacyDelivery { await postLegacy(key: fact.key, legacyDelivery) }
            return
        }
        // A replay or a second producer of an already posted notice is a no-op.
        guard let record, record.state == .pending else { return }
        if let legacyDelivery, record.urgency != .info { legacy[record.key] = legacyDelivery }
        switch record.urgency {
        case .decision:
            await flushInfo(force: true)
            _ = await flush(keys: [record.key], catchUp: false)
        case .alert:
            if record.kind.usesFlapHold {
                armFlapHold(key: record.key)
            } else {
                _ = await flush(keys: [record.key], catchUp: false)
            }
        case .info:
            if !infoKeys.contains(record.key) { infoKeys.append(record.key) }
            if infoFirstAt == nil { infoFirstAt = now() }
            armInfoWindow()
        }
    }

    private func handleTimer(_ id: TimerID) async {
        switch id {
        case .info(let generation):
            guard generation == infoGeneration else { return }
            await flushInfo(force: false)
        case .flap(let key, let generation):
            guard flapTimers[key]?.0 == generation else { return }
            flapTimers[key] = nil
            _ = await flush(keys: [key], catchUp: false)
        case .retry(let generation):
            guard generation == retryGeneration else { return }
            retryTimer = nil
            await retryPending()
        case .fallback(let key, let generation):
            guard fallbackTimers[key]?.0 == generation else { return }
            fallbackTimers[key] = nil
            guard let row = try? repo.get(key: key), row.state == .pending,
                  let delivery = legacy[key] else { return }
            await postLegacy(key: key, delivery)
        case .attention(let generation):
            guard generation == attentionGeneration else { return }
            attentionTimer = nil
            await runAttentionPass()
        }
    }

    // MARK: Scheduling (§4)

    private func nextSerial() -> UInt64 {
        timerSerial &+= 1
        return timerSerial
    }

    private func schedule(_ delay: TimeInterval, _ id: TimerID) -> TitioNoticeTimer {
        let continuation = continuation
        return scheduler.schedule(after: delay) { continuation.yield(.timer(id)) }
    }

    /// One global sliding window: each info item pushes the flush to
    /// `infoWindow` from now, never past `infoMaxWait` from the first item.
    private func armInfoWindow() {
        guard let first = infoFirstAt else { return }
        let current = now()
        let deadline = min(current.addingTimeInterval(TitioNoticeTiming.infoWindow),
                           first.addingTimeInterval(TitioNoticeTiming.infoMaxWait))
        infoTimer?.cancel()
        infoGeneration = nextSerial()
        infoTimer = schedule(max(0, deadline.timeIntervalSince(current)), .info(infoGeneration))
    }

    private func armFlapHold(key: String) {
        flapTimers[key]?.1.cancel()
        let generation = nextSerial()
        flapTimers[key] = (generation, schedule(TitioNoticeTiming.flapHold, .flap(key, generation)))
    }

    /// Flushes the pending info batch. Unless forced (a decision is about to
    /// post), info waits up to `titioRunHold` while a Titio run is active.
    private func flushInfo(force: Bool) async {
        guard !infoKeys.isEmpty else { return }
        if !force, let target = cachedTarget, hooks.isTitioRunActive(target) {
            let current = now()
            let started = holdStartedAt ?? current
            holdStartedAt = started
            let remaining = TitioNoticeTiming.titioRunHold - current.timeIntervalSince(started)
            if remaining > 0 {
                infoTimer?.cancel()
                infoGeneration = nextSerial()
                infoTimer = schedule(min(Self.holdPollInterval, remaining), .info(infoGeneration))
                return
            }
        }
        holdStartedAt = nil
        let keys = infoKeys
        infoKeys = []
        infoFirstAt = nil
        infoTimer?.cancel()
        infoTimer = nil
        infoGeneration = nextSerial()
        _ = await flush(keys: keys, catchUp: false)
    }

    // MARK: Flush (§3 steps 3–4)

    private func language() -> TitioNoticeLanguage {
        let inputs = hooks.languageInputs()
        return TitioNoticeCopy.language(lastUserText: inputs.lastUserText, preferredLanguages: inputs.preferredLanguages)
    }

    /// The cached inbox target if its conversation still links the same
    /// thread; otherwise resolves it again (recreating a deleted inbox).
    private func target(language: TitioNoticeLanguage) async -> TitioInboxTarget? {
        if let cachedTarget,
           let conversation = try? botStore.conversation(id: cachedTarget.conversationID),
           conversation.linkedAgentThreadID == cachedTarget.threadID {
            return cachedTarget
        }
        cachedTarget = nil
        let resolved = await hooks.resolveInbox(language)
        cachedTarget = resolved
        return resolved
    }

    /// Posts `keys` (those still pending) as one message. Returns false when
    /// the inbox is unavailable or the write failed (rows stay pending).
    @discardableResult
    private func flush(keys: [String], catchUp: Bool) async -> Bool {
        guard !keys.isEmpty else { return true }
        let language = language()
        guard let target = await target(language: language) else {
            titioNoticeLog.info("titio.notice.inbox_unavailable keys=\(keys.count, privacy: .public)")
            armFallbacks(keys)
            scheduleRetry()
            return false
        }
        let viewing = await hooks.isInboxViewed(target)
        let postedAt = now()
        var written: AgentMessage?
        let result: TitioNoticeFlushResult?
        do {
            result = try repo.flush(keys: keys, postedAt: postedAt) { rows in
                let items = rows.map(TitioNoticeRenderItem.init(record:))
                guard let composed = TitioNoticeCopy.composeBatch(items, language: language, catchUp: catchUp, timeZone: timeZone) else {
                    return nil
                }
                let uuid = rows.count == 1
                    ? TitioNoticeIDs.messageID(forKey: rows[0].key)
                    : TitioNoticeIDs.digestMessageID(forKeys: rows.map(\.key))
                let message = AgentMessage(
                    id: AgentMessageID(uuid),
                    threadId: target.threadID,
                    role: .assistant,
                    content: composed.text,
                    createdAt: postedAt
                )
                try messageRepo.append(message)
                written = message
                return TitioNoticePosting(
                    messageID: uuid.uuidString,
                    batchID: rows.count > 1 ? uuid.uuidString : nil,
                    cardOwnerKey: composed.cardOwnerKey,
                    cardOptions: composed.cardOptions,
                    preview: composed.preview,
                    countsAsUnread: !viewing
                )
            }
        } catch {
            titioNoticeLog.error("titio.notice.flush_failed keys=\(keys.count, privacy: .public) error=\(String(describing: error), privacy: .public)")
            cachedTarget = nil
            armFallbacks(keys)
            scheduleRetry()
            return false
        }
        retryAttempt = 0
        guard let result, let message = written else { return true }
        for record in result.records {
            legacy[record.key] = nil
            fallbackTimers.removeValue(forKey: record.key)?.1.cancel()
        }
        await fanOut(result, message: message, target: target, viewing: viewing)
        return true
    }

    /// Post-commit effects, in the §3 step 4 order.
    private func fanOut(_ result: TitioNoticeFlushResult, message: AgentMessage, target: TitioInboxTarget, viewing: Bool) async {
        let revision = ((try? messageRepo.bodyRevision(id: message.id)) ?? nil) ?? 1
        let openDecisions = (try? repo.openDecisionCount()) ?? 0
        let conversation = persistConversation(target: target, viewing: viewing, openDecisions: openDecisions, at: message.createdAt)
        await hooks.messagePosted(TitioNoticePostedMessage(
            message: message, bodyRevision: revision, target: target, conversation: conversation, isRewrite: false
        ))
        await hooks.inboxChanged(snapshot(target: target, inbox: result.inbox, openDecisions: openDecisions))
        let keys = result.records.map(\.key)
        // `pet.notifications.denied` is in-app only: no banner, no push.
        if !result.records.allSatisfy({ $0.kind == .notificationsDenied }) {
            let identifier = result.records.count == 1
                ? result.records[0].key
                : TitioNoticeIDs.digestBannerIdentifier(messageID: message.id.value)
            deliver(identifier: identifier, text: message.content, message: message, target: target,
                    noticeKey: result.posting.cardOwnerKey ?? (result.records.count == 1 ? result.records[0].key : nil),
                    records: result.records)
        }
        do { try repo.markBanner(keys: keys, at: now()) } catch {
            titioNoticeLog.error("titio.notice.mark_banner_failed error=\(String(describing: error), privacy: .public)")
        }
        if let speak = speechBox.value {
            let urgency: TitioNoticeUrgency = result.records.contains { $0.urgency == .decision } ? .decision
                : result.records.contains { $0.urgency == .alert } ? .alert : .info
            speak(TitioNoticeSpeech(
                text: Self.clip(result.posting.preview, max: TitioNoticeSpeech.maxCharacters),
                urgency: urgency,
                messageID: message.id,
                botID: target.botID,
                conversationID: target.conversationID
            ))
        }
    }

    /// Banner + push with the same identifier (the relay deduplicates re-posts).
    private func deliver(
        identifier: String,
        text: String,
        message: AgentMessage,
        target: TitioInboxTarget,
        noticeKey: String?,
        records: [TitioNoticeRecord]
    ) {
        let binding = hooks.pushBinding()
        let legacyKeys = Self.legacyRouteKeys(records)
        let conversation = target.conversationID.value.uuidString.lowercased()
        let messageID = message.id.value.uuidString.lowercased()
        let bot = target.botID.value.uuidString.lowercased()
        let bannerInfo = RemoteCodeNotificationContent.titioNoticeUserInfo(
            botID: bot, conversationID: conversation, messageID: messageID, noticeKey: noticeKey,
            identifier: identifier, profileID: binding.profileID, hostID: binding.hostID,
            legacy: legacyKeys, includeBotIdWithoutProfile: true
        )
        let pushInfo = RemoteCodeNotificationContent.titioNoticeUserInfo(
            botID: bot, conversationID: conversation, messageID: messageID, noticeKey: noticeKey,
            identifier: identifier, profileID: binding.profileID, hostID: binding.hostID,
            legacy: legacyKeys
        )
        hooks.postBanner(RemoteCodeNotificationContent.titioNotice(identifier: identifier, body: text, userInfo: bannerInfo))
        let push = RemoteCodeNotificationContent.titioNotice(identifier: identifier, body: text, userInfo: pushInfo)
        let deliverPush = hooks.deliverPush
        Task { await deliverPush(push) }
    }

    /// Writes the inbox conversation's unread/attention state off the MainActor
    /// (§8): unread unless viewed; needs-attention while decisions are open.
    private func persistConversation(target: TitioInboxTarget, viewing: Bool, openDecisions: Int, at date: Date) -> BotConversation? {
        guard var conversation = try? botStore.conversation(id: target.conversationID) else { return nil }
        conversation.unread = !viewing
        if openDecisions > 0 {
            conversation.attentionState = .needsAttention
        } else {
            conversation.attentionState = viewing ? .none : .unreadActivity
        }
        conversation.updatedAt = date
        do {
            try botStore.upsertConversation(conversation)
        } catch {
            titioNoticeLog.error("titio.notice.conversation_update_failed error=\(String(describing: error), privacy: .public)")
        }
        return conversation
    }

    private func snapshot(target: TitioInboxTarget, inbox: TitioInboxState, openDecisions: Int) -> TitioInboxSnapshot {
        TitioInboxSnapshot(
            botID: target.botID,
            conversationID: target.conversationID,
            threadID: target.threadID,
            unreadCount: inbox.unreadCount,
            openDecisions: openDecisions,
            lastPreview: inbox.lastPreview,
            lastAt: inbox.lastAt
        )
    }

    // MARK: Failure handling (§3 step 6)

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let backoff = TitioNoticeTiming.retryBackoff
        let delay = backoff[min(retryAttempt, backoff.count - 1)]
        retryAttempt += 1
        retryGeneration = nextSerial()
        retryTimer = schedule(delay, .retry(retryGeneration))
    }

    /// Decisions and alerts due now that cannot post get the legacy
    /// banner/push after `legacyFallbackAfter` (once per key).
    private func armFallbacks(_ keys: [String]) {
        for key in keys where legacy[key] != nil && fallbackTimers[key] == nil && !fallbackPosted.contains(key) {
            let generation = nextSerial()
            fallbackTimers[key] = (generation, schedule(TitioNoticeTiming.legacyFallbackAfter, .fallback(key, generation)))
        }
    }

    private func postLegacy(key: String, _ delivery: TitioNoticeLegacyDelivery) async {
        guard fallbackPosted.insert(key).inserted else { return }
        titioNoticeLog.error("titio.notice.fallback key=\(key, privacy: .public)")
        hooks.postBanner(delivery.content)
        if delivery.pushes {
            let deliverPush = hooks.deliverPush
            let content = delivery.content
            Task { await deliverPush(content) }
        }
    }

    /// Retries every pending row: decisions one by one (each keeps its card),
    /// the rest as one batch. Info rows in the live window stay there.
    private func retryPending() async {
        if !(await warmTarget()) { return }
        guard let pending = try? repo.listPending() else { scheduleRetry(); return }
        let waiting = Set(infoKeys).union(flapTimers.keys)
        let rows = pending.filter { !waiting.contains($0.key) }
        guard !rows.isEmpty else { return }
        for row in rows where row.urgency == .decision {
            guard await flush(keys: [row.key], catchUp: false) else { return }
        }
        let others = rows.filter { $0.urgency != .decision }
        for row in others where row.urgency == .alert {
            guard await flush(keys: [row.key], catchUp: false) else { return }
        }
        let info = others.filter { $0.urgency == .info }.map(\.key)
        if !info.isEmpty { _ = await flush(keys: info, catchUp: false) }
    }

    /// Binds an inbox that already exists (so opening it marks it read and
    /// the desk knows it) without creating one. False while it exists but
    /// cannot be resolved yet; a retry is then scheduled.
    private func warmTarget() async -> Bool {
        guard cachedTarget == nil,
              let existing = try? repo.inboxState(), existing.conversationID != nil else { return true }
        if await target(language: language()) != nil { return true }
        scheduleRetry()
        return false
    }

    // MARK: Startup (§3 steps 5, 7)

    private func handleStartup() async {
        let current = now()
        do {
            let pruned = try repo.prune(endedBefore: current.addingTimeInterval(-TitioNoticeTiming.retention))
            if pruned > 0 { titioNoticeLog.info("titio.notice.pruned count=\(pruned, privacy: .public)") }
        } catch {
            titioNoticeLog.error("titio.notice.prune_failed error=\(String(describing: error), privacy: .public)")
        }
        await repostMissingBanners(now: current)
        guard let pending = try? repo.listPending(), !pending.isEmpty else {
            _ = await warmTarget()
            return
        }
        // Decisions keep their own card; everything else is one catch-up batch.
        for row in pending where row.urgency == .decision {
            guard await flush(keys: [row.key], catchUp: false) else { return }
        }
        let others = pending.filter { $0.urgency != .decision }.map(\.key)
        if !others.isEmpty {
            _ = await flush(keys: others, catchUp: others.count >= 2)
        }
    }

    /// A crash between commit and banner: re-post with the same identifier
    /// (the relay and `SystemNotifier` deduplicate), never a second message.
    private func repostMissingBanners(now current: Date) async {
        guard let rows = try? repo.rowsNeedingBannerRepost(now: current), !rows.isEmpty else { return }
        let grouped = Dictionary(grouping: rows) { $0.messageID ?? "" }
        for (messageID, records) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let uuid = UUID(uuidString: messageID) else { continue }
            let keys = records.map(\.key)
            defer { try? repo.markBanner(keys: keys, at: current) }
            guard !records.allSatisfy({ $0.kind == .notificationsDenied }),
                  let message = try? messageRepo.get(id: AgentMessageID(uuid)),
                  let target = await target(language: language()),
                  message.threadId == target.threadID else { continue }
            let allInBatch = (try? repo.notices(messageID: messageID)) ?? records
            let identifier = allInBatch.count == 1 ? allInBatch[0].key : TitioNoticeIDs.digestBannerIdentifier(messageID: uuid)
            let owner = allInBatch.first { $0.actions != nil }?.key ?? (allInBatch.count == 1 ? allInBatch[0].key : nil)
            deliver(identifier: identifier, text: message.content, message: message, target: target,
                    noticeKey: owner, records: allInBatch)
        }
    }

    // MARK: Source resolution (§6)

    private func handleSourceResolved(key: String, reason: TitioNoticeResolution) async {
        flapTimers.removeValue(forKey: key)?.1.cancel()
        fallbackTimers.removeValue(forKey: key)?.1.cancel()
        infoKeys.removeAll { $0 == key }
        if infoKeys.isEmpty { infoFirstAt = nil }
        legacy[key] = nil
        let current = now()
        do {
            guard let row = try repo.get(key: key) else { return }
            if row.state == .pending {
                _ = try repo.drop(key: key, resolution: row.kind.usesFlapHold ? .flap : reason, at: current)
                return
            }
            guard case .resolved(let record) = try repo.resolveFromSource(key: key, resolution: reason, at: current) else { return }
            await rewrite(record, at: current)
        } catch {
            titioNoticeLog.error("titio.notice.source_resolve_failed key=\(key, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Rewrites the original message: strips its choices block and appends
    /// the status line. A digest message is rewritten only by its card owner.
    /// A message that transcript retention already removed is left removed
    /// (an upsert would resurrect it as a new row).
    private func rewrite(_ record: TitioNoticeRecord, at date: Date) async {
        guard let raw = record.messageID, let uuid = UUID(uuidString: raw),
              let resolution = record.resolution,
              let status = TitioNoticeStatus(resolution: resolution),
              record.batchID == nil || record.actions != nil else { return }
        let id = AgentMessageID(uuid)
        guard let original = try? messageRepo.get(id: id) else {
            titioNoticeLog.info("titio.notice.rewrite_skipped_missing key=\(record.key, privacy: .public)")
            return
        }
        let messageLanguage = TitioNoticeCopy.detectedLanguage(original.content) ?? language()
        let text = TitioNoticeCopy.resolvedText(
            original: original.content,
            statusLine: TitioNoticeCopy.statusLine(status, language: messageLanguage, at: date, timeZone: timeZone)
        )
        guard text != original.content else { return }
        let updated = AgentMessage(
            id: original.id, threadId: original.threadId, role: original.role,
            content: text, createdAt: original.createdAt, attachments: original.attachments
        )
        do { try messageRepo.append(updated) } catch {
            titioNoticeLog.error("titio.notice.rewrite_failed key=\(record.key, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        let revision = ((try? messageRepo.bodyRevision(id: id)) ?? nil) ?? 1
        var resolvedTarget = cachedTarget
        if resolvedTarget == nil { resolvedTarget = await target(language: messageLanguage) }
        guard let target = resolvedTarget, target.threadID == original.threadId else { return }
        let openDecisions = (try? repo.openDecisionCount()) ?? 0
        let conversation = settleAttention(target: target, openDecisions: openDecisions)
        await hooks.messagePosted(TitioNoticePostedMessage(
            message: updated, bodyRevision: revision, target: target, conversation: conversation, isRewrite: true
        ))
        if let inbox = try? repo.inboxState() {
            await hooks.inboxChanged(snapshot(target: target, inbox: inbox, openDecisions: openDecisions))
        }
    }

    /// After a resolution: needs-attention clears once no decision is open.
    private func settleAttention(target: TitioInboxTarget, openDecisions: Int) -> BotConversation? {
        guard var conversation = try? botStore.conversation(id: target.conversationID) else { return nil }
        guard openDecisions == 0, conversation.attentionState == .needsAttention else { return conversation }
        conversation.attentionState = conversation.unread ? .unreadActivity : .none
        try? botStore.upsertConversation(conversation)
        return conversation
    }

    // MARK: Read state (§8)

    private func handleMarkRead() async {
        guard let target = cachedTarget else { return }
        do {
            let inbox = try repo.updateInboxState { $0.unreadCount = 0 }
            let openDecisions = (try? repo.openDecisionCount()) ?? 0
            if var conversation = try botStore.conversation(id: target.conversationID) {
                conversation.unread = false
                if openDecisions == 0, conversation.attentionState != .working { conversation.attentionState = .none }
                try botStore.upsertConversation(conversation)
            }
            await hooks.inboxChanged(snapshot(target: target, inbox: inbox, openDecisions: openDecisions))
        } catch {
            titioNoticeLog.error("titio.notice.mark_read_failed error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Direct reply banner (§2)

    private func handleDirectReply(_ reply: DirectReply) async {
        let banner = TitioNoticeCopy.directReplyBanner(replyText: reply.text)
        guard !banner.body.isEmpty else { return }
        let identifier = "titio.reply.\(reply.runID.value.uuidString)"
        let binding = hooks.pushBinding()
        let messageID = (reply.messageID?.value ?? reply.runID.value).uuidString.lowercased()
        func info(includeBot: Bool) -> [String: String] {
            RemoteCodeNotificationContent.titioNoticeUserInfo(
                botID: reply.botID.value.uuidString.lowercased(),
                conversationID: reply.conversationID.value.uuidString.lowercased(),
                messageID: messageID, noticeKey: nil, identifier: identifier,
                profileID: binding.profileID, hostID: binding.hostID,
                includeBotIdWithoutProfile: includeBot
            )
        }
        hooks.postBanner(RemoteCodeNotificationContent.titioNotice(identifier: identifier, body: banner.body, userInfo: info(includeBot: true)))
        let push = RemoteCodeNotificationContent.titioNotice(identifier: identifier, body: banner.body, userInfo: info(includeBot: false))
        let deliverPush = hooks.deliverPush
        Task { await deliverPush(push) }
    }

    // MARK: Pet / terminal events (§5)

    private func handlePetEvent(_ event: EventBus.Event) async {
        guard case .object(let payload) = event.payload else { return }
        // Resolutions first: they never classify as a notice.
        if event.kind == "ssh.session.updated",
           payload["status"]?.stringValue == "connected" || payload["reason"]?.stringValue == "user_requested",
           let surface = payload["surface_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            await handleSourceResolved(key: TitioNoticeIDs.petSSHDisconnect(surfaceId: surface.uuidString), reason: .elsewhere)
            return
        }
        if ["files.edit.saved", "files.edit.discarded", "files.edit.closed"].contains(event.kind),
           let session = payload["session_id"]?.stringValue, !session.isEmpty {
            await handleSourceResolved(key: TitioNoticeIDs.petFileConflict(sessionId: session), reason: .elsewhere)
            return
        }
        guard let terminal = PetTerminalNotificationRecorder.classify(event),
              let mapped = Self.noticeKind(for: terminal.kind) else { return }
        if !mapped.isFailure, mapped.defaultUrgency == .info, await hooks.isFocusedSuccess(event) { return }
        let key: String
        switch terminal.kind {
        case .sshUnexpectedDisconnect:
            guard let surface = terminal.surfaceID else { return }
            key = TitioNoticeIDs.petSSHDisconnect(surfaceId: surface.value.uuidString)
        case .fileConflict:
            guard let session = payload["session_id"]?.stringValue, !session.isEmpty else { return }
            key = TitioNoticeIDs.petFileConflict(sessionId: session)
        default:
            key = TitioNoticeIDs.petEvent(sequence: terminal.sequence)
        }
        let workspaceName: String?
        if let workspace = terminal.workspaceID {
            workspaceName = await hooks.workspaceName(workspace)
        } else {
            workspaceName = nil
        }
        let facts = TitioNoticeFacts(
            title: Self.petTitle(payload: payload),
            workspaceName: workspaceName,
            exitCode: payload["exit_code"]?.intValue,
            durationMs: payload["duration_ms"]?.intValue
        )
        let fact = TitioNoticeFact(
            key: key,
            kind: mapped,
            source: TitioNoticeSource(workspaceId: terminal.workspaceID?.value.uuidString),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: mapped, facts: facts),
            occurredAt: terminal.createdAt
        )
        await handleIngest(fact, legacy: nil)
    }

    static func noticeKind(for kind: PetTerminalNotificationKind) -> TitioNoticeKind? {
        switch kind {
        case .gitDelivery(.succeeded): return .gitCompleted
        case .gitDelivery(.failed): return .gitFailed
        case .projectScript(.succeeded): return .scriptCompleted
        case .projectScript(.failed): return .scriptFailed
        case .sshTransfer(.succeeded): return .transferCompleted
        case .sshTransfer(.failed): return .transferFailed
        case .sshUnexpectedDisconnect: return .sshDisconnected
        case .providerUpdateFailed: return .providerUpdateFailed
        case .fileConflict: return .fileConflict
        }
    }

    /// The best human name an event payload carries (script name, file,
    /// provider, transfer direction…); nil when it has none.
    static func petTitle(payload: [String: JSONValue]) -> String? {
        for key in ["name", "title", "file_name", "host"] {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        if let path = payload["path"]?.stringValue, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        if let provider = payload["provider"]?.stringValue, !provider.isEmpty {
            return provider
        }
        return nil
    }

    // MARK: Bot attention projector (§5)

    private func scheduleAttentionPass() {
        attentionTimer?.cancel()
        attentionGeneration = nextSerial()
        attentionTimer = schedule(Self.attentionDebounce, .attention(attentionGeneration))
    }

    private func runAttentionPass() async {
        let items: [BotAttentionItem]
        let bots: [BotID: BotDefinition]
        let openBotKeys: Set<String>
        let openThreadKeys: Set<String>
        do {
            items = try botStore.listAttention()
            bots = Dictionary(try botStore.list(includeHidden: true).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            openBotKeys = try repo.openKeys(prefix: "bot.attention.")
            openThreadKeys = try repo.openKeys(prefix: "thread.")
        } catch {
            titioNoticeLog.error("titio.notice.attention_pass_failed error=\(String(describing: error), privacy: .public)")
            return
        }
        let plan = Self.attentionPlan(
            items: items, bots: bots, openBotKeys: openBotKeys, openThreadKeys: openThreadKeys,
            linkedThread: { [botStore] id in (try? botStore.conversation(id: id))?.linkedAgentThreadID }
        )
        for key in plan.resolved {
            await handleSourceResolved(key: key, reason: .elsewhere)
        }
        for candidate in plan.ingest {
            let options: [String]?
            if candidate.kind == .botQuestion, let thread = candidate.threadID {
                options = latestChoices(thread: thread)
            } else {
                options = nil
            }
            var facts = candidate.facts
            facts.options = options
            let fact = TitioNoticeFact(
                key: candidate.key,
                kind: candidate.kind,
                source: candidate.source,
                facts: facts,
                actions: TitioNoticeAction.defaultActions(kind: candidate.kind, facts: facts),
                occurredAt: candidate.occurredAt
            )
            await handleIngest(fact, legacy: nil)
        }
    }

    /// The Bot's own choices from its latest assistant message, if any.
    private func latestChoices(thread: AgentThreadID) -> [String]? {
        guard let recent = try? messageRepo.listRecent(threadId: thread, limit: 6),
              let last = recent.last(where: { $0.role == .assistant }),
              let choices = BotChoicesBlock.parse(last.content).choices else { return nil }
        return choices.options
    }

    struct AttentionCandidate: Equatable {
        var key: String
        var kind: TitioNoticeKind
        var source: TitioNoticeSource
        var facts: TitioNoticeFacts
        var threadID: AgentThreadID?
        var occurredAt: Date
    }

    struct AttentionPlan: Equatable {
        var ingest: [AttentionCandidate]
        var resolved: [String]
    }

    /// Pure projector rules (§5): unacknowledged question/handoff/approval →
    /// `botQuestion`, blocked/unknownEffect → `botBlocked`; only Bots with
    /// notifications on that are not Titio; skipped when a thread request
    /// notice already covers the conversation's linked thread. Open notices
    /// whose item is gone (acknowledged elsewhere) resolve.
    static func attentionPlan(
        items: [BotAttentionItem],
        bots: [BotID: BotDefinition],
        openBotKeys: Set<String>,
        openThreadKeys: Set<String>,
        linkedThread: (BotConversationID) -> AgentThreadID?
    ) -> AttentionPlan {
        var ingest: [AttentionCandidate] = []
        var live = Set<String>()
        for item in items where item.acknowledgedAt == nil {
            let kind: TitioNoticeKind
            switch item.kind {
            case .question, .handoff, .approval: kind = .botQuestion
            case .blocked, .unknownEffect: kind = .botBlocked
            case .unread: continue
            }
            let key = TitioNoticeIDs.botAttention(itemId: item.id.value.uuidString)
            live.insert(key)
            guard let bot = bots[item.botID], bot.deletedAt == nil, bot.notificationsEnabled,
                  bot.handle.lowercased() != TitioBot.handle else { continue }
            if openBotKeys.contains(key) { continue }
            let thread = item.conversationID.flatMap(linkedThread)
            if let thread {
                let prefix = "thread.\(thread.value.uuidString).attention."
                if openThreadKeys.contains(where: { $0.hasPrefix(prefix) }) { continue }
            }
            let detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            ingest.append(AttentionCandidate(
                key: key,
                kind: kind,
                source: TitioNoticeSource(
                    threadId: thread?.value.uuidString,
                    botId: bot.id.value.uuidString.lowercased(),
                    conversationId: item.conversationID?.value.uuidString.lowercased(),
                    attentionItemId: item.id.value.uuidString.lowercased()
                ),
                facts: TitioNoticeFacts(botName: bot.name, detail: detail.isEmpty ? item.title : detail),
                threadID: thread,
                occurredAt: item.createdAt
            ))
        }
        let resolved = openBotKeys.subtracting(live).sorted()
        return AttentionPlan(ingest: ingest, resolved: resolved)
    }

    // MARK: Helpers

    /// Legacy route keys (`threadId`, `runId`…) for the push map, from the
    /// first row that has a thread (or activity) source.
    static func legacyRouteKeys(_ records: [TitioNoticeRecord]) -> [String: String] {
        guard let record = records.first(where: { $0.source.threadId != nil || $0.source.activityItemId != nil }) ?? records.first else {
            return [:]
        }
        var keys: [String: String] = [:]
        if records.count == 1 {
            keys["threadId"] = record.source.threadId
            keys["runId"] = record.source.runId
            keys["finalMessageId"] = record.source.finalMessageId
        }
        keys["workspaceId"] = record.source.workspaceId
        keys["activityItemId"] = record.source.activityItemId
        if records.count > 1 {
            keys["outcome"] = "completed"
        } else {
            switch record.kind {
            case .runCompleted, .botReply, .gitCompleted, .scriptCompleted, .transferCompleted: keys["outcome"] = "completed"
            case .approval, .userInput, .manualAction, .botQuestion, .fileConflict: keys["outcome"] = "attention"
            case .external, .notificationsDenied: break
            default: keys["outcome"] = "failed"
            }
        }
        return keys.compactMapValues { $0 }
    }

    /// The route a navigation option opens, in the push userInfo shape.
    static func navigationRoute(for action: TitioNoticeAction, record: TitioNoticeRecord, target: TitioInboxTarget?) -> [String: String] {
        var route: [String: String] = [:]
        switch action {
        case .openThread:
            route["threadId"] = record.source.threadId
            route["workspaceId"] = record.source.workspaceId
            route["finalMessageId"] = record.source.finalMessageId
        case .openBot:
            route["botId"] = record.source.botId
            route["conversationId"] = record.source.conversationId
        case .openActivity:
            if let item = record.source.activityItemId {
                route["activityItemId"] = item
            } else if let run = record.source.runId {
                route["activityItemId"] = "run:\(run.lowercased())"
            } else {
                route["activityDestination"] = "true"
            }
        case .openAllActivity:
            route["activityDestination"] = "true"
        default:
            break
        }
        return route.compactMapValues { $0 }
    }

    static func clip(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A tiny lock-protected value for the center's nonisolated state.
final class TitioNoticeLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Sets `newValue` and returns the previous value atomically.
    func exchange(_ newValue: Value) -> Value {
        lock.withLock {
            let previous = stored
            stored = newValue
            return previous
        }
    }
}
