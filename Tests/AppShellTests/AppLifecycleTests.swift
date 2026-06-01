import AppKit
import XCTest
@testable import AppShell

final class AppLifecycleRecorderTests: XCTestCase {
    private func makeRecorder() -> (AppLifecycleRecorder, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2Lifecycle-" + UUID().uuidString, isDirectory: true)
        return (AppLifecycleRecorder(directory: dir), dir)
    }

    func test_uncleanExitIsDetectableOnNextLaunch() {
        let (first, dir) = makeRecorder()
        first.beginRun()
        // No endRunCleanly: simulates the app vanishing (SIGTERM/SIGKILL/crash)
        // before applicationWillTerminate could run.

        let next = AppLifecycleRecorder(directory: dir)
        XCTAssertNotNil(
            next.consumeStaleRunMarker(),
            "a run that ends without a clean shutdown must leave a forensic marker so the next launch can prove the app died silently — this is the only on-disk evidence when there is no crash report"
        )
    }

    func test_cleanExitLeavesNoStaleMarker() {
        let (first, dir) = makeRecorder()
        first.beginRun()
        first.endRunCleanly(reason: "applicationWillTerminate")

        let next = AppLifecycleRecorder(directory: dir)
        XCTAssertNil(
            next.consumeStaleRunMarker(),
            "a clean applicationWillTerminate must clear the marker so an expected shutdown is not misreported as a silent death"
        )
    }

    func test_consumingStaleMarkerIsIdempotent() {
        let (first, dir) = makeRecorder()
        first.beginRun()

        let next = AppLifecycleRecorder(directory: dir)
        XCTAssertNotNil(next.consumeStaleRunMarker())
        XCTAssertNil(
            AppLifecycleRecorder(directory: dir).consumeStaleRunMarker(),
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

    func test_handleSignalRunsTerminateOnlyForTerminatingSignals() {
        let (recorder, _) = makeRecorder()
        var sighupTerminated = false
        recorder.handleSignal(SIGHUP) { sighupTerminated = true }
        XCTAssertFalse(sighupTerminated, "SIGHUP must be recorded but must not trigger app termination")

        var sigtermTerminated = false
        recorder.handleSignal(SIGTERM) { sigtermTerminated = true }
        XCTAssertTrue(sigtermTerminated, "SIGTERM must drive the graceful termination closure")
    }

    func test_recordWritesForensicLineToDisk() throws {
        let (recorder, dir) = makeRecorder()
        recorder.record("signal=SIGTERM terminating=true")

        let log = try String(contentsOf: dir.appendingPathComponent("lifecycle.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("signal=SIGTERM"), "recorded events must be persisted to the lifecycle log")
        XCTAssertTrue(log.contains("pid=\(ProcessInfo.processInfo.processIdentifier)"),
                      "each line must carry the pid so an incident can be tied to a specific process")
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
