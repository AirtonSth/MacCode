import XCTest
@testable import SocketServer
import Darwin

/// C-02: non-blocking socket writes must retry EAGAIN, preserve full-frame
/// integrity, and only fail on hard errors or a no-progress idle timeout.
final class NonBlockingWriteTests: XCTestCase {

    // MARK: - Unit: writeAll control flow

    func test_writeAll_retriesEAGAINUntilComplete_byteIdentical() {
        // WHY: a full kernel send buffer returns EAGAIN; that is expected under
        // 3G bufferbloat and must not abort mid-frame (the reconnect bug).
        let payload = Data(repeating: 0xA5, count: 64)
        var calls = 0
        var eagainCount = 0
        var waitCalls = 0
        var clock: TimeInterval = 1_000
        let ok = DirectHTTPServer.writeAll(
            fd: 42,
            data: payload,
            progressIdleTimeout: 60,
            now: { clock },
            writeFn: { _, _, count in
                calls += 1
                // First attempt: refuse (EAGAIN). Second: short write. Third: rest.
                if calls == 1 {
                    eagainCount += 1
                    errno = EAGAIN
                    return -1
                }
                if calls == 2 {
                    return min(16, count)
                }
                if calls == 3 {
                    eagainCount += 1
                    errno = EWOULDBLOCK
                    return -1
                }
                return count
            },
            waitWritable: { _, remaining in
                waitCalls += 1
                XCTAssertGreaterThan(remaining, 0)
                // Idle clock barely advances — still well under the progress budget.
                clock += 0.01
                return true
            }
        )
        XCTAssertTrue(ok, "EAGAIN must not fail a write that later completes")
        XCTAssertEqual(eagainCount, 2, "both would-block flavours must be retried")
        XCTAssertEqual(waitCalls, 2, "each EAGAIN must park on write-ready")
        XCTAssertGreaterThanOrEqual(calls, 4)
    }

    func test_writeAll_shortWritesAccumulateWithoutMidFrameAbort() {
        // WHY: frame integrity requires the full buffer on the wire before the
        // caller sees success — partial progress is fine, partial+close is not.
        let payload = Data((0..<500).map { UInt8($0 % 251) })
        var offset = 0
        let ok = DirectHTTPServer.writeAll(
            fd: 7,
            data: payload,
            writeFn: { _, _, count in
                let chunk = min(17, count)
                offset += chunk
                return chunk
            },
            waitWritable: { _, _ in
                XCTFail("short writes without EAGAIN must not wait")
                return false
            }
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(offset, payload.count)
    }

    func test_writeAll_EPIPEIsFatalEvenAfterPartialProgress() {
        // WHY: peer gone is a real error — close is correct. Only EAGAIN is soft.
        let payload = Data(repeating: 0x11, count: 32)
        var calls = 0
        let ok = DirectHTTPServer.writeAll(
            fd: 9,
            data: payload,
            writeFn: { _, _, count in
                calls += 1
                if calls == 1 { return 8 }
                errno = EPIPE
                return -1
            },
            waitWritable: { _, _ in
                XCTFail("EPIPE must not enter the write-ready wait")
                return true
            }
        )
        XCTAssertFalse(ok, "EPIPE must remain fatal")
        XCTAssertEqual(calls, 2)
    }

    func test_writeAll_ECONNRESETIsFatal() {
        let payload = Data("reset".utf8)
        let ok = DirectHTTPServer.writeAll(
            fd: 3,
            data: payload,
            writeFn: { _, _, _ in
                errno = ECONNRESET
                return -1
            },
            waitWritable: { _, _ in true }
        )
        XCTAssertFalse(ok)
    }

    func test_writeAll_noProgressTimeoutCloses() {
        // WHY: acceptance requires a 60s *no progress* timeout, not a total
        // wall-clock 5s SO_SNDTIMEO that killed large frames on 3G.
        let payload = Data(repeating: 0x22, count: 8)
        var clock: TimeInterval = 0
        var waitCalls = 0
        let ok = DirectHTTPServer.writeAll(
            fd: 5,
            data: payload,
            progressIdleTimeout: 60,
            now: { clock },
            writeFn: { _, _, _ in
                errno = EAGAIN
                return -1
            },
            waitWritable: { _, remaining in
                waitCalls += 1
                // Simulate time jumping past the idle budget while still blocked.
                clock += remaining + 0.001
                return false
            }
        )
        XCTAssertFalse(ok, "no progress for the idle budget must fail the write")
        XCTAssertEqual(waitCalls, 1)
    }

    func test_writeAll_progressResetsIdleTimeout() {
        // WHY: a large frame that keeps trickling bytes must not die at 60s wall
        // time if every interval still made progress.
        let payload = Data(repeating: 0x33, count: 40)
        var clock: TimeInterval = 0
        var phase = 0
        let ok = DirectHTTPServer.writeAll(
            fd: 11,
            data: payload,
            progressIdleTimeout: 60,
            now: { clock },
            writeFn: { _, _, count in
                phase += 1
                if phase % 2 == 1 {
                    errno = EAGAIN
                    return -1
                }
                // Wall time advances a lot between progress events; idle clock
                // must reset on each accepted byte so we stay under budget.
                clock += 30
                return min(1, count)
            },
            waitWritable: { _, remaining in
                XCTAssertGreaterThan(remaining, 0,
                                     "progress must reset idle budget before wait")
                return true
            }
        )
        XCTAssertTrue(ok, "progress must reset the idle timeout across long wall time")
        XCTAssertEqual(payload.count * 2, phase, "EAGAIN then 1-byte write per payload byte")
    }

    func test_writeAll_emptyPayloadSucceedsWithoutSyscall() {
        var calls = 0
        let ok = DirectHTTPServer.writeAll(
            fd: 1,
            data: Data(),
            writeFn: { _, _, _ in
                calls += 1
                return 0
            }
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(calls, 0)
    }

    func test_enableNonBlocking_setsO_NONBLOCK() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let flagsBefore = fcntl(fds[0], F_GETFL)
        XCTAssertEqual(flagsBefore & O_NONBLOCK, 0)
        XCTAssertTrue(DirectHTTPServer.enableNonBlocking(fds[0]))
        let flagsAfter = fcntl(fds[0], F_GETFL)
        XCTAssertNotEqual(flagsAfter & O_NONBLOCK, 0)
        // Idempotent.
        XCTAssertTrue(DirectHTTPServer.enableNonBlocking(fds[0]))
    }

    // MARK: - Integration: 500 KB on a constrained socket (3g-ruim stand-in)

    func test_writeAll_500KB_completesWithoutWriteFailedOnConstrainedBuffer() throws {
        // WHY: acceptance criterion — 500 KB transfer under backpressure must
        // complete with no write_failed. A tiny SO_SNDBUF + slow reader forces
        // repeated EAGAIN the same way 3G bufferbloat does on a real uplink.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let writer = fds[0]
        let reader = fds[1]
        defer { close(writer); close(reader) }

        var sndbuf: Int32 = 4 * 1024
        setsockopt(writer, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
        var rcvbuf: Int32 = 4 * 1024
        setsockopt(reader, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        XCTAssertTrue(DirectHTTPServer.enableNonBlocking(writer))
        XCTAssertTrue(DirectHTTPServer.enableNonBlocking(reader))

        let payloadSize = 500 * 1024
        let payload = Data((0..<payloadSize).map { UInt8($0 & 0xFF) })

        let readerDone = expectation(description: "slow reader drained 500KB")
        let receivedBox = ReceivedBuffer()
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [UInt8](repeating: 0, count: 512)
            while receivedBox.count < payloadSize {
                let n = Darwin.read(reader, &buf, buf.count)
                if n > 0 {
                    receivedBox.append(buf, count: n)
                    // Simulate slow uplink consumption (3g-ruim-ish drain).
                    Thread.sleep(forTimeInterval: 0.000_2)
                } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.001)
                } else if n == 0 {
                    break
                } else {
                    break
                }
            }
            readerDone.fulfill()
        }

        let writeOK = DirectHTTPServer.writeAll(fd: writer, data: payload)
        XCTAssertTrue(writeOK, "500 KB write under backpressure must complete (no write_failed)")

        wait(for: [readerDone], timeout: 60)
        let received = receivedBox.data
        XCTAssertEqual(received.count, payload.count, "byte count must match serial write")
        XCTAssertEqual(received, payload, "final bytes must be identical to the serial payload")
    }

    func test_writeAll_waitForWritableUsesDispatchSourceWrite() throws {
        // WHY: prove the production wait path (DispatchSourceWrite) unblocks
        // once a peer drains the send buffer — not only the injected test double.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let writer = fds[0]
        let reader = fds[1]
        defer { close(writer); close(reader) }

        var sndbuf: Int32 = 2 * 1024
        setsockopt(writer, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
        XCTAssertTrue(DirectHTTPServer.enableNonBlocking(writer))

        // Fill the buffer until write would block.
        let junk = Data(repeating: 0x44, count: 64 * 1024)
        _ = junk.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var total = 0
            for _ in 0..<32 {
                let n = Darwin.write(writer, base, min(4096, junk.count))
                if n > 0 { total += n; continue }
                break
            }
            return total
        }

        let unlocked = expectation(description: "writable after drain")
        DispatchQueue.global().async {
            // Wait for writable while peer is not draining yet — should park.
            // Start draining shortly after.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                var buf = [UInt8](repeating: 0, count: 4096)
                for _ in 0..<64 {
                    let n = Darwin.read(reader, &buf, buf.count)
                    if n <= 0 { break }
                }
            }
            let ready = DirectHTTPServer.waitForWritable(fd: writer, timeout: 5)
            XCTAssertTrue(ready, "DispatchSourceWrite must fire after peer drain")
            unlocked.fulfill()
        }
        wait(for: [unlocked], timeout: 10)
    }
}

// MARK: - Helpers

private final class ReceivedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ buf: [UInt8], count: Int) {
        lock.lock()
        storage.append(contentsOf: buf[0..<count])
        lock.unlock()
    }
}
