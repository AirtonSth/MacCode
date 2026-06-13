import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Surfaces
import Persistence

/// PERF-MAC_APPSHELL_AGENT_LEAK — EventBus closure leak on AgentApp surface close.
///
/// WHY: Every AgentAppSurface subscribes to EventBus on creation (via AppCommandRouter).
/// Before this fix close() was a no-op, so the subscription — and its captured closure
/// referencing the VM's reloadThreads/reloadQueuedMessages paths — lived for the
/// app's lifetime.  Each create + close cycle leaked one more subscriber, proportional
/// to the number of surfaces ever opened/restored in a session.
///
/// Fix: close() calls onClose (set by AppCommandRouter to { EventBus.shared.unsubscribe(token) })
/// and nils onClose so no double-unsubscribe is possible.
@MainActor
final class AgentAppSurfaceSubscriptionLeakTests: XCTestCase {

    // MARK: - Helpers

    private func makeSurface() throws -> AgentAppSurface {
        let dir = NSTemporaryDirectory() + "RC2AgentLeak-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        return AgentAppSurface(
            workspaceID: WorkspaceID(),
            cwd: dir,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo
        )
    }

    // MARK: - Tests

    /// Subscribe count returns to baseline after create + close.
    /// WHY: before the fix close() was empty, so every surface leaked exactly
    /// one subscriber.  This test catches a regression where the unsubscribe is
    /// removed or never called.
    func test_close_unsubscribesEventBusToken() throws {
        let baseline = EventBus.shared.subscriberCountForTests

        let surface = try makeSurface()

        // Wire the subscription exactly as AppCommandRouter does.
        let token = EventBus.shared.subscribe(since: nil) { [weak surface] ev in
            guard ev.kind.hasPrefix("agent.thread.") else { return }
            DispatchQueue.main.async { surface?.viewModel.reloadThreads() }
        }
        surface.subscriptionToken = AnyHashable(token)
        surface.onClose = { EventBus.shared.unsubscribe(token) }

        XCTAssertEqual(
            EventBus.shared.subscriberCountForTests, baseline + 1,
            "after wiring the subscription, count must be baseline + 1"
        )

        // Tear down.
        surface.close()

        XCTAssertEqual(
            EventBus.shared.subscriberCountForTests, baseline,
            "after close(), the EventBus subscriber count must return to the pre-create baseline — leaking the subscription would leave count at baseline + 1"
        )
    }

    /// close() is idempotent: calling it twice must not double-unsubscribe
    /// (which would corrupt the subscriber map by removing an unrelated subscriber
    /// that acquired the recycled UUID in between the two calls).
    func test_close_isIdempotent() throws {
        let baseline = EventBus.shared.subscriberCountForTests

        let surface = try makeSurface()
        let token = EventBus.shared.subscribe(since: nil) { _ in }
        surface.subscriptionToken = AnyHashable(token)
        surface.onClose = { EventBus.shared.unsubscribe(token) }

        surface.close()
        surface.close()  // second call must be a no-op

        XCTAssertEqual(
            EventBus.shared.subscriberCountForTests, baseline,
            "calling close() twice must not produce a count below baseline — onClose must be nilled after the first call to prevent double-unsubscribe"
        )
    }

    /// A surface whose onClose was never set (e.g., test harness or partial init)
    /// must not crash on close().
    func test_close_noopWhenOnCloseNotSet() throws {
        let surface = try makeSurface()
        // onClose is intentionally not set.
        XCTAssertNoThrow(surface.close(),
                         "close() must be safe when onClose was never assigned — the optional chain must handle the nil case")
    }
}
