import Foundation

public enum BotComputerGuestSpec {
    public static let imageTag = "remotecode/computer:local"
    public static let recipeLabelKey = "remotecode.recipe"
    /// Bump when start.sh / Dockerfile change. Missing label rebuilds the image.
    public static let recipeRevision = "4"
    public static let guestUserHome = "/home/remotecode"
    public static let screenPort = 6080
    public static let minimumShmBytes: Int = 256 * 1024 * 1024

    public static func containerName(botID: BotID) -> String {
        "remotecode-bot-\(botID.value.uuidString.lowercased())"
    }

    public static func guestHomeRoot(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("bot-guests", isDirectory: true)
    }

    public static func guestBotRootURL(appSupport: URL, botID: BotID) -> URL {
        guestHomeRoot(appSupport: appSupport)
            .appendingPathComponent(botID.value.uuidString.lowercased(), isDirectory: true)
    }

    public static func guestHomeURL(appSupport: URL, botID: BotID) -> URL {
        guestBotRootURL(appSupport: appSupport, botID: botID)
            .appendingPathComponent("home", isDirectory: true)
    }

    public static func viewerTokenURL(appSupport: URL, botID: BotID) -> URL {
        guestBotRootURL(appSupport: appSupport, botID: botID)
            .appendingPathComponent("viewer-token")
    }

    /// Per-bot Docker build context. Its editable Dockerfile lives at the guest-home root.
    public static func recipeURL(appSupport: URL, botID: BotID) -> URL {
        guestHomeURL(appSupport: appSupport, botID: botID)
    }

    public static func botImageTag(botID: BotID) -> String {
        "remotecode/computer:bot-\(botID.value.uuidString.lowercased())"
    }

    public static func networkName(botID: BotID) -> String {
        "remotecode-bot-\(botID.value.uuidString.lowercased())"
    }

    public static func nextContainerName(botID: BotID) -> String {
        "\(containerName(botID: botID))-next"
    }

    public static func assertGuestHomePath(_ path: String, appSupport: URL, botID: BotID) throws {
        let allowed = guestHomeURL(appSupport: appSupport, botID: botID).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        if candidate.contains("..") {
            throw BotComputerGuestError.invalidHomePath
        }
        guard candidate == allowed || candidate.hasPrefix(allowed + "/") else {
            throw BotComputerGuestError.invalidHomePath
        }
    }

    public static func containerCreateOptions(
        botID: BotID,
        guestHome: String,
        appSupport: URL,
        viewerToken: String,
        image: String = imageTag,
        name: String? = nil
    ) throws -> BotComputerContainerCreateOptions {
        try assertGuestHomePath(guestHome, appSupport: appSupport, botID: botID)
        guard viewerToken.range(of: #"^[a-zA-Z0-9-]{32,128}$"#, options: .regularExpression) != nil else {
            throw BotComputerGuestError.invalidScreenURL
        }
        return BotComputerContainerCreateOptions(
            name: name ?? containerName(botID: botID),
            image: image,
            labels: [
                "remotecode.managed": "1",
                "remotecode.botId": botID.value.uuidString.lowercased(),
            ],
            environment: ["REMOTECODE_VIEWER_TOKEN": viewerToken],
            binds: ["\(guestHome):\(guestUserHome)"],
            hostIP: "127.0.0.1",
            hostPort: 0,
            containerPort: screenPort,
            shmSize: minimumShmBytes,
            network: networkName(botID: botID)
        )
    }

    public static func terminalCommand() -> [String] {
        ["env", "DISPLAY=:1", "xterm"]
    }

    /// Playwright MCP inside the guest: headed on the Xvfb display so the user
    /// can watch and log in through the guest screen. Uses the image's chromium;
    /// Playwright must not download browsers in the guest.
    public static let playwrightGuestUserDataDir = "/home/remotecode/.browser-profiles/playwright"

    public static func playwrightMCPCommand(userDataDir: String = playwrightGuestUserDataDir) -> [String] {
        [
            "env", "DISPLAY=:1",
            "npx", "--yes", "@playwright/mcp@latest",
            "--executable-path", "/usr/bin/chromium",
            "--no-sandbox",
            "--user-data-dir", userDataDir,
        ]
    }

    public static func execUsesRoot(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("apt") || trimmed.hasPrefix("apt-get")
    }

    public static func assertExecCommand(_ command: String) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4000, !trimmed.contains("\0") else {
            throw BotComputerGuestError.observeFailed
        }
        return trimmed
    }

    public static func screenURL(hostPort: Int, token: String) throws -> URL {
        guard hostPort > 0,
              token.range(of: #"^[a-zA-Z0-9-]{32,128}$"#, options: .regularExpression) != nil
        else { throw BotComputerGuestError.invalidScreenURL }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = hostPort
        components.path = "/vnc.html"
        components.queryItems = [
            URLQueryItem(name: "autoconnect", value: "1"),
            URLQueryItem(name: "resize", value: "scale"),
            URLQueryItem(name: "view_only", value: "0"),
            // noVNC plays bell.oga on every RFB Bell (xterm rings it constantly).
            // ui.js only plays when the `bell` config var is exactly "on".
            URLQueryItem(name: "bell", value: "off"),
            URLQueryItem(name: "path", value: "websockify?token=\(token)"),
        ]
        guard let url = components.url else { throw BotComputerGuestError.invalidScreenURL }
        return url
    }

    public static func validateScreenURL(_ url: URL) throws {
        guard url.host == "127.0.0.1" else { throw BotComputerGuestError.invalidScreenURL }
    }

    /// Desk/Studio viewer entry. Refuse any host that is not loopback.
    public static func viewerURL(_ url: URL) throws -> URL {
        try validateScreenURL(url)
        return url
    }
}

public struct BotComputerContainerCreateOptions: Equatable, Sendable {
    public var name: String
    public var image: String
    public var labels: [String: String]
    public var environment: [String: String]
    public var binds: [String]
    public var hostIP: String
    public var hostPort: Int
    public var containerPort: Int
    public var shmSize: Int
    public var network: String?
}

public enum BotComputerGuestError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalidHomePath
    case invalidScreenURL
    case dockerUnavailable
    case observeFailed
    case notReady

    public var description: String {
        switch self {
        case .invalidHomePath:
            return "Guest home path is not allowed."
        case .invalidScreenURL:
            return "Guest screen URL must stay on 127.0.0.1."
        case .dockerUnavailable:
            return "Docker is unavailable. Start Docker, then try again."
        case .observeFailed:
            return "Could not capture the Linux desktop."
        case .notReady:
            return "Docker desktop is not ready."
        }
    }

    public var errorDescription: String? { description }
}
