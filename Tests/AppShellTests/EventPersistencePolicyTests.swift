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
}
