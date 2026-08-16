import Foundation

/// Dedicated website-data identity for a bot browser.
/// Workspace browsers use `workspaceID.value` as the WKWebsiteDataStore id.
/// Bot browsers must not share that mapping or they inherit workspace cookies.
public enum BotBrowserIdentity: Sendable {
    /// XOR namespace so a bot id never equals a workspace id used as a store key.
    public static let websiteDataNamespace = UUID(uuidString: "A11CE70B-B07B-4000-8000-B07B00000001")!

    public static func persistDirectoryName(for botID: BotID) -> String {
        botID.value.uuidString.lowercased()
    }

    public static func dataStoreIdentifier(for botID: BotID) -> UUID {
        xorUUID(websiteDataNamespace, botID.value)
    }

    public static func xorUUID(_ left: UUID, _ right: UUID) -> UUID {
        let a = left.uuid
        let b = right.uuid
        var mixed = UUID(uuid: (
            a.0 ^ b.0, a.1 ^ b.1, a.2 ^ b.2, a.3 ^ b.3,
            a.4 ^ b.4, a.5 ^ b.5, a.6 ^ b.6, a.7 ^ b.7,
            a.8 ^ b.8, a.9 ^ b.9, a.10 ^ b.10, a.11 ^ b.11,
            a.12 ^ b.12, a.13 ^ b.13, a.14 ^ b.14, a.15 ^ b.15
        ))
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        if mixed == zero {
            mixed = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        }
        return mixed
    }
}

public struct BotBrowserTarget: Codable, Equatable, Sendable {
    public var url: String
    public var title: String

    public init(url: String, title: String = "") {
        self.url = url
        self.title = title
    }
}

public struct BotBrowserPageState: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var cookies: [String: String]

    public init(url: String, title: String = "", cookies: [String: String] = [:]) {
        self.url = url
        self.title = title
        self.cookies = cookies
    }
}

public struct BotBrowserLoginPredicate: Equatable, Sendable {
    public var cookieNames: Set<String>

    public static let standard = BotBrowserLoginPredicate(cookieNames: ["session", "sid", "auth"])

    public init(cookieNames: Set<String>) {
        self.cookieNames = Set(cookieNames.map { $0.lowercased() })
    }

    public func isLoggedIn(_ page: BotBrowserPageState) -> Bool {
        page.cookies.keys.contains { cookieNames.contains($0.lowercased()) }
    }
}

/// Tell the user to log in and do not complete until the page looks logged in.
public enum BotBrowserLoginWait: Sendable {
    public struct Result: Equatable, Sendable {
        public var isComplete: Bool
        public var userMessage: String?
        public var url: String

        public init(isComplete: Bool, userMessage: String?, url: String) {
            self.isComplete = isComplete
            self.userMessage = userMessage
            self.url = url
        }
    }

    public static func userPrompt(url: String) -> String {
        "Log in in this bot's browser, then the bot will continue. Opened \(url)"
    }

    public static func evaluate(
        url: String,
        page: BotBrowserPageState,
        predicate: BotBrowserLoginPredicate = .standard
    ) -> Result {
        if predicate.isLoggedIn(page) {
            return Result(isComplete: true, userMessage: nil, url: page.url.isEmpty ? url : page.url)
        }
        return Result(isComplete: false, userMessage: userPrompt(url: url), url: url)
    }

    /// Drive a local fixture sequence. Incomplete until a logged-in sample appears.
    public static func wait(
        url: String,
        pages: [BotBrowserPageState],
        predicate: BotBrowserLoginPredicate = .standard
    ) -> [Result] {
        pages.map { evaluate(url: url, page: $0, predicate: predicate) }
    }
}

/// Same host-state event workspace browsers emit so iOS can mirror the target.
public enum BotBrowserHostState: Sendable {
    public static let eventKind = "surface.browser"

    public static func makePayload(surfaceID: SurfaceID, url: String, title: String?) -> [String: String] {
        var payload = [
            "surface_id": surfaceID.value.uuidString,
            "url": url,
        ]
        if let title, !title.isEmpty {
            payload["title"] = title
        }
        return payload
    }
}
