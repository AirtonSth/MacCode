import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence

@MainActor
final class SidebarSelectionAndBotOrderTests: XCTestCase {
    private let a = BotID(UUID()), b = BotID(UUID()), c = BotID(UUID())
    private let ws = WorkspaceID(UUID())

    func test_deskSelection_onlyWhenBotsDeskIsActiveSurface() {
        // WHY: a stale selectedBotID must not highlight a row while a workspace owns the content.
        XCTAssertNil(SidebarViewModel.deskSelection(isBotsSelected: false, screen: .desk, botID: a, context: nil, threadID: nil))
        XCTAssertNil(SidebarViewModel.deskSelection(isBotsSelected: true, screen: .studio, botID: a, context: nil, threadID: nil))
        XCTAssertNil(SidebarViewModel.deskSelection(isBotsSelected: true, screen: .desk, botID: nil, context: nil, threadID: nil))
        XCTAssertEqual(SidebarViewModel.deskSelection(isBotsSelected: true, screen: .desk, botID: a, context: nil, threadID: nil)?.botID, a)
    }

    func test_workspaceBotRowSelected_onlyForItsOwnContext() {
        // WHY: "Developer" under elephant must light up, not the same bot under another workspace or General.
        let sel = SidebarViewModel.DeskSelection(botID: a, context: .workspace(ws), threadID: nil)
        XCTAssertTrue(SidebarViewModel.isBotConversationSelected(botID: a, context: .workspace(ws), in: sel))
        XCTAssertFalse(SidebarViewModel.isBotConversationSelected(botID: a, context: .workspace(WorkspaceID(UUID())), in: sel))
        XCTAssertFalse(SidebarViewModel.isBotConversationSelected(botID: a, context: .general, in: sel))
        XCTAssertFalse(SidebarViewModel.isGeneralBotSelected(a, in: sel))
        XCTAssertFalse(SidebarViewModel.isBotConversationSelected(botID: b, context: .workspace(ws), in: sel))
    }

    func test_generalBotRowSelected_forGeneralOrLegacyChat() {
        XCTAssertTrue(SidebarViewModel.isGeneralBotSelected(a, in: .init(botID: a, context: .general, threadID: nil)))
        XCTAssertTrue(SidebarViewModel.isGeneralBotSelected(a, in: .init(botID: a, context: nil, threadID: nil)))
        XCTAssertFalse(SidebarViewModel.isGeneralBotSelected(a, in: nil))
    }

    func test_reorderedBotIDs_landsBeforeTarget_inBothDirections() {
        XCTAssertEqual(SidebarViewModel.reorderedBotIDs([a, b, c], moving: a, before: c), [b, a, c])
        XCTAssertEqual(SidebarViewModel.reorderedBotIDs([a, b, c], moving: c, before: a), [c, a, b])
        XCTAssertEqual(SidebarViewModel.reorderedBotIDs([a, b, c], moving: a, before: a), [a, b, c])
        XCTAssertEqual(SidebarViewModel.reorderedBotIDs([a, b], moving: c, before: a), [a, b])
    }

    func test_untitledThread_visibleOnlyWhenRunningOrSelected() {
        // WHY: a running "New thread" had no row at all, so nothing showed it was running.
        let t = AgentThreadID(UUID())
        XCTAssertFalse(SidebarViewModel.showsThread(title: "New thread", id: t, keep: []))
        XCTAssertTrue(SidebarViewModel.showsThread(title: "New thread", id: t, keep: [t]))
        XCTAssertTrue(SidebarViewModel.showsThread(title: "Fix bug", id: t, keep: []))
    }

    func test_dragReorder_survivesSidebarReload_evenWhenMRUWouldDisagree() throws {
        // WHY: reload() used to re-sort by last activity, silently undoing the user's drop.
        let dir = NSTemporaryDirectory() + "RC2SidebarDrag-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = SidebarViewModel(context: ctx, router: router)
        let first = try router.createWorkspace(name: "one", cwd: "/a")
        let second = try router.createWorkspace(name: "two", cwd: "/b")
        let third = try router.createWorkspace(name: "three", cwd: "/c")
        vm.reload()
        vm.reorderWorkspace(third.id, before: first.id)
        vm.reload()
        XCTAssertEqual(vm.workspaces.map(\.id), [third.id, first.id, second.id])
    }

    func test_duplicateTitleAges_onlyForRepeatedTitles() {
        // WHY: identical conversation titles were indistinguishable; unique ones must stay clean.
        let now = Date(timeIntervalSince1970: 100_000)
        func row(_ title: String, ago: TimeInterval) -> SidebarViewModel.WorkspaceConversationRow {
            .init(threadID: AgentThreadID(UUID()), workspaceID: ws, title: title, botID: nil, updatedAt: now.addingTimeInterval(-ago))
        }
        let a = row("Fix bug", ago: 240), b = row("Fix bug", ago: 7_200), c = row("Other", ago: 10), d = row("Fix bug", ago: 5)
        let ages = SidebarViewModel.duplicateTitleAges([a, b, c, d], now: now)
        XCTAssertEqual(ages[a.id], "4m")
        XCTAssertEqual(ages[b.id], "2h")
        XCTAssertEqual(ages[d.id], "now")
        XCTAssertNil(ages[c.id])
        // Titles equal only after truncation still collide.
        let long = String(repeating: "x", count: 40)
        let e = row(long + "1", ago: 60), f = row(long + "2", ago: 120)
        XCTAssertEqual(SidebarViewModel.duplicateTitleAges([e, f], now: now).count, 2)
    }
}
