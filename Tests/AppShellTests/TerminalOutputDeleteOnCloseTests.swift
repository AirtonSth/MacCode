import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence
@testable import Surfaces

/// Verify that closing a surface (or workspace) deletes its persisted
/// terminal_output_chunks rows, and that a live surface retains its chunks.
///
/// WHY this matters: TerminalOutputRepository.delete(surfaceID:) had zero
/// production callers before this fix; the table grew unbounded. These tests
/// pin the invariant that closeSurface / closeWorkspace are the delete triggers.
@MainActor
final class TerminalOutputDeleteOnCloseTests: XCTestCase {

    // MARK: - Setup helpers

    private func makeContext() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "RC2TermDeleteTest-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    /// Insert a few chunks so there is measurable stored data for `surfaceID`.
    /// Live PTY writers start near chunk 1 after prepare; reserve a high band so
    /// fixture inserts cannot UNIQUE-collide with concurrent shell output.
    private func seedChunks(repo: TerminalOutputRepository, surfaceID: String, count: Int = 3) throws {
        let base: Int64 = 100_000
        for i in 0..<count {
            try repo.append(
                surfaceID: surfaceID,
                workspaceID: nil,
                chunkIndex: base + Int64(i),
                data: Data("chunk\(i)".utf8)
            )
        }
    }

    private func waitForTotalBytes(
        _ expected: Int,
        repo: TerminalOutputRepository,
        surfaceID: String,
        timeout: TimeInterval = 2
    ) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var bytes = try repo.totalBytes(surfaceID: surfaceID)
        while bytes != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            bytes = try repo.totalBytes(surfaceID: surfaceID)
        }
        return bytes
    }

    override func tearDown() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        super.tearDown()
    }

    // MARK: - closeSurface deletes chunks

    func test_closeSurface_deletesTerminalChunksForClosedSurface() throws {
        // WHY: the closed surface's history has no owner once removed from the
        // layout; keeping it leaks storage proportional to usage lifetime.
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())

        // Terminal history cleanup is type-specific; create an explicit terminal
        // tab rather than relying on the default Agent App surface.
        let descriptor = try router.createSurface(
            workspace: ws.id,
            type: .terminal,
            paneID: nil,
            title: "history-terminal"
        )
        let surfaceID = descriptor.id.value.uuidString
        let repo = ctx.terminalOutputRepo

        try seedChunks(repo: repo, surfaceID: surfaceID)
        XCTAssertGreaterThan(try repo.totalBytes(surfaceID: surfaceID), 0,
                             "pre-condition: chunks must be present before close")

        try router.closeSurface(workspace: ws.id, surface: descriptor.id)

        XCTAssertEqual(try waitForTotalBytes(0, repo: repo, surfaceID: surfaceID), 0,
                       "closeSurface must delete all terminal_output_chunks for the closed surface")
    }

    func test_closeConnectedSSHSurfaceDeletesOuterIDHistoryAfterEmbeddedWriter() async throws {
        // WHY: SSHSurface owns an unregistered TerminalSurface. Closing only the
        // outer object must still serialize final deletion behind that inner writer.
        let (ctx, router) = try makeContext()
        let workspace = try router.createWorkspace(name: "ssh", cwd: NSTemporaryDirectory())
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .ssh,
            paneID: nil,
            title: "ssh"
        )
        let ssh = try XCTUnwrap(SurfaceRegistry.shared.surface(descriptor.id) as? SSHSurface)
        await ssh.connectImmediatelyForTesting(
            SSHHostProfile(label: "Local refusal", destination: "127.0.0.1", port: 1)
        )

        try seedChunks(
            repo: ctx.terminalOutputRepo,
            surfaceID: descriptor.id.value.uuidString
        )
        ssh.appendSystemText(String(repeating: "x", count: 70 * 1024))

        try router.closeSurface(workspace: workspace.id, surface: descriptor.id)

        XCTAssertEqual(
            try waitForTotalBytes(
                0,
                repo: ctx.terminalOutputRepo,
                surfaceID: descriptor.id.value.uuidString
            ),
            0,
            "closing the registered SSH wrapper must leave no history rows that its embedded writer can resurrect"
        )
    }

    func test_appTerminationJoinsUnregisteredTabDeleteAndRetriesLockedSQLiteUntilRowsAndSidecarAreGone() async throws {
        // WHY: closeSurface unregisters the tab immediately. If its queued final
        // DELETE hits a transient SQLite lock, application termination can no
        // longer discover the surface and exits with orphan rows plus its C80
        // failure anchor unless the delete owns a process-global barrier.
        let (context, router) = try makeContext()
        try context.db.execute("PRAGMA busy_timeout=25;")
        let workspace = try router.createWorkspace(name: "pending delete", cwd: NSTemporaryDirectory())
        // Terminal history cleanup is type-specific; create an explicit terminal
        // tab rather than relying on the default Agent App surface.
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "pending delete"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let readyDeadline = Date().addingTimeInterval(2)
        while surface.historyWriterGenerationForTesting == nil, Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let writerGeneration = try XCTUnwrap(surface.historyWriterGenerationForTesting)
        let surfaceID = descriptor.id.value.uuidString
        try seedChunks(repo: context.terminalOutputRepo, surfaceID: surfaceID)
        try context.terminalOutputRepo.recordFailureAnchor(
            surfaceID: surfaceID,
            writerGeneration: writerGeneration,
            reason: "delete_pending_fixture",
            minimumNextChunkIndex: 1
        )
        XCTAssertFalse(try context.terminalOutputRepo.failureAnchors(surfaceID: surfaceID).isEmpty)

        let lockDatabase = try SQLiteDB(path: context.db.path)
        try lockDatabase.execute("BEGIN IMMEDIATE;")
        let lockBox = SendableSQLiteBox(lockDatabase)
        try router.closeSurface(workspace: workspace.id, surface: descriptor.id)
        XCTAssertNil(SurfaceRegistry.shared.surface(descriptor.id), "fixture must remove the surface before quit")
        let lockReleased = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            try? lockBox.database.execute("ROLLBACK;")
            lockReleased.signal()
        }

        let completed = closeSurfacesForApplicationTermination([], timeout: 2)

        XCTAssertTrue(completed, "quit must join the ownerless final-delete barrier")
        XCTAssertEqual(
            lockReleased.wait(timeout: .now()),
            .success,
            "the real quit helper must not return before the locked ownerless delete can resume"
        )
        XCTAssertEqual(
            try context.terminalOutputRepo.totalBytes(surfaceID: surfaceID),
            0,
            "the retried final DELETE must remove all SQLite history rows before quit returns"
        )
        XCTAssertTrue(
            try context.terminalOutputRepo.failureAnchors(surfaceID: surfaceID).isEmpty,
            "confirmed final deletion must also clear every C80 sidecar anchor"
        )
    }

    func test_appTerminationJoinsUnregisteredDeleteAlreadyQueuedBehindLiveClear() async throws {
        // WHY: close can arrive while a reusable clear owns the serial writer.
        // The surface is then unregistered before clear completion. Final delete
        // must already be globally joinable and must not depend on a later weak
        // MainActor callback retaining the retired coordinator.
        let (context, router) = try makeContext()
        let workspace = try router.createWorkspace(
            name: "pending delete behind clear",
            cwd: NSTemporaryDirectory()
        )
        // Terminal history cleanup is type-specific; create an explicit terminal
        // tab rather than relying on the default Agent App surface.
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "pending delete behind clear"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let readyDeadline = Date().addingTimeInterval(2)
        while surface.historyWriterGenerationForTesting == nil, Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let writerGeneration = try XCTUnwrap(surface.historyWriterGenerationForTesting)
        let surfaceID = descriptor.id.value.uuidString
        try seedChunks(repo: context.terminalOutputRepo, surfaceID: surfaceID)
        try context.terminalOutputRepo.recordFailureAnchor(
            surfaceID: surfaceID,
            writerGeneration: writerGeneration,
            reason: "delete_behind_clear_fixture",
            minimumNextChunkIndex: 1
        )

        let clearStarted = DispatchSemaphore(value: 0)
        let allowClear = DispatchSemaphore(value: 0)
        let clearReleased = DispatchSemaphore(value: 0)
        surface.setBeforeLiveHistoryClearForTesting {
            clearStarted.signal()
            _ = allowClear.wait(timeout: .now() + 3)
            clearReleased.signal()
        }
        router.surfaceClearHistory(surface: descriptor.id)
        XCTAssertEqual(clearStarted.wait(timeout: .now() + 2), .success)

        try router.closeSurface(workspace: workspace.id, surface: descriptor.id)
        XCTAssertNil(SurfaceRegistry.shared.surface(descriptor.id))
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            allowClear.signal()
        }

        let completed = closeSurfacesForApplicationTermination([], timeout: 2)

        XCTAssertTrue(completed, "quit must join a final delete queued behind live clear")
        XCTAssertEqual(
            clearReleased.wait(timeout: .now()),
            .success,
            "quit must not return before the blocked serial history queue resumes"
        )
        XCTAssertEqual(try context.terminalOutputRepo.totalBytes(surfaceID: surfaceID), 0)
        XCTAssertTrue(try context.terminalOutputRepo.failureAnchors(surfaceID: surfaceID).isEmpty)
    }

    func test_failedFinalDeleteRemainsGloballyRetryableAfterFastWindow() async throws {
        // WHY: the first app-close observation may hit the coordinator's
        // bounded two-second SQLite window. Dropping that failed disposition
        // makes a later real quit report success while rows and C80 metadata
        // remain orphaned after the tab has already been unregistered.
        let (context, router) = try makeContext()
        try context.db.execute("PRAGMA busy_timeout=25;")
        let workspace = try router.createWorkspace(
            name: "retained failed delete",
            cwd: NSTemporaryDirectory()
        )
        // Terminal history cleanup is type-specific; create an explicit terminal
        // tab rather than relying on the default Agent App surface.
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "retained failed delete"
        )
        let surface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let readyDeadline = Date().addingTimeInterval(2)
        while surface.historyWriterGenerationForTesting == nil, Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let writerGeneration = try XCTUnwrap(surface.historyWriterGenerationForTesting)
        let surfaceID = descriptor.id.value.uuidString
        try seedChunks(repo: context.terminalOutputRepo, surfaceID: surfaceID)
        try context.terminalOutputRepo.recordFailureAnchor(
            surfaceID: surfaceID,
            writerGeneration: writerGeneration,
            reason: "retained_failed_delete_fixture",
            minimumNextChunkIndex: 1
        )

        let lockDatabase = try SQLiteDB(path: context.db.path)
        try lockDatabase.execute("BEGIN IMMEDIATE;")
        let lockBox = SendableSQLiteBox(lockDatabase)
        try router.closeSurface(workspace: workspace.id, surface: descriptor.id)
        XCTAssertNil(SurfaceRegistry.shared.surface(descriptor.id))

        XCTAssertFalse(
            closeSurfacesForApplicationTermination([], timeout: 3),
            "the first bounded disposition must report the persistent lock"
        )
        XCTAssertGreaterThan(try context.terminalOutputRepo.totalBytes(surfaceID: surfaceID), 0)
        XCTAssertFalse(try context.terminalOutputRepo.failureAnchors(surfaceID: surfaceID).isEmpty)

        let lockReleased = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            try? lockBox.database.execute("ROLLBACK;")
            lockReleased.signal()
        }
        XCTAssertTrue(
            closeSurfacesForApplicationTermination([], timeout: 2),
            "a later quit pass must retry the retained disposition after unlock"
        )
        XCTAssertEqual(lockReleased.wait(timeout: .now()), .success)
        XCTAssertEqual(try context.terminalOutputRepo.totalBytes(surfaceID: surfaceID), 0)
        XCTAssertTrue(try context.terminalOutputRepo.failureAnchors(surfaceID: surfaceID).isEmpty)
    }

    func test_pendingDeleteRegistrySaturationNeverDropsThe513thDurableDelete() throws {
        // WHY: the registry cap is a worker bound, not permission to forget a
        // closed tab. Every overflow disposition must remain durably owned and
        // become joinable after the first 512 locked attempts drain.
        let (context, _) = try makeContext()
        try context.db.execute("PRAGMA busy_timeout=25;")
        let surfaceIDs = (0...512).map { _ in SurfaceID().value.uuidString }
        for surfaceID in surfaceIDs {
            try context.terminalOutputRepo.append(
                surfaceID: surfaceID,
                workspaceID: nil,
                chunkIndex: 1,
                data: Data("pending-delete".utf8)
            )
        }

        let registeredSurfaceCount = SurfaceRegistry.shared.all().count
        let lockDatabase = try SQLiteDB(path: context.db.path)
        try lockDatabase.execute("BEGIN IMMEDIATE;")
        for surfaceID in surfaceIDs {
            TerminalSurface.scheduleOwnerlessHistoryDelete(
                repository: context.terminalOutputRepo,
                surfaceID: surfaceID
            )
        }
        try lockDatabase.execute("ROLLBACK;")

        XCTAssertTrue(
            closeSurfacesForApplicationTermination([], timeout: 10),
            "quit must join durable overflow after worker slots become available"
        )
        for surfaceID in surfaceIDs {
            XCTAssertEqual(
                try context.terminalOutputRepo.totalBytes(surfaceID: surfaceID),
                0,
                "every accepted close, including number 513, must delete its SQLite history"
            )
        }
        XCTAssertEqual(
            SurfaceRegistry.shared.all().count,
            registeredSurfaceCount,
            "pending delete ownership must not retain or create Surface instances"
        )
    }

    func test_pendingDeleteReplaysAfterProcessMemoryLossWithoutDeletingSuccessor() async throws {
        // WHY: a real quit can exhaust its two-second lock window after the tab
        // already left the layout. Process memory then disappears, so only a
        // durable tombstone can finish cleanup on the next launch.
        let appSupport = NSTemporaryDirectory()
            + "RC2TermDeleteRelaunch-" + UUID().uuidString
        var context: AppContext? = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport
        )
        try context?.db.execute("PRAGMA busy_timeout=25;")
        let databasePath = try XCTUnwrap(context?.db.path)
        var router: AppCommandRouter? = AppCommandRouter(context: try XCTUnwrap(context))
        context?.router = router
        let workspace = try XCTUnwrap(router).createWorkspace(
            name: "durable pending delete",
            cwd: NSTemporaryDirectory()
        )
        // Terminal history cleanup is type-specific; create an explicit terminal
        // tab rather than relying on the default Agent App surface.
        let firstDescriptor = try XCTUnwrap(router).createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "durable pending delete"
        )
        let secondDescriptor = try XCTUnwrap(router).createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "successor guard"
        )
        var firstSurface = SurfaceRegistry.shared.surface(firstDescriptor.id) as? TerminalSurface
        var secondSurface = SurfaceRegistry.shared.surface(secondDescriptor.id) as? TerminalSurface
        let readyDeadline = Date().addingTimeInterval(3)
        while (firstSurface?.historyWriterGenerationForTesting == nil
                || secondSurface?.historyWriterGenerationForTesting == nil),
              Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstGeneration = try XCTUnwrap(firstSurface?.historyWriterGenerationForTesting)
        let secondGeneration = try XCTUnwrap(secondSurface?.historyWriterGenerationForTesting)
        let firstID = firstDescriptor.id.value.uuidString
        let secondID = secondDescriptor.id.value.uuidString
        let repository = try XCTUnwrap(context?.terminalOutputRepo)
        try seedChunks(repo: repository, surfaceID: firstID)
        try seedChunks(repo: repository, surfaceID: secondID)
        for (surfaceID, generation) in [
            (firstID, firstGeneration),
            (secondID, secondGeneration),
        ] {
            try repository.recordFailureAnchor(
                surfaceID: surfaceID,
                writerGeneration: generation,
                reason: "process_exit_pending_delete",
                minimumNextChunkIndex: 1
            )
        }

        let lockDatabase = try SQLiteDB(path: databasePath)
        try lockDatabase.execute("BEGIN IMMEDIATE;")
        try XCTUnwrap(router).closeSurface(
            workspace: workspace.id,
            surface: firstDescriptor.id
        )
        try XCTUnwrap(router).closeSurface(
            workspace: workspace.id,
            surface: secondDescriptor.id
        )
        XCTAssertFalse(
            closeSurfacesForApplicationTermination([], timeout: 3),
            "fixture must exhaust the real quit deadline while SQLite is locked"
        )

        TerminalHistoryCoordinator.resetPendingFinalDeleteMemoryForTesting()
        firstSurface = nil
        secondSurface = nil
        context?.router = nil
        router = nil
        context = nil
        try lockDatabase.execute("ROLLBACK;")

        let successorDatabase = try SQLiteDB(path: databasePath)
        let successorRepository = TerminalOutputRepository(db: successorDatabase)
        let successorGeneration = try successorRepository.clearForReuse(
            surfaceID: secondID,
            expectedWriterGeneration: secondGeneration
        )
        let successorMarker = Data("SUCCESSOR_MUST_SURVIVE".utf8)
        try successorRepository.append(
            surfaceID: secondID,
            workspaceID: workspace.id.value.uuidString,
            chunkIndex: 1,
            data: successorMarker
        )

        let relaunchedContext = try AppContext(
            channel: .debug,
            dbPathOverride: databasePath,
            appSupportOverride: appSupport
        )
        let replayDeadline = Date().addingTimeInterval(5)
        while Date() < replayDeadline {
            if try relaunchedContext.terminalOutputRepo.totalBytes(surfaceID: firstID) == 0,
               try relaunchedContext.terminalOutputRepo.failureAnchors(surfaceID: firstID).isEmpty,
               try relaunchedContext.terminalOutputRepo.failureAnchors(surfaceID: secondID).isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(
            try relaunchedContext.terminalOutputRepo.totalBytes(surfaceID: firstID),
            0,
            "launch replay must finish the ownerless delete after RAM state disappeared"
        )
        XCTAssertTrue(
            try relaunchedContext.terminalOutputRepo.failureAnchors(surfaceID: firstID).isEmpty
        )
        XCTAssertTrue(
            try relaunchedContext.terminalOutputRepo.failureAnchors(surfaceID: secondID).isEmpty,
            "stale delete replay must clean only its retired generation metadata"
        )
        let successorPreparation = try relaunchedContext.terminalOutputRepo.prepareHistory(
            surfaceID: secondID
        )
        XCTAssertEqual(successorPreparation.writerGeneration, successorGeneration)
        XCTAssertTrue(
            try relaunchedContext.terminalOutputRepo.readWindow(surfaceID: secondID).text
                .contains(String(decoding: successorMarker, as: UTF8.self)),
            "relaunch replay must never delete a newer writer generation"
        )
    }

    func test_surfaceClearHistory_deletesTerminalChunksForLiveSurface() throws {
        // WHY: the public surface.clear_history RPC promises to clear terminal
        // history. Sending Ctrl-L alone only clears the viewport; old chunks
        // must also disappear from read_history and persisted storage.
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())

        let descriptor = try router.createSurface(
            workspace: ws.id,
            type: .terminal,
            paneID: nil,
            title: "clear-history-terminal"
        )
        let surfaceID = descriptor.id.value.uuidString
        let repo = ctx.terminalOutputRepo

        try seedChunks(repo: repo, surfaceID: surfaceID)
        XCTAssertGreaterThan(try repo.totalBytes(surfaceID: surfaceID), 0,
                             "pre-condition: chunks must be present before clear_history")

        router.surfaceClearHistory(surface: descriptor.id)

        let deadline = Date().addingTimeInterval(2)
        var persisted = try repo.readWindow(surfaceID: surfaceID).text
        while persisted.contains("chunk0"), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            persisted = try repo.readWindow(surfaceID: surfaceID).text
        }
        XCTAssertFalse(
            persisted.contains("chunk0"),
            "surfaceClearHistory must remove the pre-clear prefix while the reusable live writer may persist newer shell output"
        )
    }

    // MARK: - closeSurface does not delete chunks for other surfaces

    func test_closeSurface_doesNotDeleteChunksForLiveSurface() throws {
        // WHY: deleting another surface's history would silently erase scrollback
        // that is still visible in the app.
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())

        // Open a second terminal surface.
        let desc2 = try router.createSurface(workspace: ws.id, type: .terminal, paneID: nil, title: "t2")
        guard case .pane(let pane) = ctx.state.workspaces[ws.id]?.layout,
              let desc1 = pane.surfaces.first(where: { $0.id != desc2.id }) else {
            return XCTFail("expected two surfaces")
        }

        let repo = ctx.terminalOutputRepo
        let sid1 = desc1.id.value.uuidString
        let sid2 = desc2.id.value.uuidString

        try seedChunks(repo: repo, surfaceID: sid1)
        try seedChunks(repo: repo, surfaceID: sid2)

        // Close only the first surface.
        try router.closeSurface(workspace: ws.id, surface: desc1.id)

        XCTAssertEqual(try waitForTotalBytes(0, repo: repo, surfaceID: sid1), 0,
                       "closed surface chunks must be deleted")
        XCTAssertGreaterThan(try repo.totalBytes(surfaceID: sid2), 0,
                             "live surface chunks must not be deleted when a different surface is closed")
    }

    // MARK: - closeWorkspace deletes chunks for all its surfaces

    func test_closeWorkspace_deletesChunksForAllSurfacesInWorkspace() throws {
        // WHY: closing the workspace removes all its surfaces from the layout at
        // once; each surface's history must be cleaned up just as if each was
        // individually closed.
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())

        // Add a second surface so the workspace has two surfaces to delete.
        let desc2 = try router.createSurface(workspace: ws.id, type: .terminal, paneID: nil, title: "t2")
        guard case .pane(let pane) = ctx.state.workspaces[ws.id]?.layout,
              let desc1 = pane.surfaces.first(where: { $0.id != desc2.id }) else {
            return XCTFail("expected two surfaces")
        }

        let repo = ctx.terminalOutputRepo
        let sid1 = desc1.id.value.uuidString
        let sid2 = desc2.id.value.uuidString

        try seedChunks(repo: repo, surfaceID: sid1)
        try seedChunks(repo: repo, surfaceID: sid2)

        try router.closeWorkspace(ws.id)

        XCTAssertEqual(try waitForTotalBytes(0, repo: repo, surfaceID: sid1), 0,
                       "closeWorkspace must delete chunks for every surface it contained")
        XCTAssertEqual(try waitForTotalBytes(0, repo: repo, surfaceID: sid2), 0,
                       "closeWorkspace must delete chunks for every surface it contained")
    }

    // MARK: - live surface keeps chunks while another is closed

    func test_liveWorkspaceSurface_retainsChunksWhenOtherWorkspaceClosed() throws {
        // WHY: deleting chunks scoped to the wrong workspace would silently
        // destroy history for open surfaces the user can still see.
        let (ctx, router) = try makeContext()
        let ws1 = try router.createWorkspace(name: "ws1", cwd: NSTemporaryDirectory())
        let ws2 = try router.createWorkspace(name: "ws2", cwd: NSTemporaryDirectory())

        guard case .pane(let pane1) = ctx.state.workspaces[ws1.id]?.layout,
              let desc1 = pane1.surfaces.first,
              case .pane(let pane2) = ctx.state.workspaces[ws2.id]?.layout,
              let desc2 = pane2.surfaces.first else {
            return XCTFail("expected one surface per workspace")
        }

        let repo = ctx.terminalOutputRepo
        let sid1 = desc1.id.value.uuidString
        let sid2 = desc2.id.value.uuidString

        try seedChunks(repo: repo, surfaceID: sid1)
        try seedChunks(repo: repo, surfaceID: sid2)

        // Close ws2 only.
        try router.closeWorkspace(ws2.id)

        XCTAssertGreaterThan(try repo.totalBytes(surfaceID: sid1), 0,
                             "ws1 surface chunks must survive when ws2 is closed")
        XCTAssertEqual(try waitForTotalBytes(0, repo: repo, surfaceID: sid2), 0,
                       "ws2 surface chunks must be deleted when ws2 is closed")
    }
}

private final class SendableSQLiteBox: @unchecked Sendable {
    let database: SQLiteDB

    init(_ database: SQLiteDB) {
        self.database = database
    }
}
