import Darwin
import Foundation
import XCTest
import CoreModel
@testable import AppShell
@testable import AppLifecycleSupport
@testable import Persistence

final class HostScopedSessionBackupCLITests: XCTestCase {
    private struct Fixture {
        let root: URL
        let support: URL
        let database: URL
        let backup: URL
        let parentBot: BotID
        let childBot: BotID
        let parentThread: AgentThreadID
        let childThread: AgentThreadID
        let parentRun: AgentRunID
        let childRun: AgentRunID
        let queueID: AgentQueuedMessageID
        let pin: BotConversationContextPin
        let childPin: BotConversationContextPin
        let cursor: String
        let cwd: String
        let bindingURLs: [URL]
        let nativeFiles: [URL]
    }

    private func fixture() throws -> Fixture {
        let probe = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"], "RC_CONTEXT_PROBE_ROOT must name invocation-owned scratch"), isDirectory: true)
        let root = probe.appendingPathComponent("HostScopedBackup-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let database = root.appendingPathComponent("source.sqlite")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let db = try SQLiteDB(path: database.path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let host = "backup-fixture-host"
        let parentBot = try store.create(name: "Backup parent", title: "Backup parent", description: "", soul: "", provider: .distill, model: "test")
        let childBot = try store.create(name: "Backup child", title: "Backup child", description: "", soul: "", provider: .distill, model: "test")
        let parentGrant = try store.grantContext(hostID: host, botID: parentBot.id, context: .general, actions: [.read, .send, .delegate], expectedRevision: 0)
        let childGrant = try store.grantContext(hostID: host, botID: childBot.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        var parent = AgentThread(title: "Backup parent", provider: .distill, model: "test")
        parent.status = .running
        var child = AgentThread(title: "Backup child", provider: .distill, model: "test")
        child.status = .running
        let parentConversation = BotConversation(botID: parentBot.id, title: parent.title, linkedAgentThreadID: parent.id)
        let childConversation = BotConversation(botID: childBot.id, title: child.title, linkedAgentThreadID: child.id)
        let pin = try store.createContextualConversation(parentConversation, newThread: parent, hostID: host, context: parentGrant.context, policyRevision: parentGrant.policyRevision)
        let childPin = try store.createContextualConversation(childConversation, newThread: child, hostID: host, context: childGrant.context, policyRevision: childGrant.policyRevision)
        let parentRun = AgentRun(threadId: parent.id, provider: .distill, model: "test", status: .running)
        let childRun = AgentRun(threadId: child.id, provider: .distill, model: "test", status: .running)
        let runs = AgentRunRepository(db: db)
        try runs.upsert(parentRun)
        try runs.upsert(childRun)
        _ = try store.recordContextDelegation(hostID: host, parentRunID: parentRun.id, childRunID: childRun.id, childThreadID: child.id)
        let queueID = try AgentQueuedMessageRepository(db: db).enqueue(threadId: parent.id, text: "Held after restore", attachments: [], interactionMode: .default).id
        let cwd = root.path
        let cursor = "owned-fixture-session-cursor"
        let providerSessions = ProviderSessionRuntimeRepository(db: db)
        try providerSessions.upsert(ProviderSessionRuntime(threadId: parent.id, provider: .distill, status: .running, resumeCursor: cursor, cwd: cwd, model: "test", lastRunId: parentRun.id))
        try providerSessions.upsert(ProviderSessionRuntime(threadId: child.id, provider: .distill, status: .running, cwd: cwd, model: "test", lastRunId: childRun.id))
        let identity = try BotContextRuntimeIdentity(hostID: pin.hostID, botID: pin.botID, context: pin.context, policyRevision: pin.policyRevision)
        let guestHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identity.storageBotID)
        try FileManager.default.createDirectory(at: guestHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = try BotContextSessionStore.prepare(pin: pin, threadID: parent.id, parentRunID: nil, cwd: cwd, resumeCursor: nil, appSupport: support) {
            (try? store.authorizes(hostID: host, botID: pin.botID, context: pin.context, action: .read, policyRevision: pin.policyRevision)) == true
        }
        try BotContextSessionStore.recordOpened(sessionID: cursor, pin: pin, threadID: parent.id, parentRunID: nil, cwd: cwd, expectedResumeCursor: nil, appSupport: support) {
            (try? store.authorizes(hostID: host, botID: pin.botID, context: pin.context, action: .read, policyRevision: pin.policyRevision)) == true
        }
        let bindingDirectory = support.appendingPathComponent("bot-context-sessions", isDirectory: true)
            .appendingPathComponent(identity.storageBotID.value.uuidString.lowercased(), isDirectory: true)
        var bindings = [bindingDirectory.appendingPathComponent(pin.conversationID.value.uuidString.lowercased() + ".json")]
        var nativeFiles: [URL] = []
        let firstHistory = home.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent("owned-history-000.json")
        try FileManager.default.createDirectory(at: firstHistory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("owned initial native history 000".utf8).write(to: firstHistory)
        nativeFiles.append(firstHistory)
        for index in 1..<12 {
            var sessionThread = AgentThread(title: "Backup session \(index)", provider: .distill, model: "test")
            sessionThread.status = .running
            let conversation = BotConversation(botID: parentBot.id, title: sessionThread.title, linkedAgentThreadID: sessionThread.id)
            let sessionPin = try store.createContextualConversation(conversation, newThread: sessionThread, hostID: host, context: parentGrant.context, policyRevision: parentGrant.policyRevision)
            let sessionCursor = "owned-fixture-session-\(index)"
            let sessionHome = try BotContextSessionStore.prepare(pin: sessionPin, threadID: sessionThread.id, parentRunID: nil, cwd: cwd, resumeCursor: nil, appSupport: support) {
                (try? store.authorizes(hostID: host, botID: parentBot.id, context: .general, action: .read, policyRevision: parentGrant.policyRevision)) == true
            }
            try BotContextSessionStore.recordOpened(sessionID: sessionCursor, pin: sessionPin, threadID: sessionThread.id, parentRunID: nil, cwd: cwd, expectedResumeCursor: nil, appSupport: support) {
                (try? store.authorizes(hostID: host, botID: parentBot.id, context: .general, action: .read, policyRevision: parentGrant.policyRevision)) == true
            }
            bindings.append(bindingDirectory.appendingPathComponent(sessionPin.conversationID.value.uuidString.lowercased() + ".json"))
            let history = sessionHome.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for fileIndex in 0..<18 {
                let file = history.appendingPathComponent(String(format: "history-%03d.json", fileIndex))
                try Data("owned initial history session=\(index) file=\(fileIndex)".utf8).write(to: file)
                nativeFiles.append(file)
            }
        }
        return Fixture(root: root, support: support, database: database, backup: root.appendingPathComponent("backup.sqlite"), parentBot: parentBot.id, childBot: childBot.id, parentThread: parent.id, childThread: child.id, parentRun: parentRun.id, childRun: childRun.id, queueID: queueID, pin: pin, childPin: childPin, cursor: cursor, cwd: cwd, bindingURLs: bindings, nativeFiles: nativeFiles)
    }

    private func startCLI(_ arguments: [String], fixture: Fixture) throws -> (Process, FileHandle, FileHandle) {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["RC_HOST_MATRIX_BINARY"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("RC_HOST_MATRIX_BINARY must name packaged host binary")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var childEnvironment = environment
        childEnvironment["RC2_APP_SUPPORT"] = fixture.support.path
        childEnvironment["RC2_DB_PATH"] = fixture.database.path
        childEnvironment["RC2_CHANNEL"] = "debug"
        childEnvironment["RC2_DISABLE_MANAGED_DISTILL_RECONCILE"] = "1"
        process.environment = childEnvironment
        let out = fixture.root.appendingPathComponent("stdout-\(UUID().uuidString)")
        let err = fixture.root.appendingPathComponent("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: out)
        let stderr = try FileHandle(forWritingTo: err)
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return (process, stdout, stderr)
    }

    private func run(_ arguments: [String], fixture: Fixture) throws -> (Int32, String, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["RC_HOST_MATRIX_BINARY"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("RC_HOST_MATRIX_BINARY must name packaged host binary")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var childEnvironment = environment
        childEnvironment["RC2_APP_SUPPORT"] = fixture.support.path
        childEnvironment["RC2_DB_PATH"] = fixture.database.path
        childEnvironment["RC2_CHANNEL"] = "debug"
        childEnvironment["RC2_DISABLE_MANAGED_DISTILL_RECONCILE"] = "1"
        process.environment = childEnvironment
        let out = fixture.root.appendingPathComponent("stdout-\(UUID().uuidString)")
        let err = fixture.root.appendingPathComponent("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: out)
        let stderr = try FileHandle(forWritingTo: err)
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if try !waitUntil(timeout: 120, condition: { !process.isRunning }) {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw NSError(domain: "HostScopedSessionBackupCLITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "packaged CLI exceeded 120-second deadline"])
        }
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        func boundedText(_ url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > 64 * 1024 ? size - 64 * 1024 : 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        }
        let result = (process.terminationStatus, try boundedText(out), try boundedText(err))
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.removeItem(at: err)
        return result
    }

    private func reviewToken(_ output: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let data = try XCTUnwrap(output.data(using: .utf8), file: file, line: line)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        return try XCTUnwrap(json["review_fingerprint"] as? String, file: file, line: line)
    }

    private func requireLiveDocker() throws {
        guard let binary = ProcessInfo.processInfo.environment["RC_HOST_MATRIX_BINARY"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("RC_HOST_MATRIX_BINARY must name packaged host binary")
        }
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 to let packaged CLI prove real Docker quiescence")
        }
        _ = try BotComputerDockerCLI().info()
    }

    private func snapshot(_ urls: [URL]) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: urls.map { ($0.path, try Data(contentsOf: $0)) })
    }

    private func scopedInventory(_ f: Fixture) throws -> [String: Data] {
        let guestHome = try XCTUnwrap(f.nativeFiles.first).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bindings = f.support.appendingPathComponent("bot-context-sessions", isDirectory: true)
        var result: [String: Data] = [:]
        for (label, root) in [("guest", guestHome), ("bindings", bindings)] {
            for file in filesRecursively(under: root) {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                result["\(label)/\(relative)"] = try Data(contentsOf: file)
            }
        }
        return result
    }

    private func stop(_ process: Process) -> Bool {
        let pid = process.processIdentifier
        guard kill(pid, SIGSTOP) == 0 else { return false }
        var status: Int32 = 0
        return waitpid(pid, &status, WUNTRACED) == pid && (status & 0x7f) == 0x7f
    }

    private func waitUntil(timeout: TimeInterval, condition: () throws -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return try condition()
    }

    private func filesRecursively(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }
    }

    private func stages(_ f: Fixture) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: f.support, includingPropertiesForKeys: nil))?.filter { $0.lastPathComponent.hasPrefix(".scoped-restore-") } ?? []
    }

    private func database(_ f: Fixture) throws -> SQLiteDB { try SQLiteDB(path: f.database.path, readonly: true) }

    private func mutateCurrentState(_ f: Fixture) throws {
        let writable = try SQLiteDB(path: f.database.path)
        let store = BotStore(db: writable)
        _ = try store.revokeContext(hostID: f.pin.hostID, botID: f.parentBot, context: .general, expectedRevision: 1)
        try AgentRunRepository(db: writable).markStopped(id: f.parentRun)
        let removeImportedChild = try writable.prepare("DELETE FROM agent_runs WHERE id = ?;")
        try removeImportedChild.bind(1, f.childRun.value.uuidString)
        _ = try removeImportedChild.step()
        let removeImportedRuntime = try writable.prepare("DELETE FROM provider_session_runtime WHERE thread_id = ?;")
        try removeImportedRuntime.bind(1, f.childThread.value.uuidString)
        _ = try removeImportedRuntime.step()
        let stopped = ProviderSessionRuntime(threadId: f.parentThread, provider: .distill, status: .cancelled, resumeCursor: f.cursor, cwd: f.cwd, model: "test", lastRunId: f.parentRun)
        try ProviderSessionRuntimeRepository(db: writable).upsert(stopped)
    }

    private func assertDatabaseState(_ f: Fixture, revoked: Bool, rolledBack: Bool = false, restored: Bool = true) throws {
        let db = try database(f)
        let store = BotStore(db: db)
        let grant = try XCTUnwrap(store.getContextBinding(hostID: f.pin.hostID, botID: f.parentBot, context: .general))
        XCTAssertEqual(grant.state, revoked ? .revoked : .active)
        XCTAssertEqual(grant.policyRevision, revoked ? 2 : 1)
        XCTAssertNotNil(try store.get(id: f.parentBot))
        XCTAssertNotNil(try store.get(id: f.childBot))
        XCTAssertEqual(try store.conversationContextPin(conversationID: f.pin.conversationID), f.pin)
        XCTAssertEqual(try store.conversationContextPin(conversationID: f.childPin.conversationID), f.childPin)
        XCTAssertEqual(try store.conversation(id: f.pin.conversationID)?.linkedAgentThreadID, f.parentThread)
        XCTAssertEqual(try AgentThreadRepository(db: db).get(id: f.parentThread)?.id, f.parentThread)
        XCTAssertEqual(try AgentThreadRepository(db: db).get(id: f.childThread)?.id, f.childThread)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: f.parentRun)?.status, revoked ? .cancelled : .running)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: f.childRun)?.status, revoked ? (rolledBack ? nil : .interrupted) : .running)
        let providerSessions = ProviderSessionRuntimeRepository(db: db)
        XCTAssertEqual(try providerSessions.get(threadId: f.parentThread)?.status, revoked ? .cancelled : .running)
        XCTAssertEqual(try providerSessions.get(threadId: f.childThread)?.status, revoked ? (rolledBack ? nil : .interrupted) : .running)
        let queue = try XCTUnwrap(AgentQueuedMessageRepository(db: db).get(id: f.queueID))
        XCTAssertEqual(queue.durableState, .queued)
        XCTAssertEqual(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: f.queueID.value.uuidString, db: db), revoked && restored)
        XCTAssertEqual(try store.contextDelegation(childRunID: f.childRun)?.closed, revoked && restored)
    }

    func testPackagedCLIBackupRestoreAndRecoveryRoundTripPreservesNativeAndCurrentAuthority() throws {
        try requireLiveDocker()
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let initialNative = try snapshot(f.nativeFiles)
        let initialBindings = try snapshot(f.bindingURLs)
        XCTAssertTrue(initialBindings.values.contains { String(decoding: $0, as: UTF8.self).contains(f.cursor) })
        let runtime = ProviderSessionRuntime(threadId: f.parentThread, provider: .distill, status: .running, resumeCursor: f.cursor, cwd: f.cwd, model: "test", lastRunId: f.parentRun)
        try ProviderSessionRuntimeRepository(db: try SQLiteDB(path: f.database.path)).upsert(runtime)
        let create = try run(["--create-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(create.0, 0, create.2)
        let inspected = try run(["--inspect-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(inspected.0, 0, inspected.2)
        let token = try reviewToken(inspected.1)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(inspected.1.data(using: .utf8))) as? [String: Any])["scoped_session_count"] as? Int, 12)

        try mutateCurrentState(f)
        for (index, file) in f.nativeFiles.enumerated() {
            try Data("current native history after snapshot file=\(index)".utf8).write(to: file)
        }
        let currentNative = try snapshot(f.nativeFiles)
        let firstNativePath = try XCTUnwrap(f.nativeFiles.first).path
        let currentHistory = try XCTUnwrap(currentNative[firstNativePath])
        XCTAssertNotEqual(currentNative, initialNative)
        let restore = try run(["--restore-database-backup", f.backup.path, "--restore-review", token], fixture: f)
        XCTAssertEqual(restore.0, 0, restore.2)
        XCTAssertEqual(try snapshot(f.nativeFiles), initialNative)
        XCTAssertEqual(try snapshot(f.bindingURLs), initialBindings)
        try assertDatabaseState(f, revoked: true)

        let recoveryPath = try XCTUnwrap(restore.1.components(separatedBy: "Recovery backup: ").last?.split(whereSeparator: \.isNewline).first.map(String.init), "restore must report native recovery backup")
        let recoveryURL = URL(fileURLWithPath: recoveryPath)
        let recoveryReview = try run(["--inspect-database-backup", recoveryURL.path], fixture: f)
        XCTAssertEqual(recoveryReview.0, 0, recoveryReview.2)
        let recoveryToken = try reviewToken(recoveryReview.1)
        let rollback = try run(["--restore-database-backup", recoveryURL.path, "--restore-review", recoveryToken], fixture: f)
        XCTAssertEqual(rollback.0, 0, rollback.2)
        XCTAssertEqual(try snapshot(f.nativeFiles), currentNative)
        XCTAssertEqual(try snapshot(f.bindingURLs), initialBindings)
        try assertDatabaseState(f, revoked: true, rolledBack: true)
    }

    func testPackagedCLIInterruptedRestoreAndInterruptedRollbackRecoverOriginalCurrentState() throws {
        try requireLiveDocker()
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertGreaterThanOrEqual(f.nativeFiles.count, 190, "fixture must make archive copies observable")
        let initialNative = try snapshot(f.nativeFiles)
        let initialBindings = try snapshot(f.bindingURLs)
        let initialScopedInventory = try scopedInventory(f)
        let created = try run(["--create-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(created.0, 0, created.2)
        let reviewed = try run(["--inspect-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(reviewed.0, 0, reviewed.2)
        let token = try reviewToken(reviewed.1)

        try mutateCurrentState(f)
        let marker = try XCTUnwrap(f.nativeFiles.first).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("auth.json")
        let markerBytes = Data("synthetic excluded fixture marker; never credential material".utf8)
        try markerBytes.write(to: marker)
        for (index, file) in f.nativeFiles.enumerated() {
            try Data("newer current original file=\(index)".utf8).write(to: file)
        }
        let currentURLs = f.nativeFiles + [marker]
        let currentNative = try snapshot(currentURLs)
        let currentBindings = try snapshot(f.bindingURLs)
        let currentScopedInventory = try scopedInventory(f)
        let currentFingerprint = try HostDatabaseRestore.inspect(backupURL: f.database).fingerprint
        let journal = f.support.appendingPathComponent(".scoped-session-restore.json")
        let (first, firstOut, firstErr) = try startCLI(["--restore-database-backup", f.backup.path, "--restore-review", token], fixture: f)
        var firstKilled = false
        defer {
            if first.isRunning && !firstKilled { _ = kill(first.processIdentifier, SIGKILL); first.waitUntilExit() }
            try? firstOut.close()
            try? firstErr.close()
        }
        let caughtInstall = try waitUntil(timeout: 30) {
            guard FileManager.default.fileExists(atPath: journal.path), first.isRunning else { return false }
            let hasUndo = stages(f).contains { stage in
                !filesRecursively(under: stage.appendingPathComponent("undo", isDirectory: true)).isEmpty
            }
            return hasUndo && f.nativeFiles.contains { file in
                (try? Data(contentsOf: file)) == initialNative[file.path]
            }
        }
        XCTAssertTrue(caughtInstall, "did not observe published native files and undo with journal before SQLite commit")
        guard caughtInstall else { _ = kill(first.processIdentifier, SIGKILL); first.waitUntilExit(); firstKilled = true; return }
        XCTAssertTrue(stop(first), "must stop and observe stopped state for exact restore CLI child")
        XCTAssertEqual(kill(first.processIdentifier, SIGKILL), 0, "must kill exact stopped restore CLI child")
        first.waitUntilExit()
        firstKilled = true
        XCTAssertEqual(try HostDatabaseRestore.inspect(backupURL: f.database).fingerprint, currentFingerprint)

        let firstRecovery = try startCLI(["--inspect-database-backup", f.backup.path], fixture: f)
        var recoveryKilled = false
        defer {
            if firstRecovery.0.isRunning && !recoveryKilled { _ = kill(firstRecovery.0.processIdentifier, SIGKILL); firstRecovery.0.waitUntilExit() }
            try? firstRecovery.1.close()
            try? firstRecovery.2.close()
        }
        let caughtRollback = try waitUntil(timeout: 30) {
            guard FileManager.default.fileExists(atPath: journal.path), firstRecovery.0.isRunning else { return false }
            return stages(f).contains { stage in
                let undo = stage.appendingPathComponent("undo", isDirectory: true)
                let entries = FileManager.default.enumerator(at: undo, includingPropertiesForKeys: nil)
                return entries?.contains { item in
                    (item as? URL)?.lastPathComponent.hasPrefix("discard-") == true
                } == true
            }
        }
        XCTAssertTrue(caughtRollback, "did not observe atomic incoming-home discard during native rollback")
        guard caughtRollback else {
            if firstRecovery.0.isRunning { _ = kill(firstRecovery.0.processIdentifier, SIGKILL) }
            firstRecovery.0.waitUntilExit()
            recoveryKilled = true
            return
        }
        XCTAssertTrue(stop(firstRecovery.0), "must stop and observe stopped state for exact recovery CLI child")
        XCTAssertEqual(kill(firstRecovery.0.processIdentifier, SIGKILL), 0, "must kill exact stopped recovery CLI child")
        firstRecovery.0.waitUntilExit()
        recoveryKilled = true
        XCTAssertEqual(try HostDatabaseRestore.inspect(backupURL: f.database).fingerprint, currentFingerprint)

        let recovered = try run(["--inspect-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(recovered.0, 0, recovered.2)
        XCTAssertEqual(try HostDatabaseRestore.inspect(backupURL: f.database).fingerprint, currentFingerprint)
        XCTAssertEqual(try snapshot(currentURLs), currentNative)
        XCTAssertEqual(try snapshot(f.bindingURLs), currentBindings)
        XCTAssertEqual(try scopedInventory(f), currentScopedInventory)
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertTrue(stages(f).isEmpty)
        try assertDatabaseState(f, revoked: true, rolledBack: true, restored: false)
    }

    func testPackagedCLIRestoreAndCreateRefuseHeldAppInstanceLockWithoutBackupFiles() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        guard case .acquired(let lock) = AppInstanceLock.acquire(directory: f.support) else {
            return XCTFail("fixture must acquire its own AppInstanceLock")
        }
        let before = try Data(contentsOf: f.database)
        let supportInventory = Set(try FileManager.default.subpathsOfDirectory(atPath: f.support.path))
        let create = try run(["--create-database-backup", f.backup.path], fixture: f)
        XCTAssertNotEqual(create.0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
        let restore = try run(["--restore-database-backup", f.backup.path, "--restore-review", "unused"], fixture: f)
        XCTAssertNotEqual(restore.0, 0)
        XCTAssertEqual(try Data(contentsOf: f.database), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
        XCTAssertEqual(Set(try FileManager.default.subpathsOfDirectory(atPath: f.support.path)), supportInventory)
        withExtendedLifetime(lock) {}
    }

    func testPackagedCLIScopedRestoreQuarantinesOrphansOnlyWhenAsked() throws {
        try requireLiveDocker()
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let source = try SQLiteDB(path: f.database.path)
            try source.execute("""
                PRAGMA foreign_keys=OFF;
                INSERT INTO agent_messages(id,thread_id,role,content,created_at) VALUES('m-orphan','22222222-2222-4222-8222-222222222222','user','lost parent','2026-01-01T00:00:00Z');
                """)
        }
        let created = try run(["--create-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(created.0, 0, created.2)
        let review = try run(["--inspect-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(review.0, 0, review.2)
        let token = try reviewToken(review.1)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(review.1.data(using: .utf8))) as? [String: Any])["scoped_session_count"] as? Int, 12)
        try mutateCurrentState(f)
        let bytesBefore = try Data(contentsOf: f.database)
        let nativeBefore = try scopedInventory(f)

        let refused = try run(["--restore-database-backup", f.backup.path, "--restore-review", token], fixture: f)
        XCTAssertNotEqual(refused.0, 0, "orphan rows must refuse a scoped restore by default")
        XCTAssertTrue(refused.2.contains("foreign key check failed"), refused.2)
        XCTAssertEqual(try Data(contentsOf: f.database), bytesBefore, "refused scoped restore must not alter the database")
        XCTAssertEqual(try scopedInventory(f), nativeBefore, "refused scoped restore must not alter native history")

        let restored = try run(["--restore-database-backup", f.backup.path, "--restore-review", token, "--quarantine-orphans"], fixture: f)
        XCTAssertEqual(restored.0, 0, restored.2)
        let line = try XCTUnwrap(restored.1.split(separator: "\n").first { $0.hasPrefix("Orphan rows were saved aside in: ") }.map(String.init), restored.1)
        let quarantine = URL(fileURLWithPath: String(line.dropFirst("Orphan rows were saved aside in: ".count)))
        let saved = try SQLiteDB(path: quarantine.path)
        let statement = try saved.prepare("SELECT COUNT(*) FROM agent_messages WHERE id='m-orphan';")
        defer { statement.reset() }
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnInt64(0), 1, "the orphan must be saved, not dropped")
        try assertDatabaseState(f, revoked: true)
    }

    func testPackagedCLIRejectsTamperedBackupWithoutChangingDatabase() throws {
        try requireLiveDocker()
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let created = try run(["--create-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(created.0, 0, created.2)
        let review = try run(["--inspect-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(review.0, 0, review.2)
        let validToken = try reviewToken(review.1)
        let bytesBefore = try Data(contentsOf: f.database)
        let companion = HostScopedSessionArchive.companionURL(for: f.backup)
        let archivedHistory = try XCTUnwrap(filesRecursively(under: companion.appendingPathComponent("histories")).first)
        let archivedBytes = try Data(contentsOf: archivedHistory)
        let nativeBefore = try scopedInventory(f)
        try Data("changed archived history bytes".utf8).write(to: archivedHistory)
        let historyTamper = try run(["--restore-database-backup", f.backup.path, "--restore-review", validToken], fixture: f)
        XCTAssertNotEqual(historyTamper.0, 0, "history hash mismatch must fail despite previously valid review token")
        XCTAssertEqual(try Data(contentsOf: f.database), bytesBefore)
        XCTAssertEqual(try scopedInventory(f), nativeBefore)
        try archivedBytes.write(to: archivedHistory)
        let manifestURL = companion.appendingPathComponent("manifest.json")
        let manifestBytes = try Data(contentsOf: manifestURL)
        try Data(manifestBytes + Data("duplicate".utf8)).write(to: manifestURL)
        let companionTamper = try run(["--restore-database-backup", f.backup.path, "--restore-review", validToken], fixture: f)
        XCTAssertNotEqual(companionTamper.0, 0, "companion tamper must fail despite previously valid review token")
        XCTAssertEqual(try Data(contentsOf: f.database), bytesBefore)
        try manifestBytes.write(to: manifestURL)
        let savedCompanion = f.root.appendingPathComponent("saved-companion")
        try FileManager.default.moveItem(at: companion, to: savedCompanion)
        let databaseOnlyReview = try run(["--inspect-database-backup", f.backup.path], fixture: f)
        XCTAssertEqual(databaseOnlyReview.0, 0, databaseOnlyReview.2)
        let databaseOnlyToken = try reviewToken(databaseOnlyReview.1)
        let databaseOnlyRestore = try run(["--restore-database-backup", f.backup.path, "--restore-review", databaseOnlyToken], fixture: f)
        XCTAssertNotEqual(databaseOnlyRestore.0, 0, "database-only restore must not detach existing native history")
        XCTAssertEqual(try scopedInventory(f), nativeBefore)
        XCTAssertEqual(try HostDatabaseRestore.inspect(backupURL: f.database).fingerprint, try HostDatabaseRestore.inspect(backupURL: f.backup).fingerprint)
        let outside = f.root.appendingPathComponent("outside-companion", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("outside owned sentinel".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: companion, withDestinationURL: outside)
        let companionSymlink = try run(["--inspect-database-backup", f.backup.path], fixture: f)
        XCTAssertNotEqual(companionSymlink.0, 0, "symlink companion must be rejected")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside owned sentinel".utf8))
        let backupBytes = try Data(contentsOf: f.backup)
        try Data(backupBytes + Data("tamper".utf8)).write(to: f.backup)
        let rejected = try run(["--restore-database-backup", f.backup.path, "--restore-review", "invalid-review-token"], fixture: f)
        XCTAssertNotEqual(rejected.0, 0, "tampered archive must not restore")
        XCTAssertEqual(try Data(contentsOf: f.database), bytesBefore, "rejected restore must not mutate the current database")
        let inputSentinel = f.root.appendingPathComponent("outside-sentinel")
        try Data("owned sentinel".utf8).write(to: inputSentinel)
        let link = f.root.appendingPathComponent("backup-link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inputSentinel)
        let symlink = try run(["--inspect-database-backup", link.path], fixture: f)
        XCTAssertNotEqual(symlink.0, 0, "symlink input must be rejected")
        XCTAssertEqual(try Data(contentsOf: inputSentinel), Data("owned sentinel".utf8))
    }

    func testPackagedCLIRejectsMixedDatabaseOperationsBeforeCreatingBackup() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let rejected = try run(["--create-database-backup", f.backup.path, "--inspect-database-backup", f.backup.path], fixture: f)
        XCTAssertNotEqual(rejected.0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
    }
}
