import XCTest
import CoreModel
@testable import Surfaces

/// Regression for audit F12: `SurfaceRuntimeBus` published health on a serial
/// `queue.async`, so a health TRANSITION (e.g. "process exited", "input stalled")
/// was delivered LATE — it sat in a background FIFO before the sink ran — and the
/// `queue.sync` getter could block. The fix stores the sink under a lock and emits
/// SYNCHRONOUSLY on the caller thread (the sink itself hops to @MainActor where it
/// needs to), so a transition is observable immediately and deterministically.
final class SurfaceRuntimeBusTests: XCTestCase {

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(SurfaceID, Bool)] = []
        func record(_ id: SurfaceID, _ alive: Bool) { lock.lock(); _calls.append((id, alive)); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _calls.count }
        var last: (SurfaceID, Bool)? { lock.lock(); defer { lock.unlock() }; return _calls.last }
    }

    private func health(alive: Bool) -> TerminalRuntimeHealth {
        TerminalRuntimeHealth(
            processAlive: alive,
            childPID: alive ? 4242 : nil,
            exitStatus: nil,
            terminationSignal: nil,
            ptyOpen: alive,
            inputAccepting: alive,
            terminalDeadReason: alive ? nil : "process_exited",
            lastOutputAt: nil,
            outputPartial: false,
            outputPendingBytes: 0,
            historyWriteFailures: 0,
            rows: 24,
            cols: 80
        )
    }

    override func tearDown() {
        SurfaceRuntimeBus.shared.sink = nil   // don't leak the test sink into other tests
        super.tearDown()
    }

    func test_emit_invokesSinkSynchronously() {
        let captured = Captured()
        SurfaceRuntimeBus.shared.sink = { id, h in captured.record(id, h.alive) }

        let surface = SurfaceID()
        SurfaceRuntimeBus.shared.emit(surface, health(alive: true))

        // The assertion runs on the SAME line of execution as emit — with the old
        // `queue.async` this would still be 0 here. Synchronous delivery is the fix.
        XCTAssertEqual(captured.count, 1, "emit must deliver the health to the sink synchronously, not on a deferred queue")
        XCTAssertEqual(captured.last?.0, surface)
        XCTAssertEqual(captured.last?.1, true)
    }

    func test_emit_preservesOrderOfTransitions() {
        let captured = Captured()
        SurfaceRuntimeBus.shared.sink = { id, h in captured.record(id, h.alive) }
        let surface = SurfaceID()

        SurfaceRuntimeBus.shared.emit(surface, health(alive: true))
        SurfaceRuntimeBus.shared.emit(surface, health(alive: false))

        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured.last?.1, false, "the latest transition (dead) must be the one observed last — no reordering/drop")
    }

    func test_emit_withNoSink_isNoOp() {
        SurfaceRuntimeBus.shared.sink = nil
        // Must not crash / must not block.
        SurfaceRuntimeBus.shared.emit(SurfaceID(), health(alive: true))
    }

    func test_sinkGetterReturnsWhatWasSet_withoutBlocking() {
        XCTAssertNil(SurfaceRuntimeBus.shared.sink)
        SurfaceRuntimeBus.shared.sink = { _, _ in }
        XCTAssertNotNil(SurfaceRuntimeBus.shared.sink, "the lock-guarded getter must return the set sink without blocking or deadlocking")
    }
}
