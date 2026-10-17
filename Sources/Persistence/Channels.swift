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

// MARK: - Bundle-ID derivation

extension ReleaseChannel {
    /// Derives the release channel from a CFBundleIdentifier string.
    /// Priority: exact bundle-id match -> .debug fallback.
    /// This is the inverse of `ReleaseChannel.bundleID` and is used at launch
    /// so that a notarized stable bundle (io.remotecode.desktop) automatically
    /// gets .stable without relying solely on the RC2_CHANNEL env var.
    public static func channelFromBundleID(_ bundleID: String) -> ReleaseChannel {
        for channel in [ReleaseChannel.stable, .canary, .debug] {
            if channel.bundleID == bundleID { return channel }
        }
        return .debug
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
        if let env = ProcessInfo.processInfo.environment["RC2_SOCKET_PATH"], env.hasPrefix("/") { return env }
        // Use a short path under /tmp because Unix socket path is limited (~104 bytes).
        return "/tmp/\(channel.displayName).sock"
    }

    public static func databasePath(for channel: ReleaseChannel, override: String? = nil) -> String {
        if let override { return override }
        let dir = appSupportDirectory(for: channel)
        return dir.appendingPathComponent("remotecode.sqlite").path
    }
}
