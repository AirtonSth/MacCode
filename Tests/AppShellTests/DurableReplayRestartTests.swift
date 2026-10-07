import XCTest
@testable import AppShell
@testable import SocketServer
@testable import Persistence
import CoreModel

/// C8 across a host restart, with the real SQLite event log and the real
/// persister. Why it matters: a Mac restart used to force every iPhone into a
/// full baseline even though the state events it missed are on disk. After a
/// clean quit the next boot must continue the sequence above everything the
/// old boot published (no seq reuse), replay the missed state events from the
/// log on the read-only connection, and report the threads whose live deltas
/// died with the old process. Without a clean record it must not pretend.
@MainActor
final class DurableReplayRestartTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "RC2DurableRestart-" + UUID().uuidString
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func boot() throws -> (AppContext, EventBus) {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let bus = EventBus()
        AppDelegate.wireEventPersistence(context: context, eventBus: bus)
        bus.reloadFromPersistence(lastSeq: try context.eventLog.lastSeq(), recent: [])
        return (context, bus)
    }

    private func state(_ bus: EventBus, _ marker: String) {
        bus.publish(kind: .workspaceUpdated, payload: .object([
            "workspace_id": .string("w-1"), "name": .string(marker),
        ]))
    }

    private func delta(_ bus: EventBus, thread: String) {
        bus.publish(kind: .agentItemDelta, payload: .object([
            "thread_id": .string(thread), "item_id": .string("i-1"), "delta": .string("tok"),
        ]))
    }

    /// Old boot: the client saw through `cursor`, then missed two state
    /// events and deltas on two threads; the last thing published was a delta.
    private func runOldBoot(cleanQuit: Bool) throws -> (cursor: Int64, highWater: Int64, epoch: UInt64) {
        let (context, bus) = try boot()
        state(bus, "anchor")
        delta(bus, thread: "t-before")
        let cursor = bus.currentSeq
        delta(bus, thread: "t-a")
        state(bus, "missed-1")
        state(bus, "missed-2")
        delta(bus, thread: "t-b")
        context.flushEventPersistence(eventBus: bus)
        if cleanQuit {
            XCTAssertTrue(DurableReplayResumeRecord.write(
                eventBus: bus,
                settings: context.settingsRepo,
                bootEpoch: context.liveActivityHostIdentity.bootEpoch
            ))
        }
        return (cursor, bus.currentSeq, context.liveActivityHostIdentity.bootEpoch)
    }

    func test_cleanRestart_continuesSequence_replaysMissedStateFromLog_andGapsLostThreads() throws {
        let old = try runOldBoot(cleanQuit: true)
        let (context, bus) = try boot()
        XCTAssertEqual(context.liveActivityHostIdentity.bootEpoch, old.epoch + 1)

        XCTAssertTrue(DurableReplayResumeRecord.restore(
            eventBus: bus, settings: context.settingsRepo,
            bootEpoch: context.liveActivityHostIdentity.bootEpoch
        ))
        XCTAssertEqual(bus.currentSeq, old.highWater,
                       "the trailing delta was never persisted; its seq must still not be reused")

        let accepted = DurableReplayContract.acceptedResume(
            requestedSinceSequence: old.cursor,
            requestedResumeHost: "host",
            requestedResumeBootEpoch: Int64(old.epoch),
            serverId: "host",
            bootEpoch: Int64(context.liveActivityHostIdentity.bootEpoch),
            currentSequence: bus.currentSeq,
            previousBoot: bus.previousBootReplay
        )
        XCTAssertTrue(accepted == (old.cursor, true, true))

        state(bus, "new-boot")
        context.flushEventPersistence(eventBus: bus)
        let plan = bus.durableReplayPlan(since: old.cursor, previousBoot: true)
        XCTAssertEqual(plan.outcome, .replay)
        XCTAssertEqual(Set(plan.streamGaps.map(\.stream)), [.thread("t-a"), .thread("t-b")],
                       "t-before lost nothing the client had not already seen")

        let page = try XCTUnwrap(bus.readDurableReplayPage(
            after: old.cursor, through: plan.durableThrough, maxBytes: 1 << 20
        ), "the read-only connection reaches the cursor in the event log")
        let replayed = (page.events + plan.ringBacklog)
            .compactMap { $0.payload.objectValue?["name"]?.stringValue }
        XCTAssertEqual(replayed, ["missed-1", "missed-2", "new-boot"])
        XCTAssertTrue(page.events.allSatisfy { $0.ts > 0 }, "replayed events keep their stored time")

        XCTAssertFalse(DurableReplayResumeRecord.restore(
            eventBus: bus, settings: context.settingsRepo,
            bootEpoch: context.liveActivityHostIdentity.bootEpoch
        ), "the record is consumed once")
    }

    func test_uncleanRestart_withoutRecord_keepsBaseline() throws {
        let old = try runOldBoot(cleanQuit: false)
        let (context, bus) = try boot()
        XCTAssertFalse(DurableReplayResumeRecord.restore(
            eventBus: bus, settings: context.settingsRepo,
            bootEpoch: context.liveActivityHostIdentity.bootEpoch
        ))
        let accepted = DurableReplayContract.acceptedResume(
            requestedSinceSequence: old.cursor,
            requestedResumeHost: "host",
            requestedResumeBootEpoch: Int64(old.epoch),
            serverId: "host",
            bootEpoch: Int64(context.liveActivityHostIdentity.bootEpoch),
            currentSequence: bus.currentSeq,
            previousBoot: bus.previousBootReplay
        )
        XCTAssertTrue(accepted == (0, false, false), "a crash may have lost events: baseline")

        // The same cursor without the envelope: its boot is unproven, so the
        // log (whose crashed-boot deltas no ledger remembers) must not serve it.
        let legacy = DurableReplayContract.acceptedResume(
            requestedSinceSequence: old.cursor,
            requestedResumeHost: nil,
            requestedResumeBootEpoch: nil,
            serverId: "host",
            bootEpoch: Int64(context.liveActivityHostIdentity.bootEpoch),
            currentSequence: bus.currentSeq,
            previousBoot: bus.previousBootReplay
        )
        XCTAssertTrue(legacy == (old.cursor, false, false))
        let plan = bus.durableReplayPlan(since: legacy.since, allowEventLog: legacy.eventLog)
        XCTAssertEqual(plan.outcome, .baselineRequired,
                       "t-a and t-b lost deltas in the crashed boot; a log replay would never report them")
    }

    func test_eventAfterTheRecord_invalidatesIt_butDiagnosticsDoNot() throws {
        let (context, bus) = try boot()
        state(bus, "anchor")
        context.flushEventPersistence(eventBus: bus)
        let settings = context.settingsRepo
        let epoch = context.liveActivityHostIdentity.bootEpoch
        XCTAssertTrue(DurableReplayResumeRecord.write(eventBus: bus, settings: settings, bootEpoch: epoch))

        bus.publish(kind: .diagnosticWSConnectionClosed, payload: .object(["reason": .string("peerClose")]))
        XCTAssertFalse(try settings.get(DurableReplayResumeRecord.settingsKey)?.isEmpty ?? true,
                       "a close diagnostic from the server shutdown is in the log and replays")

        state(bus, "late-state")
        XCTAssertEqual(try settings.get(DurableReplayResumeRecord.settingsKey), "",
                       "a state event after the record would make it lie")
    }

    func test_recordIsRefused_whileLogWritesArePending() throws {
        let (context, bus) = try boot()
        let gate = DispatchSemaphore(value: 0)
        AppContext.beforeEventLogBatchWriteForTesting = { gate.wait() }
        defer { AppContext.beforeEventLogBatchWriteForTesting = nil }
        state(bus, "pending")
        XCTAssertFalse(DurableReplayResumeRecord.write(
            eventBus: bus, settings: context.settingsRepo,
            bootEpoch: context.liveActivityHostIdentity.bootEpoch
        ), "the log is not complete yet")
        gate.signal()
        context.flushEventPersistence(eventBus: bus)
    }

    /// The budget estimate runs before the welcome, so it must stay cheap
    /// for any cursor: it stops at `rowLimit` rows and skips the byte sum
    /// once retention has passed the cursor.
    func test_sqliteEstimate_isBoundedByRowLimit_andReportsAPrunedCursor() throws {
        let (context, bus) = try boot()
        state(bus, "anchor")
        let cursor = bus.currentSeq
        for index in 0..<20 { state(bus, "row-\(index)") }
        context.flushEventPersistence(eventBus: bus)
        let log = EventLogRepository(db: context.readDB)

        let all = try log.estimateReplay(after: cursor, through: bus.currentSeq, rowLimit: .max)
        XCTAssertEqual(all.rows, 20)
        XCTAssertTrue(all.anchored)
        let bounded = try log.estimateReplay(after: cursor, through: bus.currentSeq, rowLimit: 3)
        XCTAssertEqual(bounded.rows, 3)
        XCTAssertLessThan(bounded.bytes, all.bytes)

        let beforeRetention = try log.estimateReplay(after: 0, through: bus.currentSeq, rowLimit: .max)
        XCTAssertFalse(beforeRetention.anchored, "no row at or below the cursor: it may have been pruned")
        XCTAssertEqual(beforeRetention.rows, 0, "no byte sum for a cursor the log cannot serve")
    }
}
