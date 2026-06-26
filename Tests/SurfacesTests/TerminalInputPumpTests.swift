import XCTest
import Darwin
@testable import Surfaces

/// Regression for the "terminal is alive but typing is dead" freeze (audit F3/#6).
///
/// The PTY input pump used to handle a non-draining child (slave tty input buffer
/// full -> `write()` returns EAGAIN -> `.wouldBlock`) with an OPEN-ENDED
/// `usleep`+continue loop. On the pump's SERIAL queue that single stuck chunk
/// head-of-line-blocked every later keystroke forever, with no timeout and no
/// recovery. The fix bounds each retry window: past a budget the drain pauses
/// input, keeps the accepted bytes queued, and retries the unwritten suffix
/// without pretending later keystrokes were accepted.
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

    private final class WriterMode: @unchecked Sendable {
        private let lock = NSLock()
        private var _draining = false
        func setDraining() { lock.lock(); _draining = true; lock.unlock() }
        var isDraining: Bool { lock.lock(); defer { lock.unlock() }; return _draining }
    }

    private final class WrittenLog: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [String] = []
        func record(_ data: Data, offset: Int) {
            let suffix = Data(data.dropFirst(offset))
            let text = String(decoding: suffix, as: UTF8.self)
            lock.lock()
            chunks.append(text)
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return chunks.joined()
        }
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

    func test_stuckChild_pausesInputAndKeepsAcceptedBytesQueued() {
        let counters = Counters()
        let stalled = Flag()
        let died = Flag()
        let payload = Data("ls -la\n".utf8)

        // Writer that NEVER drains (child wedged): always EAGAIN/.wouldBlock.
        let pump = TerminalInputPump(
            maxQueuedBytes: 1024 * 1024,
            retryDelay: 10_000,                // keep the scheduled retry out of the assertion window
            maxWouldBlockWaitMicros: 10_000,
            writer: { _, _ in
                counters.recordWouldBlock()
                return .wouldBlock
            }
        )
        pump.onInputStalled = { unwritten in stalled.set(unwritten) }
        pump.onTerminalFailure = { _ in died.set() }

        XCTAssertEqual(pump.enqueue(payload), .accepted)
        pump.drain()   // barrier: waits for the async drain to finish

        XCTAssertTrue(stalled.isSet,
            "a child that never reads stdin must surface a RECOVERABLE stall, not spin forever")
        XCTAssertEqual(stalled.payload, payload.count,
            "the stall reports the unwritten chunk that remains queued for retry")
        XCTAssertFalse(died.isSet,
            "transient backpressure (EAGAIN) must NOT mark the terminal dead — that is what makes typing recoverable")
        XCTAssertFalse(pump.inputAccepting,
            "while accepted bytes are still pending, later keystrokes must not be reported as accepted")
        XCTAssertEqual(pump.queuedByteCount, payload.count,
            "accepted bytes must stay queued instead of being silently dropped")
        XCTAssertEqual(pump.enqueue(Data("pwd\n".utf8)), .inputStalled,
            "later input must fail loud until the already accepted chunk is delivered")
        XCTAssertLessThan(counters.wouldBlockCalls, 1000,
            "the retry must be bounded by the budget, not an unbounded spin")
        pump.stop()
    }

    func test_stalledAcceptedBytes_retryAndResumeWhenChildDrains() {
        let counters = Counters()
        let mode = WriterMode()
        let stalled = Flag()
        let resumed = Flag()
        let payload = Data("echo after-stall\n".utf8)
        let pump = TerminalInputPump(
            retryDelay: 1_000,
            maxWouldBlockWaitMicros: 1_000,
            writer: { data, offset in
                if mode.isDraining {
                    let n = data.count - offset
                    counters.recordWrite(n)
                    return .wrote(n)
                }
                counters.recordWouldBlock()
                return .wouldBlock
            }
        )
        pump.onInputStalled = { unwritten in
            stalled.set(unwritten)
            mode.setDraining()
        }
        pump.onInputResumed = { resumed.set() }

        XCTAssertEqual(pump.enqueue(payload), .accepted)
        pump.drain()

        XCTAssertTrue(stalled.isSet, "the first blocked window must publish the stalled state")
        XCTAssertFalse(pump.inputAccepting, "input stays paused until the queued bytes are delivered")

        usleep(20_000)
        pump.drain()

        XCTAssertEqual(counters.written, payload.count,
            "the unwritten suffix from the accepted chunk must be retried and delivered")
        XCTAssertTrue(resumed.isSet, "delivery after a stall must publish input resume")
        XCTAssertTrue(pump.inputAccepting, "input accepts new text again after the stalled chunk drains")
        XCTAssertEqual(pump.queuedByteCount, 0, "delivered stalled bytes leave no hidden backlog")
    }

    func test_preacceptedLaterChunksWaitBehindStalledRetry() {
        let mode = WriterMode()
        let written = WrittenLog()
        let first = Data("first\n".utf8)
        let second = Data("second\n".utf8)
        let pump = TerminalInputPump(
            retryDelay: 1_000,
            maxWouldBlockWaitMicros: 1_000,
            writer: { data, offset in
                if mode.isDraining {
                    written.record(data, offset: offset)
                    return .wrote(data.count - offset)
                }
                return .wouldBlock
            }
        )
        pump.onInputStalled = { _ in mode.setDraining() }

        XCTAssertEqual(pump.enqueue(first), .accepted)
        XCTAssertEqual(pump.enqueue(second), .accepted)
        pump.drain()

        usleep(30_000)
        pump.drain()

        XCTAssertEqual(written.text, "first\nsecond\n",
            "chunks accepted before the stall must still drain in FIFO order after the stalled suffix is retried")
        XCTAssertTrue(pump.inputAccepting)
        XCTAssertEqual(pump.queuedByteCount, 0)
    }

    func test_resumeWaitsForAllAcceptedBacklogBeforeReopeningInput() {
        let mode = WriterMode()
        let written = WrittenLog()
        let resumedAfterBytes = Flag()
        let first = Data("first\n".utf8)
        let second = Data("second\n".utf8)
        let pump = TerminalInputPump(
            retryDelay: 1_000,
            maxWouldBlockWaitMicros: 1_000,
            writer: { data, offset in
                if mode.isDraining {
                    written.record(data, offset: offset)
                    return .wrote(data.count - offset)
                }
                return .wouldBlock
            }
        )
        pump.onInputStalled = { _ in mode.setDraining() }
        pump.onInputResumed = {
            resumedAfterBytes.set(written.text.utf8.count)
        }

        XCTAssertEqual(pump.enqueue(first), .accepted)
        XCTAssertEqual(pump.enqueue(second), .accepted)
        pump.drain()

        XCTAssertFalse(pump.inputAccepting,
            "external input must stay closed while the preaccepted backlog is still pending")

        usleep(30_000)
        pump.drain()

        XCTAssertEqual(written.text, "first\nsecond\n",
            "the accepted backlog must drain FIFO before the pump resumes external input")
        XCTAssertEqual(resumedAfterBytes.payload, first.count + second.count,
            "resume must fire only after every already-accepted chunk has drained")
        XCTAssertTrue(pump.inputAccepting)
        XCTAssertEqual(pump.enqueue(Data("third\n".utf8)), .accepted,
            "new input may be accepted after, not during, the accepted backlog drain")
        pump.drain()
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
