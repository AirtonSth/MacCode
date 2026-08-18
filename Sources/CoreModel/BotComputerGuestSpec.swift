import Foundation

public enum BotComputerGuestSpec {
    public static let imageTag = "remotecode/computer:local"
    public static let guestUserHome = "/home/remotecode"
    public static let screenPort = 6080
    public static let minimumShmBytes: Int = 256 * 1024 * 1024

    public static func containerName(botID: BotID) -> String {
        "remotecode-bot-\(botID.value.uuidString.lowercased())"
    }

    public static func guestHomeRoot(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("bot-guests", isDirectory: true)
    }

    public static func guestHomeURL(appSupport: URL, botID: BotID) -> URL {
        guestHomeRoot(appSupport: appSupport)
            .appendingPathComponent(botID.value.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
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
        appSupport: URL
    ) throws -> BotComputerContainerCreateOptions {
        try assertGuestHomePath(guestHome, appSupport: appSupport, botID: botID)
        return BotComputerContainerCreateOptions(
            name: containerName(botID: botID),
            image: imageTag,
            labels: [
                "remotecode.managed": "1",
                "remotecode.botId": botID.value.uuidString.lowercased(),
            ],
            binds: ["\(guestHome):\(guestUserHome)"],
            hostIP: "127.0.0.1",
            hostPort: 0,
            containerPort: screenPort,
            shmSize: minimumShmBytes
        )
    }

    public static func screenURL(hostPort: Int, token: String) throws -> URL {
        guard hostPort > 0, !token.isEmpty else { throw BotComputerGuestError.invalidScreenURL }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = hostPort
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw BotComputerGuestError.invalidScreenURL }
        return url
    }

    public static func validateScreenURL(_ url: URL) throws {
        guard url.host == "127.0.0.1" else { throw BotComputerGuestError.invalidScreenURL }
    }
}

public struct BotComputerContainerCreateOptions: Equatable, Sendable {
    public var name: String
    public var image: String
    public var labels: [String: String]
    public var binds: [String]
    public var hostIP: String
    public var hostPort: Int
    public var containerPort: Int
    public var shmSize: Int
}

public enum BotComputerGuestError: Error, Equatable {
    case invalidHomePath
    case invalidScreenURL
    case dockerUnavailable
    case observeFailed
    case notReady
}
