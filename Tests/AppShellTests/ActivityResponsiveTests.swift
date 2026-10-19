import XCTest
import SwiftUI
import AppKit
@testable import AppShell
import SocketServer

/// WHY: Activity opens in resizable panes; its header (search + pickers + tabs) must fit
/// 320, 500 and 900 pt instead of forcing the pane wider.
@MainActor
final class ActivityResponsiveTests: XCTestCase {
    func test_activityFitsNarrowMediumAndWidePanes() {
        let defaults = UserDefaults(suiteName: "activity-responsive-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in .object(["items": .array([]), "counts": .object([:])]) },
            setViewed: { _ in .object([:]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        let root = ActivityRootView(model: model, workspaceOptions: { [("workspace", "a workspace with a long name")] })
        let controller = NSHostingController(rootView: root)
        for width in [320.0, 500.0, 900.0] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 800))
            XCTAssertLessThanOrEqual(size.width, width + 0.5, "Activity must fit a \(Int(width)) pt pane")
        }
    }
}
