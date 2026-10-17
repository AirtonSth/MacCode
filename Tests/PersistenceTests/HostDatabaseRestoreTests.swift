import Foundation
import XCTest
import CoreModel
@testable import Persistence

final class HostDatabaseRestoreTests: XCTestCase {
    private struct Fixture: Codable {
        let botA: BotID
        let botB: BotID
        let botC: BotID
        let conversation: BotConversationID
        let thread: AgentThreadID
        let queued: AgentQueuedMessageID
        let stoppedRun: AgentRunID
        let orphanRun: AgentRunID
    }

    private func makeFixture(_ root: URL) throws -> Fixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path)
        try Schema.migrate(db)
        let settings = SettingsRepository(db: db)
        try settings.set("server_id", "host-before")
        try settings.set("live_activity.boot_epoch", "1")
        let store = BotStore(db: db)
        let a = try store.create(name: "Restore A", title: "A", description: "", soul: "", provider: .distill, model: "test")
        let b = try store.create(name: "Restore B", title: "B", description: "", soul: "", provider: .distill, model: "test")
        for bot in [a, b] {
            _ = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        }
        var thread = AgentThread(title: "Restored canonical", provider: .distill, model: "test")
        thread.status = .running
        let conversation = BotConversation(botID: a.id, title: "Restore A", linkedAgentThreadID: thread.id)
        try store.createContextualConversation(conversation, newThread: thread, hostID: "host", context: .general, policyRevision: 1)
        let queued = try AgentQueuedMessageRepository(db: db).enqueue(threadId: thread.id, text: "Preserve restored intent", attachments: [AgentAttachment(path: "/nonexistent/restore-attachment.txt", displayName: "restore-attachment.txt", kind: .file)], interactionMode: .default)
        let stopped = AgentRun(threadId: thread.id, provider: .distill, model: "test", status: .running)
        let orphan = AgentRun(threadId: thread.id, provider: .distill, model: "test", status: .running)
        let runs = AgentRunRepository(db: db)
        try runs.upsert(stopped)
        try runs.upsert(orphan)
        do {
            let backup = try SQLiteDB(path: root.appendingPathComponent("before-revoke.sqlite").path)
            try db.backup(to: backup)
        }
        _ = try store.revokeContext(hostID: "host", botID: a.id, context: .general, expectedRevision: 1)
        try runs.markStopped(id: stopped.id)
        do {
            let remove = try db.prepare("DELETE FROM agent_runs WHERE id=?;")
            defer { remove.reset() }
            try remove.bind(1, orphan.id.value.uuidString)
            _ = try remove.step()
        }
        let c = try store.create(name: "Current C", title: "C", description: "", soul: "", provider: .distill, model: "test")
        _ = try store.grantContext(hostID: "host", botID: c.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        let receipts = CommandReceiptRepository(db: db)
        XCTAssertEqual(try receipts.claim(method: "agent.message.send", clientRequestId: "after-backup-request", ownerFingerprint: "restore-test-owner", paramsHash: "stable-hash"), .claimed)
        try receipts.record(method: "restore.probe", clientRequestId: "after-backup-committed", resultJSON: "{\"done\":true}")
        try settings.set("server_id", "host-current")
        try settings.set("live_activity.boot_epoch", "9")
        return Fixture(botA: a.id, botB: b.id, botC: c.id, conversation: conversation.id, thread: thread.id, queued: queued.id, stoppedRun: stopped.id, orphanRun: orphan.id)
    }

    private func assertRestored(_ root: URL, fixture: Fixture) throws {
        let db = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path, readonly: true)
        let store = BotStore(db: db)
        let a = try XCTUnwrap(store.getContextBinding(hostID: "host", botID: fixture.botA, context: .general))
        XCTAssertEqual(a.state, .revoked)
        XCTAssertEqual(a.policyRevision, 2)
        for id in [fixture.botB, fixture.botC] {
            let binding = try XCTUnwrap(store.getContextBinding(hostID: "host", botID: id, context: .general))
            XCTAssertEqual(binding.state, .active)
            XCTAssertEqual(binding.policyRevision, 1)
            let bot = try XCTUnwrap(store.get(id: id))
            XCTAssertNotNil(try store.getRevision(id: XCTUnwrap(bot.currentRevisionID)))
        }
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: fixture.botA, context: .general, action: .send, policyRevision: 1))
        let pin = try XCTUnwrap(store.conversationContextPin(conversationID: fixture.conversation))
        XCTAssertEqual(pin.conversationID, fixture.conversation)
        XCTAssertEqual(pin.policyRevision, 1)
        XCTAssertEqual(try store.conversation(id: fixture.conversation)?.linkedAgentThreadID, fixture.thread)
        let queued = try XCTUnwrap(AgentQueuedMessageRepository(db: db).get(id: fixture.queued))
        XCTAssertEqual(queued.threadId, fixture.thread)
        XCTAssertEqual(queued.text, "Preserve restored intent")
        XCTAssertEqual(queued.attachments.map(\.path), ["/nonexistent/restore-attachment.txt"])
        let stopped = try XCTUnwrap(AgentRunRepository(db: db).get(id: fixture.stoppedRun))
        XCTAssertEqual(stopped.status, .cancelled)
        XCTAssertEqual(stopped.terminalReason, "userStop")
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: fixture.orphanRun)?.status, .interrupted)
        XCTAssertEqual(try AgentThreadRepository(db: db).get(id: fixture.thread)?.status, .interrupted)
        XCTAssertEqual(try SettingsRepository(db: db).get("server_id"), "host-current")
        XCTAssertGreaterThanOrEqual(UInt64(try SettingsRepository(db: db).get("live_activity.boot_epoch") ?? "") ?? 0, 9)
        let receipts = CommandReceiptRepository(db: db)
        XCTAssertEqual(try receipts.status(method: "agent.message.send", clientRequestId: "after-backup-request", ownerFingerprint: "restore-test-owner"), .unknown)
        XCTAssertEqual(try receipts.get(method: "restore.probe", clientRequestId: "after-backup-committed"), "{\"done\":true}")
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: SettingsStore(db: db), appSupportDirectory: root)
        var effects = 0
        authority.onSend = { _, _, _, _, _, _ in effects += 1; return [:] }
        authority.onRoutineSend = { _ in effects += 1; return [:] }
        let params: [String: Any] = ["client_request_id": "stale-restored-request", "host_id": "host", "bot_id": fixture.botA.value.uuidString.lowercased(), "context_key": "general:v1", "context_version": 1, "policy_revision": 1, "text": "must not execute", "routine_id": UUID().uuidString]
        for method in ["bot.send", "bot.routine.run", "bot.scheduler.tick"] {
            XCTAssertThrowsError(try authority.dispatch(method: method, params: params)) {
                XCTAssertEqual(($0 as? BotRemoteControlAuthority.Error)?.message, "Bot context authority is not active for this request.")
            }
        }
        XCTAssertEqual(effects, 0)
    }

    func testPreRevocationBackupCannotReplaceCurrentAuthorityOrReviveRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostRestore-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        let before = try Data(contentsOf: root.appendingPathComponent("before-revoke.sqlite"))
        let recovery = try HostDatabaseRestore.restore(backupURL: root.appendingPathComponent("before-revoke.sqlite"), currentURL: root.appendingPathComponent("current.sqlite"), reviewToken: HostDatabaseRestore.inspect(backupURL: root.appendingPathComponent("before-revoke.sqlite")).fingerprint)
        try assertRestored(root, fixture: fixture)
        let exactEpochDB = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path, readonly: true)
        XCTAssertEqual(try SettingsRepository(db: exactEpochDB).get("live_activity.boot_epoch"), "9")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("before-revoke.sqlite")), before)
        let recovered = try SQLiteDB(path: recovery.path, readonly: true)
        XCTAssertEqual(try BotStore(db: recovered).getContextBinding(hostID: "host", botID: fixture.botA, context: .general)?.policyRevision, 2)
        XCTAssertNil(try AgentRunRepository(db: recovered).get(id: fixture.orphanRun))
        let mode = try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".restore-stage-") })
        let updatedDB = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path)
        let updatedStore = BotStore(db: updatedDB)
        let c = try updatedStore.updateProfile(id: fixture.botC, title: "Still editable")
        XCTAssertEqual(c.title, "Still editable")
        XCTAssertThrowsError(try updatedStore.create(name: "Collision", title: "Collision", description: "", handle: c.handle, soul: "", provider: .distill, model: "test"))
    }

    func testInvalidFutureAndAliasedBackupsLeaveCurrentAuthorityUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostRestore-invalid-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        let current = root.appendingPathComponent("current.sqlite")
        let missing = root.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: missing, currentURL: current))
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: current, currentURL: current))
        let link = root.appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: current)
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: link, currentURL: current))
        let hardlink = root.appendingPathComponent("hardlink.sqlite")
        try FileManager.default.linkItem(at: current, to: hardlink)
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: hardlink, currentURL: current))
        let future = root.appendingPathComponent("future.sqlite")
        do {
            let db = try SQLiteDB(path: future.path)
            try Schema.migrate(db)
            try db.execute("INSERT INTO schema_meta(version,applied_at) VALUES (\(Schema.currentVersion + 1),'future');")
        }
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: future, currentURL: current))
        let db = try SQLiteDB(path: current.path, readonly: true)
        XCTAssertEqual(try BotStore(db: db).getContextBinding(hostID: "host", botID: fixture.botA, context: .general)?.policyRevision, 2)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: fixture.stoppedRun)?.status, .cancelled)
        XCTAssertNil(try AgentRunRepository(db: db).get(id: fixture.orphanRun))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testUnexpectedBackupTriggerCannotResurrectRevokedAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostRestore-trigger-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        do {
            let backup = try SQLiteDB(path: root.appendingPathComponent("before-revoke.sqlite").path)
            try backup.execute("""
                CREATE TRIGGER sqliteX_resurrect AFTER INSERT ON bot_context_bindings BEGIN
                    UPDATE bot_context_bindings SET state='active',policy_revision=1
                    WHERE host_id=NEW.host_id AND bot_id=NEW.bot_id AND context_key=NEW.context_key;
                END;
                """)
        }
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: root.appendingPathComponent("before-revoke.sqlite"), currentURL: root.appendingPathComponent("current.sqlite"))) {
            XCTAssertTrue(String(describing: $0).contains("exact trusted database schema"))
        }
        let current = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path, readonly: true)
        XCTAssertEqual(try BotStore(db: current).getContextBinding(hostID: "host", botID: fixture.botA, context: .general)?.state, .revoked)
        XCTAssertEqual(try AgentRunRepository(db: current).get(id: fixture.stoppedRun)?.status, .cancelled)
    }

    func testMissingCurrentBindingNeverAdoptsBackupGrant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostRestore-missing-binding-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        do {
            let current = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path)
            let remove = try current.prepare("DELETE FROM bot_context_bindings WHERE bot_id=?;")
            defer { remove.reset() }
            try remove.bind(1, fixture.botB.value.uuidString.lowercased())
            _ = try remove.step()
        }
        _ = try HostDatabaseRestore.restore(backupURL: root.appendingPathComponent("before-revoke.sqlite"), currentURL: root.appendingPathComponent("current.sqlite"), reviewToken: HostDatabaseRestore.inspect(backupURL: root.appendingPathComponent("before-revoke.sqlite")).fingerprint)
        let current = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path, readonly: true)
        let store = BotStore(db: current)
        XCTAssertNil(try store.getContextBinding(hostID: "host", botID: fixture.botB, context: .general))
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: fixture.botB, context: .general, action: .send, policyRevision: 1))
    }

    func testLegacyQueuedWorkRequiresReviewWithoutReplacingCurrentDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostRestore-legacy-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        do {
            let backup = try SQLiteDB(path: root.appendingPathComponent("before-revoke.sqlite").path)
            let thread = AgentThread(title: "Legacy queued", provider: .distill, model: "test")
            try AgentThreadRepository(db: backup).upsert(thread)
            _ = try AgentQueuedMessageRepository(db: backup).enqueue(threadId: thread.id, text: "Needs explicit review", attachments: [], interactionMode: .default)
        }
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: root.appendingPathComponent("before-revoke.sqlite"), currentURL: root.appendingPathComponent("current.sqlite"))) {
            XCTAssertTrue(String(describing: $0).contains("requiring explicit review"))
        }
        let current = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path, readonly: true)
        XCTAssertEqual(try BotStore(db: current).getContextBinding(hostID: "host", botID: fixture.botA, context: .general)?.policyRevision, 2)
        XCTAssertNil(try AgentRunRepository(db: current).get(id: fixture.orphanRun))
    }

    func test_exportPreRevocationHostRestoreFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["RC_HOST_RESTORE_FIXTURE_ROOT"] else { throw XCTSkip("set isolated restore fixture root") }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path.contains("/.sandbox-worktrees/"), root.path.contains("/.sandbox-state/host-restore-"),
              !FileManager.default.fileExists(atPath: root.path) else { throw SQLiteError.open("fixture requires a fresh isolated restore directory") }
        let fixture = try makeFixture(root)
        try JSONEncoder().encode(fixture).write(to: root.appendingPathComponent("fixture.json"))
    }

    func test_verifyPreRevocationHostRestoreFixture() throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_RESTORE_VERIFY"] == "1",
              let path = ProcessInfo.processInfo.environment["RC_HOST_RESTORE_FIXTURE_ROOT"] else { throw XCTSkip("set isolated restore verification") }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path.contains("/.sandbox-worktrees/"), root.path.contains("/.sandbox-state/host-restore-") else { throw SQLiteError.open("verification requires an isolated restore directory") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        try assertRestored(root, fixture: fixture)
    }
}
