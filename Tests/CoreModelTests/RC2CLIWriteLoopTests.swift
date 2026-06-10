import XCTest
@testable import CoreModel

/// Tests RC2CLIWriteLoop - the safe write helper for the rc2 CLI.
///
/// WHY these tests exist:
///   - A single Darwin.write call is not guaranteed to write all bytes; on a
///     Unix domain socket with a full kernel send buffer a short write (n < len)
///     silently truncates the payload.  The write-loop MUST accumulate partial
///     writes until all bytes are sent.
///   - The bytesWritten sum must equal the total requested on success, and must
///     equal the partial amount on a mid-stream error - so callers can detect
///     truncation and return an error rather than proceeding with a corrupt RPC.
///   - The receive-timeout path (SO_RCVTIMEO via --timeout) is already tested
///     in RC2CLITimeoutParserTests; here we confirm the write result correctly
///     captures how much was written so the RPC.call method can gate on success.
final class RC2CLIWriteLoopTests: XCTestCase {

    // MARK: - full write in one syscall

    func test_singleCallWritesAll_successIsTrue() {
        // WHY: the common case - kernel accepts all bytes in one call.
        // If bytesWritten != total the write-loop has a bug.
        let payload = Data("hello\n".utf8)
        var callCount = 0
        let result = RC2CLIWriteLoop.writeAll(fd: 42, data: payload) { _, _, count in
            callCount += 1
            return count  // simulate full write
        }
        XCTAssertTrue(result.success,
                      "all bytes written in one call must report success")
        XCTAssertEqual(result.bytesWritten, payload.count,
                       "bytesWritten must equal payload length on full write")
        XCTAssertEqual(result.total, payload.count,
                       "total must equal payload length regardless of call count")
        XCTAssertEqual(callCount, 1,
                       "single sufficient write must not loop unnecessarily")
    }

    // MARK: - short write accumulation

    func test_shortWritesAreAccumulated_sumEqualsTotal() {
        // WHY: this is the core perf fix - two short writes (3 + 3 = 6 bytes)
        // on a 6-byte payload must both be counted and success reported.
        // Before the fix a single write returning 3 would leave 3 bytes unsent.
        let payload = Data("ABCDEF".utf8)  // 6 bytes
        var remaining = payload.count
        let result = RC2CLIWriteLoop.writeAll(fd: 1, data: payload) { _, _, count in
            // simulate short write: write half each time
            let chunk = min(3, count)
            remaining -= chunk
            return chunk
        }
        XCTAssertTrue(result.success,
                      "accumulated short writes summing to total must be success")
        XCTAssertEqual(result.bytesWritten, 6,
                       "bytesWritten must sum ALL partial writes (short-write accumulation)")
        XCTAssertEqual(result.total, 6)
    }

    func test_shortWriteAccountingReflectsEachIteration() {
        // WHY: the loop must advance the pointer by exactly n on each iteration.
        // We record byte counts per call and verify the total matches.
        let payload = Data(repeating: 0x41, count: 9)  // 9 bytes
        var writtenPerCall: [Int] = []
        let result = RC2CLIWriteLoop.writeAll(fd: 3, data: payload) { _, _, count in
            // return 1 byte per call to exercise maximum short-write depth
            let n = min(1, count)
            writtenPerCall.append(n)
            return n
        }
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.bytesWritten, 9,
                       "9 single-byte writes must accumulate to 9 total bytes")
        XCTAssertEqual(writtenPerCall.count, 9,
                       "write function must be called once per byte when writing 1 at a time")
        XCTAssertEqual(writtenPerCall.reduce(0, +), 9,
                       "sum of per-call byte counts must equal payload size")
    }

    // MARK: - hard write error

    func test_writeErrorMidStream_successIsFalseAndPartialCountReturned() {
        // WHY: if write() returns <= 0 mid-stream (broken pipe, EBADF, etc.)
        // success must be false and bytesWritten must reflect only what was
        // written BEFORE the error - so RPC.call can return an error response
        // instead of proceeding with a truncated request.
        let payload = Data(repeating: 0x42, count: 10)
        var calls = 0
        let result = RC2CLIWriteLoop.writeAll(fd: 5, data: payload) { _, _, count in
            calls += 1
            if calls == 1 { return 4 }   // first call: 4 bytes
            if calls == 2 { return -1 }  // second call: error (SIGPIPE / EPIPE)
            return count
        }
        XCTAssertFalse(result.success,
                       "error on second write call must produce success=false")
        XCTAssertEqual(result.bytesWritten, 4,
                       "bytesWritten must reflect only bytes written before the error")
        XCTAssertEqual(result.total, 10,
                       "total must still equal the original payload size")
    }

    func test_firstCallError_zeroWritten() {
        // WHY: an immediate error (e.g. fd already closed) must report 0 written.
        let payload = Data("test".utf8)
        let result = RC2CLIWriteLoop.writeAll(fd: 99, data: payload) { _, _, _ in
            return -1
        }
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.bytesWritten, 0,
                       "immediate write error must report 0 bytes written")
    }

    // MARK: - empty data edge case

    func test_emptyData_successAndZeroBytes() {
        // WHY: an empty payload (shouldn't happen in practice, but must not crash
        // or loop forever).
        var callCount = 0
        let result = RC2CLIWriteLoop.writeAll(fd: 0, data: Data()) { _, _, _ in
            callCount += 1
            return 0
        }
        XCTAssertTrue(result.success,
                      "empty payload must succeed immediately with 0 bytes")
        XCTAssertEqual(result.bytesWritten, 0)
        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(callCount, 0,
                       "write function must not be called for empty payload")
    }

    // MARK: - WriteResult equality

    func test_writeResult_equality() {
        // WHY: WriteResult is Equatable - callers can assert exact results in tests.
        let a = RC2CLIWriteLoop.WriteResult(bytesWritten: 5, total: 5)
        let b = RC2CLIWriteLoop.WriteResult(bytesWritten: 5, total: 5)
        let c = RC2CLIWriteLoop.WriteResult(bytesWritten: 4, total: 5)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_writeResult_successFlagDerivation() {
        // WHY: success is derived from bytesWritten == total; no separate field.
        XCTAssertTrue(RC2CLIWriteLoop.WriteResult(bytesWritten: 10, total: 10).success)
        XCTAssertFalse(RC2CLIWriteLoop.WriteResult(bytesWritten: 9, total: 10).success)
        XCTAssertTrue(RC2CLIWriteLoop.WriteResult(bytesWritten: 0, total: 0).success)
    }
}
