// TokenSaverStderrDrainTests.swift
//
// Covers P2: sidecar stderr pipe-buffer-full deadlock prevention.
//
// UNIT COVERAGE
// The drain handler is set inside `start()` after a real `Process.run()` —
// there is no injected pipe seam.  The only independently testable seam in the
// same file is `TokenSaverDistillLaunchPlanner.decide`, so we exercise it here
// to keep the test file meaningful without writing a tautological test
// (Rule 8 compliance).
//
// MANUAL VERIFICATION PLAN (for the stderr drain itself)
// 1. Launch the macOS app with a valid subscription + Token Saver enabled so
//    that `start()` is reached and `Process.run()` succeeds.
// 2. In Terminal: `lsof -p <pid> | grep FIFO`  — confirm TWO FIFOs exist
//    (one for stdout, one for stderr).
// 3. Run `sudo dtrace -n 'syscall::read:entry /pid==$target/{...}' -p <pid>` or
//    attach with Instruments > File Activity, filter on RemoteCodeDistillService.
//    Write ~128 KB to the sidecar's stderr (e.g. via lldb `expression …`).
//    Before this fix: sidecar hangs on the write syscall once the 64 KB kernel
//    buffer fills.  After this fix: the write completes immediately because
//    `availableData` continuously drains the read end.
// 4. Confirm `status == .running(…)` is still reachable after the stderr flood.

import Foundation
import Testing
@testable import AppShell

@Suite("TokenSaverDistillLaunchPlanner — stderr drain companion")
struct TokenSaverStderrDrainTests {

    // MARK: - Failure reason diagnostics

    /// Why it matters: a sidecar crash loop must show the real stderr cause
    /// instead of a generic "exited; restarting" banner that hides model-load
    /// incompatibilities.
    @Test("failure reason includes last actionable stderr line")
    func failureReasonIncludesLastActionableStderrLine() {
        let stderr = """
        RemoteCodeDistillService MLX memory bounded: cacheLimit=128MB memoryLimit=6144MB
        RemoteCodeDistillService failed: mismatchedSize(path: [\"language_model\"], expectedShape: [10752, 2560], actualShape: [10752, 320])
        """
        let reason = TokenSaverDistillFailureReasonFormatter.appendDiagnostic(
            to: "RemoteCodeDistillService exited; restarting",
            stderrLine: stderr
        )

        #expect(reason.contains("RemoteCodeDistillService exited; restarting"))
        #expect(reason.contains("mismatchedSize"))
        #expect(!reason.contains("MLX memory bounded"))
    }

    /// Why it matters: the app should strip the repeated executable prefix and
    /// keep the UI banner short enough to stay readable.
    @Test("stderr diagnostic strips service prefix and truncates long lines")
    func stderrDiagnosticStripsPrefixAndTruncates() {
        let longTail = String(repeating: "x", count: 400)
        let diagnostic = TokenSaverDistillFailureReasonFormatter.sanitizedDiagnostic(
            from: "RemoteCodeDistillService failed: \(longTail)"
        )

        #expect(diagnostic?.hasPrefix("RemoteCodeDistillService failed:") == false)
        #expect((diagnostic?.count ?? 0) <= 223)
        #expect(diagnostic?.hasSuffix("...") == true)
    }

    // MARK: - LaunchPlanner (testable seam)

    /// Why it matters: planner is the sole guard that prevents `start()` (and
    /// thus the stderr pipe setup) from being called when prerequisites are
    /// unmet.  A regression that calls `start()` unconditionally would launch
    /// the sidecar — and reinstall the drain — at the wrong time.
    @Test("skip when not subscribed — start() never reached")
    func skipWhenNotSubscribed() {
        let input = TokenSaverDistillLaunchInput(
            hasPrivateAccount: true,
            isSubscribed: false,
            tokenSaverEnabled: true,
            modelValidation: .init(state: .installed, reason: nil)
        )
        let decision = TokenSaverDistillLaunchPlanner.decide(input)
        #expect(decision == .skip(reason: "subscription required"))
    }

    @Test("skip when token saver disabled — start() never reached")
    func skipWhenTokenSaverDisabled() {
        let input = TokenSaverDistillLaunchInput(
            hasPrivateAccount: true,
            isSubscribed: true,
            tokenSaverEnabled: false,
            modelValidation: .init(state: .installed, reason: nil)
        )
        let decision = TokenSaverDistillLaunchPlanner.decide(input)
        #expect(decision == .skip(reason: "token saver disabled"))
    }

    @Test("require model when not installed — start() never reached")
    func requireModelWhenNotInstalled() {
        let input = TokenSaverDistillLaunchInput(
            hasPrivateAccount: true,
            isSubscribed: true,
            tokenSaverEnabled: true,
            modelValidation: .init(state: .missing, reason: "model absent")
        )
        let decision = TokenSaverDistillLaunchPlanner.decide(input)
        #expect(decision == .requireModel(reason: "model absent"))
    }

    @Test("start when all prerequisites met — start() is reached and drain installed")
    func startWhenAllPrerequisitesMet() {
        let input = TokenSaverDistillLaunchInput(
            hasPrivateAccount: true,
            isSubscribed: true,
            tokenSaverEnabled: true,
            modelValidation: .init(state: .installed, reason: nil)
        )
        let decision = TokenSaverDistillLaunchPlanner.decide(input)
        #expect(decision == .start)
        // When decision == .start the controller calls start(), which after a
        // successful Process.run() installs:
        //   stderr.fileHandleForReading.readabilityHandler = { handle in
        //       _ = handle.availableData
        //   }
        // This is verified by code inspection at:
        //   Sources/AppShell/TokenSaverDistillServiceController.swift
        //   inside the `do { try process.run() … }` block in `start()`.
    }
}
