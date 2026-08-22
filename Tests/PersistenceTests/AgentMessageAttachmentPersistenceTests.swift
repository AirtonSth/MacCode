import XCTest
@testable import CoreModel
@testable import Persistence

final class AgentMessageAttachmentPersistenceTests: XCTestCase {
    func test_contentIdentitySurvivesRelaunchAndForkMessageCopy() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-message-attachment-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let threadRepository = AgentThreadRepository(db: db)
        let parent = AgentThread(title: "parent", provider: .codex, model: "gpt-5.5")
        let fork = AgentThread(title: "fork", provider: .codex, model: "gpt-5.5")
        try threadRepository.upsert(parent)
        try threadRepository.upsert(fork)
        let incoming = support.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let firstSource = incoming.appendingPathComponent("proof.txt")
        let renamedSource = incoming.appendingPathComponent("proof.png")
        let bytes = Data("identity-through-relaunch-and-fork".utf8)
        try bytes.write(to: firstSource)
        try bytes.write(to: renamedSource)
        let store = AgentAttachmentStore(
            root: support.appendingPathComponent("agent-attachments", isDirectory: true)
        )
        let first = try store.stage(path: firstSource.path)
        let renamed = try store.stage(path: renamedSource.path)
        let parentMessage = AgentMessage(
            threadId: parent.id,
            role: .user,
            content: "parent",
            attachments: [first]
        )
        try AgentMessageRepository(db: db).append(parentMessage)
        let forkMessage = AgentMessage(
            threadId: fork.id,
            role: .user,
            content: parentMessage.content,
            attachments: parentMessage.attachments
        )
        try AgentMessageRepository(db: db).append(forkMessage)

        let relaunchedRepository = AgentMessageRepository(db: db)
        let relaunched = try XCTUnwrap(relaunchedRepository.get(id: parentMessage.id)?.attachments.first)
        let copiedToFork = try XCTUnwrap(relaunchedRepository.get(id: forkMessage.id)?.attachments.first)

        XCTAssertNotEqual(first.id, renamed.id)
        XCTAssertEqual(first.sha256, renamed.sha256)
        XCTAssertEqual(first.path, renamed.path)
        XCTAssertEqual(first.displayName, "proof.txt")
        XCTAssertEqual(first.kind, .file)
        XCTAssertEqual(renamed.displayName, "proof.png")
        XCTAssertEqual(renamed.kind, .image)
        XCTAssertEqual(relaunched.id, copiedToFork.id)
        XCTAssertEqual(relaunched.displayName, copiedToFork.displayName)
        XCTAssertEqual(relaunched.kind, copiedToFork.kind)
        XCTAssertEqual(relaunched.mimeType, copiedToFork.mimeType)
        XCTAssertEqual(relaunched.path, copiedToFork.path)
        XCTAssertEqual(try store.validatedForRetry(relaunched), relaunched,
                       "retry after relaunch must resolve the same immutable blob identity")
    }

    func test_attachmentMetadataSurvivesEveryMessageReadPath() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-message-attachment-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let threadRepository = AgentThreadRepository(db: db)
        let messageRepository = AgentMessageRepository(db: db)
        let thread = AgentThread(title: "attachment", provider: .codex, model: "gpt-5.5")
        try threadRepository.upsert(thread)
        let attachment = AgentAttachment(
            id: "known-sha",
            path: support.appendingPathComponent("managed/known-sha.png").path,
            displayName: "proof.png",
            kind: .image,
            mimeType: "image/png",
            sha256: "known-sha",
            sizeBytes: 42
        )
        let message = AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "inspect this",
            attachments: [attachment]
        )

        try messageRepository.append(message)

        XCTAssertEqual(try messageRepository.get(id: message.id)?.attachments, [attachment])
        XCTAssertEqual(try messageRepository.list(threadId: thread.id).first?.attachments, [attachment])
        XCTAssertEqual(try messageRepository.listRecent(threadId: thread.id, limit: 10).first?.attachments, [attachment])
        XCTAssertEqual(try messageRepository.listPage(threadId: thread.id, limit: 10, before: nil).messages.first?.attachments, [attachment])
        XCTAssertEqual(try messageRepository.listWithinBodyBudget(threadId: thread.id, budget: 0).rows.first?.attachments, [attachment],
                       "body trimming may omit text but must retain attachment identity needed for retry and audit")
    }

    func test_preMigrationMessageDefaultsToNoAttachments() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 34 })
        try db.execute("""
            INSERT INTO agent_threads(id, title, provider, model, status, created_at, updated_at)
            VALUES('legacy-thread', 'legacy', 'codex', 'gpt-5', 'completed',
                   '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
            INSERT INTO agent_messages(id, thread_id, role, content, created_at)
            VALUES('22222222-2222-2222-2222-222222222222', 'legacy-thread', 'user', 'legacy message',
                   '2026-01-01T00:00:00Z');
        """)

        try Schema.migrate(db)

        let messageID = AgentMessageID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        XCTAssertEqual(try AgentMessageRepository(db: db).get(id: messageID)?.attachments, [],
                       "existing message rows must migrate without fabricating or losing content")
    }
}
