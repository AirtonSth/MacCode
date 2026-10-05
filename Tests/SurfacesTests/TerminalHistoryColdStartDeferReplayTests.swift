import XCTest

@testable import CoreModel
@testable import Persistence
@testable import Surfaces

/// PERF (cold launch): restored terminals must not auto-start SQLite history
/// replay on prepare completion. Weak Macs hang when many restored tabs each
/// read + Ghostty-reset during `reinstantiateRestoredSurfaces`. Demand paths
/// (`requestReplayIfNeeded`) unlock replay for the selected/read surface only.
@MainActor
final class TerminalHistoryColdStartDeferReplayTests: XCTestCase {
    func test_prepareRestoredWithDefer_doesNotAutoReplayUntilRequested() throws {
        // WHY: auto-replay on prepare is the multi-terminal cold-start fan-out.
        // Deferral must keep needsReplay pending and leave the renderer empty
        // until an explicit demand (visibility / transcript read).
        let database = try SQLiteDB(path: ":memory:")
        try Schema.migrate(database)
        let repository = TerminalOutputRepository(db: database)
        let surfaceID = SurfaceID().value.uuidString
        let workspaceID = WorkspaceID().value.uuidString
        let marker = Data("COLD_START_DEFER_MARKER\n".utf8)
        try repository.append(
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            chunkIndex: 1,
            data: marker
        )

        let delegate = DeferReplayDelegateSpy()
        let coordinator = TerminalHistoryCoordinator(
            repository: repository,
            surfaceID: surfaceID,
            workspaceID: workspaceID
        )
        coordinator.delegate = delegate
        coordinator.prepare(restored: true, deferReplay: true)

        try waitUntilReady(coordinator)
        XCTAssertTrue(
            coordinator.isReplayDeferredForTesting,
            "restored cold-start prepare must keep deferral latched until demand"
        )
        XCTAssertFalse(
            coordinator.replayInFlight,
            "deferred prepare must not start a concurrent history read"
        )

        // Passive replayIfNeeded must remain a no-op under deferral.
        coordinator.replayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            delegate.renderedData,
            Data(),
            "passive replay while deferred must not feed Ghostty/renderer"
        )
        XCTAssertTrue(coordinator.isReplayDeferredForTesting)

        coordinator.requestReplayIfNeeded()
        try waitUntilReplayIdle(coordinator)
        XCTAssertFalse(coordinator.isReplayDeferredForTesting)
        XCTAssertEqual(
            delegate.renderedData,
            marker + TerminalHistoryCoordinator.restoredModeReset,
            "demand replay must feed the persisted cold-start prefix once unlocked"
        )
    }

    func test_prepareRestoredWithoutDefer_stillAutoReplays() throws {
        // WHY: non-deferred restore (and tests that expect auto-replay) must
        // keep the previous prepare-complete → replay behavior.
        let database = try SQLiteDB(path: ":memory:")
        try Schema.migrate(database)
        let repository = TerminalOutputRepository(db: database)
        let surfaceID = SurfaceID().value.uuidString
        let workspaceID = WorkspaceID().value.uuidString
        let marker = Data("AUTO_REPLAY_STILL_WORKS\n".utf8)
        try repository.append(
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            chunkIndex: 1,
            data: marker
        )

        let delegate = DeferReplayDelegateSpy()
        let coordinator = TerminalHistoryCoordinator(
            repository: repository,
            surfaceID: surfaceID,
            workspaceID: workspaceID
        )
        coordinator.delegate = delegate
        coordinator.prepare(restored: true, deferReplay: false)

        try waitUntilReady(coordinator)
        try waitUntilReplayIdle(coordinator)
        XCTAssertFalse(coordinator.isReplayDeferredForTesting)
        XCTAssertEqual(
            delegate.renderedData,
            marker + TerminalHistoryCoordinator.restoredModeReset,
            "default prepare(restored:) must still auto-replay for non-deferred paths"
        )
    }

    func test_restoredTerminalSurfaceDefersHistoryReplayUntilVisible() throws {
        // WHY: TerminalSurface is the production wiring for reinstantiateRestoredSurfaces.
        // Restored tabs start hidden and must not demand-start history until selected.
        let database = try SQLiteDB(path: ":memory:")
        try Schema.migrate(database)
        let repository = TerminalOutputRepository(db: database)
        let restoredID = SurfaceID()
        let workspaceID = WorkspaceID()
        let marker = Data("SURFACE_DEFER_VISIBLE\n".utf8)
        try repository.append(
            surfaceID: restoredID.value.uuidString,
            workspaceID: workspaceID.value.uuidString,
            chunkIndex: 1,
            data: marker
        )

        let surface = try TerminalSurface(
            workspaceID: workspaceID,
            title: "deferred restore",
            launch: .shell(cwd: NSTemporaryDirectory()),
            restoredSurfaceID: restoredID,
            historyRepo: repository
        )
        defer { surface.close() }

        try waitUntilSurfaceHistoryReady(surface)
        XCTAssertTrue(
            surface.historyReplayDeferredForTesting,
            "restored TerminalSurface must wire prepare(deferReplay: true)"
        )

        surface.didBecomeVisible()
        XCTAssertFalse(
            surface.historyReplayDeferredForTesting,
            "didBecomeVisible is the demand path that unlocks cold-start replay"
        )
    }

    // MARK: - Helpers

    private func waitUntilReady(
        _ coordinator: TerminalHistoryCoordinator,
        timeout: TimeInterval = 3
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .ready = coordinator.preparationStateForTesting { return }
            if case .failed = coordinator.preparationStateForTesting {
                XCTFail("prepare failed")
                throw WaitTimeout()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("timed out waiting for prepare ready")
        throw WaitTimeout()
    }

    private func waitUntilReplayIdle(
        _ coordinator: TerminalHistoryCoordinator,
        timeout: TimeInterval = 3
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !coordinator.replayInFlight,
               case .ready = coordinator.preparationStateForTesting {
                // Allow one more turn for main-async completeReplay.
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if !coordinator.replayInFlight { return }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("timed out waiting for replay idle")
        throw WaitTimeout()
    }

    private func waitUntilSurfaceHistoryReady(
        _ surface: TerminalSurface,
        timeout: TimeInterval = 3
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .ready = surface.historyPreparationStateForTesting { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("timed out waiting for surface history prepare")
        throw WaitTimeout()
    }

    private struct WaitTimeout: Error {}

    private final class DeferReplayDelegateSpy: TerminalHistoryCoordinatorDelegate {
        var renderedData = Data()
        var terminalHistoryIsClosing: Bool { false }

        func terminalHistoryCoordinator(
            _ coordinator: TerminalHistoryCoordinator,
            didEncounter issue: TerminalHistoryCoordinator.Issue
        ) {}

        func terminalHistoryCoordinator(
            _ coordinator: TerminalHistoryCoordinator,
            didPrepareReplay data: Data
        ) {
            renderedData = data
        }
    }
}
