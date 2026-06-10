import XCTest
import Foundation
@testable import AgentRuntime

// P1: these tests pin the safety contract for stdin writes. Each case encodes
// WHY: a misclassification here is the difference between an uncatchable crash
// (writing to a closed pipe) and a recoverable sessionNotFound error.
final class GuardedStdinWriteTests: XCTestCase {

    // WHY: if the child process already exited, the pipe is closed; writing
    // would raise SIGPIPE/EPIPE and crash. We must short-circuit to
    // sessionNotFound BEFORE any write is attempted, regardless of the
    // (irrelevant) byte counts.
    func testDeadProcessIsSessionNotFoundWithoutWriting() {
        let result = GuardedStdinWrite.classify(
            processAlive: false,
            bytesWritten: 0,
            expected: 10,
            errnoValue: 0
        )
        XCTAssertEqual(result, .sessionNotFound)
    }

    // WHY: EPIPE is the canonical "peer closed the read end" failure. It is the
    // exact condition that crashes the app today and must map to a recoverable
    // sessionNotFound, never .error and never a crash.
    func testEPIPEMapsToSessionNotFound() {
        let result = GuardedStdinWrite.classify(
            processAlive: true,
            bytesWritten: -1,
            expected: 10,
            errnoValue: EPIPE
        )
        XCTAssertEqual(result, .sessionNotFound)
    }

    // WHY: EBADF means the file descriptor is closed/invalid (e.g. the pipe was
    // torn down during shutdown). Same recovery semantics as EPIPE.
    func testEBADFMapsToSessionNotFound() {
        let result = GuardedStdinWrite.classify(
            processAlive: true,
            bytesWritten: -1,
            expected: 10,
            errnoValue: EBADF
        )
        XCTAssertEqual(result, .sessionNotFound)
    }

    // WHY: a full write (bytesWritten == expected) is the happy path and must
    // be .ok so the caller does not spuriously fail the turn.
    func testFullWriteIsOK() {
        let result = GuardedStdinWrite.classify(
            processAlive: true,
            bytesWritten: 10,
            expected: 10,
            errnoValue: 0
        )
        XCTAssertEqual(result, .ok)
    }

    // WHY: a short write means bytes remain unsent. Returning .ok here would
    // silently drop part of a JSON line and corrupt the protocol stream, so it
    // must be .error (caller retries/handles the remainder).
    func testShortWriteIsError() {
        let result = GuardedStdinWrite.classify(
            processAlive: true,
            bytesWritten: 4,
            expected: 10,
            errnoValue: 0
        )
        XCTAssertEqual(result, .error)
    }

    // WHY: a transient failure such as EINTR/EAGAIN is NOT a dead session; it
    // must surface as a generic .error (retryable) rather than tearing the
    // session down as sessionNotFound.
    func testTransientErrnoIsGenericError() {
        let interrupted = GuardedStdinWrite.classify(
            processAlive: true,
            bytesWritten: -1,
            expected: 10,
            errnoValue: EINTR
        )
        XCTAssertEqual(interrupted, .error)

        let again = GuardedStdinWrite.classify(
            processAlive: true,
            bytesWritten: -1,
            expected: 10,
            errnoValue: EAGAIN
        )
        XCTAssertEqual(again, .error)
    }
}
