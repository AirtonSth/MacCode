import XCTest
@testable import AgentRuntime

/// The Distill/Grok turn watchdog keeps one timer per turn and only moves its
/// deadline per stream event. WHY: it must keep the old inactivity semantics
/// exactly: never fire while events keep arriving (long goals run for hours),
/// fire once a full window after the last event, and never fire once cancelled.
final class ACPTurnInactivityDeadlineTests: XCTestCase {
    private final class Fires: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [UInt64] = []
        func record() { lock.withLock { times.append(DispatchTime.now().uptimeNanoseconds) } }
        var all: [UInt64] { lock.withLock { times } }
    }

    /// Polls instead of sleeping a fixed time: a loaded host may wake the timer late.
    private func waitForFires(_ fires: Fires, count: Int, within seconds: TimeInterval = 5) async throws {
        let end = Date().addingTimeInterval(seconds)
        while fires.all.count < count, Date() < end {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_refreshesKeepItQuietThenItFiresOnceAWindowAfterTheLastOne() async throws {
        // A 1 s window against 50 ms refreshes leaves a 20x margin, so one late
        // Task.sleep wake on a host loaded by parallel worktrees cannot open a
        // real quiet gap and fire legitimately.
        let timeout: TimeInterval = 1
        let fires = Fires()
        let deadline = ACPTurnInactivityDeadline(timeout: timeout) { fires.record() }
        defer { deadline.cancel() }
        var lastRefresh: UInt64 = 0
        var longestGap: UInt64 = 0
        for _ in 0..<24 {  // ~1.2 s of activity, longer than the window
            deadline.refresh()
            let now = DispatchTime.now().uptimeNanoseconds
            if lastRefresh != 0 { longestGap = max(longestGap, now &- lastRefresh) }
            lastRefresh = now
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if Double(longestGap) / 1_000_000_000 >= timeout * 0.9 {
            throw XCTSkip("host stalled \(longestGap / 1_000_000) ms between refreshes; a fire would be legitimate")
        }
        XCTAssertTrue(fires.all.isEmpty, "activity inside the window must not fire")

        try await waitForFires(fires, count: 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fires.all.count, 1, "quiet past the window fires exactly once")
        let quiet = Double((fires.all.first ?? 0) &- lastRefresh) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(quiet, timeout - 0.01, "it must wait a full window after the last event")
    }

    func test_refreshAfterExpiryArmsAgainAndCancelSilencesIt() async throws {
        let fires = Fires()
        let deadline = ACPTurnInactivityDeadline(timeout: 0.05) { fires.record() }
        deadline.refresh()
        try await waitForFires(fires, count: 1)
        XCTAssertEqual(fires.all.count, 1)
        deadline.refresh()
        try await waitForFires(fires, count: 2)
        XCTAssertEqual(fires.all.count, 2, "a refresh after expiry must arm a new window")

        deadline.refresh()
        deadline.cancel()
        deadline.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fires.all.count, 2, "a cancelled watchdog must never fire")
    }
}
