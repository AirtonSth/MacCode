import XCTest
@testable import AgentRuntime

/// Checkpoint enrich used to `readDataToEndOfFile()` git stdout/stderr, so a
/// dirty workspace with an 8 MiB uncommitted patch pinned the whole blob.
/// Capture is now prefix-capped via PipeAccumulator while the fd still drains.
///
/// WHY: Agent App cannot keep multi-MiB git patches in RAM after every turn.
final class BoundedGitDiffCapTests: XCTestCase {

    /// Write `payload` on a helper queue so an 8 MiB blob cannot deadlock
    /// the test thread on a full ~64 KiB pipe buffer.
    private func pipeWithBackgroundWriter(_ payload: Data) -> Pipe {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            writer.write(payload)
            try? writer.close()
        }
        return pipe
    }

    func test_stdoutCap_is2MiB() {
        XCTAssertEqual(GitDiff.stdoutCaptureMaxBytes, 2 * 1024 * 1024)
        XCTAssertEqual(GitDiff.stderrCaptureMaxBytes, 1 * 1024 * 1024)
    }

    func test_readCapped_eightMiBPipe_retainsPrefixDrainsToEOF() throws {
        let fixtureBytes = 8 * 1024 * 1024
        let payload = Data(repeating: 0x41, count: fixtureBytes)
        let pipe = pipeWithBackgroundWriter(payload)

        let uncappedPipe = pipeWithBackgroundWriter(payload)
        let before = uncappedPipe.fileHandleForReading.readDataToEndOfFile().count
        XCTAssertEqual(before, fixtureBytes,
                       "BEFORE: uncapped readDataToEndOfFile pins the whole 8 MiB blob")

        let (retained, truncated) = GitDiff.readCapped(
            pipe.fileHandleForReading,
            maxBytes: GitDiff.stdoutCaptureMaxBytes
        )
        let after = retained.count
        XCTAssertTrue(truncated, "an 8 MiB blob against a 2 MiB cap must report truncation")
        XCTAssertEqual(after, GitDiff.stdoutCaptureMaxBytes,
                       "AFTER: retained prefix equals the cap, not the fixture")
        XCTAssertEqual(retained, Data(repeating: 0x41, count: GitDiff.stdoutCaptureMaxBytes))
        // Writer is already closed; a further read must be EOF (drain completed).
        let leftover = pipe.fileHandleForReading.readData(ofLength: 64)
        XCTAssertTrue(leftover.isEmpty, "capped capture must still drain the fd to EOF")

        let reduction = Double(before - after) / Double(before)
        XCTAssertGreaterThanOrEqual(reduction, 0.50)
        XCTAssertGreaterThanOrEqual(reduction, 0.75)
        NSLog(
            "[perf-proof] gitDiff readCapped before=%d after=%d cap=%d reduction_pct=%.2f",
            before, after, GitDiff.stdoutCaptureMaxBytes, reduction * 100
        )
    }

    func test_readCapped_stderrCap_eightMiBRetains1MiB() throws {
        let fixtureBytes = 8 * 1024 * 1024
        let payload = Data(repeating: 0x42, count: fixtureBytes)
        let pipe = pipeWithBackgroundWriter(payload)

        let (retained, truncated) = GitDiff.readCapped(
            pipe.fileHandleForReading,
            maxBytes: GitDiff.stderrCaptureMaxBytes
        )
        XCTAssertTrue(truncated)
        XCTAssertEqual(retained.count, GitDiff.stderrCaptureMaxBytes)
        let leftover = pipe.fileHandleForReading.readData(ofLength: 64)
        XCTAssertTrue(leftover.isEmpty)
        let reduction = Double(fixtureBytes - retained.count) / Double(fixtureBytes)
        XCTAssertGreaterThan(reduction, 0.87,
                             "1 MiB stderr cap on 8 MiB should save ~87.5%")
    }

    func test_decodeCapturedUTF8_midCharacterCutDoesNotYieldEmpty() {
        // "café" is 5 UTF-8 bytes (é = C3 A9). Cutting the last byte used to
        // make String(data:encoding: .utf8) return nil → the whole prefix
        // became "". Boundary trim must keep "caf".
        let cafe = Data("café".utf8)
        XCTAssertEqual(cafe.count, 5)
        let cut = Data(cafe.dropLast())
        XCTAssertEqual(cut.last, 0xC3, "fixture must land inside the 2-byte é")
        XCTAssertNil(String(data: cut, encoding: .utf8),
                     "strict UTF-8 decode of a mid-character cut is nil (the bug)")
        let decoded = GitDiff.decodeCapturedUTF8(cut)
        XCTAssertFalse(decoded.isEmpty, "capped git prefix must not vanish at a UTF-8 split")
        XCTAssertEqual(decoded, "caf")

        let grin = Data("ok 😀".utf8) // 😀 is F0 9F 98 80
        XCTAssertEqual(grin.suffix(4), Data([0xF0, 0x9F, 0x98, 0x80]))
        let grinCut = Data(grin.dropLast())
        XCTAssertFalse(GitDiff.decodeCapturedUTF8(grinCut).isEmpty)
        XCTAssertTrue(GitDiff.decodeCapturedUTF8(grinCut).hasPrefix("ok"))
    }

    func test_readCapped_underCap_preservesFullPayload() throws {
        let payload = Data("hello-git-status\n".utf8)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()
        let (retained, truncated) = GitDiff.readCapped(
            pipe.fileHandleForReading,
            maxBytes: GitDiff.stdoutCaptureMaxBytes
        )
        XCTAssertFalse(truncated)
        XCTAssertEqual(retained, payload)
    }

    /// Same 8 MiB pipe fixture, warmed n=5, so retained-byte savings are not a
    /// one-shot accident of a single drain.
    func test_microbench_eightMiBPipe_retainedBytesStayAtCap() throws {
        let fixtureBytes = 8 * 1024 * 1024
        let payload = Data(repeating: 0x41, count: fixtureBytes)
        let warmup = 2
        let samples = 5
        var before: [Int] = []
        var after: [Int] = []

        func once() throws -> (uncapped: Int, capped: Int) {
            let uncappedPipe = pipeWithBackgroundWriter(payload)
            let uncapped = uncappedPipe.fileHandleForReading.readDataToEndOfFile().count

            let cappedPipe = pipeWithBackgroundWriter(payload)
            let (retained, truncated) = GitDiff.readCapped(
                cappedPipe.fileHandleForReading,
                maxBytes: GitDiff.stdoutCaptureMaxBytes
            )
            XCTAssertTrue(truncated)
            return (uncapped, retained.count)
        }

        for _ in 0..<warmup { _ = try once() }
        for _ in 0..<samples {
            let sample = try once()
            before.append(sample.uncapped)
            after.append(sample.capped)
        }
        let beforeMedian = before.sorted()[samples / 2]
        let afterMedian = after.sorted()[samples / 2]
        let reduction = Double(beforeMedian - afterMedian) / Double(beforeMedian)
        NSLog(
            "[perf-proof] gitDiff eightMiB_microbench before_median=%d after_median=%d reduction_pct=%.2f before=%@ after=%@",
            beforeMedian, afterMedian, reduction * 100,
            String(describing: before), String(describing: after)
        )
        XCTAssertEqual(beforeMedian, fixtureBytes)
        XCTAssertEqual(afterMedian, GitDiff.stdoutCaptureMaxBytes)
        XCTAssertGreaterThanOrEqual(reduction, 0.50)
        XCTAssertGreaterThanOrEqual(reduction, 0.75)
    }

    func test_diff_eightMiBUncommittedPatch_isCappedAndSummaryStaysUsable() throws {
        let dir = NSTemporaryDirectory() + "rc2-git-cap-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        func run(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
        }
        run(["git", "init", "-q", "-b", "main", dir])
        run(["git", "-C", dir, "config", "user.email", "t@t.t"])
        run(["git", "-C", dir, "config", "user.name", "test"])
        try "seed\n".write(toFile: dir + "/big.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "big.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "init"])

        // ~8 MiB of added text so `git diff HEAD` is larger than the capture cap.
        let line = String(repeating: "x", count: 127) + "\n"
        let target = 8 * 1024 * 1024
        var body = ""
        body.reserveCapacity(target + line.count)
        while body.utf8.count < target {
            body.append(line)
        }
        try body.write(toFile: dir + "/big.txt", atomically: true, encoding: .utf8)

        let summary = GitDiff.summary(in: dir)
        XCTAssertTrue(summary.isGitRepo)
        XCTAssertTrue(summary.dirty)
        XCTAssertTrue(summary.files.contains { $0.path == "big.txt" && $0.status == .modified },
                      "summary porcelain must stay usable under the capture cap")

        let patch = GitDiff.diff(in: dir, path: "big.txt")
        let retained = patch.utf8.count
        let capWithNotice = GitDiff.stdoutCaptureMaxBytes + GitDiff.truncationNotice.utf8.count
        XCTAssertLessThanOrEqual(retained, capWithNotice,
                                 "diff() must not return an 8 MiB patch")
        XCTAssertTrue(patch.contains(GitDiff.truncationNotice.trimmingCharacters(in: .newlines)),
                      "truncated patch must carry a visible notice so the UI does not look complete")
        XCTAssertTrue(patch.contains("big.txt"),
                      "prefix of the patch must remain so the changed path is still visible")
        let reduction = Double((8 * 1024 * 1024) - retained) / Double(8 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(reduction, 0.50)
        NSLog(
            "[perf-proof] gitDiff.diff eightMiB_patch retained=%d cap=%d reduction_pct=%.2f",
            retained, GitDiff.stdoutCaptureMaxBytes, reduction * 100
        )
    }
}
