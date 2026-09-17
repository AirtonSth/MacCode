import Darwin
import XCTest
@testable import AgentRuntime

/// Regression coverage for the bounded pipe-drain API.
///
/// The default path must preserve provider bytes so an exit-time drain cannot
/// silently remove a terminal NDJSON frame. Retention is capped at 2 MiB
/// (stdout) / 1 MiB (stderr); remaining pipe data is still drained, and the
/// runtime keeps the absolute deadline on every read loop.
final class BoundedPipeDrainCapTests: XCTestCase {

    func test_sharedCapsMatchTwoMiBStdoutAndOneMiBStderr() {
        // WHY: teardown sites share these constants so a verbose child cannot
        // retain an unbounded pipe snapshot at process exit.
        XCTAssertEqual(BoundedPipeDrain.defaultStdoutMaxBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(BoundedPipeDrain.defaultStderrMaxBytes, 1 * 1_024 * 1_024)
        XCTAssertLessThan(
            BoundedPipeDrain.defaultStderrMaxBytes,
            BoundedPipeDrain.defaultStdoutMaxBytes
        )
    }

    func test_defaultDrainPreservesAllProviderBytes() throws {
        let pipe = Pipe()
        let payload = Data(repeating: 0x41, count: 64) + Data(repeating: 0x42, count: 64)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(
            BoundedPipeDrain.readRemaining(from: pipe.fileHandleForReading, timeout: 0.1),
            payload,
            "the default provider drain must not silently drop a terminal frame"
        )
    }

    func test_explicitCapRetainsPrefixWhileDraining() throws {
        let pipe = Pipe()
        let payload = Data(repeating: 0x41, count: 64) + Data(repeating: 0x42, count: 64)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        let retained = BoundedPipeDrain.readRemaining(
            from: pipe.fileHandleForReading,
            timeout: 0.1,
            maxBytes: 32
        )
        XCTAssertEqual(
            retained,
            Data(repeating: 0x41, count: 32),
            "an explicit diagnostic cap retains the first bytes while the drain consumes the rest"
        )
    }

    func test_underCapPreservesFullPayload() throws {
        let pipe = Pipe()
        let payload = Data("hello-ndjson\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(
            BoundedPipeDrain.readRemaining(
                from: pipe.fileHandleForReading,
                timeout: 0.1,
                maxBytes: 1_024
            ),
            payload
        )
    }

    func test_eightMiBPipeRetainsAtMostStdoutCap() throws {
        // WHY: an 8 MiB leftover pipe at provider teardown used to retain
        // Int.max. Retention must stay at the 2 MiB stdout cap while the rest
        // is discarded so the child cannot block.
        let payloadBytes = 8 * 1_024 * 1_024
        let cap = BoundedPipeDrain.defaultStdoutMaxBytes
        let retained = try drainConcurrentPayload(
            byteCount: payloadBytes,
            maxBytes: cap
        )
        NSLog(
            "[memperf] pipe-cap payload=%d retained=%d cap=%d",
            payloadBytes, retained.count, cap
        )
        XCTAssertEqual(
            retained.count,
            cap,
            "an 8 MiB pipe must retain exactly the stdout cap, not the full payload"
        )
        XCTAssertLessThanOrEqual(retained.count, cap)
        XCTAssertEqual(retained, Data(repeating: 0x41, count: cap))
    }

    func test_eightMiBPipeRetainsAtMostStderrCap() throws {
        // WHY: stderr teardown is a diagnostic snapshot, not a transcript.
        // An 8 MiB stderr pipe must not retain more than 1 MiB.
        let payloadBytes = 8 * 1_024 * 1_024
        let cap = BoundedPipeDrain.defaultStderrMaxBytes
        let retained = try drainConcurrentPayload(
            byteCount: payloadBytes,
            maxBytes: cap
        )
        NSLog(
            "[memperf] pipe-stderr-cap payload=%d retained=%d cap=%d",
            payloadBytes, retained.count, cap
        )
        XCTAssertEqual(retained.count, cap)
        XCTAssertLessThanOrEqual(retained.count, cap)
    }

    private func drainConcurrentPayload(byteCount: Int, maxBytes: Int) throws -> Data {
        signal(SIGPIPE, SIG_IGN)
        let pipe = Pipe()
        let chunk = Data(repeating: 0x41, count: 64 * 1_024)
        let writer = DispatchQueue(label: "io.remotecode.bounded-pipe-drain.8mib")
        let done = DispatchSemaphore(value: 0)
        writer.async {
            var remaining = byteCount
            while remaining > 0 {
                let n = min(remaining, chunk.count)
                let slice = n == chunk.count ? chunk : Data(repeating: 0x41, count: n)
                try? pipe.fileHandleForWriting.write(contentsOf: slice)
                remaining -= n
            }
            try? pipe.fileHandleForWriting.close()
            done.signal()
        }
        let retained = BoundedPipeDrain.readRemaining(
            from: pipe.fileHandleForReading,
            timeout: 5,
            maxBytes: maxBytes
        )
        XCTAssertEqual(
            done.wait(timeout: .now() + 5),
            .success,
            "the writer must finish after the drain consumes (and discards past-cap) bytes"
        )
        return retained
    }
}
