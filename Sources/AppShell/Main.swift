import Foundation
import AppKit
import Persistence

@main
@MainActor
struct RemoteCodeMain {
    static func main() {
        // Priority: explicit env override -> bundle-id derivation -> .debug
        let channel: ReleaseChannel
        if let envRaw = ProcessInfo.processInfo.environment["RC2_CHANNEL"],
           let envChannel = ReleaseChannel(rawValue: envRaw) {
            channel = envChannel
        } else {
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            channel = ReleaseChannel.channelFromBundleID(bundleID)
        }
        let appSupportOverride = ProcessInfo.processInfo.environment["RC2_APP_SUPPORT"]
        let dbOverride = ProcessInfo.processInfo.environment["RC2_DB_PATH"]

        let app = NSApplication.shared
        RemoteCodeAppearance.apply(to: app)
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(channel: channel, appSupportOverride: appSupportOverride, dbOverride: dbOverride)
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
