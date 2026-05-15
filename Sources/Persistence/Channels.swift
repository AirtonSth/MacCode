import Foundation

public enum ReleaseChannel: String, Sendable {
    case debug
    case canary
    case stable

    public var bundleID: String {
        switch self {
        case .debug: return "io.remotecode.RemoteCode2.debug"
        case .canary: return "io.remotecode.RemoteCode2.canary"
        case .stable: return "io.remotecode.RemoteCode2"
        }
    }

    public var displayName: String {
        switch self {
        case .debug: return "RemoteCode2Debug"
        case .canary: return "RemoteCode2Canary"
        case .stable: return "RemoteCode2"
        }
    }
}

public enum AppPaths {
    public static func appSupportDirectory(for channel: ReleaseChannel, override: String? = nil) -> URL {
        if let override { return URL(fileURLWithPath: override) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent(channel.displayName, isDirectory: true)
    }

    public static func socketPath(for channel: ReleaseChannel, override: String? = nil) -> String {
        if let override { return override }
        // Use a short path under /tmp because Unix socket path is limited (~104 bytes).
        return "/tmp/\(channel.displayName).sock"
    }

    public static func databasePath(for channel: ReleaseChannel, override: String? = nil) -> String {
        if let override { return override }
        let dir = appSupportDirectory(for: channel)
        return dir.appendingPathComponent("remotecode2.sqlite").path
    }
}
