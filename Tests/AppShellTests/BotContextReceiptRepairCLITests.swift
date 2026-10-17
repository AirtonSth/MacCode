import AgentRuntime
import AppLifecycleSupport
import CoreModel
import Foundation
import Persistence
import XCTest
@testable import AppShell

final class BotContextReceiptRepairCLITests: XCTestCase {
    private struct Fixture {
        let root: URL
        let support: URL
        let database: URL
        let runID: AgentRunID
        let pin: BotConversationContextPin
        let threadID: AgentThreadID
        let queueID: AgentQueuedMessageID
        let guestRecord: URL
        let config: URL
        let env: URL
    }

    private func fixture(status: AgentRunStatus = .cancelled) throws -> Fixture {
        let probe = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
        let root = probe.appendingPathComponent("ReceiptRepair-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("owned.sqlite")
        let host = "repair-fixture-host"
        let result: (AgentRunID, BotConversationContextPin, AgentThreadID, AgentQueuedMessageID, URL, URL, URL) = try {
            let db = try SQLiteDB(path: database.path)
            try Schema.migrate(db)
            let store = BotStore(db: db)
            let bot = try store.create(name: "Repair fixture", title: "Repair fixture", description: "", soul: "", provider: .distill, model: "test")
            let grant = try store.grantContext(hostID: host, botID: bot.id, context: .general, actions: [.read, .send], expectedRevision: 0)
            let thread = AgentThread(title: "Repair fixture", provider: .distill, model: "test")
            let conversation = BotConversation(botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id)
            let pin = try store.createContextualConversation(conversation, newThread: thread, hostID: host, context: grant.context, policyRevision: grant.policyRevision)
            let run = AgentRun(threadId: thread.id, provider: .distill, model: "test", status: status)
            try AgentRunRepository(db: db).upsert(run)
            try ProviderSessionRuntimeRepository(db: db).upsert(ProviderSessionRuntime(threadId: thread.id,
                provider: .distill, status: status == .running ? .running : .cancelled,
                resumeCursor: "owned-native-cursor", lastRunId: run.id))
            let queued = try AgentQueuedMessageRepository(db: db).enqueue(threadId: thread.id,
                text: "private queued fixture intent", attachments: [], interactionMode: .default)
            let identity = try BotContextRuntimeIdentity(hostID: pin.hostID, botID: pin.botID, context: pin.context, policyRevision: pin.policyRevision)
            try BotContextGuestRecovery.begin(identity: identity, runID: run.id, conversationID: pin.conversationID, appSupport: support)
            let scope = support.appendingPathComponent("guest-runs", isDirectory: true)
                .appendingPathComponent(identity.storageBotID.value.uuidString.lowercased(), isDirectory: true)
            let guestRecord = scope.appendingPathComponent(run.id.value.uuidString.lowercased() + ".context.json")
            let native = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identity.storageBotID)
                .appendingPathComponent(".distill-context-session-\(pin.conversationID.value.uuidString.lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let config = native.appendingPathComponent("config.toml")
            try Data("synthetic marker and config secret".utf8).write(to: config)
            let env = scope.appendingPathComponent(run.id.value.uuidString.lowercased() + ".env")
            try Data("synthetic environment secret".utf8).write(to: env)
            _ = try store.revokeContext(hostID: host, botID: bot.id, context: .general, expectedRevision: grant.policyRevision)
            _ = try CommandReceiptRepository(db: db).claim(method: "agent.message.send", clientRequestId: "interrupted-owned-claim", ownerFingerprint: "owner", paramsHash: "hash")
            try EventLogRepository(db: db).append(seq: 41, kind: "owned.fixture", payloadJSON: "{}")
            return (run.id, pin, thread.id, queued.id, guestRecord, config, env)
        }()
        return Fixture(root: root, support: support, database: database, runID: result.0, pin: result.1, threadID: result.2, queueID: result.3, guestRecord: result.4, config: result.5, env: result.6)
    }

    private func runCLI(_ arguments: [String], fixture: Fixture) throws -> (Int32, String, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["RC_HOST_MATRIX_BINARY"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("RC_HOST_MATRIX_BINARY must name packaged host binary")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var child = environment
        child["RC2_APP_SUPPORT"] = fixture.support.path
        child["RC2_DB_PATH"] = fixture.database.path
        child["RC2_CHANNEL"] = "debug"
        child["RC2_DISABLE_MANAGED_DISTILL_RECONCILE"] = "1"
        process.environment = child
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, stdout, stderr)
    }

    private func report(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], file: file, line: line)
    }

    private func setReceiptInsertFailure(_ enabled: Bool, database: URL) throws {
        let db = try SQLiteDB(path: database.path)
        if enabled {
            try db.execute("""
                CREATE TRIGGER owned_context_repair_failure BEFORE INSERT ON settings
                WHEN NEW.key LIKE 'bot.context.cleanup.receipt.%'
                BEGIN SELECT RAISE(ABORT, 'owned receipt failure'); END;
                """)
        } else {
            try db.execute("DROP TRIGGER owned_context_repair_failure;")
        }
    }

    private func eventCount(database: URL) throws -> Int {
        let db = try SQLiteDB(path: database.path)
        let statement = try db.prepare("SELECT COUNT(*) FROM events WHERE kind = 'bot.context.cleanup.repaired';")
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    private func assertFencedClaim(database: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let db = try SQLiteDB(path: database.path)
        let receipts = CommandReceiptRepository(db: db)
        XCTAssertEqual(try receipts.status(method: "agent.message.send", clientRequestId: "interrupted-owned-claim", ownerFingerprint: "owner"), .unknown, file: file, line: line)
        XCTAssertEqual(try receipts.claim(method: "agent.message.send", clientRequestId: "interrupted-owned-claim", ownerFingerprint: "owner", paramsHash: "hash"), .unknown, file: file, line: line)
    }

    private func assertCleanupCompleted(_ fixture: Fixture, status: AgentRunStatus = .cancelled, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.config.path), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.env.path), file: file, line: line)
        let data = try Data(contentsOf: fixture.guestRecord)
        let record = try JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: data)
        XCTAssertEqual(record.state, .ended, file: file, line: line)
        let db = try SQLiteDB(path: fixture.database.path)
        let run = try XCTUnwrap(AgentRunRepository(db: db).get(id: fixture.runID), file: file, line: line)
        XCTAssertEqual(run.status, status, file: file, line: line)
        XCTAssertEqual(try ProviderSessionRuntimeRepository(db: db).get(threadId: fixture.threadID)?.status,
                       status == .interrupted ? .interrupted : .cancelled, file: file, line: line)
        let queued = try XCTUnwrap(AgentQueuedMessageRepository(db: db).get(id: fixture.queueID), file: file, line: line)
        XCTAssertEqual(queued.text, "private queued fixture intent", file: file, line: line)
        XCTAssertEqual(queued.durableState, .queued, file: file, line: line)
        let binding = try XCTUnwrap(BotStore(db: db).getContextBinding(hostID: fixture.pin.hostID, botID: fixture.pin.botID, context: fixture.pin.context), file: file, line: line)
        XCTAssertEqual(binding.state, .revoked, file: file, line: line)
        XCTAssertEqual(binding.policyRevision, 2, file: file, line: line)
    }

    func testPackagedCLIFailureThenNewProcessRepairsReceiptOnce() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER1"] == "1" || ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER1=1 or RC_LIVE_DOCKER=1 for real Docker info check")
        }
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try setReceiptInsertFailure(true, database: fixture.database)
        let (failedStatus, failedOut, failedErr) = try runCLI(["--repair-context-receipts"], fixture: fixture)
        XCTAssertEqual(failedStatus, 1, failedErr)
        let failed = try report(failedOut)
        XCTAssertEqual((failed["repaired"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((failed["failures"] as? [String: Any])?.count, 1)
        XCTAssertEqual(try eventCount(database: fixture.database), 0)
        try assertCleanupCompleted(fixture)
        try assertFencedClaim(database: fixture.database)

        try setReceiptInsertFailure(false, database: fixture.database)
        let (repairedStatus, repairedOut, repairedErr) = try runCLI(["--repair-context-receipts"], fixture: fixture)
        XCTAssertEqual(repairedStatus, 0, repairedErr)
        let repaired = try report(repairedOut)
        XCTAssertEqual((repaired["repaired"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((repaired["existing"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(try eventCount(database: fixture.database), 1)
        try assertCleanupCompleted(fixture)
        try assertFencedClaim(database: fixture.database)
        for secret in [fixture.root.path, fixture.config.path, "synthetic marker and config secret", "synthetic environment secret"] {
            XCTAssertFalse(repairedOut.contains(secret))
        }

        let (existingStatus, existingOut, existingErr) = try runCLI(["--repair-context-receipts"], fixture: fixture)
        XCTAssertEqual(existingStatus, 0, existingErr)
        let existing = try report(existingOut)
        XCTAssertEqual((existing["repaired"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((existing["existing"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try eventCount(database: fixture.database), 1)
        try assertFencedClaim(database: fixture.database)
        let db = try SQLiteDB(path: fixture.database.path)
        XCTAssertEqual(try EventLogRepository(db: db).lastSeq(), 42, "repair sequence must advance past ordinary persisted events")
    }

    func testPackagedCLIRepairsImportedActiveRowsWithoutSendingQueuedIntent() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for real Docker absence proof")
        }
        let fixture = try fixture(status: .running)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runCLI(["--repair-context-receipts"], fixture: fixture)
        XCTAssertEqual(result.0, 0, result.2)
        let decoded = try report(result.1)
        XCTAssertEqual((decoded["repaired"] as? [[String: Any]])?.first?["runStatus"] as? String, "interrupted")
        try assertCleanupCompleted(fixture, status: .interrupted)
        try assertFencedClaim(database: fixture.database)
        XCTAssertEqual(try eventCount(database: fixture.database), 1)
        XCTAssertFalse(result.1.contains("private queued fixture intent"))
        let db = try SQLiteDB(path: fixture.database.path)
        let messages = try db.prepare("SELECT COUNT(*) FROM agent_messages;")
        XCTAssertTrue(try messages.step())
        XCTAssertEqual(messages.columnInt64(0), 0, "repair cannot send or replay the queued intent")
        let runs = try db.prepare("SELECT COUNT(*) FROM agent_runs;")
        XCTAssertTrue(try runs.step())
        XCTAssertEqual(runs.columnInt64(0), 1, "repair cannot create a replacement run")
    }

    func testPackagedCLIRepairsCurrentRunAlongsideEndedHistoryOfSameThread() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for real Docker absence proof")
        }
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let identity = try BotContextRuntimeIdentity(hostID: fixture.pin.hostID, botID: fixture.pin.botID,
            context: fixture.pin.context, policyRevision: fixture.pin.policyRevision)
        try BotContextGuestRecovery.end(identity: identity, runID: fixture.runID, appSupport: fixture.support)
        try FileManager.default.removeItem(at: fixture.env)
        let newRun = AgentRun(threadId: fixture.threadID, provider: .distill, model: "test", status: .running)
        try BotContextGuestRecovery.begin(identity: identity, runID: newRun.id,
            conversationID: fixture.pin.conversationID, appSupport: fixture.support)
        let newEnv = fixture.env.deletingLastPathComponent().appendingPathComponent(newRun.id.value.uuidString.lowercased() + ".env")
        try Data("new owned run environment".utf8).write(to: newEnv)
        try {
            let db = try SQLiteDB(path: fixture.database.path)
            try AgentRunRepository(db: db).upsert(newRun)
            try ProviderSessionRuntimeRepository(db: db).upsert(ProviderSessionRuntime(threadId: fixture.threadID,
                provider: .distill, status: .running, resumeCursor: "owned-next-cursor", lastRunId: newRun.id))
        }()
        let result = try runCLI(["--repair-context-receipts"], fixture: fixture)
        XCTAssertEqual(result.0, 0, result.2)
        XCTAssertEqual((try report(result.1)["repaired"] as? [[String: Any]])?.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newEnv.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.config.path))
        let db = try SQLiteDB(path: fixture.database.path)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: fixture.runID)?.status, .cancelled)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: newRun.id)?.status, .interrupted)
        XCTAssertEqual(try ProviderSessionRuntimeRepository(db: db).get(threadId: fixture.threadID)?.status, .interrupted)
        XCTAssertEqual(try AgentQueuedMessageRepository(db: db).get(id: fixture.queueID)?.durableState, .queued)
        XCTAssertEqual(try BotStore(db: db).getContextBinding(hostID: fixture.pin.hostID,
            botID: fixture.pin.botID, context: fixture.pin.context)?.state, .revoked)
    }

    func testPackagedCLIRefusesStoppedContainerWithMismatchedOwnershipWithoutMutation() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for real stopped-container ownership check")
        }
        let fixture = try fixture()
        var cleanupConfirmed = true
        defer { if cleanupConfirmed { try? FileManager.default.removeItem(at: fixture.root) } }
        let identity = try BotContextRuntimeIdentity(hostID: fixture.pin.hostID, botID: fixture.pin.botID,
            context: fixture.pin.context, policyRevision: fixture.pin.policyRevision)
        try BotContextGuestRecovery.end(identity: identity, runID: fixture.runID, appSupport: fixture.support)
        try FileManager.default.removeItem(at: fixture.config)
        try FileManager.default.removeItem(at: fixture.env)
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        let name = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
        let network = BotComputerGuestSpec.networkName(botID: identity.storageBotID)
        guard try !docker.containerExists(name: name), try !docker.networkExists(name: network) else {
            XCTFail("owned Docker fixture names unexpectedly exist")
            return
        }
        var ownedContainerID: String?
        var createdNetwork = false
        cleanupConfirmed = false
        defer {
            do {
                if let ownedContainerID { try docker.remove(name: ownedContainerID) }
                if createdNetwork, try docker.networkExists(name: network) { try docker.removeNetwork(name: network) }
                cleanupConfirmed = try !docker.containerExists(name: name) && !docker.networkExists(name: network)
                XCTAssertTrue(cleanupConfirmed)
            } catch { XCTFail("owned stopped-container cleanup failed") }
        }
        try docker.ensureNetwork(name: network)
        createdNetwork = true
        let home = BotComputerGuestSpec.guestHomeURL(appSupport: fixture.support, botID: identity.storageBotID)
        var options = try BotComputerGuestSpec.containerCreateOptions(botID: identity.storageBotID,
            guestHome: home.path, appSupport: fixture.support, viewerToken: UUID().uuidString,
            contextualNetworkPolicy: true)
        options.labels[BotComputerGuestSpec.botIDLabelKey] = UUID().uuidString.lowercased()
        ownedContainerID = try docker.create(options: options)
        let before = try docker.inspect(name: name)
        XCTAssertFalse(before.running)
        let result = try runCLI(["--repair-context-receipts"], fixture: fixture)
        XCTAssertNotEqual(result.0, 0)
        XCTAssertEqual(try eventCount(database: fixture.database), 0)
        XCTAssertEqual(try docker.inspect(name: name), before, "repair must not mutate a container without exact ownership")
        try assertCleanupCompleted(fixture)
    }

    func testPackagedCLIRefusesMixedFlagsAndHeldHostLockBeforeCleanup() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock: AppInstanceLock
        switch AppInstanceLock.acquire(directory: fixture.support) {
        case .acquired(let acquired): lock = acquired
        case .heldByOther: XCTFail("owned host lock unexpectedly held"); return
        case .unavailable(let code): XCTFail("could not hold owned host lock: \(code)"); return
        }
        let (mixedStatus, _, _) = try runCLI(["--repair-context-receipts", "--inspect-database-backup"], fixture: fixture)
        XCTAssertNotEqual(mixedStatus, 0)
        let (lockedStatus, _, _) = try runCLI(["--repair-context-receipts"], fixture: fixture)
        XCTAssertNotEqual(lockedStatus, 0)
        withExtendedLifetime(lock) {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.config.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.env.path))
        XCTAssertEqual(try eventCount(database: fixture.database), 0)
        let data = try Data(contentsOf: fixture.guestRecord)
        XCTAssertEqual(try JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: data).state, .pending)
    }
}
