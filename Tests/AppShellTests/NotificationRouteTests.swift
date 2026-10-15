import XCTest
import CoreModel
@testable import AppShell

/// Titio banners open the inbox message (hub spec §9); every legacy payload
/// must keep routing exactly as before.
@MainActor
final class NotificationRouteTests: XCTestCase {
    func test_botPayloadRoutesToTheConversationAndMessage() throws {
        // WHY: a banner click must land on the notice it announced.
        let bot = UUID(), conversation = UUID(), message = UUID()
        let intent = try XCTUnwrap(AppDelegate.routeFromNotification(userInfo: [
            "botId": bot.uuidString.lowercased(),
            "conversationId": conversation.uuidString.lowercased(),
            "messageId": message.uuidString.lowercased(),
            // Legacy keys ride along for old clients; the bot branch wins.
            "threadId": UUID().uuidString,
            "category": RemoteCodeNotificationContent.titioNoticeCategoryIdentifier,
        ]))
        XCTAssertEqual(intent.bot, NotificationRouteIntent.BotRoute(
            botId: BotID(bot), conversationId: BotConversationID(conversation), messageId: AgentMessageID(message)
        ))
        XCTAssertNil(intent.threadId, "the bot route does not also open the thread")
        XCTAssertFalse(intent.opensActivity)
    }

    func test_botPayloadWithoutMessageStillOpensTheConversation() throws {
        let bot = UUID(), conversation = UUID()
        let intent = try XCTUnwrap(AppDelegate.routeFromNotification(userInfo: [
            "botId": bot.uuidString, "conversationId": conversation.uuidString,
        ]))
        XCTAssertEqual(intent.bot?.conversationId, BotConversationID(conversation))
        XCTAssertNil(intent.bot?.messageId)
    }

    func test_legacyPayloadsRouteAsBefore() throws {
        // WHY: the kill switch and old banners still carry today's keys.
        let thread = UUID(), workspace = UUID(), final = UUID()
        let threadIntent = try XCTUnwrap(AppDelegate.routeFromNotification(userInfo: [
            "threadId": thread.uuidString, "workspaceId": workspace.uuidString, "finalMessageId": final.uuidString,
        ]))
        XCTAssertEqual(threadIntent, NotificationRouteIntent(
            threadId: AgentThreadID(thread), workspaceId: WorkspaceID(workspace), finalMessageId: AgentMessageID(final)
        ))
        let activity = try XCTUnwrap(AppDelegate.routeFromNotification(userInfo: ["activityItemId": "run:abc"]))
        XCTAssertTrue(activity.opensActivity)
        XCTAssertNil(activity.bot)
        XCTAssertNil(AppDelegate.routeFromNotification(userInfo: ["outcome": "completed"]))
    }

    func test_botIdWithoutConversationFallsBackToTheLegacyRoute() throws {
        // WHY: a partial bot payload must not swallow a valid thread route.
        let thread = UUID()
        let intent = try XCTUnwrap(AppDelegate.routeFromNotification(userInfo: [
            "botId": UUID().uuidString, "threadId": thread.uuidString,
        ]))
        XCTAssertNil(intent.bot)
        XCTAssertEqual(intent.threadId, AgentThreadID(thread))
    }

    func test_pushDataOmitsBotIdWithoutAProfileBinding() {
        // WHY: iOS bot routes need profileId + hostId; with a botId but no
        // profile the route would be nil, so the push must fall back to the
        // legacy thread/Activity keys instead (§8).
        let unbound = RemoteCodeNotificationContent.titioNoticeUserInfo(
            botID: "b", conversationID: "c", messageID: "m", noticeKey: "run.R.failed",
            identifier: "run.R.failed", profileID: nil, hostID: "h",
            legacy: ["threadId": "T", "outcome": "failed", "runId": " "]
        )
        XCTAssertNil(unbound["botId"])
        XCTAssertEqual(unbound["threadId"], "T")
        XCTAssertNil(unbound["runId"], "blank legacy values are dropped")
        XCTAssertEqual(unbound["attentionItemId"], "titio.inbox.c")
        XCTAssertEqual(unbound["acknowledgeBotOnOpen"], "false")
        XCTAssertEqual(unbound["idempotencyKey"], "run.R.failed")
        XCTAssertEqual(unbound["category"], "RemoteCodeTitioNotice")

        let bound = RemoteCodeNotificationContent.titioNoticeUserInfo(
            botID: "b", conversationID: "c", messageID: "m", noticeKey: nil,
            identifier: "x", profileID: "p", hostID: "h"
        )
        XCTAssertEqual(bound["botId"], "b")
        XCTAssertEqual(bound["profileId"], "p")
        XCTAssertEqual(bound["hostId"], "h")
        XCTAssertNil(bound["noticeKey"])

        let macBanner = RemoteCodeNotificationContent.titioNoticeUserInfo(
            botID: "b", conversationID: "c", messageID: "m", noticeKey: nil,
            identifier: "x", profileID: nil, hostID: nil, includeBotIdWithoutProfile: true
        )
        XCTAssertEqual(macBanner["botId"], "b", "the Mac banner always opens the inbox")
    }

    func test_titioBannerContentUsesTheTitioCategoryAndFirstLine() {
        let content = RemoteCodeNotificationContent.titioNotice(
            identifier: "run.R.completed", body: "Heads up: **Build** in **api** is done.\nSummary: “ok”", userInfo: [:]
        )
        XCTAssertEqual(content.title, "Titio")
        XCTAssertEqual(content.body, "Heads up: Build in api is done.")
        XCTAssertEqual(content.categoryIdentifier, "RemoteCodeTitioNotice")
        XCTAssertEqual(content.threadIdentifier, "bot.titio")
    }

    func test_titioCategoryIsRegisteredWithOpenOnly() {
        // WHY: approve/decline from the lock screen is out of scope (§14).
        let titio = SystemNotifier.notificationCategories.first { $0.identifier == "RemoteCodeTitioNotice" }
        XCTAssertEqual(titio?.actions.map(\.identifier), [RemoteCodeNotificationContent.openActionIdentifier])
        XCTAssertNotNil(SystemNotifier.notificationCategories.first {
            $0.identifier == RemoteCodeNotificationContent.threadUpdateCategoryIdentifier
        }, "the legacy category stays registered")
    }
}
