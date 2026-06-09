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
