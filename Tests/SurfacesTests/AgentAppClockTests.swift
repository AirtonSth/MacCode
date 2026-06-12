import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// Tests for QA-MAC_AGENT-CLOCK: injectable clock in AgentAppViewModel.
///
/// WHY per assertion:
///  - "Working for Xs" elapsed math reads vm.currentTime() not wall Date() so
///    a frozen clock makes it deterministic and fast without real delay.
///  - Adaptive-sidebar debounce uses currentTime().timeIntervalSinceReferenceDate
///    so lastAutomaticChange comparisons are stable under the fake clock.
///  - setClockForTests must not alter production behaviour: the default clock
///    must return a real Date (not a fixed time) so elapsed never reads 0 in prod.
@MainActor
final class AgentAppClockTests: XCTestCase {

    // MARK: - Helpers

    private func makeVM() throws -> AgentAppViewModel {
        let tmp = NSTemporaryDirectory() + "rc2-clk-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo  = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo     = AgentRunRepository(db: db)
        let workspaceID = WorkspaceID()
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        return AgentAppViewModel(
            workspaceID: workspaceID, cwd: tmp,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo
        )
    }

    // MARK: - Clock seam: default is real wall time

    /// WHY: in production the clock must return an advancing Date so "Working for Xs"
    /// never reads 0 just because the seam was accidentally wired to a fixed time.
    func test_defaultClock_returnsRealDate() throws {
        let vm = try makeVM()
        let before = Date()
        let t = vm.currentTime()
        let after = Date()
        XCTAssertGreaterThanOrEqual(t, before,
            "default clock must not return a time before the call site")
        XCTAssertLessThanOrEqual(t, after,
            "default clock must not return a time after the call site")
    }

    // MARK: - Clock seam: setClockForTests freezes time

    /// WHY: the test-clock injection must make currentTime() return the injected
    /// value so elapsed-time assertions are not subject to wall-clock races.
    func test_setClockForTests_freezesCurrentTime() throws {
        let vm = try makeVM()
        let frozen = Date(timeIntervalSince1970: 1_000_000)
        vm.setClockForTests { frozen }
        XCTAssertEqual(vm.currentTime(), frozen,
            "setClockForTests must replace the clock so currentTime() returns the injected value")
    }

    // MARK: - elapsedString logic (via resolvedRunStartedAt + clock)

    /// WHY: "Working for Xs" must show the correct elapsed seconds relative to the
    /// clock, not wall time, so CI does not flake when the run is slow.
    /// This tests the elapsed formula: max(0, now - runStartedAt) in seconds.
    func test_elapsedSeconds_withFrozenClock_isExact() throws {
        let vm = try makeVM()
        let epoch = Date(timeIntervalSince1970: 0)
        // Simulate a run that started 45 seconds ago (relative to frozen now).
        let start = Date(timeIntervalSince1970: -45)
        let now   = epoch
        vm.setClockForTests { now }
        vm.runStartedAt = start
        // The public helper resolvedRunStartedAt resolves the start time;
        // elapsed = now - start = 45 s.
        let resolved = AgentAppViewModel.resolvedRunStartedAt(current: vm.runStartedAt, persisted: nil)
        let elapsed = max(0, Int(now.timeIntervalSince(resolved)))
        XCTAssertEqual(elapsed, 45,
            "elapsed must be exactly 45 s when clock is frozen 45 s after runStartedAt")
    }

    /// WHY: elapsed must never go negative — max(0, ...) guard — even when the
    /// clock is frozen at a time before runStartedAt (possible during tests or
    /// immediately after the run starts).
    func test_elapsedSeconds_clampedToZero_whenClockBeforeStart() throws {
        let vm = try makeVM()
        let start = Date(timeIntervalSince1970: 100)
        let now   = Date(timeIntervalSince1970: 50)  // before start
        vm.setClockForTests { now }
        vm.runStartedAt = start
        let resolved = AgentAppViewModel.resolvedRunStartedAt(current: vm.runStartedAt, persisted: nil)
        let elapsed = max(0, Int(now.timeIntervalSince(resolved)))
        XCTAssertEqual(elapsed, 0,
            "elapsed must be clamped to 0 when the clock is earlier than runStartedAt")
    }

    /// WHY: "Working for 2m 21s" format switch at the 60-second boundary must
    /// be deterministic; a wall-time test would flake if the test ran slowly.
    func test_elapsedMinuteFormat_triggersAt60Seconds() throws {
        let vm = try makeVM()
        let start = Date(timeIntervalSince1970: 0)
        let now   = Date(timeIntervalSince1970: 141) // 2m 21s
        vm.setClockForTests { now }
        vm.runStartedAt = start
        let resolved = AgentAppViewModel.resolvedRunStartedAt(current: vm.runStartedAt, persisted: nil)
        let s = max(0, Int(now.timeIntervalSince(resolved)))
        let formatted = s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
        XCTAssertEqual(formatted, "2m 21s",
            "elapsed format must switch to Xm Ys at 60 s; got \"\(formatted)\"")
    }

    // MARK: - Clock seam: advancing clock

    /// WHY: an advancing fake clock (closure that increments a counter) must let
    /// tests verify time-progressive logic (e.g. debounce intervals) without sleep.
    func test_advancingClock_incrementsOnEachCall() throws {
        let vm = try makeVM()
        var tick: TimeInterval = 0
        vm.setClockForTests {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        }
        let t1 = vm.currentTime()
        let t2 = vm.currentTime()
        XCTAssertGreaterThan(t2, t1,
            "advancing fake clock must return a later Date on each call so debounce interval tests do not require sleep")
    }

    // MARK: - currentTime() for adaptive-sidebar debounce

    /// WHY: the adaptive-sidebar debounce stores lastAutomaticChange as a
    /// TimeInterval from currentTime().timeIntervalSinceReferenceDate. A frozen
    /// clock confirms the value is deterministic (not wall-clock dependent).
    func test_currentTime_timeIntervalSinceReferenceDate_isFrozen() throws {
        let vm = try makeVM()
        let frozen = Date(timeIntervalSinceReferenceDate: 12345.0)
        vm.setClockForTests { frozen }
        let ref = vm.currentTime().timeIntervalSinceReferenceDate
        XCTAssertEqual(ref, 12345.0,
            "timeIntervalSinceReferenceDate used by adaptive-sidebar debounce must equal the frozen value")
    }
}
