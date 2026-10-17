import Foundation
import XCTest
@testable import AppShell
import CoreModel
import Persistence
@testable import SocketServer

/// Opt-in real host fixture for historical and current iOS-client compatibility probes.
final class HostVersionMatrixServerTests: XCTestCase {
    func test_heldQueueClaimCompatibilityProbe() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let databasePath = environment["RC_HOST_MATRIX_HELD_COPY"],
              databasePath.hasPrefix("/"),
              let expectHeldValue = environment["RC_HOST_MATRIX_EXPECT_HELD"],
              ["0", "1"].contains(expectHeldValue) else {
            throw XCTSkip("Set RC_HOST_MATRIX_HELD_COPY to copied DB and RC_HOST_MATRIX_EXPECT_HELD to 0 or 1")
        }
        let database = try SQLiteDB(path: databasePath)
        try Schema.migrate(database)
        let statement = try database.prepare("SELECT thread_id FROM agent_queued_messages ORDER BY rowid LIMIT 1;")
        guard try statement.step(), let rawThreadID = statement.columnText(0),
              let threadUUID = UUID(uuidString: rawThreadID) else {
            XCTFail("Copied fixture has no canonical queued-message thread ID")
            return
        }
        let threadID = AgentThreadID(threadUUID)
        let repository = AgentQueuedMessageRepository(db: database)
        let before = try XCTUnwrap(repository.first(threadId: threadID))
        let initial = try database.prepare("SELECT q.lease_id,q.dispatch_state,h.approved FROM agent_queued_messages q JOIN host_restore_queue_holds h ON h.kind='agent' AND h.queue_id=q.id COLLATE NOCASE WHERE q.id=? COLLATE NOCASE;")
        try initial.bind(1, before.id.value.uuidString)
        XCTAssertTrue(try initial.step())
        XCTAssertTrue(initial.columnIsNull(0))
        XCTAssertEqual(initial.columnText(1), "queued")
        XCTAssertEqual(initial.columnInt64(2), 0)
        initial.reset()
        let lease = try repository.claimFirst(threadId: threadID)
        XCTAssertEqual(lease == nil, expectHeldValue == "1")
        if let lease { XCTAssertTrue(try repository.release(lease)) }
        let released = try database.prepare("SELECT lease_id,lease_started_at FROM agent_queued_messages WHERE id=? COLLATE NOCASE;")
        try released.bind(1, before.id.value.uuidString)
        XCTAssertTrue(try released.step())
        XCTAssertTrue(released.columnIsNull(0))
        XCTAssertTrue(released.columnIsNull(1))
        released.reset()
        let runs = try database.prepare("SELECT COUNT(*) FROM agent_runs WHERE status IN ('pending','running');")
        XCTAssertTrue(try runs.step())
        XCTAssertEqual(runs.columnInt64(0), 0)
        let after = try XCTUnwrap(repository.first(threadId: threadID))
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.text, before.text)
    }

    @MainActor
    func test_serveHostVersionMatrixFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["RC_HOST_VERSION_MATRIX_ROOT"],
              let portValue = environment["RC_HOST_VERSION_MATRIX_PORT"],
              let portNumber = UInt16(portValue), portNumber != 0,
              portNumber != 18217 else {
            throw XCTSkip("Set RC_HOST_VERSION_MATRIX_ROOT and RC_HOST_VERSION_MATRIX_PORT to start the fixture")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("Fixture root must be fresh and owned by this invocation: \(root.path)")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let context = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("app-support", isDirectory: true).path,
            performLaunchRunReconciliation: false
        )
        let router = AppCommandRouter(context: context)
        context.router = router

        let thread = AgentThread(title: "Host version matrix thread", provider: .codex, model: "gpt-5")
        try context.threadRepo.upsert(thread)
        let historyMarker = "host-version-matrix-history-\(UUID().uuidString.lowercased())"
        try context.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: historyMarker))
        let agentQueued = try context.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "host-version-matrix-agent-queue",
            attachments: [],
            interactionMode: .default
        )

        let bot = try context.botStore.create(
            name: "Host version matrix bot",
            title: "Fixture",
            description: "Synthetic compatibility fixture"
        )
        let conversation = BotConversation(
            botID: bot.id,
            title: "Host version matrix conversation",
            linkedAgentThreadID: thread.id
        )
        try context.botStore.upsertConversation(conversation)
        let botQueue = try context.botStore.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(
            botID: bot.id,
            conversationID: conversation.id.value.uuidString,
            text: "host-version-matrix-bot-queue"
        ))

        let trust = DeviceTrustRepository(db: context.db)
        let pairingCode = try trust.createPairingCode()
        guard let paired = try trust.redeemPairingCode(pairingCode.code, deviceName: "Host version matrix iOS") else {
            throw NSError(domain: "HostVersionMatrixServerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic pairing code could not be redeemed"])
        }
        let auth = LocalAuthAdapter(repo: DeviceTrustRepository(db: context.db))
        let server = DirectHTTPServer(
            port: portNumber,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            auth: auth,
            serverId: "host-version-matrix-fixture",
            bootEpoch: context.liveActivityHostIdentity.bootEpoch
        )
        try server.start()
        defer { server.stop() }

        let manifest: [String: Any] = [
            "host": "127.0.0.1",
            "port": Int(portNumber),
            "token": paired.token,
            "bot_id": bot.id.value.uuidString,
            "conversation_id": conversation.id.value.uuidString,
            "thread_id": thread.id.value.uuidString,
            "agent_queue_id": agentQueued.id.value.uuidString,
            "bot_queue_id": botQueue.id,
            "history_marker": historyMarker,
            "schema_version": context.bootstrapReport.schemaVersion,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        try Data("ready\n".utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)

        let stopFile = root.appendingPathComponent("stop")
        let deadline = Date().addingTimeInterval(300)
        while !FileManager.default.fileExists(atPath: stopFile.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard FileManager.default.fileExists(atPath: stopFile.path) else {
            XCTFail("Fixture exceeded 300-second limit without stop marker")
            return
        }
    }
}
