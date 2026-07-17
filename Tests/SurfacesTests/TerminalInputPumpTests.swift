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

    private final class IncrementalRetryWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var attemptsByOffset: [Int: Int] = [:]
        private var output = Data()
        let first: Data

        init(first: Data) {
            self.first = first
        }

        func write(_ data: Data, offset: Int) -> TerminalWriteResult {
            lock.lock()
            defer { lock.unlock() }
            if data == first {
                let attempts = (attemptsByOffset[offset] ?? 0) + 1
                attemptsByOffset[offset] = attempts
                guard attempts >= 2 else { return .wouldBlock }
                attemptsByOffset[offset] = 0
                output.append(data[offset])
                return .wrote(1)
            }
            output.append(data.dropFirst(offset))
            return .wrote(data.count - offset)
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: output, as: UTF8.self)
        }
    }

    private final class BlockedTinyChunkWriter: @unchecked Sendable {
        private let lock = NSLock()
        private let firstWriteGate = DispatchSemaphore(value: 0)
        private var firstWrite = true
        private var draining = false
        private var output = Data()
        let firstWriteEntered = DispatchSemaphore(value: 0)

        func write(_ data: Data, offset: Int) -> TerminalWriteResult {
            lock.lock()
            let shouldBlockFirst = firstWrite
            if shouldBlockFirst { firstWrite = false }
            let canDrain = draining
            lock.unlock()

            if shouldBlockFirst {
                firstWriteEntered.signal()
                firstWriteGate.wait()
                return .wouldBlock
            }
            guard canDrain else { return .wouldBlock }

            lock.lock()
            output.append(data.dropFirst(offset))
            lock.unlock()
            return .wrote(data.count - offset)
        }

        func releaseFirstWrite() { firstWriteGate.signal() }

        func startDraining() {
            lock.lock()
            draining = true
            lock.unlock()
        }

        var bytes: Data {
            lock.lock()
            defer { lock.unlock() }
            return output
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

    func test_repeatedPartialStallsCannotLetLaterChunkOvertakeHeadSuffix() {
        // WHY: each delayed retry re-enters the serial queue behind already
        // accepted chunks. Without an explicit FIFO head, a later chunk can
        // write between suffix retries and corrupt terminal command order.
        let first = Data("first\n".utf8)
        let second = Data("second\n".utf8)
        let writer = IncrementalRetryWriter(first: first)
        let pump = TerminalInputPump(
            retryDelay: 100,
            maxWouldBlockWaitMicros: 100,
            writer: { data, offset in writer.write(data, offset: offset) }
        )

        XCTAssertEqual(pump.enqueue(first), .accepted)
        XCTAssertEqual(pump.enqueue(second), .accepted)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, pump.queuedByteCount > 0 {
            usleep(10_000)
            pump.drain()
        }

        XCTAssertEqual(
            writer.text,
            "first\nsecond\n",
            "later accepted bytes must remain behind every retry of the FIFO head"
        )
        XCTAssertEqual(pump.queuedByteCount, 0)
        XCTAssertTrue(pump.inputAccepting)
    }

    func test_manyTinyBlockedChunksKeepMetadataBoundedAndRecoverInExactFIFOOrder() {
        // WHY: a byte-at-a-time producer can fill the 1 MiB byte budget with one
        // million queued IDs and retry closures. Bound item metadata separately
        // from bytes, and prove the accepted prefix still recovers in exact order.
        let itemLimit = 256
        let writer = BlockedTinyChunkWriter()
        let stalled = DispatchSemaphore(value: 0)
        let pump = TerminalInputPump(
            maxQueuedBytes: 1024 * 1024,
            maxQueuedItems: itemLimit,
            retryDelay: 100,
            maxWouldBlockWaitMicros: 100,
            writer: { data, offset in writer.write(data, offset: offset) }
        )
        pump.onInputStalled = { _ in stalled.signal() }

        var expected = Data()
        let first = Data([0])
        XCTAssertEqual(pump.enqueue(first), .accepted)
        expected.append(first)
        XCTAssertEqual(writer.firstWriteEntered.wait(timeout: .now() + 1), .success)

        var queueFullCount = 0
        for index in 1..<10_000 {
            let byte = Data([UInt8(index % 251)])
            switch pump.enqueue(byte) {
            case .accepted:
                expected.append(byte)
            case .queueFull:
                queueFullCount += 1
            default:
                XCTFail("blocked preaccepted tiny chunks may only be accepted or rejected as queue_full")
            }
        }

        let peak = pump.pendingChunkMetadataForTesting
        XCTAssertEqual(peak.active, itemLimit)
        XCTAssertLessThanOrEqual(peak.storage, itemLimit,
                                 "metadata storage must stay bounded while the head writer is blocked")
        XCTAssertGreaterThan(queueFullCount, 0,
                             "the independent item cap must engage before one-byte chunks exhaust the byte budget")

        writer.releaseFirstWrite()
        XCTAssertEqual(stalled.wait(timeout: .now() + 1), .success)
        let recoveryStarted = Date()
        writer.startDraining()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, pump.queuedByteCount > 0 {
            usleep(5_000)
            pump.drain()
        }

        XCTAssertEqual(writer.bytes, expected,
                       "every accepted one-byte chunk must recover in exact FIFO order")
        XCTAssertEqual(pump.queuedByteCount, 0)
        let final = pump.pendingChunkMetadataForTesting
        XCTAssertEqual(final.active, 0)
        XCTAssertLessThanOrEqual(final.storage, itemLimit + 255,
                                 "head-index compaction must keep backing metadata bounded")
        XCTAssertLessThan(Date().timeIntervalSince(recoveryStarted), 2,
                          "bounded metadata must not trade memory safety for unbounded recovery latency")
        XCTAssertTrue(pump.inputAccepting)
    }

    func test_nonHeadChunksDoNotCreateRecurringRetryTimers() {
        // WHY: only the FIFO head can make progress. Giving every accepted
        // non-head chunk its own backoff loop turns one blocked PTY into hundreds
        // of recurring queue callbacks even though none of them may write.
        let itemLimit = 64
        let pump = TerminalInputPump(
            maxQueuedItems: itemLimit,
            retryDelay: 20_000,
            maxWouldBlockWaitMicros: 1,
            writer: { _, _ in .wouldBlock }
        )

        for _ in 0..<itemLimit {
            XCTAssertEqual(pump.enqueue(Data([0x41])), .accepted)
        }
        pump.drain()

        XCTAssertEqual(
            pump.scheduledRetryCountForTesting,
            1,
            "one blocked FIFO head may own one retry; non-head chunks must wait for an explicit head handoff"
        )
        pump.stop()
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

    func test_closedDescriptorLeaseCannotWriteAfterFileDescriptorReuse() throws {
        var pipeFDs: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFDs), 0)
        defer { Darwin.close(pipeFDs[0]) }
        let originalWriteFD = pipeFDs[1]
        let lease = TerminalFileDescriptorLease(fd: originalWriteFD)

        lease.close()
        let replacement = open("/dev/null", O_WRONLY)
        XCTAssertGreaterThanOrEqual(replacement, 0)
        let reusedFD: Int32
        if replacement == originalWriteFD {
            reusedFD = replacement
        } else {
            XCTAssertEqual(dup2(replacement, originalWriteFD), originalWriteFD)
            Darwin.close(replacement)
            reusedFD = originalWriteFD
        }
        defer { Darwin.close(reusedFD) }

        XCTAssertEqual(
            lease.write(Data("must-not-escape".utf8), offset: 0),
            .failed(EBADF),
            "a stopped terminal must never write accepted bytes into a later terminal or file that reused its numeric fd"
        )
    }

    func test_stalledRetryStoppedBeforeCloseCannotEscapeIntoReusedDescriptor() throws {
        var pipeFDs: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFDs), 0)
        let originalReadFD = pipeFDs[0]
        let originalWriteFD = pipeFDs[1]
        XCTAssertTrue(TerminalFileDescriptorFlags.enableNonBlocking(originalWriteFD))
        try fillPipeUntilWouldBlock(writeFD: originalWriteFD)

        let lease = TerminalFileDescriptorLease(fd: originalWriteFD)
        let stalled = DispatchSemaphore(value: 0)
        let payload = Data("must-not-reach-reused-fd".utf8)
        let pump = TerminalInputPump(
            retryDelay: 1_000,
            maxWouldBlockWaitMicros: 1_000,
            writer: { data, offset in lease.write(data, offset: offset) }
        )
        pump.onInputStalled = { _ in stalled.signal() }

        XCTAssertEqual(pump.enqueue(payload), .accepted)
        XCTAssertEqual(
            stalled.wait(timeout: .now() + 1),
            .success,
            "a genuinely full nonblocking pipe must drive the production retry path into input_stalled"
        )

        pump.stop(reason: .processExited)
        lease.close()
        Darwin.close(originalReadFD)

        let replacement = try makeSocketPairReusing(fd: originalWriteFD)
        defer {
            Darwin.close(replacement.reusedFD)
            Darwin.close(replacement.peerFD)
        }
        let sentinel = Data("replacement-owner-only".utf8)
        let sent = sentinel.withUnsafeBytes { pointer in
            Darwin.write(replacement.reusedFD, pointer.baseAddress, sentinel.count)
        }
        XCTAssertEqual(sent, sentinel.count)

        usleep(250_000)
        pump.drain()
        XCTAssertEqual(
            pump.queuedByteCount,
            0,
            "a retry that wakes after stop must discard its queue accounting without invoking the writer"
        )
        XCTAssertEqual(
            try readAvailableData(from: replacement.peerFD),
            sentinel,
            "no accepted byte from the stopped terminal may escape into a new resource that reused its numeric fd"
        )
    }

    private func fillPipeUntilWouldBlock(writeFD: Int32) throws {
        let chunk = Data(repeating: 0xA5, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeBytes { pointer in
                Darwin.write(writeFD, pointer.baseAddress, chunk.count)
            }
            if count > 0 { continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "failed while filling test pipe"]
            )
        }
    }

    private func makeSocketPairReusing(fd targetFD: Int32) throws -> (reusedFD: Int32, peerFD: Int32) {
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if sockets[0] == targetFD {
            return (sockets[0], sockets[1])
        }
        if sockets[1] == targetFD {
            return (sockets[1], sockets[0])
        }
        guard dup2(sockets[0], targetFD) == targetFD else {
            let savedErrno = errno
            Darwin.close(sockets[0])
            Darwin.close(sockets[1])
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedErrno))
        }
        Darwin.close(sockets[0])
        return (targetFD, sockets[1])
    }

    private func readAvailableData(from fd: Int32) throws -> Data {
        XCTAssertTrue(TerminalFileDescriptorFlags.enableNonBlocking(fd))
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer[0..<Int(count)])
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return result }
            if count == 0 { return result }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
