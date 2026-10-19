import XCTest
import SwiftUI
import AppKit
@testable import AppShell

/// WHY: every screen opens in a resizable pane or window; none may force a width
/// wider than a narrow pane (320 pt) at its root.
@MainActor
final class AppResponsiveMinimumWidthTests: XCTestCase {
    func test_botsScreenFitsNarrowMediumAndWidePanes() throws {
        let directory = NSTemporaryDirectory() + "RC2Responsive-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let controller = NSHostingController(rootView: BotsRootView(vm: BotsViewModel(context: context)))
        for width in [360.0, 500.0, 900.0] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 800))
            XCTAssertLessThanOrEqual(size.width, width + 0.5, "Bots must fit a \(Int(width)) pt content column")
        }
    }

    func test_noScreenRootDemandsMoreThanANarrowPane() throws {
        // Root/sheet minimum widths are read from the shipped sources; any regression back to
        // 540-980 pt minimums fails here.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Sources/AppShell/BotsWindow.swift", "Sources/AppShell/ScheduledTasksWindow.swift", "Sources/AppShell/SettingsWindow.swift",
                     "Sources/AppShell/ActivityWindow.swift", "Sources/AppShell/BotsTeamsGroups.swift", "Sources/AppShell/TitioQuickChat.swift",
                     "Sources/AppShell/BotContextExportSheet.swift", "Sources/AppShell/SSHSurface.swift", "Sources/AppShell/FilesSurface.swift",
                     "Sources/AppShell/DistillAccountsSettingsSection.swift", "Sources/Surfaces/DiffPanelSurface.swift"]
        let pattern = try NSRegularExpression(pattern: #"\.frame\((?:minWidth|width): (\d+)"#)
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let value = Int(ns.substring(with: match.range(at: 1))) ?? 0
                XCTAssertLessThanOrEqual(value, 360, "\(file) forces \(value) pt: \(ns.substring(with: match.range))")
            }
        }
    }

    func test_settingsScheduleAndBotsRenderAtNarrowMediumAndWideWidths() throws {
        // WHY: these screens are the ones the user resizes into splits; each must lay out
        // inside 360, 500 and 900 pt without demanding more width.
        let directory = NSTemporaryDirectory() + "RC2ResponsiveRender-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let screens: [(String, AnyView)] = [
            ("settings", AnyView(SettingsView(vm: SettingsViewModel(context: context)))),
            ("schedule", AnyView(ScheduledTasksRootView(vm: ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)))),
            ("bots", AnyView(BotsRootView(vm: BotsViewModel(context: context)))),
        ]
        let artifacts = ProcessInfo.processInfo.environment["REMOTE_CODE_RESPONSIVE_ARTIFACT_DIR"]
        for (name, view) in screens {
            for width in [360.0, 500.0, 900.0] {
                let controller = NSHostingController(rootView: view)
                let fit = controller.sizeThatFits(in: CGSize(width: width, height: 800))
                XCTAssertLessThanOrEqual(fit.width, width + 0.5, "\(name) must fit \(Int(width)) pt")
                guard let artifacts else { continue }
                let host = NSHostingView(rootView: view.frame(width: width, height: 700))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                host.appearance = NSAppearance(named: .darkAqua)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: artifacts).appendingPathComponent("\(name)-\(Int(width)).png"))
                window.contentView = nil
            }
        }
    }
}
