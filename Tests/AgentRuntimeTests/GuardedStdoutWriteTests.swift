import XCTest
@testable import AgentRuntime
import Darwin

/// plan-final W1: closed stdout is peerClosed, not a crash.
final class GuardedStdoutWriteTests: XCTestCase {
    func test_classify_epipeIsPeerClosed() {
        let result = GuardedStdoutWrite.classify(bytesWritten: -1, expected: 10, errnoValue: EPIPE)
        XCTAssertEqual(result, .peerClosed)
    }

    func test_classify_fullWriteIsWroteAll() {
        let result = GuardedStdoutWrite.classify(bytesWritten: 10, expected: 10, errnoValue: 0)
        XCTAssertEqual(result, .wroteAll)
    }

    func test_classify_shortWriteIsPartial() {
        let result = GuardedStdoutWrite.classify(bytesWritten: 3, expected: 10, errnoValue: 0)
        XCTAssertEqual(result, .wrotePartial(3))
    }

    func test_writeAll_toPipeThenCloseReader_doesNotCrash() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        close(readFD) // consumer closed
        let ok = GuardedStdoutWrite.writeAll(Data("hello".utf8), to: writeFD)
        XCTAssertFalse(ok, "EPIPE after peer close must return false, not raise")
        let deferred = GuardedStdoutWrite.deferredSideEffectAfterCompleteDelivery(
            "savings-ledger-row", delivered: ok
        )
        XCTAssertNil(deferred,
                     "a broken stdout pipe must not run the savings ledger for undelivered output")
        close(writeFD)
    }

    func test_partialDeliveryDoesNotReleaseDeferredSideEffect() {
        let deferred = GuardedStdoutWrite.deferredSideEffectAfterCompleteDelivery(
            "savings-ledger-row", delivered: false
        )
        XCTAssertNil(deferred,
                     "partial delivery is not sufficient proof that the agent saw compressed output")
        XCTAssertEqual(
            GuardedStdoutWrite.deferredSideEffectAfterCompleteDelivery("savings-ledger-row", delivered: true),
            "savings-ledger-row"
        )
    }

    func test_writeAll_toOpenPipe_deliversBytes() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        let payload = Data("payload-bytes".utf8)
        XCTAssertTrue(GuardedStdoutWrite.writeAll(payload, to: writeFD))
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(readFD, &buf, buf.count)
        XCTAssertEqual(n, payload.count)
        close(readFD)
        close(writeFD)
    }
}
