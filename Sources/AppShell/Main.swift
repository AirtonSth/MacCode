import Foundation
import AppKit
import Persistence

@main
@MainActor
struct RemoteCodeMain {
    static func main() {
        let envChannel = ProcessInfo.processInfo.environment["RC2_CHANNEL"] ?? "debug"
        let channel = ReleaseChannel(rawValue: envChannel) ?? .debug
        let appSupportOverride = ProcessInfo.processInfo.environment["RC2_APP_SUPPORT"]
        let dbOverride = ProcessInfo.processInfo.environment["RC2_DB_PATH"]

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(channel: channel, appSupportOverride: appSupportOverride, dbOverride: dbOverride)
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
