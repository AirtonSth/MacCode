import CoreModel
import Foundation
import XCTest
@testable import Persistence

final class BotRoutineDispatchAuthorityTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let database: URL
        let db: SQLiteDB
        let store: BotStore
        let settings: SettingsStore
        let authority: BotRemoteControlAuthority
        let routine: BotRoutineDefinition
        let now: Date
    }

    private func withFixture(frequency: ScheduledTaskFrequency = .once, _ body: (Fixture) throws -> Void) throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
            .appendingPathComponent("RoutineDispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let database = root.appendingPathComponent("owned.sqlite")
        let db = try SQLiteDB(path: database.path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let settings = SettingsStore(db: db)
        settings.update { $0.botsControlPlaneEnabled = true; $0.botsAutonomyEnabled = true }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bot = try store.create(name: "Dispatch", title: "Dispatch", description: "", soul: "", provider: .distill, model: "unused")
        let schedule = BotScheduleSpec(provider: .distill, model: "unused", frequency: frequency,
            scheduledDate: now.addingTimeInterval(-1), timeZoneIdentifier: "UTC")
        let routine = BotRoutineDefinition(botID: bot.id, name: "Owned scheduled task", prompt: "private original fixture intent",
            scheduleSpecJSON: schedule.encodedJSON(), createdAt: now.addingTimeInterval(-10), updatedAt: now.addingTimeInterval(-10))
        try store.saveRoutine(routine, now: now.addingTimeInterval(-10))
        try store.setRoutineEnabled(id: routine.id, enabled: true, now: now.addingTimeInterval(-10))
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: settings, appSupportDirectory: root)
        try body(Fixture(root: root, database: database, db: db, store: store, settings: settings,
            authority: authority, routine: routine, now: now))
    }

    private func claimed(_ f: Fixture) throws -> BotRemoteControlAuthority.RoutineFire {
        let fires = try f.authority.claimDueRoutines(now: f.now)
        XCTAssertEqual(fires.count, 1, "test must drive the shipped scheduler claim, not manufacture a fire")
        return try XCTUnwrap(fires.first)
    }

    private func assertNoRuns(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        for table in ["agent_threads", "agent_runs", "agent_messages", "agent_queued_messages"] {
            let query = try f.db.prepare("SELECT COUNT(*) FROM \(table);")
            XCTAssertTrue(try query.step(), file: file, line: line)
            XCTAssertEqual(query.columnInt64(0), 0, "automatic refusal must not create work in \(table)", file: file, line: line)
        }
    }

    func testPauseThroughAnotherSettingsStoreAfterClaimPreventsDispatchAndReopenReplay() throws {
        try withFixture { f in
            let fire = try claimed(f)
            var calls = 0
            f.authority.onRoutineSend = { _ in
                calls += 1
                throw BotRemoteControlAuthority.Error(code: -32091, message: "owned execution boundary reached")
            }
            try {
                let other = try SQLiteDB(path: f.database.path)
                SettingsStore(db: other).update { $0.botsAutonomyEnabled = false }
            }()
            let result = f.authority.startRoutineFire(fire, now: f.now)
            XCTAssertEqual(calls, 0, "a claimed slot is not permission to execute after host scheduling policy is paused")
            XCTAssertEqual(result["result"] as? String, "failed")
            XCTAssertTrue((result["error"] as? String)?.contains("paused") == true)
            XCTAssertFalse(f.settings.reload().isBotAutonomyActive)
            try assertNoRuns(f)
            try {
                let reopenedDB = try SQLiteDB(path: f.database.path)
                let settings = SettingsStore(db: reopenedDB)
                let reopened = BotRemoteControlAuthority(db: reopenedDB, store: BotStore(db: reopenedDB), settings: settings, appSupportDirectory: f.root)
                XCTAssertTrue(try reopened.claimDueRoutines(now: f.now).isEmpty)
                settings.update { $0.botsAutonomyEnabled = true }
                XCTAssertTrue(try reopened.claimDueRoutines(now: f.now).isEmpty, "reenabling cannot reclaim the spent occurrence")
            }()
            XCTAssertEqual(calls, 0)
        }
    }

    func testPauseObservedDuringDispatchSkipsMissedSlotsWhenSameAuthorityResumes() throws {
        try withFixture(frequency: .hourly) { f in
            let fire = try claimed(f)
            var calls = 0
            f.authority.onRoutineSend = { _ in
                calls += 1
                throw BotRemoteControlAuthority.Error(code: -32091, message: "owned execution boundary reached")
            }
            f.settings.update { $0.botsAutonomyEnabled = false }
            let paused = f.authority.startRoutineFire(fire, now: f.now)
            XCTAssertEqual(paused["result"] as? String, "failed")
            XCTAssertEqual(calls, 0)
            f.settings.update { $0.botsAutonomyEnabled = true }
            XCTAssertTrue(try f.authority.claimDueRoutines(now: f.now.addingTimeInterval(2 * 3600 + 120)).isEmpty,
                          "a pause found at dispatch must reseed missed occurrences, just like a pause found at tick")
            try assertNoRuns(f)
        }
    }

    func testDisableOrEditAfterClaimPreventsCapturedPromptDispatch() throws {
        for edit in [false, true] {
            try withFixture { f in
                let fire = try claimed(f)
                var calls = 0
                f.authority.onRoutineSend = { _ in
                    calls += 1
                    throw BotRemoteControlAuthority.Error(code: -32091, message: "owned execution boundary reached")
                }
                if edit {
                    var changed = f.routine
                    changed.prompt = "private replacement fixture intent"
                    try f.store.saveRoutine(changed, now: f.now.addingTimeInterval(1))
                } else {
                    try f.store.setRoutineEnabled(id: f.routine.id, enabled: false, now: f.now)
                }
                let result = f.authority.startRoutineFire(fire, now: f.now.addingTimeInterval(2))
                XCTAssertEqual(calls, 0, "dispatch must re-read durable activation and reject an obsolete definition")
                XCTAssertEqual(result["result"] as? String, "failed")
                XCTAssertTrue((result["error"] as? String)?.contains("changed") == true)
                XCTAssertFalse((result["error"] as? String)?.contains("private") == true)
                try assertNoRuns(f)
            }
        }
    }

    func testContextualRoutineAndTickRefuseRevokedRevisionAfterReopen() throws {
        try withFixture { f in
            let host = "owned-routine-context"
            let grant = try f.store.grantContext(hostID: host, botID: f.routine.botID, context: .general,
                actions: [.read, .send, .schedule], expectedRevision: 0)
            var calls = 0
            f.authority.onRoutineSend = { _ in
                calls += 1
                throw BotRemoteControlAuthority.Error(code: -32091, message: "owned execution boundary reached")
            }
            let params: [String: Any] = ["bot_id": f.routine.botID.value.uuidString.lowercased(),
                "host_id": host, "context_key": BotContext.general.storageKey,
                "context_version": BotContext.contractVersion, "policy_revision": grant.policyRevision,
                "routine_id": f.routine.id.value.uuidString.lowercased(), "client_request_id": "owned-context-routine"]
            for method in ["bot.routine.run", "bot.scheduler.tick"] {
                XCTAssertThrowsError(try f.authority.dispatch(method: method, params: params, now: f.now)) { error in
                    XCTAssertEqual((error as? BotRemoteControlAuthority.Error)?.code, -32602,
                                   "active contextual resources must remain unavailable, not use a legacy route")
                }
            }
            _ = try f.store.revokeContext(hostID: host, botID: f.routine.botID, context: .general,
                expectedRevision: grant.policyRevision)
            let db = try SQLiteDB(path: f.database.path)
            let reopened = BotRemoteControlAuthority(db: db, store: BotStore(db: db),
                settings: SettingsStore(db: db), appSupportDirectory: f.root)
            reopened.onRoutineSend = f.authority.onRoutineSend
            for method in ["bot.routine.run", "bot.scheduler.tick"] {
                XCTAssertThrowsError(try reopened.dispatch(method: method, params: params, now: f.now)) { error in
                    XCTAssertEqual((error as? BotRemoteControlAuthority.Error)?.code, -32084,
                                   "revoked context must fail current authority before scheduler or send effects")
                }
            }
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try reopened.claimDueRoutines(now: f.now).count, 1,
                           "refused contextual requests must not consume the separate legacy occurrence")
            try assertNoRuns(f)
        }
    }

    func testControlPlaneDisabledThroughAnotherStorePreventsManualRoutineDispatch() throws {
        try withFixture { f in
            _ = try claimed(f)
            var calls = 0
            f.authority.onRoutineSend = { _ in
                calls += 1
                throw BotRemoteControlAuthority.Error(code: -32091, message: "owned execution boundary reached")
            }
            try {
                let other = try SQLiteDB(path: f.database.path)
                SettingsStore(db: other).update { $0.botsControlPlaneEnabled = false }
            }()
            XCTAssertThrowsError(try f.authority.dispatch(method: "bot.routine.run", params: [
                "bot_id": f.routine.botID.value.uuidString.lowercased(),
                "routine_id": f.routine.id.value.uuidString.lowercased(),
                "client_request_id": "owned-disabled-control-plane"
            ], now: f.now)) { error in
                XCTAssertEqual((error as? BotRemoteControlAuthority.Error)?.code, -32081)
            }
            XCTAssertEqual(calls, 0, "the master host control-plane policy differs from the automatic scheduling pause")
            XCTAssertFalse(f.settings.reload().isBotControlPlaneActive)
            try assertNoRuns(f)
        }
    }

    func testForceNowDisabledThroughAnotherStoreLeavesQueueUntouched() throws {
        try withFixture { f in
            let first = try f.store.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(botID: f.routine.botID, text: "first", createdAt: f.now))
            let second = try f.store.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(botID: f.routine.botID, text: "second", createdAt: f.now))
            let before = try f.store.listQueuedFollowUps(botID: f.routine.botID)
            var calls = 0
            f.authority.onForceQueuedFollowUp = { _, _ in
                calls += 1
                return ["force_status": "queued"]
            }
            try {
                let other = try SQLiteDB(path: f.database.path)
                SettingsStore(db: other).update { $0.botsControlPlaneEnabled = false }
            }()
            XCTAssertThrowsError(try f.authority.dispatch(method: "bot.queue.force_now", params: [
                "bot_id": f.routine.botID.value.uuidString.lowercased(),
                "id": second.id,
                "client_request_id": "owned-disabled-force-now"
            ], now: f.now)) { error in
                XCTAssertEqual((error as? BotRemoteControlAuthority.Error)?.code, -32081)
            }
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try f.store.listQueuedFollowUps(botID: f.routine.botID), before)
            XCTAssertEqual(before.map(\.id), [first.id, second.id])
        }
    }

    func testUnchangedAutomaticAndExplicitManualRunStillReachSendBoundary() throws {
        try withFixture { f in
            let fire = try claimed(f)
            var calls = 0
            f.authority.onRoutineSend = { _ in
                calls += 1
                // A deliberate refusal proves admission without inventing a provider run.
                throw BotRemoteControlAuthority.Error(code: -32091, message: "owned execution boundary reached")
            }
            let automatic = f.authority.startRoutineFire(fire, now: f.now)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(automatic["error"] as? String, "owned execution boundary reached")
            f.settings.update { $0.botsAutonomyEnabled = false }
            try f.store.setRoutineEnabled(id: f.routine.id, enabled: false, now: f.now)
            _ = try f.authority.dispatch(method: "bot.routine.run", params: [
                "bot_id": f.routine.botID.value.uuidString.lowercased(),
                "routine_id": f.routine.id.value.uuidString.lowercased(),
                "client_request_id": "owned-manual-run"
            ], now: f.now)
            XCTAssertEqual(calls, 2, "automatic pause must not remove the explicit human test-run action")
            try assertNoRuns(f)
        }
    }
}
