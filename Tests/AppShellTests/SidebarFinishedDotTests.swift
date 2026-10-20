import XCTest
@testable import AppShell

/// WHY: the owner (2026-10-20) wants every submenu row (conversation, Bot,
/// terminal tab) to show the green dot when its work just finished, like the
/// workspace row, until the user opens it.
final class SidebarFinishedDotTests: XCTestCase {
    func test_rowThatStoppedRunningGetsTheDotUntilItRunsAgain() {
        let finished = SidebarViewModel.finishedAfterTransition(previous: ["a", "b"], now: ["b"], current: [], except: nil)
        XCTAssertEqual(finished, ["a"])
        XCTAssertEqual(SidebarViewModel.finishedAfterTransition(previous: ["b"], now: ["a", "b"], current: finished, except: nil), [],
                       "running again replaces the dot with the spinner")
    }

    func test_rowOnScreenNeverGetsTheDot() {
        XCTAssertEqual(SidebarViewModel.finishedAfterTransition(previous: ["a"], now: [], current: [], except: "a"), [])
    }

    func test_everyChildRowRendersTheDot() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "{ finishedDot }").count - 1, 4, "conversation, workspace Bot, general Bot and open tab rows")
    }
}

/// WHY: the owner (2026-10-20) wants anything with a spinner on top, never above pinned.
final class SidebarRunningFirstTests: XCTestCase {
    func test_runningMovesUpButNeverAbovePinned() {
        let order = SidebarViewModel.runningFirst(["pin", "a", "b", "c", "d"], isPinned: { $0 == "pin" }, isRunning: { $0 == "c" || $0 == "pin" })
        XCTAssertEqual(order, ["pin", "c", "a", "b", "d"])
    }
}
