import XCTest
@testable import Persistence
import CoreModel

/// Correctness pin for AgentMessageRepository.listRecent(threadId:limit:).
///
/// WHY: listRecent was changed from `out.reversed()` (allocates a new Array) to
/// `out.reverse()` (mutates in-place, zero extra allocation). Both produce the
/// same oldest-first result. This test pins that the returned order and content
/// are identical to what list() returns for the same rows, so a regression that
/// accidentally dropped the reverse step would be caught immediately.
final class AgentMessageListRecentTests: XCTestCase {

    private func makeRepo() throws -> (AgentMessageRepository, AgentThreadID) {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let thread = AgentThread(title: "recent-test", provider: .codex, model: "gpt-5")
        try AgentThreadRepository(db: db).upsert(thread)
        return (AgentMessageRepository(db: db), thread.id)
    }

    // listRecent with limit >= total count must return the same ordered slice as list().
    func test_listRecent_fullLimit_matchesList() throws {
        let (repo, tid) = try makeRepo()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        for i in 0..<5 {
            try repo.append(AgentMessage(
                threadId: tid,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "msg-\(i)",
                createdAt: base.addingTimeInterval(Double(i))
            ))
        }

        let recent = try repo.listRecent(threadId: tid, limit: 10)
        let full   = try repo.list(threadId: tid)

        XCTAssertEqual(recent.map(\.content), full.map(\.content),
            "listRecent with limit >= count must return exactly the same oldest-first " +
            "sequence as list(); in-place reverse() must not change order vs old reversed()")
    }

    // listRecent with limit < total count must return the NEWEST limit messages, oldest-first.
    func test_listRecent_partialLimit_returnsNewestOldestFirst() throws {
        let (repo, tid) = try makeRepo()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        for i in 0..<5 {
            try repo.append(AgentMessage(
                threadId: tid,
                role: .user,
                content: "msg-\(i)",
                createdAt: base.addingTimeInterval(Double(i))
            ))
        }

        let recent = try repo.listRecent(threadId: tid, limit: 3)

        // newest 3 = msg-2, msg-3, msg-4; displayed oldest-first = same sequence
        XCTAssertEqual(recent.map(\.content), ["msg-2", "msg-3", "msg-4"],
            "listRecent(limit:3) must return the 3 newest messages in oldest-first " +
            "display order; wrong order means the in-place reverse() was omitted or inverted")
    }

    // Zero limit must return an empty array without error.
    func test_listRecent_zeroLimit_returnsEmpty() throws {
        let (repo, tid) = try makeRepo()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try repo.append(AgentMessage(threadId: tid, role: .user, content: "x", createdAt: base))

        let recent = try repo.listRecent(threadId: tid, limit: 0)

        XCTAssertTrue(recent.isEmpty,
            "listRecent(limit:0) must return an empty array; max(0, limit) guard must hold")
    }

    // F13: placeholder-title repair only needs the earliest user message. This must
    // return exactly what `list().first(where: { $0.role == .user })` returned, so
    // the LIMIT 1 query is behavior-equivalent without loading the whole thread.
    func test_firstUserMessage_returnsEarliestUserRowSkippingAssistants() throws {
        let (repo, tid) = try makeRepo()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try repo.append(AgentMessage(threadId: tid, role: .assistant, content: "a0", createdAt: base))
        try repo.append(AgentMessage(threadId: tid, role: .user, content: "first-user", createdAt: base.addingTimeInterval(1)))
        try repo.append(AgentMessage(threadId: tid, role: .user, content: "second-user", createdAt: base.addingTimeInterval(2)))

        let first = try repo.firstUserMessage(threadId: tid)
        let viaList = try repo.list(threadId: tid).first(where: { $0.role == .user })
        XCTAssertEqual(first?.content, "first-user",
            "firstUserMessage must return the earliest USER row, skipping assistant rows")
        XCTAssertEqual(first?.content, viaList?.content,
            "firstUserMessage(LIMIT 1) must match the full-scan first(where:) it replaces")
        XCTAssertEqual(first?.role, .user)
    }

    func test_firstUserMessage_nilWhenNoUserMessages() throws {
        let (repo, tid) = try makeRepo()
        try repo.append(AgentMessage(threadId: tid, role: .assistant, content: "only-assistant", createdAt: Date()))
        XCTAssertNil(try repo.firstUserMessage(threadId: tid),
            "a thread with no user message must return nil so title repair skips it (and marks it visited)")
    }

    func test_listWithinBodyBudgetBlanksOldestBodiesBeforeHydratingContent() throws {
        let (repo, tid) = try makeRepo()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try repo.append(AgentMessage(threadId: tid, role: .user, content: String(repeating: "a", count: 40), createdAt: base))
        try repo.append(AgentMessage(threadId: tid, role: .assistant, content: String(repeating: "b", count: 40), createdAt: base.addingTimeInterval(1)))
        try repo.append(AgentMessage(threadId: tid, role: .assistant, content: "newest-kept", createdAt: base.addingTimeInterval(2)))

        let result = try repo.listWithinBodyBudget(threadId: tid, budget: 20, contentLimit: 80_000)

        XCTAssertEqual(result.blanked, 2,
                       "the repository must blank old oversized bodies before Agent App hydrates content so long thread open does not transiently load every old blob")
        XCTAssertEqual(result.rows.map(\.content), ["", "", "newest-kept"],
                       "message metadata/order must remain intact while only the newest bodies inside the budget are hydrated")
    }

    func test_listWithinBodyBudgetUsesUtf8ByteEstimateForMultibyteCaps() throws {
        let (repo, tid) = try makeRepo()
        try repo.append(AgentMessage(
            threadId: tid,
            role: .user,
            content: String(repeating: "🙂", count: 4),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        ))

        let result = try repo.listWithinBodyBudget(threadId: tid, budget: 10, contentLimit: 4)

        XCTAssertEqual(result.blanked, 1,
                       "body budgeting is byte-based, so a character cap must not underestimate multibyte UTF-8 content and hydrate old blobs that already exceed the byte budget")
        XCTAssertEqual(result.rows.map(\.content), [""],
                       "oversized multibyte content should be blanked before hydration just like oversized ASCII content")
    }
}
