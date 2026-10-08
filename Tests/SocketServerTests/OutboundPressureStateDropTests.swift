import XCTest
@testable import SocketServer
import CoreModel

/// MOR-03 / MOR-12: when a saturated socket drops a state event the host tells
/// the phone with `baselineRequired`. The frame always carried
/// `requestedAfterSequence == currentSequence`, the cheap form that iOS answers
/// by replaying `events.recent` from its own cursor. If a later event reached
/// the phone before that frame (the frame is rate limited to one per second
/// and may itself not fit the queue), the phone's cursor was already past the
/// dropped event and it was never recovered. The gate must remember dropped
/// state events and ask for a snapshot exactly when the client may be past
/// one, at most once per client snapshot window so a snapshot in flight is
/// not invalidated every second.
final class OutboundPressureStateDropTests: XCTestCase {
    // MARK: - Gate

    func test_dropWithNothingAcceptedAfterIt_keepsTheCheapForm() throws {
        let gate = OutboundPressureBaselineGate()
        gate.noteAccepted(9)
        gate.noteStateDrop(10)

        let drops = try XCTUnwrap(gate.takeStateDrops(now: 100))

        XCTAssertEqual(drops.lowest, 10)
        XCTAssertEqual(drops.highest, 10)
        XCTAssertFalse(drops.clientMayBePast,
                       "the client is still below the drop: its own replay returns the event")
    }

    func test_eventAcceptedAfterTheDrop_asksForTheSnapshotForm() throws {
        let gate = OutboundPressureBaselineGate()
        gate.noteStateDrop(10)
        gate.noteAccepted(11)

        let drops = try XCTUnwrap(gate.takeStateDrops(now: 100))

        XCTAssertEqual(drops.lowest, 10)
        XCTAssertEqual(drops.highest, 10)
        XCTAssertTrue(drops.clientMayBePast,
                      "seq 11 may reach the client first; a replay from its cursor would skip seq 10")
    }

    func test_severalDrops_reportTheWholeRange() throws {
        let gate = OutboundPressureBaselineGate()
        gate.noteStateDrop(12)
        gate.noteStateDrop(10)
        gate.noteAccepted(11)

        let drops = try XCTUnwrap(gate.takeStateDrops(now: 100))

        XCTAssertEqual(drops.lowest, 10)
        XCTAssertEqual(drops.highest, 12)
        XCTAssertTrue(drops.clientMayBePast)
    }

    func test_take_clearsTheRange_andPutBackIsReEvaluated() throws {
        let gate = OutboundPressureBaselineGate()
        gate.noteStateDrop(10)

        let first = try XCTUnwrap(gate.takeStateDrops(now: 100))
        XCTAssertFalse(first.clientMayBePast)
        XCTAssertNil(gate.takeStateDrops(now: 100), "one accepted baseline covers the range once")

        // The baseline could not be queued: the range goes back, and an event
        // accepted meanwhile changes what the next emission must ask for.
        gate.noteStateDrop(first.lowest)
        gate.noteStateDrop(first.highest)
        gate.noteAccepted(11)
        let retried = try XCTUnwrap(gate.takeStateDrops(now: 101))
        XCTAssertEqual(retried.lowest, 10)
        XCTAssertTrue(retried.clientMayBePast)
    }

    /// Every snapshot-form frame raises the client's minimum snapshot
    /// sequence, also while it is still downloading one. Sent once per second
    /// they make a slow snapshot never converge and the client disconnects.
    func test_insideTheSnapshotWindow_onlyOneSnapshotFormIsAsked_andLaterDropsStayPending() throws {
        let gate = OutboundPressureBaselineGate()
        gate.noteStateDrop(10)
        gate.noteAccepted(11)
        let first = try XCTUnwrap(gate.takeStateDrops(now: 100))
        XCTAssertTrue(first.clientMayBePast)
        gate.holdSnapshotForm(for: 15, now: 100)

        gate.noteStateDrop(20)
        gate.noteAccepted(21)
        let held = try XCTUnwrap(gate.takeStateDrops(now: 101))
        XCTAssertFalse(held.clientMayBePast, "inside the window only the cheap form is emitted")
        XCTAssertEqual(held.highest, 20, "the cheap form still names the newest dropped sequence")
        let heldAgain = try XCTUnwrap(gate.takeStateDrops(now: 114.9))
        XCTAssertEqual(heldAgain.lowest, 20, "the range is only peeked while the window is open")
        XCTAssertFalse(heldAgain.clientMayBePast)

        gate.noteStateDrop(30)
        let afterWindow = try XCTUnwrap(gate.takeStateDrops(now: 115))
        XCTAssertEqual(afterWindow.lowest, 20)
        XCTAssertEqual(afterWindow.highest, 30)
        XCTAssertTrue(afterWindow.clientMayBePast,
                      "the drops kept during the window are recovered by one snapshot form after it")
        XCTAssertNil(gate.takeStateDrops(now: 116))
    }

    /// A drop that was only peeked inside the window has no emission left
    /// once pressure stops; the host owes it one at the end of the window.
    func test_dropPeekedInsideTheWindow_staysOwed_untilAnEmissionTakesIt() throws {
        let gate = OutboundPressureBaselineGate()
        XCTAssertFalse(gate.hasPendingStateDrops, "nothing dropped, nothing owed")
        gate.holdSnapshotForm(for: 15, now: 100)
        gate.noteStateDrop(20)
        gate.noteAccepted(21)

        _ = try XCTUnwrap(gate.takeStateDrops(now: 101))
        XCTAssertTrue(gate.hasPendingStateDrops,
                      "the cheap form sent inside the window does not recover a drop the client is past")

        let afterWindow = try XCTUnwrap(gate.takeStateDrops(now: 115))
        XCTAssertTrue(afterWindow.clientMayBePast)
        XCTAssertFalse(gate.hasPendingStateDrops, "the emission after the window covers the range once")

        gate.noteStateDrop(30)
        gate.markClosed()
        XCTAssertFalse(gate.hasPendingStateDrops, "a closed connection is owed nothing")
    }

    // MARK: - Live socket

    private final class FrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [[String: Any]] = []

        /// One receive loop for the whole test: a timed-out receive would
        /// leave an orphaned `task.receive` behind.
        func start(_ task: URLSessionWebSocketTask) {
            task.receive { [weak self] result in
                guard let self, case .success(let message) = result else { return }
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: data = Data()
                }
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.lock.lock(); self.frames.append(object); self.lock.unlock()
                }
                self.start(task)
            }
        }

        var all: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return frames
        }

        func baselines() -> [(requestedAfter: Int64, current: Int64)] {
            all.compactMap { frame in
                guard frame["type"] as? String == "baselineRequired",
                      let requestedAfter = (frame["requestedAfterSequence"] as? NSNumber)?.int64Value,
                      let current = (frame["currentSequence"] as? NSNumber)?.int64Value else { return nil }
                return (requestedAfter, current)
            }
        }
    }

    private final class BusRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sequences: [String: [Int64]] = [:]

        func record(_ event: EventBus.Event) {
            lock.lock(); sequences[event.kind, default: []].append(event.seq); lock.unlock()
        }

        func sequences(of kind: String) -> [Int64] {
            lock.lock(); defer { lock.unlock() }
            return sequences[kind] ?? []
        }
    }

    /// Larger than any budget this socket can reach (64 KiB floor), so the
    /// event is always dropped, never queued.
    private static let oversizedBlob = String(repeating: "x", count: 72 * 1_024)

    @MainActor
    private func startServer() throws -> (DirectHTTPServer, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 33_000...44_000)
            let server = DirectHTTPServer(
                port: port,
                loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                serverId: "state-drop-host",
                bootEpoch: 42,
                webSocketOutboundMaxQueuedBytes: 2_048
            )
            if (try? server.start()) != nil { return (server, port) }
        }
        throw NSError(domain: "OutboundPressureStateDropTests", code: 1)
    }

    private func connect(
        port: UInt16,
        snapshotTimeoutMs: Int? = nil
    ) -> (URLSessionWebSocketTask, FrameCollector) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("\(EventBus.shared.currentSeq)", forHTTPHeaderField: "x-rc2-since-seq")
        if let snapshotTimeoutMs {
            request.setValue("\(snapshotTimeoutMs)", forHTTPHeaderField: "X-RC2-Snapshot-Timeout-Ms")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        let frames = FrameCollector()
        task.resume()
        frames.start(task)
        return (task, frames)
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func uniqueKind(_ prefix: String) -> String {
        "\(prefix).\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }

    @MainActor
    func test_stateEventDroppedBehindALaterAcceptedEvent_isRecoveredBySnapshotForm() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)
        let droppedKind = uniqueKind("test.ws.statedrop")
        let acceptedKind = uniqueKind("test.ws.afterdrop")
        let recorder = BusRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { recorder.record($0) }
        defer { EventBus.shared.unsubscribe(subscription) }
        let (task, frames) = connect(port: port)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let welcomed = await waitUntil(2) { frames.all.contains { $0["type"] as? String == "welcome" } }
        XCTAssertTrue(welcomed)

        // First drop: its baseline is emitted at once and arms the 1/s gate.
        // Second drop, published back to back: its baseline is deferred by
        // the gate, and a later event is delivered before it.
        EventBus.shared.publishRawForTesting(kind: droppedKind, payload: .object([
            "blob": .string(Self.oversizedBlob),
        ]))
        EventBus.shared.publishRawForTesting(kind: droppedKind, payload: .object([
            "blob": .string(Self.oversizedBlob),
        ]))
        EventBus.shared.publishRawForTesting(kind: acceptedKind, payload: .object(["marker": .bool(true)]))
        let dropped = try XCTUnwrap(recorder.sequences(of: droppedKind).last)
        let accepted = try XCTUnwrap(recorder.sequences(of: acceptedKind).last)
        XCTAssertGreaterThan(accepted, dropped)

        let recovered = await waitUntil(4) {
            frames.baselines().contains { $0.requestedAfter < dropped && dropped <= $0.current }
        }

        XCTAssertTrue(
            recovered,
            "the client is already past seq \(dropped); only a baseline that starts below it recovers the event: \(frames.baselines())"
        )
        XCTAssertTrue(
            frames.all.contains { $0["kind"] as? String == acceptedKind },
            "the later event was delivered on the same socket"
        )
        XCTAssertFalse(frames.all.contains { $0["type"] as? String == "closing" },
                       "pressure never closes the socket")
    }

    /// The window end to end. Inside the client's snapshot window a new state
    /// drop gets only the cheap form: a second snapshot form would invalidate
    /// the snapshot in flight. The client is already past that drop, so the
    /// cheap form does not recover it; when the window ends the host must ask
    /// for the snapshot form itself, also when pressure has stopped and no
    /// other emission would ever run.
    @MainActor
    func test_stateDropInsideTheSnapshotWindow_getsTheCheapForm_thenOneSnapshotFormWhenTheWindowEnds() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)
        let droppedKind = uniqueKind("test.ws.statedrop")
        let acceptedKind = uniqueKind("test.ws.afterdrop")
        let recorder = BusRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { recorder.record($0) }
        defer { EventBus.shared.unsubscribe(subscription) }
        // The shortest window a client can negotiate keeps the test short.
        let (task, frames) = connect(
            port: port,
            snapshotTimeoutMs: Int(DirectHTTPServer.wsSnapshotTimeoutMinMs)
        )
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let welcomed = await waitUntil(2) { frames.all.contains { $0["type"] as? String == "welcome" } }
        XCTAssertTrue(welcomed)

        // Opens the window: the second drop is behind an accepted event and
        // is recovered by a snapshot form (see the test above).
        for _ in 0..<2 {
            EventBus.shared.publishRawForTesting(kind: droppedKind, payload: .object([
                "blob": .string(Self.oversizedBlob),
            ]))
        }
        EventBus.shared.publishRawForTesting(kind: acceptedKind, payload: .object(["marker": .bool(true)]))
        let firstDrop = try XCTUnwrap(recorder.sequences(of: droppedKind).last)
        let snapshotForms = {
            frames.baselines().filter { $0.requestedAfter < $0.current && $0.current >= firstDrop }
        }
        let windowOpened = await waitUntil(4) { !snapshotForms().isEmpty }
        XCTAssertTrue(windowOpened, "no snapshot form opened the window: \(frames.baselines())")

        // A state drop inside the window, again behind an accepted event.
        EventBus.shared.publishRawForTesting(kind: droppedKind, payload: .object([
            "blob": .string(Self.oversizedBlob),
        ]))
        EventBus.shared.publishRawForTesting(kind: acceptedKind, payload: .object(["marker": .bool(true)]))
        let heldDrop = try XCTUnwrap(recorder.sequences(of: droppedKind).last)
        XCTAssertGreaterThan(heldDrop, firstDrop)

        // Two flush periods of the 1/s gate, well inside the 5 s window.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(
            snapshotForms().count, 1,
            "a second snapshot form inside the window invalidates the snapshot in flight: \(frames.baselines())"
        )
        XCTAssertTrue(
            frames.baselines().contains { $0.requestedAfter == $0.current && $0.current >= heldDrop },
            "inside the window the new drop is announced with the cheap form: \(frames.baselines())"
        )

        // Nothing is published any more: only the host's own emission at the
        // end of the window can recover the drop.
        let recovered = await waitUntil(6) {
            frames.baselines().contains { $0.requestedAfter < heldDrop && heldDrop <= $0.current }
        }
        XCTAssertTrue(
            recovered,
            "seq \(heldDrop) was dropped inside the window and never recovered after it: \(frames.baselines())"
        )
        XCTAssertEqual(snapshotForms().count, 2, "one snapshot form per window: \(frames.baselines())")
        XCTAssertFalse(frames.all.contains { $0["type"] as? String == "closing" },
                       "pressure never closes the socket")
    }

    /// The diagnostic was published on the shared bus, delivered back to the
    /// socket that was under pressure, and re-triggered the pressure it
    /// reported once per second.
    @MainActor
    func test_acceptedPressureBaseline_publishesNothingOnTheBus() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)
        let recorder = BusRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { recorder.record($0) }
        defer { EventBus.shared.unsubscribe(subscription) }
        let (task, frames) = connect(port: port)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let welcomed = await waitUntil(2) { frames.all.contains { $0["type"] as? String == "welcome" } }
        XCTAssertTrue(welcomed)

        EventBus.shared.publishRawForTesting(kind: uniqueKind("test.ws.statedrop"), payload: .object([
            "blob": .string(Self.oversizedBlob),
        ]))
        let baselineSent = await waitUntil(2) { !frames.baselines().isEmpty }
        XCTAssertTrue(baselineSent, "the pressure baseline must have been accepted")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(recorder.sequences(of: "diagnostic.ws_outbound_pressure"), [],
                       "reporting pressure must not add an event to the stream that is under pressure")
    }
}
