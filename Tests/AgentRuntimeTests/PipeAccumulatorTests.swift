import XCTest
@testable import AgentRuntime

/// Tests for PipeAccumulator — the pure drain helper that prevents >64KB
/// pipe-full deadlocks in ProviderCLIProbe.run().
final class PipeAccumulatorTests: XCTestCase {

    // MARK: - Unit tests (pure accumulator)

    func test_emptyAccumulatorYieldsEmptyString() {
        let acc = PipeAccumulator()
        XCTAssertEqual(acc.string, "",
                       "unwritten accumulator must yield empty string so probe code that reads before any chunks are available does not produce garbage output")
    }

    func test_singleChunkRoundTrips() {
        var acc = PipeAccumulator()
        acc.append(Data("hello\n".utf8))
        XCTAssertEqual(acc.string, "hello\n",
                       "a single appended chunk must survive decode intact so probe output is not corrupted for CLIs that write everything in one shot")
    }

    func test_multipleChunksAreConcatenatedInOrder() {
        var acc = PipeAccumulator()
        acc.append(Data("line1\n".utf8))
        acc.append(Data("line2\n".utf8))
        acc.append(Data("line3\n".utf8))
        XCTAssertEqual(acc.string, "line1\nline2\nline3\n",
                       "chunks must be joined in append-order so multi-fragment pipe reads produce the same output as a single blocking readDataToEndOfFile call")
    }

    func test_largeMultiChunkMatchesReferenceBytes() {
        // 128 KB spread across 4 chunks of 32 KB — exceeds the macOS pipe
        // kernel buffer (~65536 bytes) that causes the deadlock being fixed.
        let chunkSize = 32 * 1024
        let chunkCount = 4
        let byte: UInt8 = 0x41 // "A"
        let singleChunk = Data(repeating: byte, count: chunkSize)

        var acc = PipeAccumulator()
        for _ in 0..<chunkCount {
            acc.append(singleChunk)
        }

        let expected = Data(repeating: byte, count: chunkSize * chunkCount)
        XCTAssertEqual(acc.data, expected,
                       "128 KB split across 4 chunks must produce byte-exact concatenated output — proving the concurrent drain path handles the pipe-full scenario without data loss")
        XCTAssertEqual(acc.data.count, chunkSize * chunkCount,
                       "accumulated byte count must equal sum of chunk sizes: pipe draining must not drop or duplicate bytes")
    }

    func test_appendedDataPreservesExactBytes() {
        // Verify no encoding/decoding artifacts for arbitrary binary patterns.
        var acc = PipeAccumulator()
        let chunk1 = Data([0x00, 0xFF, 0x0A, 0x7F])
        let chunk2 = Data([0xAB, 0xCD])
        acc.append(chunk1)
        acc.append(chunk2)
        XCTAssertEqual(acc.data, chunk1 + chunk2,
                       "accumulator must preserve byte-exact content across appends so stderr/stdout are not altered between drain and parse")
    }

    // MARK: - Integration smoke test

    func test_probeDoesNotDeadlockOnLargeOutput() throws {
        // Spawn a real shell script that emits 128 KB to stdout.
        // The fix (concurrent drain) must let it complete within the timeout
        // rather than deadlocking after 64 KB fills the OS pipe buffer.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("large-output")
        // python3 is available on macOS; write 131072 bytes (128 KB) of "A"
        try """
        #!/bin/sh
        python3 -c "import sys; sys.stdout.write('A' * 131072); sys.stdout.flush()"
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        // versionStatus uses run() with a 2 s timeout; if drain is broken it
        // would hang until the timeout and return nil.
        let status = ProviderCLIProbe.versionStatus(binaryPath: binary.path, timeoutSeconds: 5.0)

        // The first line is 131072 "A"s with no newline; version is the trimmed first line.
        XCTAssertNotNil(status.version,
                        "probe must return a non-nil version when child emits 128 KB — deadlock would return nil after burning the full timeout")
        XCTAssertEqual(status.version?.count, 131072,
                       "probe must capture all 128 KB of output without data loss when concurrent drain is active")
    }
}
