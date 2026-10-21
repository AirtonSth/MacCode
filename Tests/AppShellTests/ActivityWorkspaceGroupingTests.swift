import XCTest
import SwiftUI
import DesignSystemKit
@testable import AppShell

/// Activity groups each section by workspace. A workspace's rows must never mix with another's,
/// and grouping must not change how many items a section shows.
final class ActivityWorkspaceGroupingTests: XCTestCase {
    private func item(_ id: String, workspaceID: String?, name: String? = nil, color: String? = nil, at date: String) -> ActivityWireItem {
        ActivityWireItem(
            id: id, kind: "agent", run_id: nil, request_id: nil, notification_id: nil,
            workspace_id: workspaceID, thread_id: nil, surface_id: nil, state: "completed", title: id,
            workspace_name: name, workspace_color: color, provider: nil, summary: nil, occurred_at: date,
            started_at: nil, finished_at: nil, viewed_at: nil, attention_acknowledged_at: nil,
            needs_action: false, blocking: false, final_message_id: nil, checkpoint_id: nil, error: nil
        )
    }

    func test_interleavedWorkspacesSplitIntoGroupsNewestFirstKeepingItemOrder() {
        let items = [
            item("a1", workspaceID: "A", name: "api", color: "blue", at: "2026-10-21T12:00:00Z"),
            item("b1", workspaceID: "B", name: "web", color: "green", at: "2026-10-21T11:00:00Z"),
            item("a2", workspaceID: "A", name: "api", color: "blue", at: "2026-10-21T10:00:00Z"),
            item("b2", workspaceID: "B", name: "web", color: "green", at: "2026-10-21T09:00:00Z"),
        ]
        let groups = ActivityWorkspaceGrouping.groups(items: items)

        XCTAssertEqual(groups.map(\.id), ["A", "B"], "the group holding the newest item comes first")
        XCTAssertEqual(groups[0].items.map(\.id), ["a1", "a2"], "a workspace's items are never mixed with another's")
        XCTAssertEqual(groups[1].items.map(\.id), ["b1", "b2"])
        XCTAssertEqual(groups[0].colorRaw, "blue")
        XCTAssertEqual(groups.map(\.count).reduce(0, +), items.count, "grouping keeps every item in the section")
    }

    func test_itemsWithoutWorkspaceGoToLastNoWorkspaceGroup() {
        let items = [
            item("bot", workspaceID: nil, at: "2026-10-21T12:00:00Z"),
            item("a1", workspaceID: "A", name: "api", at: "2026-10-21T10:00:00Z"),
        ]
        let groups = ActivityWorkspaceGrouping.groups(items: items)

        XCTAssertEqual(groups.map(\.id), ["A", ""], "the no-workspace group is last even when its item is newest")
        XCTAssertEqual(groups.last?.name, ActivityWorkspaceGrouping.noWorkspaceName)
        XCTAssertNil(groups.last?.colorRaw)
    }

    func test_sameNameDifferentIDsStaySeparateGroups() {
        let items = [
            item("a1", workspaceID: "A", name: "api", at: "2026-10-21T12:00:00Z"),
            item("b1", workspaceID: "B", name: "api", at: "2026-10-21T11:00:00Z"),
        ]
        let groups = ActivityWorkspaceGrouping.groups(items: items)

        XCTAssertEqual(groups.count, 2, "two workspaces with one name are still two workspaces")
        XCTAssertEqual(groups.map { $0.items.count }, [1, 1])
    }

    func test_knownColorResolvesToTabHexAndUnknownOrMissingIsNeutral() {
        XCTAssertEqual(ActivityWorkspaceGrouping.tint("blue"), Color(hex: 0x7CC7FF))
        XCTAssertEqual(ActivityWorkspaceGrouping.tint("not-a-color"), DS.Palette.textSecondary)
        XCTAssertEqual(ActivityWorkspaceGrouping.tint(nil), DS.Palette.textSecondary)
    }
}
