import XCTest
@testable import AppLifecycleSupport

/// plan-final W0: hang classifier is sleep-aware and forensic-only.
final class HangWatchdogTests: XCTestCase {
    func test_classifyGap_awakeLongGap_isHangLikely() {
        let kind = HangWatchdogClassifier.classifyGap(
            gapSeconds: 5,
            hangThresholdSeconds: 2,
            awake: .awake
        )
        XCTAssertEqual(kind, .hangLikely)
    }

    func test_classifyGap_displaySleepLongGap_isNotHang() {
        // E-F-003: 509s gap during display sleep is not hang proof.
        let kind = HangWatchdogClassifier.classifyGap(
            gapSeconds: 509,
            hangThresholdSeconds: 2,
            awake: .displaySleep
        )
        XCTAssertEqual(kind, .suspendedOrSleep)
    }

    func test_classifyGap_unknownAwake_failClosedToSuspended() {
        let kind = HangWatchdogClassifier.classifyGap(
            gapSeconds: 10,
            hangThresholdSeconds: 2,
            awake: .unknown
        )
        XCTAssertEqual(kind, .suspendedOrSleep)
    }

    func test_classifyGap_belowThreshold_isNormal() {
        let kind = HangWatchdogClassifier.classifyGap(
            gapSeconds: 0.5,
            hangThresholdSeconds: 2,
            awake: .awake
        )
        XCTAssertEqual(kind, .normal)
    }

    func test_bootIdChanged() {
        XCTAssertFalse(HangWatchdogClassifier.bootIdChanged(previous: nil, current: "a"))
        XCTAssertFalse(HangWatchdogClassifier.bootIdChanged(previous: "a", current: "a"))
        XCTAssertTrue(HangWatchdogClassifier.bootIdChanged(previous: "a", current: "b"))
    }

    func test_watchdogBreach_doesNotRequireRunStatusMutation() {
        // Contract: HangWatchdogBreach is pure diagnostics payload.
        let breach = HangWatchdogBreach(
            gapSeconds: 3,
            kind: .hangLikely,
            awake: .awake,
            sideContext: HangWatchdogSideContext(providerProcessCount: 2, bootId: "boot")
        )
        XCTAssertTrue(breach.sideContext.lifecycleLine.contains("hang_breach"))
        XCTAssertTrue(breach.sideContext.lifecycleLine.contains("providerProcesses=2"))
    }

    func test_evaluateForTests_emitsBreachWhenAwakeAndStaleAck() {
        let watchdog = HangWatchdog(
            pingInterval: 0.2,
            hangThreshold: 1.0,
            breachCooldown: 0,
            mainPinger: { _ in },
            awakeProvider: { .awake },
            sideContextProvider: { HangWatchdogSideContext(bootId: "t") },
            onBreach: { _ in }
        )
        let now = Date()
        let breach = watchdog.evaluateForTests(now: now, lastAck: now.addingTimeInterval(-3))
        XCTAssertNotNil(breach)
        XCTAssertEqual(breach?.kind, .hangLikely)
    }
}
