import Foundation

public enum ReleaseChannel: String, Sendable {
    case debug
    case canary
    case stable

    public var bundleID: String {
        switch self {
        case .debug: return "io.remotecode.desktop.debug"
        case .canary: return "io.remotecode.desktop.canary"
        case .stable: return "io.remotecode.desktop"
        }
    }

    public var displayName: String {
        switch self {
        case .debug: return "RemoteCodeDebug"
        case .canary: return "RemoteCodeCanary"
        case .stable: return "RemoteCode"
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
        return dir.appendingPathComponent("remotecode.sqlite").path
    }
}
