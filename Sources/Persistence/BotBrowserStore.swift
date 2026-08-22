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
    public static let snapshot = "bot_browser_snapshot"
    public static let act = "bot_browser_act"
    /// Host action kind for live page-state polls (login wait). NOT a tool;
    /// `toolNames` stays the five advertised tools.
    public static let stateKind = "state"

    public static var toolNames: [String] { [open, get, waitLogin, snapshot, act] }

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
        case snapshot:
            return "Read this bot browser's visible interactive elements. Call this before act."
        case act:
            return "Click, type, fill, or scroll an element from the last snapshot. Do not evaluate JavaScript."
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
                    "url": ["type": "string", "description": "Website / last website. Same field as the URL to open."],
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
        case snapshot:
            return ["type": "object", "properties": botID]
        case act:
            return [
                "type": "object",
                "properties": botID.merging([
                    "action": ["type": "string", "description": "click, type, fill, or scroll."],
                    "ref": ["type": "string", "description": "Element ref from bot_browser_snapshot."],
                    "text": ["type": "string"],
                ]) { _, new in new },
                "required": ["action", "ref"],
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
        // Empty takes must not touch the file: rewriting [] here races a
        // concurrent MCP-process enqueue (load-modify-write) and erases it.
        guard !pending.isEmpty else { return pending }
        try writeJSON([BotBrowserPendingOpen](), to: pendingOpensURL)
        return pending
    }

    public func replacePendingOpens(_ pending: [BotBrowserPendingOpen]) throws {
        try writeJSON(pending, to: pendingOpensURL)
    }

    public func enqueueAction(_ action: BotBrowserPendingAction) throws {
        var pending = try loadPendingActions()
        pending.removeAll { $0.id == action.id }
        pending.append(action)
        try writeJSON(pending, to: pendingActionsURL)
    }

    public func loadPendingActions() throws -> [BotBrowserPendingAction] {
        try readJSON([BotBrowserPendingAction].self, from: pendingActionsURL) ?? []
    }

    public func takePendingActions() throws -> [BotBrowserPendingAction] {
        let pending = try loadPendingActions()
        // Empty takes must not touch the file: rewriting [] here races a
        // concurrent MCP-process enqueue (load-modify-write) and erases it.
        guard !pending.isEmpty else { return pending }
        try writeJSON([BotBrowserPendingAction](), to: pendingActionsURL)
        return pending
    }

    public func writeActionResult(_ result: BotBrowserActionResult) throws {
        var results = try loadActionResults()
        results.removeAll { $0.id == result.id }
        results.append(result)
        try writeJSON(results, to: actionResultsURL)
    }

    public func takeActionResult(id: String) throws -> BotBrowserActionResult? {
        var results = try loadActionResults()
        guard let index = results.firstIndex(where: { $0.id == id }) else { return nil }
        let result = results.remove(at: index)
        try writeJSON(results, to: actionResultsURL)
        return result
    }

    private func loadActionResults() throws -> [BotBrowserActionResult] {
        try readJSON([BotBrowserActionResult].self, from: actionResultsURL) ?? []
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

    private var pendingActionsURL: URL {
        rootDirectory.appendingPathComponent("pending-actions.json")
    }

    private var actionResultsURL: URL {
        rootDirectory.appendingPathComponent("action-results.json")
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

public struct BotBrowserPendingAction: Codable, Equatable, Sendable {
    public var id: String
    public var botID: String
    public var kind: String
    public var action: String
    public var ref: String
    public var text: String
    public var url: String
    public var title: String

    public init(
        id: String,
        botID: String,
        kind: String,
        action: String,
        ref: String,
        text: String,
        url: String = "",
        title: String = ""
    ) {
        self.id = id
        self.botID = botID
        self.kind = kind
        self.action = action
        self.ref = ref
        self.text = text
        self.url = url
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case id, botID, kind, action, ref, text, url, title
    }

    // url/title arrived after ship; queued JSON without them must still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        botID = try container.decode(String.self, forKey: .botID)
        kind = try container.decode(String.self, forKey: .kind)
        action = try container.decode(String.self, forKey: .action)
        ref = try container.decode(String.self, forKey: .ref)
        text = try container.decode(String.self, forKey: .text)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(botID, forKey: .botID)
        try container.encode(kind, forKey: .kind)
        try container.encode(action, forKey: .action)
        try container.encode(ref, forKey: .ref)
        try container.encode(text, forKey: .text)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
    }
}

public struct BotBrowserActionResult: Codable, Equatable, Sendable {
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

/// MCP writes a pending open; the app applies it through `openBotBrowser`.
public enum BotBrowserHost: Sendable {
    public static let pendingOpenNotification = Notification.Name("io.remotecode.bot-browser.pending-open")
    public static let pendingActionNotification = Notification.Name("io.remotecode.bot-browser.pending-action")

    public static func requestOpen(
        store: BotBrowserStore,
        botID: BotID,
        url: String,
        title: String?,
        notify: (Notification.Name) throws -> Void = { name in
            DistributedNotificationCenter.default().post(name: name, object: nil)
        }
    ) throws -> BotBrowserTarget {
        let service = BotBrowserService(callerBotID: botID, store: store)
        let target = try service.persistNavigation(url: url, title: title)
        try store.enqueuePendingOpen(target, botID: botID)
        try notify(pendingOpenNotification)
        return target
    }

    public static func applyPendingOpens(
        store: BotBrowserStore,
        open: (BotID, String, String?) throws -> BotBrowserTarget
    ) throws -> [BotBrowserTarget] {
        var pending = try store.loadPendingOpens()
        var applied: [BotBrowserTarget] = []
        while !pending.isEmpty {
            let item = pending.removeFirst()
            guard let uuid = UUID(uuidString: item.botID) else { continue }
            do {
                let target = try open(BotID(uuid), item.url, item.title.isEmpty ? nil : item.title)
                applied.append(target)
                try store.replacePendingOpens(pending)
            } catch {
                try store.replacePendingOpens([item] + pending)
                throw error
            }
        }
        return applied
    }

    public static func requestAction(
        store: BotBrowserStore,
        action: BotBrowserPendingAction,
        notify: (Notification.Name) -> Void = { name in
            DistributedNotificationCenter.default().post(name: name, object: nil)
        }
    ) throws {
        try store.enqueueAction(action)
        notify(pendingActionNotification)
    }

    public static func applyPendingActions(
        store: BotBrowserStore,
        apply: (BotID, BotBrowserPendingAction) throws -> String
    ) throws {
        try applyPendingActionsSync(store: store, apply: apply)
    }

    private static func applyPendingActionsSync(
        store: BotBrowserStore,
        apply: (BotID, BotBrowserPendingAction) throws -> String
    ) throws {
        for item in try store.takePendingActions() {
            guard let uuid = UUID(uuidString: item.botID) else { continue }
            do {
                let payload = try apply(BotID(uuid), item)
                try store.writeActionResult(
                    BotBrowserActionResult(id: item.id, botID: item.botID, payload: payload, error: "")
                )
            } catch {
                try store.writeActionResult(
                    BotBrowserActionResult(
                        id: item.id,
                        botID: item.botID,
                        payload: "",
                        error: String(describing: error)
                    )
                )
            }
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

    public func performHostAction(
        kind: String,
        action: String,
        ref: String,
        text: String,
        url: String = "",
        title: String = "",
        timeoutMS: Double
    ) throws -> [String: Any] {
        let pending = BotBrowserPendingAction(
            id: UUID().uuidString.lowercased(),
            botID: callerBotID.value.uuidString.lowercased(),
            kind: kind,
            action: action,
            ref: ref,
            text: text,
            url: url,
            title: title
        )
        try BotBrowserHost.requestAction(store: store, action: pending)
        let deadline = Date().addingTimeInterval(max(0.2, timeoutMS / 1000))
        while Date() < deadline {
            if let result = try store.takeActionResult(id: pending.id) {
                if !result.error.isEmpty {
                    throw BotBrowserError.invalid(result.error)
                }
                if let data = result.payload.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return object
                }
                return ["payload": result.payload]
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw BotBrowserError.invalid("Bot browser is not available. Keep the RemoteCode app running and try again.")
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
            // Tools and compile say website / last website. Schema key stays url.
            // set_settings leftover last_website already rejects and points
            // here, so first-chat retried last_website on open. Accept that
            // advertised name on the existing persist path.
            guard let url = Self.firstString(arguments, keys: ["url", "website", "last_website"]) else {
                throw BotBrowserError.invalid("url is required.")
            }
            // Persist first so bot_browser_get stays truthful, then drive the
            // app-owned Playwright child through the host mailbox. A refused
            // route or missing Node.js surfaces to the bot verbatim (fail
            // loud) instead of the old fire-and-forget enqueue.
            let target = try persistNavigation(url: url, title: arguments["title"] as? String)
            let payload = try performHostAction(
                kind: BotBrowserCatalog.open,
                action: "",
                ref: "",
                text: "",
                url: target.url,
                title: target.title,
                timeoutMS: 70_000
            )
            return [
                "url": payload["url"] as? String ?? target.url,
                "title": payload["title"] as? String ?? target.title,
            ]
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
            // The Playwright lanes feed no cookies, so login detection rides
            // the leftLoginPage URL change polled LIVE through the host. Each
            // poll is a full host round-trip — 2s cadence, not the 100ms
            // store default. Host errors fall back to the persisted state
            // (legacy restored tabs still persist cookies there).
            let result = try BotBrowserLoginWait.pollUntilLoggedIn(
                url: url,
                timeoutMS: timeout,
                pollIntervalMS: 2_000,
                loadPage: {
                    let cookies = (try? self.store.readWebsiteData(botID: self.callerBotID)) ?? [:]
                    if let payload = try? self.performHostAction(
                        kind: BotBrowserCatalog.stateKind,
                        action: "",
                        ref: "",
                        text: "",
                        timeoutMS: 10_000
                    ) {
                        return BotBrowserPageState(
                            url: payload["url"] as? String ?? "",
                            title: payload["title"] as? String ?? "",
                            cookies: cookies
                        )
                    }
                    return try self.store.loadPageState(botID: self.callerBotID) ?? BotBrowserPageState(url: url)
                }
            )
            return [
                "complete": result.isComplete,
                "user_message": result.userMessage ?? "",
                "url": result.url,
            ]
        case BotBrowserCatalog.snapshot:
            return try performHostAction(
                kind: BotBrowserCatalog.snapshot,
                action: "",
                ref: "",
                text: "",
                timeoutMS: 15_000
            )
        case BotBrowserCatalog.act:
            let action = (arguments["action"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let allowed = Set(["click", "type", "fill", "scroll"])
            guard allowed.contains(action) else {
                throw BotBrowserError.invalid("action must be click, type, fill, or scroll.")
            }
            guard let ref = (arguments["ref"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ref.isEmpty else {
                throw BotBrowserError.invalid("ref is required.")
            }
            // Clicks can trigger full navigations — allow 15s, not 8s.
            return try performHostAction(
                kind: BotBrowserCatalog.act,
                action: action,
                ref: ref,
                text: arguments["text"] as? String ?? "",
                timeoutMS: 15_000
            )
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
