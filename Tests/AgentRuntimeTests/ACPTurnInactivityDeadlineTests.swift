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

    func test_refreshesKeepItQuietThenItFiresOnceAWindowAfterTheLastOne() async throws {
        let fires = Fires()
        let deadline = ACPTurnInactivityDeadline(timeout: 0.2) { fires.record() }
        defer { deadline.cancel() }
        var lastRefresh: UInt64 = 0
        for _ in 0..<8 {  // 0.4 s of activity, twice the window
            deadline.refresh()
            lastRefresh = DispatchTime.now().uptimeNanoseconds
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(fires.all.isEmpty, "activity inside the window must not fire")

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(fires.all.count, 1, "quiet past the window fires exactly once")
        let quiet = Double((fires.all.first ?? 0) &- lastRefresh) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(quiet, 0.19, "it must wait a full window after the last event")
    }

    func test_refreshAfterExpiryArmsAgainAndCancelSilencesIt() async throws {
        let fires = Fires()
        let deadline = ACPTurnInactivityDeadline(timeout: 0.05) { fires.record() }
        deadline.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fires.all.count, 1)
        deadline.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fires.all.count, 2, "a refresh after expiry must arm a new window")

        deadline.refresh()
        deadline.cancel()
        deadline.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fires.all.count, 2, "a cancelled watchdog must never fire")
    }
}
