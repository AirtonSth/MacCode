import Darwin
import Foundation
import CoreModel

public enum BotComputerError: Error, Equatable, CustomStringConvertible {
    case callerMissing
    case crossBot
    case notDockerDesktop
    case invalid(String)

    public var description: String {
        switch self {
        case .callerMissing:
            return "Bot computer requires RC_REMOTE_CODE_BOT_ID on the calling run."
        case .crossBot:
            return "A bot can only use its own Linux desktop."
        case .notDockerDesktop:
            return "bot_computer_observe and bot_computer_act require Docker with GUI."
        case .invalid(let message):
            return message
        }
    }
}

public enum BotComputerCatalog: Sendable {
    public static let serverName = "remotecode-bot-computer"
    public static let cliArgument = "bot-computer"
    public static let callerEnvironmentKey = "RC_REMOTE_CODE_BOT_ID"
    public static let observe = BotStandingInstructions.computerObserveTool
    public static let act = BotStandingInstructions.computerActTool
    public static let exec = BotStandingInstructions.computerExecTool
    public static let rebuild = BotStandingInstructions.computerRebuildTool
    public static let requestUserAction = BotStandingInstructions.requestUserActionTool
    public static let postScreenshot = BotStandingInstructions.postScreenshotTool
    public static let requestMacExecution = BotStandingInstructions.requestMacExecutionTool
    public static let threadEnvironmentKey = "RC_REMOTE_CODE_SUBAGENT_THREAD_ID"
    public static var toolNames: [String] {
        [observe, act, exec, rebuild, requestUserAction, postScreenshot, requestMacExecution]
    }

    /// Read-only content tools whose (large) results are safe to route through
    /// the Token Saver distill lane. `observe`/`act` results carry coordinates
    /// and screen state the bot acts on verbatim — never compressed.
    public static var distillableToolNames: Set<String> { [exec] }

    public static func toolCatalog() -> [[String: Any]] {
        toolNames.map { name in
            [
                "name": name,
                "description": description(for: name),
                "inputSchema": schema(for: name),
            ]
        }
    }

    public static func description(for name: String) -> String {
        switch name {
        case observe:
            return "Screenshot the Docker Linux desktop on 127.0.0.1. Returns a PNG. Do not use macos-harness."
        case act:
            return "Click, type, or press a key on the Docker Linux desktop. Batch at most 24 steps."
        case exec:
            return "Run a command inside this bot's Linux container. Use this to install packages (apt-get) or edit files. Do not run host docker."
        case rebuild:
            return "Rebuild this bot's Linux image from /home/remotecode/Dockerfile and restart the desktop. Use after editing that Dockerfile."
        case requestUserAction:
            return "Pause and ask the user to do a manual step on the computer (login, captcha, 2FA, payment, human confirmation). Never ask for passwords, codes or card data in chat. Returns at once; end your turn, the user's reply arrives as a new message."
        case postScreenshot:
            return "Post a screenshot of the Linux desktop into the chat. Use at the end of a visual task, on a visible error, before an irreversible action or after a big screen change. Limited to one per 30 seconds except kind error or action."
        case requestMacExecution:
            return "Ask the user to approve running something on the Mac, because this Linux environment lacks macOS-only tools (swift, xcodebuild, xcrun). Never automatic; end your turn after calling."
        default:
            return name
        }
    }

    public static func schema(for name: String) -> [String: Any] {
        let botID: [String: Any] = [
            "bot_id": ["type": "string", "description": "Must match the calling bot or be omitted."]
        ]
        switch name {
        case observe:
            return ["type": "object", "properties": botID]
        case exec:
            return [
                "type": "object",
                "properties": botID.merging([
                    "command": [
                        "type": "string",
                        "description": "Shell command to run inside the guest. apt-get runs as root.",
                    ],
                ]) { _, new in new },
                "required": ["command"],
            ]
        case rebuild:
            return ["type": "object", "properties": botID]
        case requestUserAction:
            return [
                "type": "object",
                "properties": botID.merging([
                    "reason": ["type": "string", "description": "Why the user must act. Max 280 characters."],
                    "kind": [
                        "type": "string",
                        "enum": ManualActionKind.allCases.map(\.rawValue),
                        "description": "login, captcha, 2fa, payment, confirm, or other.",
                    ],
                ]) { _, new in new },
                "required": ["reason", "kind"],
            ]
        case postScreenshot:
            return [
                "type": "object",
                "properties": botID.merging([
                    "reason": ["type": "string", "description": "Short caption for the screenshot."],
                    "kind": [
                        "type": "string",
                        "enum": ["normal", "error", "action"],
                        "description": "normal is rate limited; error and action are not.",
                    ],
                ]) { _, new in new },
                "required": ["reason"],
            ]
        case requestMacExecution:
            return [
                "type": "object",
                "properties": botID.merging([
                    "reason": ["type": "string", "description": "What must run on the Mac and why."],
                ]) { _, new in new },
                "required": ["reason"],
            ]
        case act:
            return [
                "type": "object",
                "properties": botID.merging([
                    "steps": [
                        "type": "array",
                        "description": "Ordered click/type/key steps.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "action": ["type": "string", "description": "click, type, or key"],
                                "x": ["type": "integer"],
                                "y": ["type": "integer"],
                                "text": ["type": "string"],
                                "key": ["type": "string"],
                            ],
                            "required": ["action"],
                        ],
                    ],
                ]) { _, new in new },
                "required": ["steps"],
            ]
        default:
            return ["type": "object", "properties": [String: Any]()]
        }
    }
}

public struct BotComputerPendingAction: Codable, Equatable, Sendable {
    public var id: String
    public var botID: String
    public var kind: String
    public var steps: [BotComputerActStep]
    public var command: String
    /// Calling thread (`RC_REMOTE_CODE_SUBAGENT_THREAD_ID`), when the run has one.
    public var threadID: String?
    public var reason: String
    /// Manual-action kind or screenshot kind, depending on `kind`.
    public var subkind: String

    public init(
        id: String,
        botID: String,
        kind: String,
        steps: [BotComputerActStep] = [],
        command: String = "",
        threadID: String? = nil,
        reason: String = "",
        subkind: String = ""
    ) {
        self.id = id
        self.botID = botID
        self.kind = kind
        self.steps = steps
        self.command = command
        self.threadID = threadID
        self.reason = reason
        self.subkind = subkind
    }

    enum CodingKeys: String, CodingKey {
        case id, botID, kind, steps, command, threadID, reason, subkind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        botID = try container.decode(String.self, forKey: .botID)
        kind = try container.decode(String.self, forKey: .kind)
        steps = try container.decodeIfPresent([BotComputerActStep].self, forKey: .steps) ?? []
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        subkind = try container.decodeIfPresent(String.self, forKey: .subkind) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(botID, forKey: .botID)
        try container.encode(kind, forKey: .kind)
        try container.encode(steps, forKey: .steps)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(threadID, forKey: .threadID)
        try container.encode(reason, forKey: .reason)
        try container.encode(subkind, forKey: .subkind)
    }
}

public struct BotComputerActionResult: Codable, Equatable, Sendable {
    public var id: String
    public var botID: String
    public var payload: String
    public var error: String

    public init(id: String, botID: String, payload: String, error: String) {
        self.id = id
        self.botID = botID
        self.payload = payload
        self.error = error
    }
}

public struct BotComputerStore: Sendable {
    public let rootDirectory: URL

    // A timed-out caller can leave a large screenshot result behind. Keep the
    // durable result channel bounded while retaining the newest responses.
    private static let maxRetainedResults = 32

    public init(appSupportDirectory: URL) {
        self.rootDirectory = appSupportDirectory.appendingPathComponent("BotComputers", isDirectory: true)
    }

    public static func open(environment: [String: String]) throws -> BotComputerStore {
        guard let override = environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            throw BotComputerError.invalid("Bot computer requires RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY.")
        }
        return BotComputerStore(appSupportDirectory: URL(fileURLWithPath: override, isDirectory: true))
    }

    public func enqueue(_ action: BotComputerPendingAction) throws {
        try withStoreLock {
            var pending = try loadPending()
            pending.append(action)
            try writeJSON(pending, to: pendingURL)
        }
    }

    public func takePending() throws -> [BotComputerPendingAction] {
        try withStoreLock {
            let pending = try loadPending()
            guard !pending.isEmpty else { return pending }
            try writeJSON([BotComputerPendingAction](), to: pendingURL)
            return pending
        }
    }

    public func hasPendingActions() throws -> Bool {
        try withStoreLock { !(try loadPending()).isEmpty }
    }

    public func writeResult(_ result: BotComputerActionResult) throws {
        try withStoreLock {
            var results = try loadResults()
            results.removeAll { $0.id == result.id }
            results.append(result)
            // PERF: cap only pays when over budget; steady-state writes skip
            // the suffix copy. Same retained newest-32.
            if results.count > Self.maxRetainedResults {
                results.removeFirst(results.count - Self.maxRetainedResults)
            }
            try writeJSON(results, to: resultsURL)
        }
    }

    public func takeResult(id: String) throws -> BotComputerActionResult? {
        try withStoreLock {
            var results = try loadResults()
            guard let index = results.firstIndex(where: { $0.id == id }) else { return nil }
            let value = results.remove(at: index)
            try writeJSON(results, to: resultsURL)
            return value
        }
    }

    private var pendingURL: URL { rootDirectory.appendingPathComponent("pending.json") }
    private var resultsURL: URL { rootDirectory.appendingPathComponent("results.json") }
    private var lockURL: URL { rootDirectory.appendingPathComponent(".lock") }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let descriptor = lockURL.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw BotComputerError.invalid("Bot computer store lock is unavailable.")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw BotComputerError.invalid("Bot computer store lock is unavailable.")
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try body()
    }

    private func loadPending() throws -> [BotComputerPendingAction] {
        try readJSON([BotComputerPendingAction].self, from: pendingURL) ?? []
    }

    private func loadResults() throws -> [BotComputerActionResult] {
        try readJSON([BotComputerActionResult].self, from: resultsURL) ?? []
    }

    // PERF: share JSON codec to avoid per-call allocation (many pending/result I/Os per loop).
    private static let sharedEncoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
    private static let sharedDecoder = JSONDecoder()
    private static let codecLock = NSLock()

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        Self.codecLock.lock()
        let data: Data
        do {
            data = try Self.sharedEncoder.encode(value)
        } catch {
            Self.codecLock.unlock()
            throw error
        }
        Self.codecLock.unlock()
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        Self.codecLock.lock()
        defer { Self.codecLock.unlock() }
        return try Self.sharedDecoder.decode(type, from: data)
    }
}

public enum BotComputerHost: Sendable {
    public static let pendingNotification = Notification.Name("io.remotecode.bot-computer.pending")

    public static func request(
        store: BotComputerStore,
        action: BotComputerPendingAction,
        notify: (Notification.Name) -> Void = { name in
            DistributedNotificationCenter.default().post(name: name, object: nil)
        }
    ) throws {
        try store.enqueue(action)
        notify(pendingNotification)
    }

    public static func applyPending(
        store: BotComputerStore,
        apply: (BotComputerPendingAction) throws -> [String: Any]
    ) throws -> Int {
        var applied = 0
        for item in try store.takePending() {
            applied += 1
            do {
                let object = try apply(item)
                let payload = (try? JSONSerialization.data(withJSONObject: object)).flatMap {
                    String(data: $0, encoding: .utf8)
                } ?? "{}"
                try store.writeResult(
                    BotComputerActionResult(id: item.id, botID: item.botID, payload: payload, error: "")
                )
            } catch {
                try store.writeResult(
                    BotComputerActionResult(
                        id: item.id,
                        botID: item.botID,
                        payload: "",
                        error: String(describing: error)
                    )
                )
            }
        }
        return applied
    }
}

public struct BotComputerService: Sendable {
    public let callerBotID: BotID
    public let store: BotComputerStore
    public var callerThreadID: String?
    public var timeoutMS: Double = 20_000

    private static let resultPollInterval: TimeInterval = 0.1

    public init(callerBotID: BotID, store: BotComputerStore, callerThreadID: String? = nil) {
        self.callerBotID = callerBotID
        self.store = store
        self.callerThreadID = callerThreadID
    }

    public static func make(environment: [String: String], store: BotComputerStore) throws -> BotComputerService {
        guard let raw = environment[BotComputerCatalog.callerEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: raw) else {
            throw BotComputerError.callerMissing
        }
        let thread = environment[BotComputerCatalog.threadEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BotComputerService(
            callerBotID: BotID(uuid),
            store: store,
            callerThreadID: (thread?.isEmpty == false) ? thread : nil
        )
    }

    public func call(name: String, arguments: [String: Any]) throws -> [String: Any] {
        if let raw = arguments["bot_id"] as? String,
           let uuid = UUID(uuidString: raw),
           BotID(uuid) != callerBotID {
            throw BotComputerError.crossBot
        }
        switch name {
        case BotComputerCatalog.observe:
            return try perform(kind: BotComputerCatalog.observe, steps: [])
        case BotComputerCatalog.act:
            let rawSteps = arguments["steps"] as? [[String: Any]] ?? []
            let steps = try parseSteps(rawSteps)
            try BotComputerGuestObserve.assertActStepCount(steps.count)
            return try perform(kind: BotComputerCatalog.act, steps: steps)
        case BotComputerCatalog.exec:
            let command = try BotComputerGuestSpec.assertExecCommand(
                arguments["command"] as? String ?? ""
            )
            return try perform(kind: BotComputerCatalog.exec, command: command)
        case BotComputerCatalog.rebuild:
            return try perform(kind: BotComputerCatalog.rebuild)
        case BotComputerCatalog.requestUserAction:
            let rawKind = (arguments["kind"] as? String ?? "other").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = ManualActionKind(rawValue: rawKind) else {
                throw BotComputerError.invalid("kind must be login, captcha, 2fa, payment, confirm, or other.")
            }
            return try perform(
                kind: BotComputerCatalog.requestUserAction,
                reason: ManualActionRequest.normalizedReason(arguments["reason"] as? String ?? ""),
                subkind: kind.rawValue
            )
        case BotComputerCatalog.postScreenshot:
            let rawKind = (arguments["kind"] as? String ?? "normal").trimmingCharacters(in: .whitespacesAndNewlines)
            guard BotScreenshotKind(rawValue: rawKind) != nil else {
                throw BotComputerError.invalid("kind must be normal, error, or action.")
            }
            return try perform(
                kind: BotComputerCatalog.postScreenshot,
                reason: ManualActionRequest.normalizedReason(arguments["reason"] as? String ?? ""),
                subkind: rawKind
            )
        case BotComputerCatalog.requestMacExecution:
            return try perform(
                kind: BotComputerCatalog.requestMacExecution,
                reason: ManualActionRequest.normalizedReason(arguments["reason"] as? String ?? "")
            )
        default:
            throw BotComputerError.invalid("unknown tool: \(name)")
        }
    }

    private func parseSteps(_ raw: [[String: Any]]) throws -> [BotComputerActStep] {
        try raw.map { item in
            let action = (item["action"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let step = BotComputerActStep(
                action: action,
                x: item["x"] as? Int,
                y: item["y"] as? Int,
                text: item["text"] as? String,
                key: item["key"] as? String
            )
            _ = try step.execCommand()
            return step
        }
    }

    private func perform(
        kind: String,
        steps: [BotComputerActStep] = [],
        command: String = "",
        reason: String = "",
        subkind: String = ""
    ) throws -> [String: Any] {
        let waitMS = (kind == BotComputerCatalog.exec || kind == BotComputerCatalog.rebuild)
            ? max(timeoutMS, 180_000)
            : timeoutMS
        let pending = BotComputerPendingAction(
            id: UUID().uuidString.lowercased(),
            botID: callerBotID.value.uuidString.lowercased(),
            kind: kind,
            steps: steps,
            command: command,
            threadID: callerThreadID,
            reason: reason,
            subkind: subkind
        )
        try BotComputerHost.request(store: store, action: pending)
        let deadline = Date().addingTimeInterval(max(0.2, waitMS / 1000))
        while Date() < deadline {
            if let result = try store.takeResult(id: pending.id) {
                if !result.error.isEmpty {
                    throw BotComputerError.invalid(result.error)
                }
                if let data = result.payload.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return object
                }
                return ["payload": result.payload]
            }
            Thread.sleep(forTimeInterval: Self.resultPollInterval)
        }
        throw BotComputerError.invalid("Docker desktop is not available. Keep RemoteCode open.")
    }
}
