// TokenSaverDistillStatusDisplayTests.swift
//
// Covers the display helpers added to TokenSaverDistillServiceStatus
// (displayLabel, displayReason, isRunning, isOperationallyBlocked) and
// the rc2TokenSaverDistillStatusChanged notification posted by the controller
// whenever its status property changes.
//
// WHY these tests exist (Rule 8):
// - displayLabel/displayReason are the contract between controller state and the
//   details popover status row.  If they return wrong values the UI shows
//   "running" while the sidecar is failed (silent fail-open, Rule 6 violation).
// - isOperationallyBlocked tells the coordinator whether to fall through to the
//   local fallback.  A wrong return value causes silent failed compression.
// - The notification is the seam that lets SidebarViewModel refresh the popover
//   row without polling.  If it is never posted (or fires on equal-value writes),
//   the popover stays stale forever.

import AgentRuntime
import DistillCore
import Foundation
import Persistence
import Testing
@testable import AppShell

// MARK: - Display label / reason / helpers

@Suite("TokenSaverDistillServiceStatus display helpers")
struct TokenSaverDistillStatusDisplayTests {

    // MARK: - displayLabel

    @Test("notStarted displayLabel is not-running")
    func notStartedLabel() {
        #expect(TokenSaverDistillServiceStatus.notStarted.displayLabel == "not running")
    }

    @Test("starting displayLabel is warming up")
    func startingLabel() {
        #expect(TokenSaverDistillServiceStatus.starting.displayLabel == "warming up")
    }

    @Test("running displayLabel is running")
    func runningLabel() {
        let ready = TokenSaverDistillStatusDisplayTests.makeReady()
        #expect(TokenSaverDistillServiceStatus.running(ready).displayLabel == "running")
    }

    @Test("blocked displayLabel is blocked")
    func blockedLabel() {
        #expect(TokenSaverDistillServiceStatus.blocked("no model").displayLabel == "blocked")
    }

    @Test("failed displayLabel is failed")
    func failedLabel() {
        #expect(TokenSaverDistillServiceStatus.failed("crash").displayLabel == "failed")
    }

    // MARK: - displayReason

    @Test("blocked displayReason returns the block reason verbatim")
    func blockedReason() {
        // WHY: the reason is the actionable signal. If it is nil the popover row
        // shows "blocked" with no path forward, which is a Rule-6 violation.
        let reason = "subscription required"
        #expect(TokenSaverDistillServiceStatus.blocked(reason).displayReason == reason)
    }

    @Test("failed displayReason returns the failure reason verbatim")
    func failedReason() {
        let reason = "RemoteCodeDistillService exited; restarting"
        #expect(TokenSaverDistillServiceStatus.failed(reason).displayReason == reason)
    }

    @Test("notStarted displayReason is nil")
    func notStartedNoReason() {
        #expect(TokenSaverDistillServiceStatus.notStarted.displayReason == nil)
    }

    @Test("starting displayReason is nil")
    func startingNoReason() {
        #expect(TokenSaverDistillServiceStatus.starting.displayReason == nil)
    }

    @Test("running displayReason is nil")
    func runningNoReason() {
        let ready = TokenSaverDistillStatusDisplayTests.makeReady()
        #expect(TokenSaverDistillServiceStatus.running(ready).displayReason == nil)
    }

    // MARK: - displayLabel is ASCII-only

    @Test("all displayLabels are ASCII-only")
    func allLabelsAreASCII() {
        // WHY: labels are used in log output and must be safe to pipe / diff.
        let ready = TokenSaverDistillStatusDisplayTests.makeReady()
        let statuses: [TokenSaverDistillServiceStatus] = [
            .notStarted, .starting, .running(ready), .blocked("x"), .failed("y")
        ]
        for status in statuses {
            for scalar in status.displayLabel.unicodeScalars {
                #expect(
                    scalar.value < 128,
                    "non-ASCII U+\(String(scalar.value, radix: 16)) in displayLabel for \(status)"
                )
            }
        }
    }

    // MARK: - isRunning

    @Test("isRunning is true only for .running")
    func isRunningOnlyForRunning() {
        let ready = TokenSaverDistillStatusDisplayTests.makeReady()
        #expect(TokenSaverDistillServiceStatus.running(ready).isRunning)
        #expect(!TokenSaverDistillServiceStatus.notStarted.isRunning)
        #expect(!TokenSaverDistillServiceStatus.starting.isRunning)
        #expect(!TokenSaverDistillServiceStatus.blocked("x").isRunning)
        #expect(!TokenSaverDistillServiceStatus.failed("y").isRunning)
    }

    // MARK: - isOperationallyBlocked

    @Test("isOperationallyBlocked is true for blocked and failed")
    func operationallyBlockedForBlockedAndFailed() {
        // WHY: both .blocked and .failed mean compression requests will fall through
        // to the local fallback without attempting the sidecar. If this returns
        // wrong, the coordinator will attempt dead-sidecar calls and surface errors.
        #expect(TokenSaverDistillServiceStatus.blocked("x").isOperationallyBlocked)
        #expect(TokenSaverDistillServiceStatus.failed("y").isOperationallyBlocked)
    }

    @Test("isOperationallyBlocked is false for operational states")
    func notOperationallyBlockedForHealthyStates() {
        let ready = TokenSaverDistillStatusDisplayTests.makeReady()
        #expect(!TokenSaverDistillServiceStatus.notStarted.isOperationallyBlocked)
        #expect(!TokenSaverDistillServiceStatus.starting.isOperationallyBlocked)
        #expect(!TokenSaverDistillServiceStatus.running(ready).isOperationallyBlocked)
    }

    // MARK: - sidecarStatusLabel (popover visibility seam)

    @Test("sidecarStatusLabel(.blocked) returns non-empty label containing the reason")
    func blockedSidecarLabel() {
        // WHY: a blocked sidecar that shows no label leaves the user believing Token
        // Saver works when the local model is not running (Rule 6 fail-loud violation).
        let label = SidebarRootView.sidecarStatusLabel(.blocked("subscription required"))
        #expect(label != nil, "blocked must produce a visible label")
        #expect(label?.isEmpty == false, "label must not be empty")
        #expect(label?.contains("subscription required") == true, "label must carry the reason")
    }

    @Test("sidecarStatusLabel(.failed) returns non-empty label containing the reason")
    func failedSidecarLabel() {
        let label = SidebarRootView.sidecarStatusLabel(.failed("RemoteCodeDistillService exited; restarting"))
        #expect(label != nil, "failed must produce a visible label")
        #expect(label?.isEmpty == false, "label must not be empty")
        #expect(label?.contains("RemoteCodeDistillService exited; restarting") == true, "label must carry the reason")
    }

    @Test("sidecarStatusLabel(.starting) returns non-empty label distinct from blocked and failed")
    func startingSidecarLabel() {
        let startingLabel = SidebarRootView.sidecarStatusLabel(.starting)
        let blockedLabel  = SidebarRootView.sidecarStatusLabel(.blocked("x"))
        let failedLabel   = SidebarRootView.sidecarStatusLabel(.failed("y"))
        #expect(startingLabel != nil, "starting must produce a visible label")
        #expect(startingLabel?.isEmpty == false, "label must not be empty")
        #expect(startingLabel != blockedLabel, "starting label must differ from blocked label")
        #expect(startingLabel != failedLabel,  "starting label must differ from failed label")
    }

    @Test("sidecarStatusLabel(.running) returns nil -- no banner when healthy")
    func runningSidecarLabel() {
        // WHY: showing a warning when the sidecar is healthy confuses the user.
        // Nil -> the status row is hidden entirely.
        let ready = TokenSaverDistillStatusDisplayTests.makeReady()
        #expect(SidebarRootView.sidecarStatusLabel(.running(ready)) == nil,
                "running must return nil so the popover row is hidden")
    }

    @Test("sidecarStatusLabel(.notStarted) returns nil -- no banner before first launch")
    func notStartedSidecarLabel() {
        #expect(SidebarRootView.sidecarStatusLabel(.notStarted) == nil,
                "notStarted must return nil so the popover row is hidden")
    }

    @Test("sidecarStatusLabel labels are ASCII-only")
    func sidecarLabelsAreASCII() {
        // WHY: labels may be piped to log output; must not contain smart quotes or em-dashes.
        let candidates: [TokenSaverDistillServiceStatus] = [
            .blocked("no model"), .failed("crash"), .starting
        ]
        for status in candidates {
            if let label = SidebarRootView.sidecarStatusLabel(status) {
                for scalar in label.unicodeScalars {
                    #expect(scalar.value < 128,
                            "non-ASCII U+\(String(scalar.value, radix: 16)) in sidecarStatusLabel for \(status)")
                }
            }
        }
    }

    // MARK: - Helpers

    static func makeReady() -> DistillServiceReadyEvent {
        let json = """
        {
          "event": "ready",
          "base_url": "http://127.0.0.1:55001",
          "host": "127.0.0.1",
          "port": 55001,
          "pid": 9999,
          "protocol": 1,
          "runtime": "mlx",
          "model_id": "test-model",
          "max_concurrent_requests": 8,
          "max_queue_depth": 64
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(DistillServiceReadyEvent.self, from: json)
    }
}

// MARK: - Status-change notification

@MainActor
@Suite("TokenSaverDistillServiceController status-change notification")
struct TokenSaverDistillStatusNotificationTests {

    // A lightweight controller that never tries to launch a real sidecar process
    // (the default executable resolver returns nil in test bundles).
    private func makeController() -> TokenSaverDistillServiceController {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2NotifTest-\(UUID().uuidString)", isDirectory: true)
        return TokenSaverDistillServiceController(
            appSupportDirectory: tmp,
            idleTimeoutMS: 0
        )
    }

    @Test("notification is NOT posted when status does not change")
    func noNotificationOnEqualWrite() async {
        let controller = makeController()
        var fired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2TokenSaverDistillStatusChanged,
            object: controller,
            queue: .main
        ) { _ in fired = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        // startIfEligible with tokenSaverEnabled=false -> stop() -> .notStarted
        // The controller starts at .notStarted; writing .notStarted again must not fire.
        controller.stop()
        // Yield so any queued main-actor work runs.
        await Task.yield()
        #expect(!fired, "notification must not fire when status stays .notStarted")
    }

    @Test("notification fires on every distinct status transition")
    func notificationFiresOnTransition() async {
        let controller = makeController()
        var fireCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2TokenSaverDistillStatusChanged,
            object: controller,
            queue: .main
        ) { _ in fireCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        // startIfEligible with no subscription -> .blocked (transition from .notStarted)
        controller.startIfEligible(
            session: nil,
            settings: AppSettings(),
            modelValidation: .installed
        )
        await Task.yield()
        #expect(fireCount >= 1,
            "notification must fire when status transitions from notStarted -> blocked")
    }

    @Test("notification object is the controller instance")
    func notificationObjectIsController() async {
        let controller = makeController()
        var receivedObject: AnyObject?
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2TokenSaverDistillStatusChanged,
            object: controller,
            queue: .main
        ) { note in receivedObject = note.object as AnyObject }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.startIfEligible(
            session: nil,
            settings: AppSettings(),
            modelValidation: .installed
        )
        await Task.yield()
        #expect(receivedObject === controller,
            "notification object must be the controller instance so multiple controllers can be distinguished")
    }
}
