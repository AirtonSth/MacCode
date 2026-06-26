import XCTest
@testable import Persistence
import CoreModel

/// PERSISTENCE-DATA-004 regression: paginating through messages that share a
/// created_at second must not skip or duplicate rows at a page boundary, even
/// when the message UUID order is the REVERSE of insertion (rowid) order.
///
/// The keyset predicate must tiebreak on the SAME key the ORDER BY uses (rowid),
/// otherwise the boundary computed from rowid order is re-filtered by UUID order
/// and rows are dropped or repeated.
final class MessagePaginationBoundaryTests: XCTestCase {

    func test_pagingWithinOneSecond_returnsEveryRowOnceInInsertionOrder() throws {
        let tmp = NSTemporaryDirectory() + "RC2PageBound-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let tr = AgentThreadRepository(db: db)
        let t = AgentThread(title: "tie", provider: .codex, model: "gpt-5")
        try tr.upsert(t)
        let mr = AgentMessageRepository(db: db)

        // All six messages share ONE created_at second, so rowid is the only
        // tiebreak. UUIDs DESCEND as insertion ascends, so id-order is the exact
        // reverse of rowid-order — the case that broke the old boundary.
        let shared = Date(timeIntervalSinceReferenceDate: 5_000)
        let contents = (0..<6).map { "m\($0)" }
        for i in 0..<6 {
            let id = AgentMessageID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 100 - i))!)
            try mr.append(AgentMessage(id: id, threadId: t.id,
                                       role: i.isMultiple(of: 2) ? .user : .assistant,
                                       content: contents[i], createdAt: shared))
        }

        // Walk older pages, two at a time, reconstructing oldest-first.
        var oldestFirst: [String] = []
        var cursor: AgentMessageCursor? = nil
        for _ in 0..<10 {
            let page = try mr.listPage(threadId: t.id, limit: 2, before: cursor)
            oldestFirst = page.messages.map(\.content) + oldestFirst
            guard page.hasMoreOlder else { break }
            cursor = page.nextBefore
        }

        XCTAssertEqual(oldestFirst, contents,
            "every same-second row must appear exactly once, in insertion (rowid) order — no boundary skips or duplicates")
    }
}
