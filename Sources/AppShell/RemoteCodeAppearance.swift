import AppKit

@MainActor
enum RemoteCodeAppearance {
    private static var darkAppearance: NSAppearance? {
        NSAppearance(named: .darkAqua)
    }

    static func apply(to app: NSApplication) {
        app.appearance = darkAppearance
    }

    static func apply(to window: NSWindow) {
        window.appearance = darkAppearance
    }

    static func apply(to view: NSView) {
        view.appearance = darkAppearance
    }
}
