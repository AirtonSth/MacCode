import XCTest
@testable import SocketServer

/// IST-N1 / IST-04 / MHS-10: iOS closes the stream when no heartbeat-bearing
/// frame arrives within the negotiated timeout (30 s Wi-Fi, 90 s cellular),
/// and it counts only frames, not its own pongs. The host timer is one-shot:
/// after a ping it used to sleep until the hard timeout, and the pong (seen
/// on the read loop) never re-armed it, so an idle but healthy peer got its
/// next frame `timeout - interval` later (20 s / 65 s) instead of `interval`.
/// That left an unmodified iPhone a few seconds of margin on Wi-Fi.
final class WebSocketLivenessCadenceTests: XCTestCase {
    /// Runs the same loop as the `/v1/ws` heartbeat timer: act, re-arm the
    /// one-shot timer from `nextWakeDelay`, sleep. `peerAnswersPings` models
    /// the pong reaching the read loop after the timer was already re-armed.
    private func run(
        interval: TimeInterval,
        timeout: TimeInterval,
        peerAnswersPings: Bool,
        maxWakes: Int
    ) -> (frames: [TimeInterval], wakes: Int, timedOutAt: TimeInterval?) {
        let nonce = Data("nonce".utf8)
        let state = WebSocketLivenessState(now: 0, interval: interval, timeout: timeout, nonce: { nonce })
        var now: TimeInterval = 0
        var frames: [TimeInterval] = []
        var wakes = 0
        now += max(0.05, state.nextWakeDelay(now: now))
        while wakes < maxWakes {
            wakes += 1
            let action = state.nextAction(now: now)
            if action == .timedOut { return (frames, wakes, now) }
            let delay = max(0.05, state.nextWakeDelay(now: now))
            switch action {
            case .heartbeat:
                frames.append(now)
            case .ping:
                frames.append(now)
                if peerAnswersPings { state.noteInboundTraffic(now: now + 0.05) }
            case .none, .timedOut:
                break
            }
            now += delay
        }
        return (frames, wakes, nil)
    }

    func test_idlePeerThatAnswersPings_getsAHeartbeatEveryInterval() {
        for (interval, timeout) in [(10.0, 30.0), (25.0, 90.0)] {
            let result = run(interval: interval, timeout: timeout, peerAnswersPings: true, maxWakes: 20)
            XCTAssertNil(result.timedOutAt, "a peer that answers every ping is alive")
            XCTAssertGreaterThanOrEqual(result.frames.count, 10)
            XCTAssertEqual(result.frames.first ?? 0, interval, accuracy: 0.001)
            for (previous, next) in zip(result.frames, result.frames.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    next - previous,
                    interval + 0.001,
                    "the client deadline counts frames: (\(interval), \(timeout)) left a gap \(previous) -> \(next)"
                )
            }
        }
    }

    func test_silentPeer_stillTimesOutAtProofPlusTimeout_withBoundedWakes() {
        let result = run(interval: 10, timeout: 30, peerAnswersPings: false, maxWakes: 100)
        XCTAssertEqual(result.timedOutAt ?? -1, 30, accuracy: 0.001,
                       "the dead-peer deadline stays last proof + timeout")
        XCTAssertEqual(result.wakes, 3, "one wake per interval while a ping is outstanding, never a poll")
        XCTAssertEqual(result.frames, [10], "no heartbeat is sent on top of an unanswered ping")
    }
}
