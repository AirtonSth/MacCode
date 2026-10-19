import XCTest
import CoreModel
import Persistence
@testable import AppShell
import SocketServer

/// WHY: a Bot's run in Activity must show that Bot's avatar so the user sees who is working;
/// plain Agent App runs keep the status icon.
@MainActor
final class ActivityBotAvatarTests: XCTestCase {
    private func item(threadID: String?, botID: String? = nil) -> ActivityWireItem {
        var item = ActivityWireItem(
            id: UUID().uuidString, kind: "agent", run_id: "run", request_id: nil, notification_id: nil,
            workspace_id: "workspace", thread_id: threadID, surface_id: nil, state: "running",
            title: "Crie um robo", workspace_name: "star", provider: "distill", summary: nil,
            occurred_at: "2026-10-19T18:00:00Z", started_at: nil, finished_at: nil, viewed_at: nil,
            attention_acknowledged_at: nil, needs_action: false, blocking: false,
            final_message_id: nil, checkpoint_id: nil, changed_files: [], error: nil
        )
        item.bot_id = botID
        return item
    }

    func test_botThreadResolvesItsBotAndPlainThreadResolvesNone() throws {
        let directory = NSTemporaryDirectory() + "RC2ActivityAvatar-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let store = context.botStore
        let bot = try store.create(name: "Developer", title: "", description: "", handle: "star-developer")
        let thread = AgentThread(title: "Crie um robo", provider: .distill, model: "fixture")
        try context.threadRepo.upsert(thread)
        try store.upsertConversation(BotConversation(botID: bot.id, title: "Crie um robo", linkedAgentThreadID: thread.id))

        XCTAssertEqual(ActivityBotResolver.botID(for: item(threadID: thread.id.value.uuidString), store: store), bot.id,
                       "an Activity row for a Bot's thread must resolve that Bot for its avatar")
        XCTAssertEqual(ActivityBotResolver.botID(for: item(threadID: nil, botID: bot.id.value.uuidString), store: store), bot.id,
                       "a bot_id on the item is enough on its own")
        XCTAssertNil(ActivityBotResolver.botID(for: item(threadID: UUID().uuidString), store: store),
                     "a plain Agent App thread has no Bot, so the row keeps its status icon")

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AppShell/ActivityWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("bot: botForItem(item)"), "the list must pass the resolved Bot into each row")
        XCTAssertTrue(source.contains("if let bot {\n                BotsAvatarView("), "the row must draw the Bot avatar when it has one")
    }
}
