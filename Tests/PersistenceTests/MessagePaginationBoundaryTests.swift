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

    func test_byteBoundedKeysetPagesReturnEveryRowOnceWithoutFullHistoryScan() throws {
        let tmp = NSTemporaryDirectory() + "RC2PageBudget-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "bounded", provider: .codex, model: "gpt-5")
        try AgentThreadRepository(db: db).upsert(thread)
        let messages = AgentMessageRepository(db: db)
        let shared = Date(timeIntervalSinceReferenceDate: 7_000)
        for index in 0..<9 {
            try messages.append(AgentMessage(
                threadId: thread.id,
                role: .assistant,
                content: "m\(index)-" + String(repeating: "x", count: 40),
                createdAt: shared
            ))
        }

        var cursor: AgentMessageCursor? = nil
        var collected: [String] = []
        for _ in 0..<10 {
            let page = try messages.listPageWithinBodyBudget(
                threadId: thread.id,
                limit: 3,
                before: cursor,
                budget: 10_000,
                contentLimit: 80_000
            )
            XCTAssertLessThanOrEqual(page.rows.count, 3)
            collected = page.rows.map(\.content) + collected
            guard page.hasMoreOlder else { break }
            cursor = page.nextBefore
        }
        XCTAssertEqual(collected, (0..<9).map { "m\($0)-" + String(repeating: "x", count: 40) },
                       "bounded keyset pages must neither duplicate nor skip same-timestamp rows")
    }

    func test_listPageWithinBodyBudget_afterCursorAndOriginalByteCounts() throws {
        let tmp = NSTemporaryDirectory() + "RC2PageBudgetAfter-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "after-budget", provider: .codex, model: "gpt-5")
        try AgentThreadRepository(db: db).upsert(thread)
        let messages = AgentMessageRepository(db: db)
        let base = Date(timeIntervalSinceReferenceDate: 9_000)
        let attachments = (0..<100).map { index in
            let digest = String(format: "%064x", index + 1)
            return AgentAttachment(
                id: digest,
                path: "/private/sql-boundary-\(index)",
                displayName:
                    String(repeating: "attachment-\(index)-", count: 20),
                kind: .file,
                mimeType: "text/plain",
                sha256: digest,
                sizeBytes: index + 1
            )
        }
        var ids: [AgentMessageID] = []
        for index in 0..<5 {
            let id = AgentMessageID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
            ids.append(id)
            let body = index == 4
                ? String(repeating: "🙂", count: 2_000)
                : "m\(index)"
            try messages.append(AgentMessage(
                id: id,
                threadId: thread.id,
                role: .assistant,
                content: body,
                createdAt: base.addingTimeInterval(TimeInterval(index)),
                attachments: index == 4 ? attachments : []
            ))
        }

        let afterFirst = try messages.listPageWithinBodyBudget(
            threadId: thread.id,
            limit: 3,
            after: AgentMessageCursor(createdAt: base, id: ids[0]),
            budget: 10_000,
            contentLimit: 80_000,
            appendEllipsisOnCap: false
        )
        XCTAssertEqual(afterFirst.rows.map(\.id), Array(ids[1...3]),
                       "after cursor must advance by created_at,rowid without skipping rows")
        XCTAssertTrue(afterFirst.hasMoreNewer || afterFirst.rows.count == 3)
        XCTAssertTrue(afterFirst.hasMoreOlder,
                      "after pages sit after older history and must advertise hasMoreOlder")
        XCTAssertEqual(afterFirst.nextBefore?.id, ids[1])
        XCTAssertEqual(afterFirst.nextAfter?.id, ids[3])

        let newest = try messages.listPageWithinBodyBudget(
            threadId: thread.id,
            limit: 2,
            budget: 2_000,
            contentLimit: 1_000,
            appendEllipsisOnCap: false,
            attachmentsByteLimit: 4_096,
            attachmentsCountLimit: 32
        )
        let large = try XCTUnwrap(newest.rows.last)
        XCTAssertEqual(large.id, ids[4])
        XCTAssertEqual(newest.originalByteCounts[large.id], 8_000,
                       "originalByteCounts must report the full persisted UTF-8 size")
        XCTAssertTrue(newest.truncatedIDs.contains(large.id),
                      "truncatedIDs must include rows whose returned content is shorter than the body")
        XCTAssertLessThanOrEqual(large.content.utf8.count, 1_000)
        XCTAssertNotNil(
            large.content.data(using: .utf8),
            "SQLite byte cap must retreat to a valid UTF-8 scalar boundary"
        )
        XCTAssertFalse(large.content.contains("…"),
                       "wire path (appendEllipsisOnCap:false) must not invent ellipsis")
        XCTAssertEqual(newest.attachmentCounts[large.id], 100)
        XCTAssertTrue(newest.attachmentTruncatedIDs.contains(large.id))
        XCTAssertTrue(
            large.attachments.isEmpty,
            "oversized attachment JSON must become [] before Swift decoding"
        )
    }
}
