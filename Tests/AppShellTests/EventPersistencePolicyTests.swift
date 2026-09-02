import XCTest
import SocketServer
@testable import AppShell

final class EventPersistencePolicyTests: XCTestCase {
    @MainActor func test_surfaceOutputEventsAreLiveOnlyAndNotPersisted() {
        let output = EventBus.Event(seq: 1, kind: "surface.output", payload: .null, ts: 0)
        let lifecycle = EventBus.Event(seq: 2, kind: "surface.created", payload: .null, ts: 0)

        XCTAssertFalse(
            AppDelegate.shouldPersistEvent(output),
            "live terminal output is high-volume mirror data and must not write one persisted event per chunk during long commands"
        )
        XCTAssertTrue(
            AppDelegate.shouldPersistEvent(lifecycle),
            "state/lifecycle events still need persistence so reconnect and restart behavior remains intact"
        )
        XCTAssertFalse(
            AppDelegate.shouldRetainRecentEvent(output),
            "live terminal output must not keep 512 large base64 batches in EventBus recent memory"
        )
        XCTAssertTrue(
            AppDelegate.shouldRetainRecentEvent(lifecycle),
            "non-output lifecycle events still need replay for reconnecting clients"
        )
    }

    @MainActor func test_agentStreamChunksAreLiveOnlyAndNotPersisted() {
        let delta = EventBus.Event(seq: 3, kind: "agent.item.delta", payload: .null, ts: 0)
        let progress = EventBus.Event(seq: 4, kind: "agent.item.progress", payload: .null, ts: 0)
        let started = EventBus.Event(seq: 5, kind: "agent.item.started", payload: .null, ts: 0)
        let completed = EventBus.Event(seq: 6, kind: "agent.item.completed", payload: .null, ts: 0)

        XCTAssertFalse(
            AppDelegate.shouldPersistEvent(delta),
            "item.delta is token-rate stream data; EventLog append is sync SQLite+prune and must not run per chunk"
        )
        XCTAssertFalse(
            AppDelegate.shouldPersistEvent(progress),
            "item.progress is the same high-frequency stream class as item.delta"
        )
        XCTAssertTrue(
            AppDelegate.shouldPersistEvent(started),
            "item start is lifecycle and must still persist for restart/replay"
        )
        XCTAssertTrue(
            AppDelegate.shouldPersistEvent(completed),
            "item complete is lifecycle and must still persist for restart/replay"
        )
        XCTAssertTrue(
            AppDelegate.shouldRetainRecentEvent(delta),
            "in-session iOS reconnect still needs the recent ring to catch missed tokens"
        )
        XCTAssertTrue(
            AppDelegate.shouldRetainRecentEvent(progress),
            "progress stays in the recent ring for live reconnect; only surface.output is dropped from memory"
        )
    }

    @MainActor func test_providerRuntimeEventsAreLiveOnlyAndNotPersisted() {
        let runtime = EventBus.Event(seq: 7, kind: "agent.provider_runtime.event", payload: .null, ts: 0)
        let started = EventBus.Event(seq: 8, kind: "agent.item.started", payload: .null, ts: 0)
        let completed = EventBus.Event(seq: 9, kind: "agent.item.completed", payload: .null, ts: 0)

        XCTAssertFalse(
            AppDelegate.shouldPersistEvent(runtime),
            "provider-runtime is already stored in agent_provider_event_logs; the capped events table must not take one SQLite write per ~5 Hz diagnostic"
        )
        XCTAssertTrue(
            AppDelegate.shouldRetainRecentEvent(runtime),
            "in-session iOS reconnect still needs the recent ring; only surface.output is dropped from memory"
        )
        XCTAssertTrue(
            AppDelegate.shouldPersistEvent(started),
            "item start is lifecycle and must still persist for restart/replay"
        )
        XCTAssertTrue(
            AppDelegate.shouldPersistEvent(completed),
            "item complete is lifecycle and must still persist for restart/replay"
        )
    }
}
