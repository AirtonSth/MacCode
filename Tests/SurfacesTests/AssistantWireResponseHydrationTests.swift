import XCTest
@testable import Surfaces
import CoreModel
import Persistence

final class AssistantWireResponseHydrationTests: XCTestCase {
    func test_offMainHydrationFollowsEveryTwentyFiveRowMessagePage() async throws {
        let root = NSTemporaryDirectory() + "rcw1-response-pages-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let thread = AgentThread(title: "paged responses", provider: .codex, model: "test-model")
        try threads.upsert(thread)

        var expected: [AgentMessageID: String] = [:]
        for index in 0..<30 {
            let message = AgentMessage(
                threadId: thread.id,
                role: .assistant,
                content: "Readable response \(index)",
                createdAt: Date(timeIntervalSince1970: Double(1_700_000_000 + index))
            )
            let wire = "RCW1\tA\t1\nO\tResponse \(index)\n.\n"
            try messages.append(message)
            try messages.upsertRCW1ResponseTranslation(
                messageId: message.id,
                runId: AgentRunID(),
                turnId: "turn-\(index)",
                wireResponseText: wire
            )
            expected[message.id] = wire
        }

        let recentLoaded = await AgentAppViewModel.loadMessagePageOffMain(
            repository: messages,
            threadId: thread.id
        )
        let recent = try XCTUnwrap(recentLoaded)
        XCTAssertEqual(recent.rows.count, 25)
        XCTAssertTrue(recent.hasMoreOlder)
        let recentResponses = await AgentAppViewModel.loadPersistedAssistantRCW1ResponsesOffMain(
            repository: messages,
            threadId: thread.id,
            messageIds: recent.rows.map(\.id)
        )
        XCTAssertEqual(recentResponses.count, 25)
        for message in recent.rows {
            XCTAssertEqual(recentResponses[message.id]?.wireResponseText, expected[message.id])
        }

        let oldestRecent = try XCTUnwrap(recent.rows.first)
        let olderLoaded = await AgentAppViewModel.loadMessagePageOffMain(
            repository: messages,
            threadId: thread.id,
            before: AgentMessageCursor(createdAt: oldestRecent.createdAt, id: oldestRecent.id)
        )
        let older = try XCTUnwrap(olderLoaded)
        XCTAssertEqual(older.rows.count, 5)
        XCTAssertFalse(older.hasMoreOlder)
        let olderResponses = await AgentAppViewModel.loadPersistedAssistantRCW1ResponsesOffMain(
            repository: messages,
            threadId: thread.id,
            messageIds: older.rows.map(\.id)
        )
        XCTAssertEqual(olderResponses.count, 5)
        for message in older.rows {
            XCTAssertEqual(olderResponses[message.id]?.wireResponseText, expected[message.id])
        }
        XCTAssertEqual(Set(recentResponses.keys).union(olderResponses.keys).count, 30,
                       "loading older pages must hydrate every row without scanning unbounded history")
    }
}
