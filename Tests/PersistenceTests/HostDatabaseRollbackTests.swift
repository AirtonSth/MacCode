import Foundation
import XCTest
import CoreModel
import SQLite3
@testable import Persistence

final class HostDatabaseRollbackTests: XCTestCase {
    func testRejectsMissingAndNonExactSchemaMetadataBeforeSignatureCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("host.sqlite")
        let db = try SQLiteDB(path: databaseURL.path)
        try Schema.migrate(db)
        let target = root.appendingPathComponent("Target.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let executable = target.appendingPathComponent("Contents/MacOS/RemoteCode")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plistURL = target.appendingPathComponent("Contents/Info.plist")
        let bundleID = "io.remotecode.desktop"

        for metadata: [String: Any] in [
            ["CFBundleExecutable": "RemoteCode", "CFBundleIdentifier": bundleID],
            ["CFBundleExecutable": "RemoteCode", "CFBundleIdentifier": bundleID, "RC2DatabaseSchemaVersion": Schema.currentVersion - 1],
            ["CFBundleExecutable": "RemoteCode", "CFBundleIdentifier": bundleID, "RC2DatabaseSchemaVersion": "\(Schema.currentVersion)"],
            ["CFBundleExecutable": "RemoteCode", "CFBundleIdentifier": bundleID, "RC2DatabaseSchemaVersion": true],
            ["CFBundleExecutable": "Other", "CFBundleIdentifier": bundleID, "RC2DatabaseSchemaVersion": Schema.currentVersion],
            ["CFBundleExecutable": "RemoteCode", "CFBundleIdentifier": bundleID, "RC2DatabaseSchemaVersion": Double(Schema.currentVersion)]
        ] {
            try (metadata as NSDictionary).write(to: plistURL)
            XCTAssertThrowsError(try HostDatabaseRollback.validate(databaseURL: databaseURL, targetURL: target, currentBundleURL: target, currentBundleIdentifier: bundleID)) { error in
                XCTAssertTrue(String(describing: error).contains("metadata"), "Unexpected refusal reason: \(error)")
            }
        }
    }

    func testPackagedBinaryRollbackCLIWhenOptedIn() throws {
        guard let binary = ProcessInfo.processInfo.environment["RC_HOST_ROLLBACK_BINARY"] else { throw XCTSkip("Set RC_HOST_ROLLBACK_BINARY to packaged RemoteCode executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("host.sqlite")
        let db = try SQLiteDB(path: database.path)
        try Schema.migrate(db)
        let bot = try BotStore(db: db).create(name: "Rollback hold", title: "Fixture", description: "", soul: "", provider: .distill, model: "test", desktopKind: .logicalExecutionSpace)
        let store = BotStore(db: db)
        _ = try store.grantContext(hostID: "rollback-fixture", botID: bot.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        let thread = AgentThread(title: "Held rollback history", provider: .distill, model: "test")
        let conversation = BotConversation(botID: bot.id, title: "Held conversation", linkedAgentThreadID: thread.id)
        try store.createContextualConversation(conversation, newThread: thread, hostID: "rollback-fixture", context: .general, policyRevision: 1)
        _ = try store.revokeContext(hostID: "rollback-fixture", botID: bot.id, context: .general, expectedRevision: 1)
        try AgentMessageRepository(db: db).append(AgentMessage(threadId: thread.id, role: .user, content: "Preserve private rollback fixture history"))
        let queue = AgentQueuedMessageRepository(db: db)
        let queued = try queue.enqueue(threadId: thread.id, text: "Retain until explicit review", attachments: [], interactionMode: .default)
        let botQueue = try store.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(botID: bot.id, conversationID: conversation.id.value.uuidString.lowercased(), text: "Retained Bot intent"))
        let attemptRun = AgentRun(id: AgentRunID(queued.id.value), threadId: thread.id, provider: .distill, model: "test", status: .running)
        try AgentRunRepository(db: db).upsert(attemptRun)
        try AgentRunRepository(db: db).markStopped(id: attemptRun.id)
        for (kind, id) in [(HostDatabaseRestore.QueueKind.agent, queued.id.value.uuidString), (.bot, botQueue.id)] {
            try HostDatabaseRestore.pauseQueue(kind: kind, id: id, db: db)
            try HostDatabaseRestore.recordQueueAttempt(kind: kind, id: id, runID: attemptRun.id, db: db)
        }
        XCTAssertNil(try queue.claimFirst(threadId: thread.id))
        XCTAssertEqual(try store.getContextBinding(hostID: "rollback-fixture", botID: bot.id, context: .general)?.state, .revoked)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: attemptRun.id)?.status, .cancelled)
        let appURL = URL(fileURLWithPath: binary).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        func run(_ arguments: [String], marker: URL? = nil) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["RC2_APP_SUPPORT"] = support.path
            environment["RC2_DB_PATH"] = database.path
            environment["RC2_CHANNEL"] = "debug"
            if let marker { environment["MARKER"] = marker.path }
            process.environment = environment
            let before = try snapshot(db)
            let capture = root.appendingPathComponent("capture-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: capture.path, contents: nil)
            let output = try FileHandle(forWritingTo: capture)
            defer {
                XCTAssertNoThrow(try output.close())
                XCTAssertNoThrow(try FileManager.default.removeItem(at: capture))
            }
            process.standardOutput = output
            process.standardError = output
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            if exited.wait(timeout: .now() + 20) == .timedOut {
                process.terminate()
                if exited.wait(timeout: .now() + 3) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    XCTAssertEqual(exited.wait(timeout: .now() + 3), .success)
                }
                XCTFail("rollback command exceeded bounded exit time")
                throw SQLiteError.execute("rollback command timed out")
            }
            XCTAssertEqual(try snapshot(db), before, "CLI must preserve every logical schema/table row, including holds, leases, history and terminal authority")
            return (process.terminationStatus, try String(contentsOf: capture, encoding: .utf8))
        }

        let success = try run(["--rollback-host", appURL.path, "--", "--database-schema-version"])
        XCTAssertEqual(success.0, 0, success.1)
        XCTAssertEqual(success.1.trimmingCharacters(in: .whitespacesAndNewlines), String(Schema.currentVersion))

        try db.execute("UPDATE schema_meta SET version=\(Schema.currentVersion + 1) WHERE version=(SELECT MAX(version) FROM schema_meta);")
        let schemaRefusal = try run(["--rollback-host", appURL.path])
        XCTAssertNotEqual(schemaRefusal.0, 0)
        XCTAssertTrue(schemaRefusal.1.contains("newer"), schemaRefusal.1)
        let maximum = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        XCTAssertTrue(try maximum.step())
        XCTAssertEqual(maximum.columnInt64(0), Int64(Schema.currentVersion + 1))
        maximum.reset()
        try db.execute("UPDATE schema_meta SET version=\(Schema.currentVersion) WHERE version=\(Schema.currentVersion + 1);")

        let legacy = root.appendingPathComponent("Legacy.app", isDirectory: true)
        let contents = legacy.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/RemoteCode")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\ntouch \"$MARKER\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let identifier = Bundle(url: appURL)?.bundleIdentifier ?? "io.remotecode.desktop.debug"
        try (["CFBundleExecutable": "RemoteCode", "CFBundleIdentifier": identifier] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        let marker = root.appendingPathComponent("legacy-executed")
        let refusal = try run(["--rollback-host", legacy.path], marker: marker)
        XCTAssertNotEqual(refusal.0, 0)
        XCTAssertTrue(refusal.1.contains("metadata"), refusal.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        for args in [["--rollback-host"], ["--rollback-host", legacy.path, "unexpected"], ["--restore-database-backup", database.path, "--rollback-host", legacy.path]] {
            let malformed = try run(args, marker: marker)
            XCTAssertNotEqual(malformed.0, 0, malformed.1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
        try (["CFBundleExecutable": "RemoteCode", "CFBundleIdentifier": identifier, "RC2DatabaseSchemaVersion": Schema.currentVersion] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        let forged = try run(["--rollback-host", legacy.path], marker: marker)
        XCTAssertNotEqual(forged.0, 0)
        XCTAssertTrue(forged.1.contains("signature"), forged.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(try queue.claimFirst(threadId: thread.id))
        XCTAssertTrue(try AgentRunRepository(db: db).listActive().isEmpty)
    }

    func testRejectsUnsignedTargetEvenWithCurrentMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("host.sqlite")
        let db = try SQLiteDB(path: databaseURL.path)
        try db.execute("CREATE TABLE schema_meta(version INTEGER NOT NULL, applied_at TEXT);")
        let insert = try db.prepare("INSERT INTO schema_meta(version, applied_at) VALUES(?, 'now');")
        try insert.bind(1, Int64(Schema.currentVersion + 1))
        _ = try insert.step()
        let target = root.appendingPathComponent("Target.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let executable = target.appendingPathComponent("Contents/MacOS/RemoteCode")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: NSDictionary = ["CFBundleExecutable": "RemoteCode", "CFBundleIdentifier": "io.remotecode.desktop", "RC2DatabaseSchemaVersion": Schema.currentVersion]
        try plist.write(to: target.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try HostDatabaseRollback.validate(databaseURL: databaseURL, targetURL: target, currentBundleURL: target, currentBundleIdentifier: "io.remotecode.desktop")) { error in
            XCTAssertTrue(String(describing: error).contains("signature"))
        }
    }

    private func snapshot(_ db: SQLiteDB) throws -> [String: [[String?]]] {
        var result: [String: [[String?]]] = [:]
        let tables = try db.prepare("SELECT type,name,sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY type,name;")
        var schema: [[String?]] = []
        var tableNames: [String] = []
        while try tables.step() {
            schema.append([tables.columnText(0), tables.columnText(1), tables.columnText(2)])
            if tables.columnText(0) == "table", let name = tables.columnText(1) { tableNames.append(name) }
        }
        tables.reset()
        result["schema"] = schema
        for name in tableNames {
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            let statement = try db.prepare("SELECT * FROM \"\(escaped)\" ORDER BY rowid;")
            var rows: [[String?]] = []
            while try statement.step() { rows.append((0..<sqlite3_column_count(statement.handle)).map { statement.columnText($0) }) }
            result[name] = rows
        }
        return result
    }
}
