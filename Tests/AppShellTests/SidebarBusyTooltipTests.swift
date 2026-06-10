import XCTest
@testable import AppShell

/// Tests for `SidebarViewModel.busyTooltip(runningThreadTitles:busySurfaceTitles:)`.
///
/// The helper is `nonisolated static`, so no `@MainActor` annotation is needed.
/// Each test encodes a business rule that fails when the tooltip derivation changes incorrectly.
final class SidebarBusyTooltipTests: XCTestCase {

    // MARK: - Idle

    func test_idle_returnsNil() {
        // When no threads are running and no surfaces are busy, the indicator
        // has no active source to report, so the tooltip must be absent.
        let result = SidebarViewModel.busyTooltip(
            runningThreadTitles: [],
            busySurfaceTitles: []
        )
        XCTAssertNil(result)
    }

    // MARK: - Thread-busy

    func test_threadBusy_tooltipNamesTheThread() {
        // A running thread called "Fix CI" must appear in the tooltip so the
        // user can identify which agent run is active from the sidebar indicator.
        let result = SidebarViewModel.busyTooltip(
            runningThreadTitles: ["Fix CI"],
            busySurfaceTitles: []
        )
        XCTAssertEqual(result, "Agent run in thread \"Fix CI\"")
    }

    func test_threadBusy_multipleThreads_useFirstTitle() {
        // When several threads are running simultaneously only the first title
        // is shown; the indicator is a compact hint, not a full enumeration.
        let result = SidebarViewModel.busyTooltip(
            runningThreadTitles: ["Fix CI", "Deploy staging"],
            busySurfaceTitles: []
        )
        XCTAssertEqual(result, "Agent run in thread \"Fix CI\"")
    }

    func test_threadBusy_emptyTitle_showsUntitled() {
        // A thread with a blank title must still produce a tooltip that
        // references "Untitled" rather than showing an empty quoted string.
        let result = SidebarViewModel.busyTooltip(
            runningThreadTitles: [""],
            busySurfaceTitles: []
        )
        XCTAssertEqual(result, "Agent run in thread \"Untitled\"")
    }

    // MARK: - Surface-busy

    func test_surfaceBusy_tooltipNamesTheSurface() {
        // A busy terminal surface titled "bash" must appear in the tooltip so
        // the user can see which surface is executing work.
        let result = SidebarViewModel.busyTooltip(
            runningThreadTitles: [],
            busySurfaceTitles: ["bash"]
        )
        XCTAssertEqual(result, "Terminal job running in \"bash\"")
    }

    func test_surfaceBusy_multipleSurfaces_useFirstTitle() {
        // When multiple surfaces are busy only the first title is surfaced; the
        // tooltip is a brief hint, not an exhaustive list.
        let result = SidebarViewModel.busyTooltip(
            runningThreadTitles: [],
            busySurfaceTitles: ["bash", "zsh"]
        )
        XCTAssertEqual(result, "Terminal job running in \"bash\"")
    }

    func test_surfaceBusy_emptyTitle_showsFallback() {
        // A busy surface with a blank title must still produce a tooltip using
        // the generic "terminal" label rather than an empty quoted string.
        let result = SidebarViewModel.busyTooltip(
            runningThreadTitles: [],
            busySurfaceTitles: [""]
        )
        XCTAssertEqual(result, "Terminal job running in \"terminal\"")
    }

    // MARK: - Thread priority over surface

    func test_threadBusyAndSurfaceBusy_threadWins() {
        // When both a running thread and a busy surface exist the thread tooltip
        // takes priority because agent runs are the primary work unit in the sidebar.
        let result = SidebarViewModel.busyTooltip(
            runningThreadTitles: ["Refactor auth"],
            busySurfaceTitles: ["bash"]
        )
        XCTAssertEqual(result, "Agent run in thread \"Refactor auth\"")
    }
}
