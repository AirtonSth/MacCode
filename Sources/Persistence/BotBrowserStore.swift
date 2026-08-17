import Foundation
import CoreModel

public enum BotBrowserError: Error, Equatable, CustomStringConvertible {
    case callerMissing
    case crossBot
    case invalid(String)

    public var description: String {
        switch self {
        case .callerMissing:
            return "Bot browser requires RC_REMOTE_CODE_BOT_ID on the calling run."
        case .crossBot:
            return "A bot can only use its own browser."
        case .invalid(let message):
            return message
        }
    }
}

public enum BotBrowserCatalog: Sendable {
    public static let serverName = "remotecode-bot-browser"
    public static let cliArgument = "bot-browser"
    public static let callerEnvironmentKey = "RC_REMOTE_CODE_BOT_ID"

    public static let open = "bot_browser_open"
    public static let get = "bot_browser_get"
    public static let waitLogin = "bot_browser_wait_login"

    public static var toolNames: [String] { [open, get, waitLogin] }

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
        case open:
            return "Open a website in this bot's own persistent browser."
        case get:
            return "Read this bot browser's last URL, title, and website-data keys."
        case waitLogin:
            return "Tell the user to log in and wait until this bot's browser looks logged in."
        default:
            return name
        }
    }

    public static func schema(for name: String) -> [String: Any] {
        let botID: [String: Any] = ["bot_id": ["type": "string", "description": "Must match the calling bot or be omitted."]]
        switch name {
        case open:
            return [
                "type": "object",
                "properties": botID.merging([
                    "url": ["type": "string", "description": "Website. Same field as the URL to open."],
                    "title": ["type": "string"],
                ]) { _, new in new },
                "required": ["url"],
            ]
        case get:
            return ["type": "object", "properties": botID]
        case waitLogin:
            return [
                "type": "object",
                "properties": botID.merging(["timeout_ms": ["type": "number"]]) { _, new in new },
            ]
        default:
            return ["type": "object", "properties": [String: Any]()]
        }
    }
}

/// On-disk website-data + last-target store keyed by the live bot-browser mapping.
public struct BotBrowserStore: Sendable {
    public let rootDirectory: URL

    public init(appSupportDirectory: URL) {
        self.rootDirectory = appSupportDirectory.appendingPathComponent("BotBrowsers", isDirectory: true)
    }

    public static func open(environment: [String: String]) throws -> BotBrowserStore {
        let override = environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let override, !override.isEmpty else {
            throw BotBrowserError.invalid("Bot browser requires RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY.")
        }
        return BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: override, isDirectory: true))
    }

    public func directory(for botID: BotID) -> URL {
        rootDirectory.appendingPathComponent(BotBrowserIdentity.persistDirectoryName(for: botID), isDirectory: true)
    }

    public func writeWebsiteData(_ records: [String: String], botID: BotID) throws {
        try writeJSON(records, to: websiteDataURL(for: botID))
    }

    public func readWebsiteData(botID: BotID) throws -> [String: String] {
        try readJSON([String: String].self, from: websiteDataURL(for: botID)) ?? [:]
    }

    public func writeMarker(_ value: String, botID: BotID, key: String = "marker") throws {
        var records = try readWebsiteData(botID: botID)
        records[key] = value
        try writeWebsiteData(records, botID: botID)
    }

    public func readMarker(botID: BotID, key: String = "marker") throws -> String? {
        try readWebsiteData(botID: botID)[key]
    }

    public func persistTarget(_ target: BotBrowserTarget, botID: BotID) throws {
        try writeJSON(target, to: targetURL(for: botID))
    }

    public func loadTarget(botID: BotID) throws -> BotBrowserTarget? {
        try readJSON(BotBrowserTarget.self, from: targetURL(for: botID))
    }

    public func persistPageState(_ state: BotBrowserPageState, botID: BotID) throws {
        try writeJSON(state, to: pageStateURL(for: botID))
        var cookies = try readWebsiteData(botID: botID)
        cookies.merge(state.cookies) { _, new in new }
        try writeWebsiteData(cookies, botID: botID)
    }

    public func enqueuePendingOpen(_ target: BotBrowserTarget, botID: BotID) throws {
        var pending = try loadPendingOpens()
        pending.removeAll { $0.botID == botID.value.uuidString.lowercased() }
        pending.append(
            BotBrowserPendingOpen(
                botID: botID.value.uuidString.lowercased(),
                url: target.url,
                title: target.title
            )
        )
        try writeJSON(pending, to: pendingOpensURL)
    }

    public func loadPendingOpens() throws -> [BotBrowserPendingOpen] {
        try readJSON([BotBrowserPendingOpen].self, from: pendingOpensURL) ?? []
    }

    public func takePendingOpens() throws -> [BotBrowserPendingOpen] {
        let pending = try loadPendingOpens()
        try writeJSON([BotBrowserPendingOpen](), to: pendingOpensURL)
        return pending
    }

    public func loadPageState(botID: BotID) throws -> BotBrowserPageState? {
        if let stored = try readJSON(BotBrowserPageState.self, from: pageStateURL(for: botID)) {
            return stored
        }
        guard let target = try loadTarget(botID: botID) else { return nil }
        return BotBrowserPageState(url: target.url, title: target.title, cookies: try readWebsiteData(botID: botID))
    }

    private func websiteDataURL(for botID: BotID) -> URL {
        directory(for: botID).appendingPathComponent("website-data.json")
    }

    private func targetURL(for botID: BotID) -> URL {
        directory(for: botID).appendingPathComponent("target.json")
    }

    private func pageStateURL(for botID: BotID) -> URL {
        directory(for: botID).appendingPathComponent("page-state.json")
    }

    private var pendingOpensURL: URL {
        rootDirectory.appendingPathComponent("pending-opens.json")
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

public struct BotBrowserPendingOpen: Codable, Equatable, Sendable {
    public var botID: String
    public var url: String
    public var title: String
}

/// MCP writes a pending open; the app applies it through `openBotBrowser`.
public enum BotBrowserHost: Sendable {
    public static let pendingOpenNotification = Notification.Name("io.remotecode.bot-browser.pending-open")

    public static func requestOpen(
        store: BotBrowserStore,
        botID: BotID,
        url: String,
        title: String?,
        notify: (Notification.Name) -> Void = { name in
            DistributedNotificationCenter.default().post(name: name, object: nil)
        }
    ) throws -> BotBrowserTarget {
        let service = BotBrowserService(callerBotID: botID, store: store)
        let target = try service.persistNavigation(url: url, title: title)
        try store.enqueuePendingOpen(target, botID: botID)
        notify(pendingOpenNotification)
        return target
    }

    public static func applyPendingOpens(
        store: BotBrowserStore,
        open: (BotID, String, String?) throws -> BotBrowserTarget
    ) throws -> [BotBrowserTarget] {
        try store.takePendingOpens().compactMap { item in
            guard let uuid = UUID(uuidString: item.botID) else { return nil }
            return try open(BotID(uuid), item.url, item.title.isEmpty ? nil : item.title)
        }
    }
}

public struct BotBrowserService: Sendable {
    public let callerBotID: BotID
    public let store: BotBrowserStore

    public init(callerBotID: BotID, store: BotBrowserStore) {
        self.callerBotID = callerBotID
        self.store = store
    }

    public static func make(environment: [String: String], store: BotBrowserStore) throws -> BotBrowserService {
        guard let raw = environment[BotBrowserCatalog.callerEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: raw) else {
            throw BotBrowserError.callerMissing
        }
        return BotBrowserService(callerBotID: BotID(uuid), store: store)
    }

    public func assertOwn(_ requested: BotID?) throws {
        if let requested, requested != callerBotID {
            throw BotBrowserError.crossBot
        }
    }

    public func persistNavigation(url: String, title: String?) throws -> BotBrowserTarget {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            throw BotBrowserError.invalid("A valid URL is required.")
        }
        let target = BotBrowserTarget(url: trimmed, title: title ?? "")
        try store.persistTarget(target, botID: callerBotID)
        return target
    }

    public func open(url: String, title: String?) throws -> BotBrowserTarget {
        try BotBrowserHost.requestOpen(store: store, botID: callerBotID, url: url, title: title)
    }

    public func current() throws -> BotBrowserTarget? {
        try store.loadTarget(botID: callerBotID)
    }

    public func waitLogin(page: BotBrowserPageState? = nil) throws -> BotBrowserLoginWait.Result {
        let target = try store.loadTarget(botID: callerBotID)
        let url = target?.url ?? page?.url ?? ""
        let observed = try page ?? store.loadPageState(botID: callerBotID) ?? BotBrowserPageState(url: url)
        return BotBrowserLoginWait.evaluate(url: url, page: observed)
    }

    public func call(name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        try assertOwn(Self.parseOptionalBotID(arguments["bot_id"]))
        switch name {
        case BotBrowserCatalog.open:
            // Tools say website. Schema key stays url.
            guard let url = Self.firstString(arguments, keys: ["url", "website"]) else {
                throw BotBrowserError.invalid("url is required.")
            }
            let target = try open(url: url, title: arguments["title"] as? String)
            return ["url": target.url, "title": target.title]
        case BotBrowserCatalog.get:
            let target = try current()
            let data = try store.readWebsiteData(botID: callerBotID)
            return [
                "url": target?.url ?? "",
                "title": target?.title ?? "",
                "website_data_keys": Array(data.keys).sorted(),
            ]
        case BotBrowserCatalog.waitLogin:
            let timeout = (arguments["timeout_ms"] as? Double)
                ?? (arguments["timeout_ms"] as? NSNumber)?.doubleValue
                ?? BotBrowserLoginWait.defaultTimeoutMS
            let url = try current()?.url ?? ""
            let result = try BotBrowserLoginWait.pollUntilLoggedIn(
                url: url,
                timeoutMS: timeout,
                loadPage: {
                    try self.store.loadPageState(botID: self.callerBotID) ?? BotBrowserPageState(url: url)
                }
            )
            return [
                "complete": result.isComplete,
                "user_message": result.userMessage ?? "",
                "url": result.url,
            ]
        default:
            throw BotBrowserError.invalid("unknown tool: \(name)")
        }
    }

    static func parseOptionalBotID(_ value: Any?) -> BotID? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: raw) else { return nil }
        return BotID(uuid)
    }

    static func firstString(_ arguments: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key] as? String { return value }
        }
        return nil
    }
}
