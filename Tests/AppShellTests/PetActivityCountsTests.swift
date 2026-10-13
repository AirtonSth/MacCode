import Persistence
import XCTest
@testable import AppShell

@MainActor
final class PetActivityCountsTests: XCTestCase {
    func testProjectionUsesServiceCountsNotLoadedItemCount() {
        let pageCounts = ActivityCounts(running: 7, queued: 2, needsYou: 3, finished: 20, newResults: 5)
        let projection = PetActivityCounts(pageCounts)

        XCTAssertEqual(projection.running, 7)
        XCTAssertEqual(projection.needsYou, 3)
        XCTAssertEqual(projection.newResults, 5)
    }

    func testWorkspaceIndicatorUsesOnlyConcreteActivityStates() {
        XCTAssertEqual(
            SidebarRootView.workspaceActivityLabel(PetActivityCounts(running: 2, needsYou: 1, newResults: 3)),
            "2 running · 1 needs you"
        )
        XCTAssertEqual(
            SidebarRootView.workspaceActivityLabel(PetActivityCounts(running: 0, needsYou: 0, newResults: 3)),
            "New result"
        )
        XCTAssertEqual(
            SidebarRootView.workspaceActivityLabel(PetActivityCounts.zero),
            "Activity unavailable"
        )
        XCTAssertEqual(
            SidebarRootView.workspaceActivityLabel(PetActivityCounts(running: 0, needsYou: 0, newResults: 0)),
            ""
        )
        XCTAssertEqual(
            SidebarViewModel.workspaceRowAccessibilityValue(
                busyDescription: nil,
                unreadCount: 0,
                activityDescription: "2 needs you",
                pinned: false,
                checked: false
            ),
            "2 needs you",
            "Legacy unread-event totals must never leak into workspace Activity status."
        )
    }

    func testNotificationReadEventRefreshesObserverWithoutWorkspaceReselection() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("PetActivityCounts-\(UUID().uuidString)")
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let id = try router.notificationCreate(
            workspaceId: workspace.id,
            title: "Agent input requested",
            body: "Review the active Agent thread",
            category: PetNotificationCategory.agentAttention.rawValue
        )
        let projection = PetActivityCountsProjection.shared
        var observed = PetActivityCounts.zero
        let token = projection.observe { counts, _ in observed = counts }
        defer { projection.removeObserver(token) }

        projection.refresh(router: router, workspaceIDs: [workspace.id])
        await waitForCount(1, observed: { observed.needsYou })
        XCTAssertEqual(observed.needsYou, 1)
        try router.notificationMarkRead(id: id)
        await waitForCount(0, observed: { observed.needsYou })
        XCTAssertEqual(observed.needsYou, 0)
    }

    private func waitForCount(
        _ expected: Int,
        observed: () -> Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if observed() == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for count \(expected); got \(observed())", file: file, line: line)
    }

    func testPetBadgeUsesNeedsYouCountAndExistingPreference() {
        let enabled = PetViewModel(settings: AppSettings(petEnabled: true, petReadyCounterEnabled: true))
        enabled.apply(activityCounts: PetActivityCounts(running: 4, needsYou: 2, newResults: 6))
        XCTAssertEqual(enabled.badgeText, "2")
        XCTAssertTrue(enabled.accessibilityValue.contains("4 running"))
        XCTAssertTrue(enabled.accessibilityValue.contains("2 items need attention"))

        let disabled = PetViewModel(settings: AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        disabled.apply(activityCounts: PetActivityCounts(running: 4, needsYou: 2, newResults: 6))
        XCTAssertNil(disabled.badgeText)
    }
}
