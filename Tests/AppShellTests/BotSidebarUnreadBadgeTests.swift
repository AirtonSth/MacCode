import XCTest
import CoreModel
@testable import AppShell
import Persistence

@MainActor
final class BotSidebarUnreadBadgeTests: XCTestCase {
    func test_generalBotRowCountsUnreadConversations_andTitioUsesItsInboxCount() throws {
        // WHY: the sidebar badge tells people a Bot has messages they have not read;
        // a read conversation must not count, and Titio's count is its notice inbox.
        let directory = NSTemporaryDirectory() + "RC2SidebarUnread-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let bot = try context.botStore.create(name: "Star", title: "", description: "", handle: "star", workspaceID: nil)
        var unread = BotConversation(botID: bot.id, title: "a"); unread.unread = true
        var read = BotConversation(botID: bot.id, title: "b"); read.unread = false
        try context.botStore.upsertConversation(unread)
        try context.botStore.upsertConversation(read)
        let tree = SidebarViewModel.loadSidebarTree(
            botStore: context.botStore, threadRepo: context.threadRepo,
            hostID: context.liveActivityHostIdentity.serverId, expanded: []
        )
        let rows = try XCTUnwrap(tree?.general)
        XCTAssertEqual(rows.first { $0.botID == bot.id }?.unreadCount, 1)
        if let titio = rows.first(where: \.isTitio) { XCTAssertEqual(titio.unreadCount, 0) }
    }

    func test_titioBadgeIsThePetAndDockTotal() {
        // WHY: Titio showed 2 while the pet, Dock and Activity showed nothing; every
        // surface must show the same needs-you plus just-finished number.
        let counts = PetActivityCounts(running: 4, needsYou: 2, newResults: 3)
        XCTAssertEqual(SidebarViewModel.titioBadgeCount(counts), counts.badgeTotal)
        XCTAssertEqual(SidebarViewModel.titioBadgeCount(counts), 5)
        XCTAssertEqual(ActivityDockBadge.label(for: counts), "5")
        XCTAssertEqual(SidebarViewModel.titioBadgeCount(.zero), 0, "unknown counts hide the badge like the Dock")
    }

    func test_activityItemIDsForReadNotices_areUniqueAndCoverRunsAndNotifications() {
        // WHY: reading Titio's inbox marks the same items read in Activity.
        func record(_ key: String, _ source: TitioNoticeSource) -> TitioNoticeRecord {
            TitioNoticeRecord(key: key, kind: .runCompleted, urgency: .info, source: source, facts: TitioNoticeFacts(),
                              actions: nil, state: .posted, resolution: nil, messageID: nil, batchID: nil,
                              occurredAt: Date(), postedAt: Date(), bannerAt: nil, resolvedAt: nil)
        }
        let ids = TitioNoticeCenter.activityItemIDs([
            record("1", TitioNoticeSource(runId: "ABC")),
            record("2", TitioNoticeSource(runId: "abc")),
            record("3", TitioNoticeSource(notificationId: "n1")),
            record("4", TitioNoticeSource()),
        ])
        XCTAssertEqual(ids, ["run:abc", "notification:n1"])
    }
}
