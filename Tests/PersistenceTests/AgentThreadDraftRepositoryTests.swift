import XCTest
@testable import CoreModel
@testable import Persistence

final class AgentThreadDraftRepositoryTests: XCTestCase {
    func test_draftsAreIsolatedByThreadAndProviderInstance() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-drafts-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let threads = AgentThreadRepository(db: db)
        let drafts = AgentThreadDraftRepository(db: db)
        let a = AgentThread(title: "A", provider: .codex, providerInstanceId: "codex-work", model: "gpt-5.5")
        let b = AgentThread(title: "B", provider: .claude, providerInstanceId: "claude-personal", model: "opus")
        try threads.upsert(a)
        try threads.upsert(b)
        let privateAttachment = AgentAttachment(
            id: "hash-a",
            path: support.appendingPathComponent("managed/hash-a.png").path,
            displayName: "private.png",
            kind: .image,
            mimeType: "image/png",
            sha256: "hash-a",
            sizeBytes: 8
        )

        try drafts.upsert(AgentThreadDraft(
            threadId: a.id,
            providerInstanceId: "codex-work",
            text: "draft A",
            attachments: [privateAttachment],
            interactionMode: .plan
        ))
        try drafts.upsert(AgentThreadDraft(
            threadId: b.id,
            providerInstanceId: "claude-personal",
            text: "draft B",
            interactionMode: .default
        ))

        XCTAssertEqual(try drafts.get(threadId: a.id)?.text, "draft A")
        XCTAssertEqual(try drafts.get(threadId: a.id)?.attachments, [privateAttachment])
        XCTAssertEqual(try drafts.get(threadId: a.id)?.providerInstanceId, "codex-work")
        XCTAssertEqual(try drafts.get(threadId: a.id)?.interactionMode, .plan)
        XCTAssertEqual(try drafts.get(threadId: b.id)?.text, "draft B",
                       "a private attachment selected in thread A must never leak into thread B")
        XCTAssertEqual(try drafts.get(threadId: b.id)?.attachments, [])
    }

    func test_deletingThreadCascadesOnlyItsDraft() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-draft-cascade-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let threads = AgentThreadRepository(db: db)
        let drafts = AgentThreadDraftRepository(db: db)
        let a = AgentThread(title: "A", provider: .codex, model: "gpt")
        let b = AgentThread(title: "B", provider: .codex, model: "gpt")
        try threads.upsert(a)
        try threads.upsert(b)
        try drafts.upsert(AgentThreadDraft(threadId: a.id, providerInstanceId: "codex", text: "A"))
        try drafts.upsert(AgentThreadDraft(threadId: b.id, providerInstanceId: "codex", text: "B"))

        try threads.delete(id: a.id)

        XCTAssertNil(try drafts.get(threadId: a.id))
        XCTAssertEqual(try drafts.get(threadId: b.id)?.text, "B")
    }

    func test_sameThreadDraftsAreIsolatedByProviderInstance() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-draft-provider-isolation-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let threads = AgentThreadRepository(db: db)
        let drafts = AgentThreadDraftRepository(db: db)
        let thread = AgentThread(title: "shared", provider: .codex, providerInstanceId: "codex-work", model: "gpt")
        try threads.upsert(thread)

        try drafts.upsert(AgentThreadDraft(
            threadId: thread.id,
            providerInstanceId: "codex-work",
            text: "private codex draft",
            interactionMode: .plan
        ))
        try drafts.upsert(AgentThreadDraft(
            threadId: thread.id,
            providerInstanceId: "claude-personal",
            text: "private claude draft",
            interactionMode: .default
        ))

        XCTAssertEqual(try drafts.get(threadId: thread.id, providerInstanceId: "codex-work")?.text,
                       "private codex draft")
        XCTAssertEqual(try drafts.get(threadId: thread.id, providerInstanceId: "claude-personal")?.text,
                       "private claude draft")
        try drafts.delete(threadId: thread.id, providerInstanceId: "codex-work")
        XCTAssertNil(try drafts.get(threadId: thread.id, providerInstanceId: "codex-work"))
        XCTAssertEqual(try drafts.get(threadId: thread.id, providerInstanceId: "claude-personal")?.text,
                       "private claude draft",
                       "sending in one provider instance must not clear another instance's unsent draft")
    }

    func test_enqueueConsumingDraftCommitsQueueAndDraftDeletionAtomically() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-draft-queue-atomic-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let thread = AgentThread(title: "atomic", provider: .codex, providerInstanceId: "codex-work", model: "gpt")
        try AgentThreadRepository(db: db).upsert(thread)
        let drafts = AgentThreadDraftRepository(db: db)
        let queue = AgentQueuedMessageRepository(db: db)
        try drafts.upsert(AgentThreadDraft(
            threadId: thread.id,
            providerInstanceId: "codex-work",
            text: "send exactly once"
        ))

        let queued = try queue.enqueueConsumingDraft(
            threadId: thread.id,
            providerInstanceId: "codex-work",
            text: "send exactly once",
            attachments: [],
            interactionMode: .default
        )

        let reloaded = try XCTUnwrap(queue.list(threadId: thread.id).first)
        XCTAssertEqual(reloaded.id, queued.id)
        XCTAssertEqual(reloaded.text, queued.text)
        XCTAssertEqual(reloaded.attachments, queued.attachments)
        XCTAssertEqual(reloaded.interactionMode, queued.interactionMode)
        XCTAssertNil(try drafts.get(threadId: thread.id, providerInstanceId: "codex-work"),
                     "a reported queued prompt must not restore as an unsent draft after relaunch")
    }

    func test_enqueueConsumingDraftRollsBackQueueWhenDraftDeletionCannotCommit() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-draft-queue-rollback-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let thread = AgentThread(title: "rollback", provider: .codex, providerInstanceId: "codex-work", model: "gpt")
        try AgentThreadRepository(db: db).upsert(thread)
        let queue = AgentQueuedMessageRepository(db: db)
        try db.execute("DROP TABLE agent_thread_drafts;")

        XCTAssertThrowsError(try queue.enqueueConsumingDraft(
            threadId: thread.id,
            providerInstanceId: "codex-work",
            text: "must not publish",
            attachments: [],
            interactionMode: .default
        ))
        XCTAssertTrue(try queue.list(threadId: thread.id).isEmpty,
                      "draft persistence failure must roll the queue mutation back")
    }
}
