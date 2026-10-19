import XCTest
import CoreModel
import SocketServer
@testable import AppShell

@MainActor
final class DistillLoopStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistillLoopStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func loop(_ id: String = "t1", state: DistillLoopStatus = .active) -> DistillLoopState {
        DistillLoopState(
            taskID: id, prompt: "check deploy", humanSchedule: "every 5 minutes",
            nextFireAt: Date(timeIntervalSince1970: 1_700_000_000), iterations: 3, state: state)
    }

    func test_updatePersistsAndEmptyUpdateRemovesThread() {
        let thread = AgentThreadID()
        let store = DistillLoopStore(directory: directory, bus: EventBus())
        store.update(thread: thread, loops: [loop()])
        XCTAssertEqual(store.loops(for: thread).map(\.taskID), ["t1"])

        let reloaded = DistillLoopStore(directory: directory, bus: EventBus())
        XCTAssertEqual(reloaded.loops(for: thread).first?.prompt, "check deploy",
                       "loops must survive a MacCode restart")

        reloaded.update(thread: thread, loops: [])
        XCTAssertTrue(DistillLoopStore(directory: directory, bus: EventBus()).loops(for: thread).isEmpty,
                      "a stopped loop must not come back after relaunch")
    }

    func test_activeLoopReloadsPausedWaitingForResumeWithoutCountdown() {
        let thread = AgentThreadID()
        DistillLoopStore(directory: directory, bus: EventBus()).update(thread: thread, loops: [loop()])

        let reloaded = DistillLoopStore(directory: directory, bus: EventBus()).loops(for: thread)

        XCTAssertEqual(reloaded.first?.state, .paused)
        XCTAssertEqual(reloaded.first?.pausedReason, DistillLoopStore.resumeWaitingReason)
        XCTAssertNil(reloaded.first?.nextFireAt, "no fake countdown for a loop whose process is dead")
        XCTAssertEqual(reloaded.first?.iterations, 3)
    }

    func test_updatePublishesLoopsUpdatedEventForMirrors() {
        let thread = AgentThreadID()
        let bus = EventBus()
        var events: [EventBus.Event] = []
        let sub = bus.subscribe(since: bus.currentSeq) { events.append($0) }
        defer { bus.unsubscribe(sub) }
        let store = DistillLoopStore(directory: directory, bus: bus)

        store.update(thread: thread, loops: [loop()])

        let event = events.first { $0.kind == "agent.thread.loops.updated" }
        guard case .object(let payload)? = event?.payload else { return XCTFail("iOS needs the loops event") }
        XCTAssertEqual(payload["thread_id"], .string(thread.value.uuidString))
        guard case .array(let loops)? = payload["loops"] else { return XCTFail("payload must carry loops") }
        XCTAssertEqual(loops.count, 1)
    }

    func test_everyPausedReasonIsResumableAndOnlyPausedIs() {
        func paused(_ id: String, _ reason: String?) -> DistillLoopState {
            var l = loop(id, state: .paused)
            l.pausedReason = reason
            return l
        }
        let reasons: [String?] = [
            DistillLoopStore.resumeWaitingReason, "MacCode restarted the agent; resuming…",
            "Couldn't resume: boom", "Agent session stopped; resume to continue", nil,
        ]
        for (i, reason) in reasons.enumerated() {
            XCTAssertTrue(DistillLoopStore.resumable(paused("p\(i)", reason)),
                          "resumability must not depend on display text: \(String(describing: reason))")
        }
        XCTAssertFalse(DistillLoopStore.resumable(loop(state: .active)))
        XCTAssertFalse(DistillLoopStore.resumable(loop(state: .expired)))
        XCTAssertFalse(DistillLoopStore.resumable(loop(state: .stopped)))

        let resumable = AgentThreadID(), other = AgentThreadID()
        let store = DistillLoopStore(directory: directory, bus: EventBus())
        store.update(thread: resumable, loops: [paused("a", "Couldn't resume: boom")])
        store.update(thread: other, loops: [loop(state: .expired)])
        XCTAssertEqual(store.resumableThreadIDs(), [resumable],
                       "launch must resume threads whose loops failed a previous resume too")
    }
}
