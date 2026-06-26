import XCTest
import Darwin
@testable import Surfaces

/// Regression for the "terminal is alive but typing is dead" freeze (audit F3/#6).
///
/// The PTY input pump used to handle a non-draining child (slave tty input buffer
/// full -> `write()` returns EAGAIN -> `.wouldBlock`) with an OPEN-ENDED
/// `usleep`+continue loop. On the pump's SERIAL queue that single stuck chunk
/// head-of-line-blocked every later keystroke forever, with no timeout and no
/// recovery. The fix bounds the retry: past a budget the drain stops waiting,
/// surfaces a RECOVERABLE stall (it must NOT mark the terminal dead), and lets
/// later input through.
final class TerminalInputPumpTests: XCTestCase {

    /// Thread-safe counters shared with the @Sendable writer closure. The pump runs
    /// `drain` on its own serial queue; tests read these only after a `drain()`
    /// barrier, so the lock just satisfies Sendable and guards the writer's own
    /// re-entrancy.
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var _wouldBlockCalls = 0
        private var _written = 0
        func recordWouldBlock() { lock.lock(); _wouldBlockCalls += 1; lock.unlock() }
        func recordWrite(_ n: Int) { lock.lock(); _written += n; lock.unlock() }
        var wouldBlockCalls: Int { lock.lock(); defer { lock.unlock() }; return _wouldBlockCalls }
        var written: Int { lock.lock(); defer { lock.unlock() }; return _written }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        private var _payload = 0
        func set(_ p: Int = 0) { lock.lock(); _value = true; _payload = p; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return _value }
        var payload: Int { lock.lock(); defer { lock.unlock() }; return _payload }
    }

    // MARK: - Pure budget seam

    func test_shouldAbortWouldBlock_falseBeforeBudget_trueAtOrPastBudget() {
        XCTAssertFalse(TerminalInputPump.shouldAbortWouldBlock(waitedMicros: 0, budgetMicros: 1000),
            "no wait yet -> keep retrying")
        XCTAssertFalse(TerminalInputPump.shouldAbortWouldBlock(waitedMicros: 999, budgetMicros: 1000),
            "under budget -> keep retrying")
        XCTAssertTrue(TerminalInputPump.shouldAbortWouldBlock(waitedMicros: 1000, budgetMicros: 1000),
            "reaching the budget must stop the spin so the serial queue is not blocked forever")
        XCTAssertTrue(TerminalInputPump.shouldAbortWouldBlock(waitedMicros: 5000, budgetMicros: 1000),
            "past the budget must abort")
    }

    func test_shouldAbortWouldBlock_zeroBudgetNeverAborts() {
        // budget 0 means "disabled" — used so the seam can express an unbounded mode
        // without a magic sentinel leaking into the call site.
        XCTAssertFalse(TerminalInputPump.shouldAbortWouldBlock(waitedMicros: 999_999, budgetMicros: 0))
    }

    // MARK: - Stuck child: bounded + recoverable

    func test_stuckChild_abortsWithinBudget_andDoesNotMarkDead() {
        let counters = Counters()
        let stalled = Flag()
        let died = Flag()

        // Writer that NEVER drains (child wedged): always EAGAIN/.wouldBlock.
        let pump = TerminalInputPump(
            maxQueuedBytes: 1024 * 1024,
            retryDelay: 500,                  // 0.5ms per retry
            maxWouldBlockWaitMicros: 5_000,   // give up after ~5ms of blocking
            writer: { _, _ in
                counters.recordWouldBlock()
                return .wouldBlock
            }
        )
        pump.onInputStalled = { unwritten in stalled.set(unwritten) }
        pump.onTerminalFailure = { _ in died.set() }

        XCTAssertEqual(pump.enqueue(Data("ls -la\n".utf8)), .accepted)
        pump.drain()   // barrier: waits for the async drain to finish

        XCTAssertTrue(stalled.isSet,
            "a child that never reads stdin must surface a RECOVERABLE stall, not spin forever")
        XCTAssertEqual(stalled.payload, Data("ls -la\n".utf8).count,
            "the stall reports the whole unwritten chunk as abandoned")
        XCTAssertFalse(died.isSet,
            "transient backpressure (EAGAIN) must NOT mark the terminal dead — that is what makes typing recoverable")
        XCTAssertTrue(pump.inputAccepting,
            "the pump must keep accepting input after a stall so later keystrokes are not permanently blocked")
        XCTAssertLessThan(counters.wouldBlockCalls, 1000,
            "the retry must be bounded by the budget, not an unbounded spin")
    }

    // MARK: - Happy path

    func test_normalWrite_fullyDrains_noStall_noFailure() {
        let stalled = Flag()
        let died = Flag()
        let counters = Counters()
        let pump = TerminalInputPump(writer: { data, offset in
            let n = data.count - offset
            counters.recordWrite(n)
            return .wrote(n)
        })
        pump.onInputStalled = { _ in stalled.set() }
        pump.onTerminalFailure = { _ in died.set() }

        XCTAssertEqual(pump.enqueue(Data("echo hi\n".utf8)), .accepted)
        pump.drain()

        XCTAssertEqual(counters.written, Data("echo hi\n".utf8).count, "all bytes written")
        XCTAssertFalse(stalled.isSet, "a draining child never stalls")
        XCTAssertFalse(died.isSet, "a clean write never marks the terminal dead")
        XCTAssertTrue(pump.inputAccepting)
    }

    func test_progressResetsBudget_partialWritesEventuallyComplete() {
        // Alternating wouldBlock/wrote: each successful byte resets the stall budget,
        // so a slow-but-progressing child completes the whole chunk without stalling.
        let counters = Counters()
        let toggle = Counters() // reuse as a call counter
        let stalled = Flag()
        let pump = TerminalInputPump(
            retryDelay: 200,
            maxWouldBlockWaitMicros: 5_000,
            writer: { data, offset in
                toggle.recordWrite(1)
                if toggle.written % 2 == 1 {
                    return .wouldBlock          // every other call blocks briefly
                }
                counters.recordWrite(1)
                return .wrote(1)                // then makes one byte of progress
            }
        )
        pump.onInputStalled = { _ in stalled.set() }

        let payload = Data("abcd".utf8)
        XCTAssertEqual(pump.enqueue(payload), .accepted)
        pump.drain()

        XCTAssertEqual(counters.written, payload.count,
            "progress between blocks resets the budget, so the whole chunk is delivered")
        XCTAssertFalse(stalled.isSet,
            "intermittent backpressure with forward progress must NOT trip the stall")
    }
}
