import AppKit
import XCTest
@testable import AppLifecycleSupport
@testable import AppShell

final class AppLifecycleRecorderTests: XCTestCase {
    private func makeRecorder() -> (AppLifecycleRecorder, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2Lifecycle-" + UUID().uuidString, isDirectory: true)
        return (AppLifecycleRecorder(directory: dir), dir)
    }

    /// Starts a real process, records the marker it would have written, then
    /// kills it without a clean shutdown — the shape of a silent death.
    private func writeMarkerForKilledProcess(in dir: URL, fileName: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        let start = try XCTUnwrap(AppLifecycleRecorder.processStartTime(pid: pid))
        let contents = "pid=\(pid) startedAt=2026-10-05T22:00:00Z procStart=\(start)"
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: dir.appendingPathComponent(fileName ?? "running.\(pid).marker"))
        kill(pid, SIGKILL)
        process.waitUntilExit()
        return contents
    }

    private func markerFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("running.") && $0.hasSuffix(".marker") }
    }

    func test_uncleanExitIsDetectableOnNextLaunch() throws {
        let (next, dir) = makeRecorder()
        let dead = try writeMarkerForKilledProcess(in: dir)

        XCTAssertEqual(
            next.consumeStaleRunMarkers(),
            [dead],
            "a run that ends without a clean shutdown must leave a forensic marker so the next launch can prove the app died silently — this is the only on-disk evidence when there is no crash report"
        )
    }

    func test_cleanExitLeavesNoStaleMarker() {
        let (first, dir) = makeRecorder()
        first.beginRun()
        first.endRunCleanly(reason: "applicationWillTerminate")

        XCTAssertEqual(markerFiles(in: dir), [], "a clean shutdown must remove this run's marker file")
        let next = AppLifecycleRecorder(directory: dir)
        XCTAssertEqual(
            next.consumeStaleRunMarkers(),
            [],
            "a clean applicationWillTerminate must clear the marker so an expected shutdown is not misreported as a silent death"
        )
    }

    func test_liveRunMarkerIsNotConsumedByAnotherLaunch() {
        // S-F8 evidence: a debug build on the same App Support flagged a LIVE
        // stable run (82210, 60220) as unclean and deleted its marker, so when
        // 60220 really died with exit(1) the next launch reported nothing.
        let (live, dir) = makeRecorder()
        live.beginRun()

        let other = AppLifecycleRecorder(directory: dir)
        XCTAssertEqual(
            other.consumeStaleRunMarkers(),
            [],
            "a marker whose pid is alive with the same start time belongs to a running app and must not be reported as an unclean exit"
        )
        XCTAssertEqual(
            markerFiles(in: dir),
            ["running.\(getpid()).marker"],
            "the live run's marker must stay on disk so its later silent death is still detected"
        )
    }

    func test_reusedPidDoesNotHideAnUncleanExit() throws {
        // The pid is alive (this test process) but it is not the process that
        // wrote the marker: a different start time means the writer is dead.
        let (next, dir) = makeRecorder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let contents = "pid=\(getpid()) startedAt=2020-01-01T00:00:00Z procStart=1.000000"
        try Data(contents.utf8).write(to: dir.appendingPathComponent("running.\(getpid()).marker"))

        XCTAssertEqual(
            next.consumeStaleRunMarkers(),
            [contents],
            "pid reuse must not make a dead run look alive; liveness needs both kill(pid,0) and a matching start time"
        )
    }

    func test_legacyMarkerFromOlderBuildIsStillJudgedByLiveness() throws {
        let (next, dir) = makeRecorder()
        let dead = try writeMarkerForKilledProcess(in: dir, fileName: "running.marker")
        XCTAssertEqual(
            next.consumeStaleRunMarkers(),
            [dead],
            "the single running.marker left by a build before per-pid markers must still be reported when its process is gone"
        )

        let liveLegacy = "pid=\(getpid()) startedAt=\(AppLifecycleRecorder.timestamp(from: Date()))"
        try Data(liveLegacy.utf8).write(to: dir.appendingPathComponent("running.marker"))
        XCTAssertEqual(
            next.consumeStaleRunMarkers(),
            [],
            "a legacy marker written by a still-running older build (no procStart) must not be consumed"
        )
    }

    func test_beginRunRecordsDebugBuildMarkerInDebugBuilds() throws {
        // WHY (perf X-00): a debug-packaged app is 5-20x slower in SwiftUI /
        // JSON paths; the boot log must make the build config visible in one
        // line so perf triage never has to guess from binary size again.
        let (recorder, dir) = makeRecorder()
        recorder.beginRun()
#if DEBUG
        let log = try String(contentsOf: dir.appendingPathComponent("lifecycle.log"), encoding: .utf8)
        XCTAssertTrue(
            log.contains("build=debug"),
            "a debug build must stamp build=debug at boot so a debug-packaged app is identifiable in one line"
        )
#else
        let log = try String(contentsOf: dir.appendingPathComponent("lifecycle.log"), encoding: .utf8)
        XCTAssertFalse(
            log.contains("build=debug"),
            "a release build must not claim to be debug at boot"
        )
#endif
    }

    func test_consumingStaleMarkerIsIdempotent() throws {
        let (next, dir) = makeRecorder()
        _ = try writeMarkerForKilledProcess(in: dir)

        XCTAssertEqual(next.consumeStaleRunMarkers().count, 1)
        XCTAssertEqual(
            AppLifecycleRecorder(directory: dir).consumeStaleRunMarkers(),
            [],
            "consuming the stale marker must clear it so the same unclean exit is reported once, not on every subsequent launch"
        )
    }

    func test_sighupNeverTerminatesAppButSigtermDoes() {
        XCTAssertFalse(
            AppLifecycleRecorder.shouldTerminate(onSignal: SIGHUP),
            "SIGHUP (controlling-terminal/session hangup) must never kill the GUI app — a dev build launched from a shell would otherwise vanish when that shell closes"
        )
        XCTAssertTrue(
            AppLifecycleRecorder.shouldTerminate(onSignal: SIGTERM),
            "SIGTERM is intentional (e.g. a relaunch's pkill) and must still bring the app down, but cleanly via the recorded path"
        )
        XCTAssertTrue(AppLifecycleRecorder.shouldTerminate(onSignal: SIGINT))
    }

    func test_heartbeatAppendsSequencedLivenessSampleToDisk() throws {
        let (recorder, dir) = makeRecorder()
        recorder.recordHeartbeat(reason: "periodic")
        recorder.recordHeartbeat(reason: "periodic")

        let log = try String(contentsOf: dir.appendingPathComponent("lifecycle.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("heartbeat seq=1"), "first heartbeat must be recorded so the last-alive time before a silent death is known")
        XCTAssertTrue(log.contains("heartbeat seq=2"), "heartbeats must be sequenced so a gap before an unclean exit reveals a main-thread hang")
        XCTAssertTrue(log.contains("rssKB="), "heartbeats must carry memory footprint so an out-of-memory kill is distinguishable from other deaths")
    }

    func test_heartbeatAppendsProviderAndSidecarMemoryStatsToDisk() throws {
        let (recorder, dir) = makeRecorder()
        recorder.recordHeartbeat(
            reason: "periodic",
            providerProcesses: 2,
            providerRSSKB: 235_000,
            orphanProviders: 0,
            sidecarProcesses: 3,
            sidecarRSSKB: 4_750_000,
            orphanSidecars: 0
        )

        let log = try String(contentsOf: dir.appendingPathComponent("lifecycle.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("providerProcesses=2"),
                      "disk heartbeat must retain provider process count because unified .info logs may be unavailable after a long-run slowdown")
        XCTAssertTrue(log.contains("providerRSSKB=235000"),
                      "disk heartbeat must retain provider RSS so Agent App memory can be separated from provider memory pressure")
        XCTAssertTrue(log.contains("sidecarProcesses=3"),
                      "disk heartbeat must retain legacy Distill sidecar process count separately from provider processes")
        XCTAssertTrue(log.contains("sidecarRSSKB=4750000"),
                      "disk heartbeat must retain legacy Distill sidecar RSS because the sidecar can dominate memory pressure while Agent App RSS stays flat")
    }

    func test_recordWritesForensicLineToDisk() throws {
        let (recorder, dir) = makeRecorder()
        recorder.record("signal=SIGTERM terminating=true")

        let log = try String(contentsOf: dir.appendingPathComponent("lifecycle.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("signal=SIGTERM"), "recorded events must be persisted to the lifecycle log")
        XCTAssertTrue(log.contains("pid=\(ProcessInfo.processInfo.processIdentifier)"),
                      "each line must carry the pid so an incident can be tied to a specific process")
    }

    // Pins the timestamp format produced by the shared ISO8601DateFormatter so
    // that hoisting the formatter cannot silently change the log line structure.
    // WHY: log consumers parse the ISO8601 prefix to correlate events; any
    // format change (e.g. fractional seconds, timezone offset style) would
    // break those parsers without this guard.
    func test_timestampFormatIsISO8601WithUTCTimezone() {
        // 2024-03-15 11:34:56 UTC -- a fixed epoch second so the assertion is
        // deterministic regardless of the machine's local timezone.
        let fixedDate = Date(timeIntervalSince1970: 1_710_502_496)
        let result = AppLifecycleRecorder.timestamp(from: fixedDate)
        XCTAssertEqual(
            result,
            "2024-03-15T11:34:56Z",
            "hoisting the ISO8601DateFormatter must not change the timestamp format -- log consumers depend on this exact ISO8601 layout"
        )
    }

    // MARK: - QA-mac:48 signal-handler write+unlink mechanics

    func test_signalMessage_mapsKnownSignals() {
        XCTAssertEqual("\(lifecycleSignalMessage(for: SIGTERM))", "signal=SIGTERM terminating\n",
            "SIGTERM must log a SIGTERM line so a crash analysis can tell a clean terminate from a hard kill")
        XCTAssertEqual("\(lifecycleSignalMessage(for: SIGINT))", "signal=SIGINT terminating\n",
            "SIGINT must log a SIGINT line")
        XCTAssertEqual("\(lifecycleSignalMessage(for: SIGSEGV))", "signal=other terminating\n",
            "an unmapped signal must still log a generic terminating line, never nothing")
    }

    func test_signalRecord_writesLineAndUnlinksMarker() throws {
        // The real sigaction handler routes through lifecycleSignalRecord before it
        // re-raises (which the OS-default disposition handles). This exercises the
        // write+unlink mechanics in-process: a SIGTERM must append its line to the
        // log fd AND remove the run marker, so the next launch sees an orderly-exit
        // trail rather than a surviving marker (which would read as a hard kill).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2Signal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let logURL = dir.appendingPathComponent("lifecycle.log")
        let markerURL = dir.appendingPathComponent("running.marker")
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        try Data("present".utf8).write(to: markerURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "precondition: marker present")

        let fd = open(logURL.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0, "must open the log fd")
        let markerPath = strdup(markerURL.path)
        defer { free(markerPath); if fd >= 0 { close(fd) } }

        lifecycleSignalRecord(fd: fd, markerPath: markerPath, signo: SIGTERM)

        let logged = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(logged.contains("signal=SIGTERM terminating"),
            "the signal handler must append the SIGTERM line to the live log fd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path),
            "the signal handler must unlink the run marker so a clean SIGTERM is not misread as a hard kill")
    }

    func test_signalRecord_negativeFdAndNilMarkerAreSafeNoops() {
        // Defensive: before installSignalHandlers (fd = -1, marker = nil) the handler
        // must not crash if a signal somehow fires.
        lifecycleSignalRecord(fd: -1, markerPath: nil, signo: SIGINT)
    }
}

final class AppLifecycleTests: XCTestCase {
    @MainActor func test_lastWindowCloseDoesNotTerminateLongRunningTerminalSessions() {
        let delegate = AppDelegate()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
            "closing the last macOS window must leave RemoteCode running so long terminal/agent sessions are not killed and the window can be reopened"
        )
    }

    @MainActor func test_mainWindowCloseHidesWindowInsteadOfDestroyingAppSession() throws {
        let tmp = NSTemporaryDirectory() + "RC2Lifecycle-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: context)
        context.router = router
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller

        controller.show()

        XCTAssertFalse(
            controller.windowShouldClose(controller.window),
            "the red close button must hide the main window instead of allowing AppKit to close the last window and terminate long-running terminal or agent work"
        )
        XCTAssertFalse(
            controller.window.isVisible,
            "close should leave RemoteCode reopenable without destroying the existing app session"
        )

        controller.window.orderOut(nil)
    }
}
