import Foundation

public enum ManualActionKind: String, Codable, CaseIterable, Sendable {
    case login
    case captcha
    case twoFactor = "2fa"
    case payment
    case confirm
    case other
}

public enum ManualActionState: String, Codable, Sendable {
    case open
    case taken
    case continued
    case declined
    case expired

    public var isOpen: Bool { self == .open || self == .taken }
}

public struct ManualActionRequest: Codable, Equatable, Sendable, Identifiable {
    public static let maxReasonLength = 280
    public static let defaultReason = "O bot pediu que você assuma"

    /// Tool result for `bot_request_user_action`. The run must end after it.
    public static let pauseReply =
        "Pausado aguardando o usuário. Encerre o turno agora. Você receberá uma mensagem quando ele terminar."
    /// Returned instead of executing act/exec/browser act while the user controls the computer.
    public static let refusalPhrase =
        "O usuário assumiu o controle deste computador, então esta chamada NÃO foi executada. Não repita: a tela está mudando. Pause a tarefa, diga que está esperando o usuário devolver o controle e tire um screenshot novo antes da próxima ação."
    public static let declineFollowUp =
        "O usuário recusou a ação manual. Siga sem isso ou pare e explique."

    public var id: UUID
    public var botID: BotID
    /// Nil when the caller env carried no thread; the host fills it from the bot's active thread.
    public var threadID: AgentThreadID?
    public var kind: ManualActionKind
    public var reason: String
    public var screenshotRef: String?
    public var createdAt: Date
    public var state: ManualActionState
    public var resolvedAt: Date?
    public var note: String?

    public init(
        id: UUID = UUID(),
        botID: BotID,
        threadID: AgentThreadID? = nil,
        kind: ManualActionKind,
        reason: String,
        screenshotRef: String? = nil,
        createdAt: Date = Date(),
        state: ManualActionState = .open,
        resolvedAt: Date? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.botID = botID
        self.threadID = threadID
        self.kind = kind
        self.reason = Self.normalizedReason(reason)
        self.screenshotRef = screenshotRef
        self.createdAt = createdAt
        self.state = state
        self.resolvedAt = resolvedAt
        self.note = note
    }

    public static func normalizedReason(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultReason }
        return String(trimmed.prefix(maxReasonLength))
    }

    public static func continueFollowUp(kind: ManualActionKind, note: String?) -> String {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shown = trimmed.isEmpty ? "nenhuma" : trimmed
        return "O usuário concluiu a ação manual (\(kind.rawValue)). Nota: \(shown). Tire um screenshot novo antes de agir."
    }
}

/// In-memory "who drives this computer" registry, keyed by bot. State is never
/// persisted: a restarted app hands control back to the bot.
public final class BotComputerControl: @unchecked Sendable {
    public static let shared = BotComputerControl()

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var controlled: Set<BotID> = []
    private var requests: [BotID: ManualActionRequest] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func isControlledByUser(_ bot: BotID) -> Bool {
        lock.withLock { controlled.contains(bot) }
    }

    public func openRequest(_ bot: BotID) -> ManualActionRequest? {
        lock.withLock { requests[bot] }
    }

    /// The user starts driving. An open request becomes `taken`.
    public func take(_ bot: BotID) {
        lock.withLock {
            controlled.insert(bot)
            if var request = requests[bot], request.state == .open {
                request.state = .taken
                requests[bot] = request
            }
        }
    }

    /// Hands control back to the bot. The request stays until `dismiss`.
    public func release(_ bot: BotID) {
        lock.withLock { _ = controlled.remove(bot) }
    }

    /// One open request per bot: a second call returns the existing id and keeps its reason.
    @discardableResult
    public func requestHelp(_ request: ManualActionRequest) -> UUID {
        lock.withLock {
            if let existing = requests[request.botID] { return existing.id }
            var stored = request
            stored.state = .open
            stored.resolvedAt = nil
            requests[request.botID] = stored
            return stored.id
        }
    }

    /// Closes the open request with `state` (continued or declined) and returns it.
    @discardableResult
    public func dismiss(
        _ id: UUID,
        as state: ManualActionState = .continued,
        note: String? = nil
    ) -> ManualActionRequest? {
        close(id, state: state, note: note)
    }

    /// Only closes when `id` is still the current request, so a stale timer cannot close a newer one.
    @discardableResult
    public func expire(_ id: UUID) -> ManualActionRequest? {
        close(id, state: .expired, note: nil)
    }

    public func forget(_ bot: BotID) {
        lock.withLock {
            controlled.remove(bot)
            requests[bot] = nil
        }
    }

    private func close(_ id: UUID, state: ManualActionState, note: String?) -> ManualActionRequest? {
        lock.withLock {
            guard let entry = requests.first(where: { $0.value.id == id }) else { return nil }
            var request = entry.value
            request.state = state
            request.resolvedAt = now()
            request.note = note
            requests[entry.key] = nil
            return request
        }
    }
}

/// In-process notifications from the host apply path to the app layer that
/// persists them into the thread. Posted on the caller's (background) thread;
/// observers must hop to their own actor. All payloads are in `userInfo`.
public extension Notification.Name {
    /// userInfo: `request` ManualActionRequest, `screenshotPNG` Data?
    static let botManualActionRequested = Notification.Name("io.remotecode.bot.manual-action-requested")
    /// userInfo: `botID` BotID, `threadID` AgentThreadID?, `jpeg` Data, `reason` String, `kind` String
    static let botScreenshotPosted = Notification.Name("io.remotecode.bot.screenshot-posted")
    /// userInfo: `botID` BotID, `threadID` AgentThreadID?, `reason` String
    static let botMacExecutionRequested = Notification.Name("io.remotecode.bot.mac-execution-requested")
    /// userInfo: `botID` BotID, `threadID` AgentThreadID. A rebuild that held the bot finished;
    /// `threadID` is the send that queued meanwhile and now drains.
    static let botVMRebuildReleased = Notification.Name("io.remotecode.bot.vm-rebuild-released")
    /// userInfo: `threadID` AgentThreadID. Posted after a manual-action take/resolve so every view model refreshes.
    static let manualActionStateChanged = Notification.Name("io.remotecode.bot.manual-action-state-changed")
}

public enum BotHostNotificationKey {
    public static let request = "request"
    public static let screenshotPNG = "screenshotPNG"
    public static let botID = "botID"
    public static let threadID = "threadID"
    public static let jpeg = "jpeg"
    public static let reason = "reason"
    public static let kind = "kind"
}

public enum ManualActionHost {
    /// Opens a request unless the bot already has one; posts `.botManualActionRequested` only for a new one.
    @discardableResult
    public static func request(
        control: BotComputerControl,
        botID: BotID,
        threadID: AgentThreadID?,
        kind: ManualActionKind,
        reason: String,
        screenshotPNG: Data?,
        center: NotificationCenter = .default
    ) -> UUID {
        let candidate = ManualActionRequest(botID: botID, threadID: threadID, kind: kind, reason: reason)
        let id = control.requestHelp(candidate)
        if id == candidate.id {
            var userInfo: [String: Any] = [BotHostNotificationKey.request: candidate]
            if let screenshotPNG { userInfo[BotHostNotificationKey.screenshotPNG] = screenshotPNG }
            center.post(name: .botManualActionRequested, object: nil, userInfo: userInfo)
        }
        return id
    }
}
