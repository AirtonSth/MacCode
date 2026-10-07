import XCTest
@testable import AppLifecycleSupport

/// S-F5: a long main-thread hang must leave a stack on disk. Before this, a
/// 72-minute hang left only `samplesRequested=0`, so its cause was never known.
final class HangStackCaptureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HangStackCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _runs: [(executable: String, arguments: [String], onMain: Bool)] = []
        private var _logs: [String] = []
        var runs: [(executable: String, arguments: [String], onMain: Bool)] { lock.lock(); defer { lock.unlock() }; return _runs }
        var logs: [String] { lock.lock(); defer { lock.unlock() }; return _logs }
        func run(_ executable: String, _ arguments: [String]) {
            lock.lock(); _runs.append((executable, arguments, Thread.isMainThread)); lock.unlock()
        }
        func log(_ line: String) { lock.lock(); _logs.append(line); lock.unlock() }
    }

    /// Fake runner that writes the `-file` target like the real tools do.
    private func makeCapture(
        calls: Calls,
        maxFiles: Int = 10,
        spindumpAvailable: Bool = false,
        failRuns: Bool = false
    ) -> HangStackCapture {
        HangStackCapture(
            directory: directory,
            pid: 4242,
            maxFiles: maxFiles,
            spindumpAvailable: { spindumpAvailable },
            runner: { executable, arguments in
                calls.run(executable, arguments)
                if failRuns { throw CocoaError(.executableNotLoadable) }
                if let index = arguments.firstIndex(of: "-file"), index + 1 < arguments.count {
                    try Data("stack".utf8).write(to: URL(fileURLWithPath: arguments[index + 1]))
                }
                return 0
            },
            log: { calls.log($0) }
        )
    }

    private func hangFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }
            .sorted()
    }

    func test_samplesOncePerEpisodeAtFiveSeconds_andAgainForANewEpisode() {
        let calls = Calls()
        let capture = makeCapture(calls: calls)
        let episodeA = Date(timeIntervalSince1970: 1_000)
        let t0 = Date(timeIntervalSince1970: 2_000)

        capture.observe(gapSeconds: 2, kind: .hangLikely, episodeStart: episodeA, now: t0)
        capture.observe(gapSeconds: 4.9, kind: .hangLikely, episodeStart: episodeA, now: t0)
        capture.waitUntilIdleForTests()
        XCTAssertTrue(calls.runs.isEmpty, "a short stall must not pay for a 3 s sample")

        // Every tick of a long hang reports the same episode; only one sample.
        for gap in [5.0, 6, 10, 30, 59] {
            capture.observe(gapSeconds: gap, kind: .hangLikely, episodeStart: episodeA, now: t0.addingTimeInterval(gap))
        }
        capture.waitUntilIdleForTests()
        XCTAssertEqual(calls.runs.count, 1)
        let run = calls.runs[0]
        XCTAssertEqual(run.executable, "/usr/bin/sample")
        XCTAssertEqual(Array(run.arguments.prefix(3)), ["4242", "3", "-mayDie"])
        XCTAssertEqual(run.arguments[3], "-file")
        XCTAssertTrue(run.arguments[4].hasPrefix(directory.path + "/hang-"))
        XCTAssertFalse(run.onMain, "the sample must never run on the main thread it is diagnosing")
        XCTAssertEqual(hangFiles().count, 1)
        XCTAssertTrue(calls.logs.contains { $0.hasPrefix("hang_stack_captured tool=sample status=0 written=1") })

        // Main answered (new last-ack) and then hung again: that is a new episode.
        let episodeB = Date(timeIntervalSince1970: 3_000)
        capture.observe(gapSeconds: 5, kind: .hangLikely, episodeStart: episodeB, now: t0.addingTimeInterval(100))
        capture.waitUntilIdleForTests()
        XCTAssertEqual(calls.runs.count, 2)
        XCTAssertEqual(hangFiles().count, 2)
    }

    func test_sleepGapNeverSamples() {
        let calls = Calls()
        let capture = makeCapture(calls: calls)
        capture.observe(gapSeconds: 509, kind: .suspendedOrSleep, episodeStart: Date(timeIntervalSince1970: 1), now: Date())
        capture.observe(gapSeconds: 509, kind: .normal, episodeStart: Date(timeIntervalSince1970: 1), now: Date())
        capture.waitUntilIdleForTests()
        XCTAssertTrue(calls.runs.isEmpty, "sleep is not a hang; sampling it would waste CPU and mislead triage")
    }

    func test_spindumpAtSixtySeconds_isSkippedAndLoggedOnceWhenItNeedsPrivileges() {
        let calls = Calls()
        let capture = makeCapture(calls: calls, spindumpAvailable: false)
        let episode = Date(timeIntervalSince1970: 1_000)
        for gap in [5.0, 60, 61, 300] {
            capture.observe(gapSeconds: gap, kind: .hangLikely, episodeStart: episode, now: Date(timeIntervalSince1970: 2_000 + gap))
        }
        capture.waitUntilIdleForTests()
        XCTAssertEqual(calls.runs.map(\.executable), ["/usr/bin/sample"], "no privilege prompt, no spindump")
        XCTAssertEqual(calls.logs.filter { $0.hasPrefix("hang_spindump_skipped reason=requires_privileges gapSec=60") }.count, 1)
        XCTAssertEqual(calls.logs.filter { $0.hasPrefix("hang_spindump_skipped") }.count, 1)
    }

    func test_spindumpAtSixtySeconds_runsOncePerEpisodeWhenAvailable() {
        let calls = Calls()
        let capture = makeCapture(calls: calls, spindumpAvailable: true)
        let episode = Date(timeIntervalSince1970: 1_000)
        for gap in [5.0, 59, 60, 120] {
            capture.observe(gapSeconds: gap, kind: .hangLikely, episodeStart: episode, now: Date(timeIntervalSince1970: 2_000 + gap))
        }
        capture.waitUntilIdleForTests()
        XCTAssertEqual(calls.runs.map(\.executable), ["/usr/bin/sample", "/usr/sbin/spindump"])
        let spindump = calls.runs[1]
        XCTAssertEqual(Array(spindump.arguments.prefix(2)), ["4242", "3"])
        XCTAssertTrue(spindump.arguments.last?.hasSuffix("-spindump.txt") == true)
        XCTAssertFalse(spindump.onMain)
    }

    func test_hangFileCountIsBounded_oldestRemoved_otherDiagnosticsKept() throws {
        // Old captures from earlier runs, plus lifecycle files that share the folder.
        for i in 0..<5 {
            try Data("old".utf8).write(to: directory.appendingPathComponent("hang-2026010\(i)T000000.000Z.txt"))
        }
        try Data("log".utf8).write(to: directory.appendingPathComponent("lifecycle.log"))
        try Data("m".utf8).write(to: directory.appendingPathComponent("running.marker"))

        let calls = Calls()
        let capture = makeCapture(calls: calls, maxFiles: 3)
        for episode in 0..<2 {
            capture.observe(
                gapSeconds: 5,
                kind: .hangLikely,
                episodeStart: Date(timeIntervalSince1970: TimeInterval(1_000 + episode)),
                now: Date(timeIntervalSince1970: TimeInterval(1_900_000_000 + episode * 60))
            )
        }
        capture.waitUntilIdleForTests()

        let files = hangFiles()
        XCTAssertEqual(files.count, 3, "a hang loop must not fill the disk")
        XCTAssertEqual(files.first, "hang-20260104T000000.000Z.txt", "only the oldest files are removed")
        XCTAssertTrue(files.contains("hang-20300317T174640.000Z.txt"))
        XCTAssertTrue(files.contains("hang-20300317T174740.000Z.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lifecycle.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("running.marker").path))
    }

    func test_runnerFailure_isLoggedAndNotRetriedWithinTheEpisode() {
        let calls = Calls()
        let capture = makeCapture(calls: calls, failRuns: true)
        let episode = Date(timeIntervalSince1970: 1_000)
        for gap in [5.0, 6, 7] {
            capture.observe(gapSeconds: gap, kind: .hangLikely, episodeStart: episode, now: Date(timeIntervalSince1970: 2_000 + gap))
        }
        capture.waitUntilIdleForTests()
        XCTAssertEqual(calls.runs.count, 1, "a broken tool must not be relaunched every second of a hang")
        XCTAssertEqual(calls.logs.filter { $0.hasPrefix("hang_stack_failed tool=sample gapSec=5") }.count, 1)
        XCTAssertFalse(calls.logs.contains { $0.hasPrefix("hang_stack_captured") }, "a failed capture must not be reported as taken")
    }

    func test_defaultSpindumpCheck_requiresRoot() throws {
        try XCTSkipIf(geteuid() == 0, "running as root")
        XCTAssertFalse(HangStackCapture.spindumpRunsWithoutPrivileges())
    }

    private func spinMainRunLoop(seconds: TimeInterval) {
        // XCTWaiter spins the main run loop, so queued main pings are acknowledged.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "spin")], timeout: seconds)
    }

    /// End to end: a real watchdog, a really blocked main thread, and the real
    /// `/usr/bin/sample`. Thresholds are scaled down so the test stays short.
    func test_realMainThreadBlock_writesExactlyOneRealSample() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sample"))
        let calls = Calls()
        let capture = HangStackCapture(
            directory: directory,
            sampleThreshold: 1.0,
            spindumpThreshold: 600,
            captureDurationSeconds: 1,
            log: { calls.log($0) }
        )
        let watchdog = HangWatchdog(
            pingInterval: 0.2,
            hangThreshold: 0.5,
            awakeProvider: { .awake },
            gapObserver: { gap, kind, episodeStart in
                capture.observe(gapSeconds: gap, kind: kind, episodeStart: episodeStart)
            }
        )
        watchdog.start()
        spinMainRunLoop(seconds: 1.5) // healthy: pings acknowledged
        capture.waitUntilIdleForTests()
        XCTAssertTrue(hangFiles().isEmpty, "a responsive main thread must not be sampled")

        // The hang: keep main blocked (no run loop) until the sample has run,
        // however long `sample` takes to launch on a cold machine.
        let deadline = Date().addingTimeInterval(30)
        while !calls.logs.contains(where: { $0.hasPrefix("hang_stack_") }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        spinMainRunLoop(seconds: 1.0) // main answers again
        watchdog.stop()
        spinMainRunLoop(seconds: 0.5)
        capture.waitUntilIdleForTests()

        let files = hangFiles()
        XCTAssertEqual(files.count, 1, "one hang episode, one sample; logs: \(calls.logs)")
        let text = try String(contentsOf: directory.appendingPathComponent(try XCTUnwrap(files.first)), encoding: .utf8)
        XCTAssertTrue(text.contains("Analysis of sampling xctest (pid \(ProcessInfo.processInfo.processIdentifier))"))
        XCTAssertTrue(text.contains("HangStackCaptureTests.test_realMainThreadBlock_writesExactlyOneRealSample"),
                      "the blocked test method must be on the captured stack")
        XCTAssertFalse(text.contains("HangStackCapture.waitUntilIdleForTests"),
                       "the stack must be taken during the hang, not after main recovered")
        XCTAssertTrue(calls.logs.contains { $0.hasPrefix("hang_stack_captured tool=sample status=0 written=1") }, "\(calls.logs)")
    }
}
