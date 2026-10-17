import Foundation
import XCTest
import CoreModel
@testable import Persistence

final class HostRestoreRollbackMatrixTests: XCTestCase {
    private struct Fixture {
        let bot: BotID
        let thread: AgentThreadID
        let conversation: BotConversationID
        let queued: AgentQueuedMessageID
        let botQueueID: String
        let run: AgentRunID
        let messageID: AgentMessageID
    }

    func testPackagedCLIRestoreAndRecoveryRollbackRoundTrip() throws {
        guard let binary = ProcessInfo.processInfo.environment["RC_HOST_MATRIX_BINARY"] else {
            throw XCTSkip("set RC_HOST_MATRIX_BINARY to absolute packaged CLI path")
        }
        let executable = URL(fileURLWithPath: binary).standardizedFileURL
        guard executable.path == binary, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SQLiteError.open("RC_HOST_MATRIX_BINARY must name an executable absolute path")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostRestoreMatrix-\(UUID())", isDirectory: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        let backup = root.appendingPathComponent("snapshot.sqlite")
        let currentPath = root.appendingPathComponent("current.sqlite").path
        do {
            let sourceDB = try SQLiteDB(path: currentPath, readonly: true)
            let snapshotDB = try SQLiteDB(path: backup.path)
            try sourceDB.backup(to: snapshotDB)
        }
        do {
            let current = try SQLiteDB(path: currentPath)
            let store = BotStore(db: current)
            _ = try store.revokeContext(hostID: "host", botID: fixture.bot, context: .general, expectedRevision: 1)
            try AgentRunRepository(db: current).markStopped(id: fixture.run)
            try AgentThreadRepository(db: current).updateStatusPreservingUnread(id: fixture.thread, status: .interrupted)
            try AgentMessageRepository(db: current).append(AgentMessage(threadId: fixture.thread, role: .assistant, content: "post-snapshot history"))
        }

        let review = try inspect(binary: executable, root: root, currentPath: currentPath, backup: backup)
        XCTAssertTrue(review.requiresConfirmation)
        XCTAssertEqual(review.agentQueueIDs.map { $0.lowercased() }, [fixture.queued.value.uuidString.lowercased()])
        XCTAssertEqual(review.botQueueIDs.map { $0.lowercased() }, [fixture.botQueueID.lowercased()])
        let firstRecovery = try restore(binary: executable, root: root, currentPath: currentPath, backup: backup, reviewToken: review.fingerprint)
        try assertState(fixture, path: URL(fileURLWithPath: currentPath), postSnapshotHistory: false)
        try assertState(fixture, path: firstRecovery, postSnapshotHistory: true)

        let rollbackReview = try inspect(binary: executable, root: root, currentPath: currentPath, backup: firstRecovery)
        let secondRecovery = try restore(binary: executable, root: root, currentPath: currentPath, backup: firstRecovery, reviewToken: rollbackReview.fingerprint)
        XCTAssertNotEqual(firstRecovery, secondRecovery)
        try assertState(fixture, path: URL(fileURLWithPath: currentPath), postSnapshotHistory: true)
        try assertState(fixture, path: secondRecovery, postSnapshotHistory: false)
    }

    private func makeFixture(_ root: URL) throws -> Fixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Matrix", title: "Matrix", description: "", soul: "", provider: .distill, model: "test")
        _ = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        let thread = AgentThread(title: "Matrix history", provider: .distill, model: "test")
        let conversation = BotConversation(botID: bot.id, title: "Matrix", linkedAgentThreadID: thread.id)
        try store.createContextualConversation(conversation, newThread: thread, hostID: "host", context: .general, policyRevision: 1)
        let message = AgentMessage(threadId: thread.id, role: .user, content: "pre-snapshot history")
        try AgentMessageRepository(db: db).append(message)
        let queued = try AgentQueuedMessageRepository(db: db).enqueue(threadId: thread.id, text: "Held intent", attachments: [], interactionMode: .default)
        let botQueueID = UUID().uuidString.lowercased()
        _ = try store.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(id: botQueueID, botID: bot.id, text: "Held bot intent"))
        let run = AgentRun(id: AgentRunID(queued.id.value), threadId: thread.id, provider: .distill, model: "test", status: .running)
        try AgentRunRepository(db: db).upsert(run)
        try AgentThreadRepository(db: db).updateStatusPreservingUnread(id: thread.id, status: .running)
        try HostDatabaseRestore.pauseQueue(kind: .agent, id: queued.id.value.uuidString, db: db)
        try HostDatabaseRestore.recordQueueAttempt(kind: .agent, id: queued.id.value.uuidString, runID: run.id, db: db)
        try HostDatabaseRestore.pauseQueue(kind: .bot, id: botQueueID, db: db)
        try HostDatabaseRestore.recordQueueAttempt(kind: .bot, id: botQueueID, runID: run.id, db: db)
        return Fixture(bot: bot.id, thread: thread.id, conversation: conversation.id, queued: queued.id, botQueueID: botQueueID, run: run.id, messageID: message.id)
    }

    private struct Review {
        let fingerprint: String
        let requiresConfirmation: Bool
        let agentQueueIDs: [String]
        let botQueueIDs: [String]
    }

    private func inspect(binary: URL, root: URL, currentPath: String, backup: URL) throws -> Review {
        let result = try invoke(binary, root: root, currentPath: currentPath, args: ["--inspect-database-backup", backup.path])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        return Review(fingerprint: try XCTUnwrap(object["review_fingerprint"] as? String),
                      requiresConfirmation: try XCTUnwrap(object["requires_confirmation"] as? Bool),
                      agentQueueIDs: try XCTUnwrap(object["agent_queue_ids"] as? [String]),
                      botQueueIDs: try XCTUnwrap(object["bot_queue_ids"] as? [String]))
    }

    private func restore(binary: URL, root: URL, currentPath: String, backup: URL, reviewToken: String) throws -> URL {
        let result = try invoke(binary, root: root, currentPath: currentPath,
                                args: ["--restore-database-backup", backup.path, "--restore-review", reviewToken])
        let marker = "Recovery backup: "
        let line = try XCTUnwrap(result.stdout.components(separatedBy: .newlines).first { $0.contains(marker) })
        let path = try XCTUnwrap(line.components(separatedBy: marker).last).trimmingCharacters(in: .whitespacesAndNewlines)
        let recovery = URL(fileURLWithPath: path).standardizedFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        return recovery
    }

    private func invoke(_ binary: URL, root: URL, currentPath: String, args: [String]) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging([
            "RC2_APP_SUPPORT": root.path, "RC2_DB_PATH": currentPath,
            "RC2_CHANNEL": "debug", "RC2_DISABLE_MANAGED_DISTILL_RECONCILE": "1"
        ]) { _, new in new }
        let token = UUID().uuidString
        let outURL = root.appendingPathComponent("cli-\(token).out")
        let errURL = root.appendingPathComponent("cli-\(token).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outFile = try FileHandle(forWritingTo: outURL)
        let errFile = try FileHandle(forWritingTo: errURL)
        defer {
            try? outFile.close()
            try? errFile.close()
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        process.standardOutput = outFile
        process.standardError = errFile
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            throw SQLiteError.open("packaged database CLI timed out")
        }
        let out = try String(contentsOf: outURL, encoding: .utf8)
        let err = try String(contentsOf: errURL, encoding: .utf8)
        guard process.terminationStatus == 0 else { throw SQLiteError.open("CLI exited \(process.terminationStatus): \(err)") }
        return (out, err)
    }

    private func assertState(_ fixture: Fixture, path: URL, postSnapshotHistory: Bool) throws {
        let db = try SQLiteDB(path: path.path, readonly: true)
        let store = BotStore(db: db)
        let binding = try XCTUnwrap(store.getContextBinding(hostID: "host", botID: fixture.bot, context: .general))
        XCTAssertEqual(binding.state, .revoked)
        XCTAssertEqual(binding.policyRevision, 2)
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: fixture.bot, context: .general, action: .send, policyRevision: 1))
        XCTAssertEqual(try AgentThreadRepository(db: db).get(id: fixture.thread)?.status, .interrupted)
        XCTAssertEqual(try AgentQueuedMessageRepository(db: db).get(id: fixture.queued)?.text, "Held intent")
        XCTAssertEqual(try AgentQueuedMessageRepository(db: db).list(threadId: fixture.thread).map(\.id), [fixture.queued])
        XCTAssertEqual(try store.listQueuedFollowUps(botID: fixture.bot).map(\.id), [fixture.botQueueID])
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: fixture.run)?.status, .cancelled)
        XCTAssertTrue(try AgentRunRepository(db: db).listActive().isEmpty)
        XCTAssertEqual(try AgentMessageRepository(db: db).get(id: fixture.messageID)?.content, "pre-snapshot history")
        let history = try AgentMessageRepository(db: db).list(threadId: fixture.thread)
        XCTAssertEqual(history.filter { $0.content == "post-snapshot history" }.count, postSnapshotHistory ? 1 : 0)
        XCTAssertEqual(try store.conversation(id: fixture.conversation)?.linkedAgentThreadID, fixture.thread)
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: fixture.queued.value.uuidString, db: db))
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: fixture.botQueueID, db: db))
        XCTAssertEqual(try HostDatabaseRestore.queueAttempt(kind: .agent, id: fixture.queued.value.uuidString, db: db), fixture.run)
        XCTAssertEqual(try HostDatabaseRestore.queueAttempt(kind: .bot, id: fixture.botQueueID, db: db), fixture.run)
    }
}
