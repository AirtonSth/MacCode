import XCTest
import SocketServer
@testable import AppShell

/// MOR-02: `bot.run.stream` fires once per token of a Bot answer and carries
/// no state. Persisting it wrote one event-log row per token (5000-row cap,
/// so real history was pruned) and left a durable write pending for each.
/// The run's lifecycle events are what a reconnecting phone needs.
final class BotRunStreamPersistencePolicyTests: XCTestCase {
    @MainActor func test_botRunStreamIsLiveOnly_andTerminalBotEventsStillPersist() {
        let stream = EventBus.Event(seq: 1, kind: "bot.run.stream", payload: .null, ts: 0)
        let started = EventBus.Event(seq: 2, kind: "bot.run.started", payload: .null, ts: 0)
        let completed = EventBus.Event(seq: 3, kind: "bot.run.completed", payload: .null, ts: 0)
        let failed = EventBus.Event(seq: 4, kind: "bot.run.failed", payload: .null, ts: 0)

        XCTAssertFalse(
            AppDelegate.shouldPersistEvent(stream),
            "a per-token liveness tick must not become an event-log row"
        )
        XCTAssertTrue(
            AppDelegate.shouldRetainRecentEvent(stream),
            "the recent ring still carries it for an in-session reconnect"
        )
        for lifecycle in [started, completed, failed] {
            XCTAssertTrue(
                AppDelegate.shouldPersistEvent(lifecycle),
                "\(lifecycle.kind) is the durable outcome of the run"
            )
        }
    }
}
