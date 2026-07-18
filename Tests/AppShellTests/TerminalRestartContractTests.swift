import XCTest
import Darwin
import AppKit

@testable import AppShell
@testable import CoreModel
@testable import Persistence
@testable import SocketServer
@testable import Surfaces

@MainActor
final class TerminalRestartContractTests: XCTestCase {
    private var temporaryDirectories: [String] = []

    override func tearDown() {
        let surfaces = SurfaceRegistry.shared.all()
        _ = closeSurfacesForApplicationTermination(surfaces, timeout: 2)
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        temporaryDirectories.forEach { try? FileManager.default.removeItem(atPath: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func test_applicationTerminationStartsAllBarriersWithoutNestedRunLoopReentrancy() {
        // WHY: RunLoop pumping on MainActor does not drain Swift executor jobs and
        // permits unrelated AppKit reentrancy. Quit must start every disposition,
        // fail loud at the common deadline, and return control without deadlock.
        var starts = 0
        let surfaces: [Surface] = [0.01, 0.03].map { delay in
            DelayedMainTerminationSurface(delay: delay) { starts += 1 }
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let completed = closeSurfacesForApplicationTermination(surfaces, timeout: 0.08)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertFalse(completed)
        XCTAssertEqual(starts, 2)
        XCTAssertGreaterThanOrEqual(elapsed, 0.06)
        XCTAssertLessThan(elapsed, 0.2)
    }

    func test_applicationTerminationUsesOneGlobalDeadline() {
        var starts = 0
        let surfaces: [Surface] = [0.01, 0.5].map { delay in
            DelayedMainTerminationSurface(delay: delay) { starts += 1 }
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let completed = closeSurfacesForApplicationTermination(surfaces, timeout: 0.06)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertFalse(completed)
        XCTAssertEqual(starts, 2)
        XCTAssertLessThan(elapsed, 0.15)
    }

    func test_applicationTerminationPersistsReaderTailPausedBeforePublicationWithoutMainActorDeadlock() async throws {
        // WHY: a PTY read can own bytes before it publishes them into the
        // handoff mailbox. Quit waits synchronously on MainActor, so completing
        // that handoff through main.async deadlocks until the global deadline
        // and loses the final terminal tail when the process exits.
        let (context, _) = try makeHarness(name: "quit-reader-prepublish")
        let surfaceID = SurfaceID()
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "Durable quit tail",
            launch: .shell(cwd: NSTemporaryDirectory()),
            assignedSurfaceID: surfaceID,
            historyRepo: context.terminalOutputRepo
        )
        let preparationDeadline = Date().addingTimeInterval(2)
        while Date() < preparationDeadline {
            if case .ready = surface.historyPreparationStateForTesting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .ready = surface.historyPreparationStateForTesting else {
            XCTFail("history must prepare before pausing the target read event")
            surface.close()
            return
        }
        let marker = "RC2_QUIT_PREPUBLISH_\(UUID().uuidString)"
        let readerPaused = DispatchSemaphore(value: 0)
        let allowPublication = DispatchSemaphore(value: 0)
        let oneShot = OneShotGate()
        let markerBytes = Data(marker.utf8)
        surface.setReaderWillPublishForTesting { output in
            guard output.range(of: markerBytes) != nil else { return }
            guard oneShot.claim() else { return }
            readerPaused.signal()
            _ = allowPublication.wait(timeout: .now() + 6)
        }
        XCTAssertEqual(
            surface.sendTextStatus("printf '\\n\(marker)\\n'; /bin/sleep 30\n"),
            .accepted
        )
        surface.drainInputPumpForTesting()
        XCTAssertEqual(
            readerPaused.wait(timeout: .now() + 5),
            .success,
            "fixture must pause after the PTY owns the marker bytes but before mailbox publication"
        )
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            allowPublication.signal()
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let completed = closeSurfacesForApplicationTermination([surface], timeout: 1.95)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertTrue(completed, "quit must not require main.async to persist an already-read PTY tail")
        XCTAssertLessThan(elapsed, 2, "quit must remain bounded below the app-exit deadline")
        let persisted = try TerminalOutputRepository(db: context.db).readWindow(
            surfaceID: surfaceID.value.uuidString
        ).text
        XCTAssertTrue(
            persisted.contains(marker),
            "the PTY tail owned before quit must be durable before the real termination helper returns"
        )
    }

    func test_coalescedRestartPreservesIdentityLayoutHistorySequenceAndEmitsNoLifecycleEvents() async throws {
        // WHY: iOS keys terminal state by surface ID and output sequence. A
        // close/create restart loses its cursor, layout owner, and scrollback.
        let (context, router) = try makeHarness(name: "success")
        let workspace = try router.createWorkspace(
            name: "Restart contract",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Restarted shell"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let oldPID = try XCTUnwrap(oldRuntime.runtimeHealth().childPID)
        let marker = "RC2_RESTART_HISTORY_\(UUID().uuidString)"
        oldRuntime.appendSystemText(marker + "\n")
        oldRuntime.flushPersistedHistory()
        SurfaceOutputBus.shared.flushNow(descriptor.id)
        let sequenceBefore = SurfaceOutputBus.shared.currentSequence(descriptor.id)
        let events = EventKindCapture(kinds: ["surface.closed", "surface.created"])
        defer { events.stop() }

        let first = Task { @MainActor in
            await router.restartSurfaceAndWaitForTesting(descriptor.id)
        }
        await Task.yield()
        let second = Task { @MainActor in
            await router.restartSurfaceAndWaitForTesting(descriptor.id)
        }
        let results = await [first.value, second.value]

        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(results.filter { !$0 }.count, 1)
        let replacement = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        XCTAssertFalse(replacement === oldRuntime)
        XCTAssertEqual(replacement.descriptor, descriptor)
        XCTAssertEqual(
            descriptorInLayout(
                context: context,
                workspaceID: workspace.id,
                surfaceID: descriptor.id
            ),
            descriptor
        )
        XCTAssertGreaterThanOrEqual(
            SurfaceOutputBus.shared.currentSequence(descriptor.id),
            sequenceBefore
        )
        let history = try await router.readTerminalHistory(
            surface: descriptor.id,
            beforeChunkID: nil,
            maxBytes: 256 * 1024
        )
        XCTAssertTrue(history.text.contains(marker))
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(waitpidOwnershipWasConsumed(oldPID))
        XCTAssertTrue(
            events.values.isEmpty,
            "runtime replacement under one ID must not masquerade as a closed/created tab"
        )
    }

    func test_restartDispositionFailureKeepsOriginalTabAndEmitsNoLifecycleEvents() async throws {
        // WHY: if durable history cannot drain, replacing the runtime would
        // create a new shell over an incomplete cursor. The old tab must remain
        // authoritative and retryable, without close/create mirror churn.
        let (context, router) = try makeHarness(name: "failure")
        try context.db.execute("PRAGMA busy_timeout=25;")
        let workspace = try router.createWorkspace(
            name: "Restart blocked",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Blocked restart"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let readyDeadline = Date().addingTimeInterval(1)
        while Date() < readyDeadline {
            if case .ready = oldRuntime.historyPreparationStateForTesting { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .ready = oldRuntime.historyPreparationStateForTesting else {
            XCTFail("terminal history must prepare before the persistent-lock fixture")
            return
        }

        let lockDatabase = try SQLiteDB(path: context.db.path)
        try lockDatabase.execute("BEGIN IMMEDIATE;")
        var lockHeld = true
        defer {
            if lockHeld { try? lockDatabase.execute("ROLLBACK;") }
        }
        oldRuntime.appendSystemText(String(repeating: "L", count: 64 * 1024))
        let events = EventKindCapture(kinds: ["surface.closed", "surface.created"])
        defer { events.stop() }

        let restarted = await router.restartSurfaceAndWaitForTesting(descriptor.id)

        XCTAssertFalse(restarted)
        XCTAssertTrue(SurfaceRegistry.shared.surface(descriptor.id) === oldRuntime)
        XCTAssertTrue(oldRuntime.runtimeHealth().processAlive)
        XCTAssertTrue(oldRuntime.runtimeHealth().inputAccepting)
        XCTAssertEqual(
            descriptorInLayout(
                context: context,
                workspaceID: workspace.id,
                surfaceID: descriptor.id
            ),
            descriptor
        )
        XCTAssertTrue(events.values.isEmpty)
        try lockDatabase.execute("ROLLBACK;")
        lockHeld = false

        let retrySucceeded = await router.restartSurfaceAndWaitForTesting(descriptor.id)
        XCTAssertTrue(retrySucceeded)
        XCTAssertFalse(SurfaceRegistry.shared.surface(descriptor.id) === oldRuntime)
        XCTAssertTrue(
            (SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface)?
                .runtimeHealth().processAlive == true
        )
        XCTAssertTrue(events.values.isEmpty)
    }

    func test_finalHistoryFailureAfterPreflightCommitsHealthyPartialReplacementAfterWriterStops() async throws {
        // WHY: the non-destructive preflight can succeed, then new output can
        // arrive while SQLite becomes locked. Once teardown finalizes the old
        // writer, leaving its dead runtime registered is worse than committing
        // the prepared shell with explicit partial-history health.
        let (context, router) = try makeHarness(name: "final-history-timeout")
        try context.db.execute("PRAGMA busy_timeout=25;")
        let workspace = try router.createWorkspace(
            name: "Final history timeout",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Single writer"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let readyDeadline = Date().addingTimeInterval(2)
        while oldRuntime.historyWriterGenerationForTesting == nil, Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try XCTUnwrap(
            oldRuntime.historyWriterGenerationForTesting
        )
        let lockDatabase = try SQLiteDB(path: context.db.path)
        var lockHeld = false
        defer {
            if lockHeld { try? lockDatabase.execute("ROLLBACK;") }
        }
        router.terminalRestartRuntimePreparerForTesting = { workspaceID, cwd, surfaceID in
            try? lockDatabase.execute("BEGIN IMMEDIATE;")
            lockHeld = true
            oldRuntime.appendSystemText(Data(repeating: 0x4C, count: 64 * 1024).base64EncodedString() + "\n")
            return TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspaceID,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }

        let restarted = await router.restartSurfaceAndWaitForTesting(descriptor.id)

        XCTAssertTrue(
            restarted,
            "an irreversible close must finish with the healthy prepared replacement"
        )
        let replacement = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        XCTAssertFalse(replacement === oldRuntime)
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(replacement.runtimeHealth().inputAccepting)
        XCTAssertTrue(replacement.runtimeHealth().outputPartial)
        XCTAssertEqual(
            replacement.runtimeHealth().outputPartialReason,
            "runtime_restart_history_incomplete"
        )
        let oldOutstanding = oldRuntime.historyOutstandingBytesForTesting
        oldRuntime.appendSystemText("late-old-writer-probe\n")
        XCTAssertEqual(
            oldRuntime.historyOutstandingBytesForTesting,
            oldOutstanding,
            "the finalized old writer must reject all post-close bytes"
        )
    }

    func test_renameDuringIrreversibleRestartCommitsHealthyReplacementWithCurrentDescriptor() async throws {
        // WHY: the process barrier yields the MainActor after the old PTY is
        // closed. A concurrent title update must not make descriptor equality
        // strand that closed runtime under the still-live surface ID.
        let (context, router) = try makeHarness(name: "rename-after-close")
        let workspace = try router.createWorkspace(
            name: "Rename after close",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Before restart"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let delayedDisposition = DispatchGroup()
        delayedDisposition.enter()
        var dispositionReleased = false
        defer {
            if !dispositionReleased { delayedDisposition.leave() }
        }
        oldRuntime.setRuntimeDispositionBarrierFactoryForTesting { _ in
            SurfaceTerminationBarrier(
                groups: [delayedDisposition],
                completionChecks: [{ true }]
            )
        }

        let restartTask = Task { @MainActor in
            await router.restartSurfaceAndWaitForTesting(descriptor.id)
        }
        let closeDeadline = Date().addingTimeInterval(2)
        while oldRuntime.runtimeHealth().processAlive, Date() < closeDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(oldRuntime.runtimeHealth().processAlive)
        try router.renameSurface(workspace.id, descriptor.id, "Renamed during restart")
        delayedDisposition.leave()
        dispositionReleased = true

        let restarted = await restartTask.value
        XCTAssertTrue(restarted)
        let replacement = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        XCTAssertFalse(replacement === oldRuntime)
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(replacement.runtimeHealth().inputAccepting)
        XCTAssertEqual(replacement.descriptor.title, "Renamed during restart")
        XCTAssertEqual(
            descriptorInLayout(
                context: context,
                workspaceID: workspace.id,
                surfaceID: descriptor.id
            )?.title,
            "Renamed during restart"
        )
    }

    func test_preparedChildKilledAfterIrreversibleCloseIsRepreparedBeforeCommit() async throws {
        // WHY: a prepared child can receive SIGKILL while the old runtime drains.
        // After the old PTY is gone, restart must prepare a fresh owned child
        // instead of returning with the dead old runtime still registered.
        let (_, router) = try makeHarness(name: "prepared-killed-after-close")
        let workspace = try router.createWorkspace(
            name: "Prepared child recovery",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Recover prepared child"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let delayedDisposition = DispatchGroup()
        delayedDisposition.enter()
        var dispositionReleased = false
        defer {
            if !dispositionReleased { delayedDisposition.leave() }
        }
        oldRuntime.setRuntimeDispositionBarrierFactoryForTesting { _ in
            SurfaceTerminationBarrier(
                groups: [delayedDisposition],
                completionChecks: [{ true }]
            )
        }
        var preparationAttempts = 0
        var preparations: [TerminalPreparedPTYRuntime] = []
        router.terminalRestartRuntimePreparerForTesting = { workspaceID, cwd, surfaceID in
            preparationAttempts += 1
            if preparationAttempts == 2 || preparationAttempts == 3 { return nil }
            let prepared = TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspaceID,
                cwd: cwd,
                surfaceID: surfaceID
            )
            if let prepared { preparations.append(prepared) }
            return prepared
        }

        let restartTask = Task { @MainActor in
            await router.restartSurfaceAndWaitForTesting(descriptor.id)
        }
        let closeDeadline = Date().addingTimeInterval(2)
        while oldRuntime.runtimeHealth().processAlive, Date() < closeDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(oldRuntime.runtimeHealth().processAlive)
        let firstPrepared = try XCTUnwrap(preparations.first)
        let firstPreparedPID = try XCTUnwrap(firstPrepared.ownedPIDForTesting)
        XCTAssertEqual(Darwin.kill(firstPreparedPID, SIGKILL), 0)
        let exitDeadline = Date().addingTimeInterval(2)
        while firstPrepared.isOwnedAndAlive(), Date() < exitDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(firstPrepared.isOwnedAndAlive())
        delayedDisposition.leave()
        dispositionReleased = true

        let restarted = await restartTask.value
        XCTAssertTrue(restarted)
        XCTAssertEqual(preparationAttempts, 4)
        XCTAssertEqual(preparations.count, 2)
        let replacement = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        XCTAssertFalse(replacement === oldRuntime)
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(replacement.runtimeHealth().inputAccepting)
    }

    func test_postTeardownUnsuspendablePreparationUsesBoundedDirectRecovery() async throws {
        // WHY: a preparer may repeatedly return an already-exited child after
        // the old PTY closes. Every rejected child must advance the finite
        // recovery budget and be reaped before one direct attach; otherwise the
        // MainActor loops forever with a dead old runtime registered.
        let (_, router) = try makeHarness(name: "bounded-direct-recovery")
        let workspace = try router.createWorkspace(
            name: "Bounded direct recovery",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Bounded recovery"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let delayedDisposition = DispatchGroup()
        delayedDisposition.enter()
        var dispositionReleased = false
        defer {
            if !dispositionReleased { delayedDisposition.leave() }
        }
        oldRuntime.setRuntimeDispositionBarrierFactoryForTesting { _ in
            SurfaceTerminationBarrier(
                groups: [delayedDisposition],
                completionChecks: [{ true }]
            )
        }
        var preparationAttempts = 0
        var firstPrepared: TerminalPreparedPTYRuntime?
        var rejectedPrepared: [(runtime: TerminalPreparedPTYRuntime, pid: pid_t)] = []
        router.terminalRestartRuntimePreparerForTesting = { workspaceID, cwd, surfaceID in
            preparationAttempts += 1
            guard preparationAttempts == 1 else {
                guard let prepared = TerminalSurface.prepareRuntimeForReplacement(
                    workspaceID: workspaceID,
                    cwd: cwd,
                    launch: .sshPlaceholder(cwd: cwd),
                    surfaceID: surfaceID
                ), let pid = prepared.ownedPIDForTesting else { return nil }
                let deadline = Date().addingTimeInterval(1)
                while prepared.isOwnedAndAlive(), Date() < deadline {
                    usleep(1_000)
                }
                rejectedPrepared.append((prepared, pid))
                return prepared
            }
            let prepared = TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspaceID,
                cwd: cwd,
                surfaceID: surfaceID
            )
            firstPrepared = prepared
            return prepared
        }

        let restartTask = Task { @MainActor in
            await router.restartSurfaceAndWaitForTesting(descriptor.id)
        }
        let closeBoundaryDeadline = Date().addingTimeInterval(2)
        while oldRuntime.runtimeHealth().processAlive, Date() < closeBoundaryDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(oldRuntime.runtimeHealth().processAlive)
        let prepared = try XCTUnwrap(firstPrepared)
        let preparedPID = try XCTUnwrap(prepared.ownedPIDForTesting)
        XCTAssertEqual(Darwin.kill(preparedPID, SIGKILL), 0)
        delayedDisposition.leave()
        dispositionReleased = true
        let startedAt = ProcessInfo.processInfo.systemUptime

        let restarted = await restartTask.value
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertTrue(restarted)
        XCTAssertEqual(preparationAttempts, 6)
        XCTAssertEqual(rejectedPrepared.count, 5)
        XCTAssertLessThan(elapsed, 2)
        XCTAssertNil(prepared.ownedPIDForTesting)
        XCTAssertTrue(waitpidOwnershipWasConsumed(preparedPID))
        for rejected in rejectedPrepared {
            XCTAssertNil(rejected.runtime.ownedPIDForTesting)
            XCTAssertTrue(waitpidOwnershipWasConsumed(rejected.pid))
        }
        let replacement = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        XCTAssertFalse(replacement === oldRuntime)
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(replacement.runtimeHealth().inputAccepting)
    }

    func test_closeDuringPostTeardownRecoveryStopsRetriesAndNeverResurrectsSurface() async throws {
        // WHY: discarding a dead prepared child awaits its process barrier and
        // permits MainActor reentrancy. If the user closes the tab in that exact
        // window, recovery must revalidate state instead of using a stale
        // descriptor to recreate an orphan runtime.
        let (context, router) = try makeHarness(name: "close-during-recovery")
        let workspace = try router.createWorkspace(
            name: "Close during recovery",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Do not resurrect"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let delayedDisposition = DispatchGroup()
        delayedDisposition.enter()
        var dispositionReleased = false
        defer {
            if !dispositionReleased { delayedDisposition.leave() }
        }
        oldRuntime.setRuntimeDispositionBarrierFactoryForTesting { _ in
            SurfaceTerminationBarrier(
                groups: [delayedDisposition],
                completionChecks: [{ true }]
            )
        }
        let delayedPreparedDiscard = DispatchGroup()
        delayedPreparedDiscard.enter()
        var preparedDiscardReleased = false
        defer {
            if !preparedDiscardReleased { delayedPreparedDiscard.leave() }
        }
        var preparedDiscardBarrierRequests = 0
        router.terminalRestartPreparedDiscardAdditionalBarrierForTesting = {
            preparedDiscardBarrierRequests += 1
            return SurfaceTerminationBarrier(
                groups: [delayedPreparedDiscard],
                completionChecks: [{ true }]
            )
        }
        var preparationAttempts = 0
        var firstPrepared: TerminalPreparedPTYRuntime?
        router.terminalRestartRuntimePreparerForTesting = { workspaceID, cwd, surfaceID in
            preparationAttempts += 1
            guard preparationAttempts == 1 else { return nil }
            let prepared = TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspaceID,
                cwd: cwd,
                surfaceID: surfaceID
            )
            firstPrepared = prepared
            return prepared
        }
        let events = EventKindCapture(kinds: ["surface.closed", "surface.created"])
        defer { events.stop() }

        let restartTask = Task { @MainActor in
            await router.restartSurfaceAndWaitForTesting(descriptor.id)
        }
        let closeBoundaryDeadline = Date().addingTimeInterval(2)
        while oldRuntime.runtimeHealth().processAlive, Date() < closeBoundaryDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(oldRuntime.runtimeHealth().processAlive)
        let prepared = try XCTUnwrap(firstPrepared)
        let preparedPID = try XCTUnwrap(prepared.ownedPIDForTesting)
        XCTAssertEqual(Darwin.kill(preparedPID, SIGKILL), 0)
        delayedDisposition.leave()
        dispositionReleased = true
        let discardDeadline = Date().addingTimeInterval(2)
        while preparedDiscardBarrierRequests < 1, Date() < discardDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(preparedDiscardBarrierRequests, 1)
        XCTAssertEqual(preparationAttempts, 1)
        XCTAssertNil(prepared.ownedPIDForTesting)

        try router.closeSurface(workspace: workspace.id, surface: descriptor.id)
        delayedPreparedDiscard.leave()
        preparedDiscardReleased = true
        let restarted = await restartTask.value

        XCTAssertFalse(restarted)
        XCTAssertNil(SurfaceRegistry.shared.surface(descriptor.id))
        XCTAssertNil(
            descriptorInLayout(
                context: context,
                workspaceID: workspace.id,
                surfaceID: descriptor.id
            )
        )
        XCTAssertEqual(preparationAttempts, 1)
        XCTAssertNil(prepared.ownedPIDForTesting)
        XCTAssertTrue(waitpidOwnershipWasConsumed(preparedPID))
        XCTAssertEqual(events.values, ["surface.closed"])
    }

    func test_processDispositionFailureCompletesReplacementAndCleansOldRuntime() async throws {
        // WHY: process cleanup failure is discovered only after PTY/Ghostty
        // teardown. Returning false there strands a permanently dead registered
        // tab. The stable-ID replacement must continue while cleanup is retried.
        let (_, router) = try makeHarness(name: "process-disposition")
        let workspace = try router.createWorkspace(
            name: "Process disposition",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Disposition fallback"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let oldPID = try XCTUnwrap(oldRuntime.runtimeHealth().childPID)
        let oldReaperReachedCompletion = DispatchSemaphore(value: 0)
        let releaseOldReaperCompletion = DispatchSemaphore(value: 0)
        oldRuntime.setChildReapCompletionForTesting {
            oldReaperReachedCompletion.signal()
            _ = releaseOldReaperCompletion.wait(timeout: .now() + 3)
        }
        let healthCapture = RuntimeHealthCapture(surfaceID: descriptor.id)
        defer {
            releaseOldReaperCompletion.signal()
            healthCapture.stop()
        }
        oldRuntime.setRuntimeDispositionBarrierFactoryForTesting { _ in
            let group = DispatchGroup()
            group.enter()
            group.leave()
            return SurfaceTerminationBarrier(
                groups: [group],
                completionChecks: [{ false }]
            )
        }
        let events = EventKindCapture(kinds: ["surface.closed", "surface.created"])
        defer { events.stop() }

        let restarted = await router.restartSurfaceAndWaitForTesting(descriptor.id)

        XCTAssertTrue(restarted)
        let replacement = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        XCTAssertFalse(replacement === oldRuntime)
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(replacement.runtimeHealth().inputAccepting)
        XCTAssertTrue(replacement.runtimeHealth().outputPartial)
        XCTAssertEqual(
            replacement.runtimeHealth().outputPartialReason,
            "runtime_restart_disposition_incomplete"
        )
        let replacementPID = try XCTUnwrap(replacement.runtimeHealth().childPID)
        XCTAssertEqual(oldReaperReachedCompletion.wait(timeout: .now() + 2), .success)
        releaseOldReaperCompletion.signal()
        let cleanupDeadline = Date().addingTimeInterval(2)
        while oldRuntime.runtimeHealth().childPID != nil, Date() < cleanupDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(oldRuntime.runtimeHealth().childPID)
        XCTAssertTrue(waitpidOwnershipWasConsumed(oldPID))
        let health = healthCapture.values
        let replacementHealthIndex = try XCTUnwrap(health.firstIndex(where: {
            $0.childPID == replacementPID && $0.processAlive && $0.inputAccepting
        }))
        XCTAssertTrue(
            health[replacementHealthIndex...].allSatisfy {
                $0.processAlive && $0.inputAccepting && $0.childPID == replacementPID
            },
            "retired runtime cleanup must not overwrite replacement health under the shared surface ID"
        )
        XCTAssertTrue(events.values.isEmpty)
    }

    func test_processDispositionGroupTimeoutCompletesReplacementAndContinuesCleanup() async throws {
        // WHY: a busy global child-reaper can exceed the restart's fast wait
        // after PTY teardown has already made the old runtime irreversible.
        // Discarding the prepared replacement then strands a dead registered
        // tab; the replacement must commit while old-runtime cleanup continues.
        let (_, router) = try makeHarness(name: "process-disposition-timeout")
        let workspace = try router.createWorkspace(
            name: "Process disposition timeout",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Disposition timeout fallback"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let oldPID = try XCTUnwrap(oldRuntime.runtimeHealth().childPID)
        let delayedDisposition = DispatchGroup()
        delayedDisposition.enter()
        var dispositionReleased = false
        defer {
            if !dispositionReleased { delayedDisposition.leave() }
        }
        oldRuntime.setRuntimeDispositionBarrierFactoryForTesting { pid in
            XCTAssertEqual(pid, oldPID)
            return SurfaceTerminationBarrier(
                groups: [delayedDisposition],
                completionChecks: [{ true }]
            )
        }
        let events = EventKindCapture(kinds: ["surface.closed", "surface.created"])
        defer { events.stop() }

        let restarted = await router.restartSurfaceAndWaitForTesting(descriptor.id)

        XCTAssertTrue(
            restarted,
            "an irreversible old-runtime close must not discard a healthy prepared replacement"
        )
        let replacement = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        XCTAssertFalse(replacement === oldRuntime)
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(replacement.runtimeHealth().inputAccepting)
        XCTAssertTrue(replacement.runtimeHealth().outputPartial)
        XCTAssertEqual(
            replacement.runtimeHealth().outputPartialReason,
            "runtime_restart_disposition_incomplete"
        )
        XCTAssertTrue(events.values.isEmpty)

        delayedDisposition.leave()
        dispositionReleased = true
        if let cleanup = oldRuntime.continueCleanupAfterFailedRuntimeRestart() {
            let cleanupCompleted = await cleanup.waitForGroupsAsync(until: .now() + 3)
            XCTAssertTrue(cleanupCompleted)
        }
        let cleanupDeadline = Date().addingTimeInterval(2)
        while oldRuntime.runtimeHealth().childPID != nil, Date() < cleanupDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(oldRuntime.runtimeHealth().childPID)
        XCTAssertTrue(waitpidOwnershipWasConsumed(oldPID))
    }

    func test_spawnPreparationFailurePreservesInteractiveRuntimeAndRetrySucceeds() async throws {
        // WHY: forkpty/descriptor setup can fail under resource pressure. The
        // current PTY must remain authoritative until a replacement PTY is
        // actually owned and ready to commit behind the same surface ID.
        let (_, router) = try makeHarness(name: "spawn-preparation")
        let workspace = try router.createWorkspace(
            name: "Spawn preparation",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Transactional restart"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let oldPID = try XCTUnwrap(oldRuntime.runtimeHealth().childPID)
        router.terminalRestartRuntimePreparerForTesting = { _, _, _ in nil }
        let events = EventKindCapture(kinds: ["surface.closed", "surface.created"])
        defer { events.stop() }

        let failed = await router.restartSurfaceAndWaitForTesting(descriptor.id)

        XCTAssertFalse(failed)
        XCTAssertTrue(SurfaceRegistry.shared.surface(descriptor.id) === oldRuntime)
        XCTAssertTrue(oldRuntime.runtimeHealth().processAlive)
        XCTAssertTrue(oldRuntime.runtimeHealth().inputAccepting)
        XCTAssertEqual(oldRuntime.runtimeHealth().childPID, oldPID)
        XCTAssertTrue(events.values.isEmpty)

        router.terminalRestartRuntimePreparerForTesting = nil
        let retried = await router.restartSurfaceAndWaitForTesting(descriptor.id)

        XCTAssertTrue(retried)
        let replacement = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        XCTAssertFalse(replacement === oldRuntime)
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(replacement.runtimeHealth().inputAccepting)
        let oldOwnershipConsumed = await waitForWaitpidOwnershipToBeConsumed(
            oldPID,
            timeout: 6
        )
        XCTAssertTrue(
            oldOwnershipConsumed,
            "an asynchronous post-timeout disposition must still consume the retired child"
        )
        XCTAssertTrue(waitpidOwnershipWasConsumed(oldPID))
        XCTAssertTrue(events.values.isEmpty)
    }

    func test_stoppedPreparedRuntimeRetriesTransientProcessStatusReadWithoutLosingOwnership() throws {
        // WHY: proc_pidinfo can transiently fail under full-suite process load.
        // A prepared, pre-exec SIGSTOP child must remain provably owned through
        // one non-consuming waitid observation and one immediate status retry.
        let prepared = try XCTUnwrap(
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: WorkspaceID(),
                cwd: NSTemporaryDirectory(),
                surfaceID: SurfaceID()
            )
        )
        defer {
            if let cleanup = prepared.discard() {
                XCTAssertTrue(cleanup.wait(until: .now() + 2))
            }
        }
        let pid = try XCTUnwrap(prepared.ownedPIDForTesting)
        var processStatusReadCount = 0
        var callOrder: [String] = []

        let owned = TerminalPTYProcessRuntime.ownsStoppedChild(
            pid: pid,
            processStatusReader: { requestedPID in
                XCTAssertEqual(requestedPID, pid)
                processStatusReadCount += 1
                callOrder.append("status")
                if processStatusReadCount == 1 { return .unavailable }
                return .snapshot(parentPID: UInt32(getpid()), status: UInt32(SSTOP))
            },
            waitObservationReader: { requestedPID in
                XCTAssertEqual(requestedPID, pid)
                callOrder.append("wait")
                return TerminalPTYProcessRuntime.stoppedChildWaitObservation(pid: requestedPID)
            }
        )

        XCTAssertTrue(owned)
        XCTAssertEqual(processStatusReadCount, 2, "fallback must retry proc status exactly once")
        XCTAssertEqual(callOrder, ["status", "wait", "status"])
    }

    func test_resumeStoppedPreparedRuntimeRetriesTransientProcessStatusRead() throws {
        // WHY: restart rechecks the stopped child before teardown, then transfers
        // ownership and resumes it. A transient proc_pidinfo failure at that
        // second gate must not reject the already-owned replacement runtime.
        let prepared = try XCTUnwrap(
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: WorkspaceID(),
                cwd: NSTemporaryDirectory(),
                surfaceID: SurfaceID()
            )
        )
        defer {
            if let cleanup = prepared.discard() {
                XCTAssertTrue(cleanup.wait(until: .now() + 2))
            }
        }
        let pid = try XCTUnwrap(prepared.ownedPIDForTesting)
        var processStatusReadCount = 0
        var callOrder: [String] = []

        let resumed = TerminalPTYProcessRuntime.resumeOwnedLiveChild(
            pid: pid,
            processStatusReader: { requestedPID in
                XCTAssertEqual(requestedPID, pid)
                processStatusReadCount += 1
                callOrder.append("status")
                if processStatusReadCount == 1 { return .unavailable }
                if processStatusReadCount <= 3 {
                    return .snapshot(parentPID: UInt32(getpid()), status: UInt32(SSTOP))
                }
                return .snapshot(parentPID: UInt32(getpid()), status: UInt32(SRUN))
            },
            waitObservationReader: { requestedPID in
                XCTAssertEqual(requestedPID, pid)
                callOrder.append("wait")
                return TerminalPTYProcessRuntime.stoppedChildWaitObservation(pid: requestedPID)
            }
        )

        XCTAssertTrue(resumed)
        XCTAssertEqual(processStatusReadCount, 4)
        XCTAssertEqual(callOrder, ["status", "wait", "status", "status", "status"])
        XCTAssertTrue(TerminalPTYProcessRuntime.ownsLiveChild(pid: pid))
    }

    func test_stoppedOwnershipProbeLeavesExitedPreparedChildWaitable() async throws {
        // WHY: the fallback must never consume exit status. Otherwise the
        // authoritative reaper loses the only child-status source and can no
        // longer prove PID ownership before cleanup.
        let prepared = try XCTUnwrap(
            TerminalSurface.prepareRuntimeForReplacement(
                workspaceID: WorkspaceID(),
                cwd: NSTemporaryDirectory(),
                launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
                surfaceID: SurfaceID()
            )
        )
        let pid = try XCTUnwrap(prepared.ownedPIDForTesting)
        let exitDeadline = Date().addingTimeInterval(2)
        var exitObserved = false
        while Date() < exitDeadline {
            switch TerminalPTYProcessRuntime.stoppedChildWaitObservation(pid: pid) {
            case .exited:
                exitObserved = true
            case .ownedAliveNoEvent:
                usleep(1_000)
            default:
                XCTFail("fixture must remain a directly owned child until /usr/bin/false exits")
                return
            }
            if exitObserved { break }
        }
        XCTAssertTrue(exitObserved, "fixture must expose an unconsumed exit status")
        var processStatusReadCount = 0

        let owned = TerminalPTYProcessRuntime.ownsStoppedChild(
            pid: pid,
            processStatusReader: { requestedPID in
                XCTAssertEqual(requestedPID, pid)
                processStatusReadCount += 1
                return .unavailable
            }
        )

        XCTAssertFalse(owned)
        XCTAssertEqual(processStatusReadCount, 1, "an observed exit must not retry proc status")
        let cleanup = try XCTUnwrap(
            prepared.discard(),
            "the prepared runtime must retain authoritative ownership until discard"
        )
        let cleanupCompleted = await cleanup.waitForGroupsAsync(until: .now() + 2)
        XCTAssertTrue(
            cleanupCompleted,
            "the authoritative discard path must consume the waitable child status"
        )
        XCTAssertNil(prepared.ownedPIDForTesting)
        XCTAssertTrue(waitpidOwnershipWasConsumed(pid))
    }

    func test_stoppedOwnershipProbeFailsClosedWithoutPIDReuseFallback() {
        // WHY: a definitive parent/status mismatch can be a reused numeric PID.
        // It must never enter a permissive wait fallback, and ambiguous wait
        // results must never trigger more than one status retry.
        var waitReadCount = 0
        XCTAssertFalse(
            TerminalPTYProcessRuntime.ownsStoppedChild(
                pid: 42,
                processStatusReader: { _ in
                    .snapshot(parentPID: UInt32(getpid()) + 1, status: UInt32(SSTOP))
                },
                waitObservationReader: { _ in
                    waitReadCount += 1
                    return .stopped(signal: SIGSTOP)
                }
            )
        )
        XCTAssertEqual(waitReadCount, 0, "wrong-parent snapshots are definitive PID-reuse failures")

        for observation in [
            TerminalPTYProcessRuntime.StoppedChildWaitObservation.exited,
            .continued,
            .unowned,
            .unknown,
            .stopped(signal: SIGTSTP),
        ] {
            var processStatusReadCount = 0
            XCTAssertFalse(
                TerminalPTYProcessRuntime.ownsStoppedChild(
                    pid: 42,
                    processStatusReader: { _ in
                        processStatusReadCount += 1
                        return .unavailable
                    },
                    waitObservationReader: { _ in observation }
                )
            )
            XCTAssertEqual(processStatusReadCount, 1)
        }

        var processStatusReadCount = 0
        XCTAssertFalse(
            TerminalPTYProcessRuntime.ownsStoppedChild(
                pid: 42,
                processStatusReader: { _ in
                    processStatusReadCount += 1
                    return .unavailable
                },
                waitObservationReader: { _ in .ownedAliveNoEvent }
            )
        )
        XCTAssertEqual(processStatusReadCount, 2, "no-event fallback permits exactly one retry")
    }

    func test_preparedChildThatExitsBeforeAttachDoesNotDestroyCurrentRuntime() async throws {
        // WHY: forkpty success proves only PID/FD creation. A prepared child can
        // exit while the old runtime drains; committing that zombie reports a
        // false healthy replacement and destroys the still-working terminal.
        let (_, router) = try makeHarness(name: "prepared-child-exit")
        let workspace = try router.createWorkspace(
            name: "Prepared child exit",
            cwd: NSTemporaryDirectory()
        )
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .terminal,
            paneID: nil,
            title: "Keep live runtime"
        )
        let oldRuntime = try XCTUnwrap(
            SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
        )
        let oldPID = try XCTUnwrap(oldRuntime.runtimeHealth().childPID)
        var preparedChildExited = false
        router.terminalRestartRuntimePreparerForTesting = { workspace, cwd, surfaceID in
            guard let prepared = TerminalSurface.prepareRuntimeForReplacement(
                workspaceID: workspace,
                cwd: cwd,
                launch: .sshPlaceholder(cwd: cwd),
                surfaceID: surfaceID
            ) else { return nil }
            let deadline = Date().addingTimeInterval(1)
            while prepared.isOwnedAndAlive(), Date() < deadline {
                usleep(1_000)
            }
            preparedChildExited = !prepared.isOwnedAndAlive()
            return prepared
        }

        let restarted = await router.restartSurfaceAndWaitForTesting(descriptor.id)

        XCTAssertTrue(preparedChildExited, "fixture must return an exited /usr/bin/false child")
        XCTAssertFalse(restarted)
        XCTAssertTrue(SurfaceRegistry.shared.surface(descriptor.id) === oldRuntime)
        XCTAssertEqual(oldRuntime.runtimeHealth().childPID, oldPID)
        XCTAssertTrue(oldRuntime.runtimeHealth().processAlive)
        XCTAssertTrue(oldRuntime.runtimeHealth().inputAccepting)
        XCTAssertTrue(oldRuntime.runtimeProcessIsOwnedAndAliveForRestartCommit())

        router.terminalRestartRuntimePreparerForTesting = nil
        let retrySucceeded = await router.restartSurfaceAndWaitForTesting(descriptor.id)
        XCTAssertTrue(retrySucceeded)
        XCTAssertFalse(SurfaceRegistry.shared.surface(descriptor.id) === oldRuntime)
    }

    private func makeHarness(name: String) throws -> (AppContext, AppCommandRouter) {
        let directory = NSTemporaryDirectory() + "RC2TerminalRestart-\(name)-\(UUID().uuidString)"
        temporaryDirectories.append(directory)
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        return (context, router)
    }

    private func descriptorInLayout(
        context: AppContext,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID
    ) -> SurfaceDescriptor? {
        guard let workspace = context.state.workspaces[workspaceID] else { return nil }
        for paneID in workspace.layout.paneIDs() {
            if let descriptor = workspace.layout.find(paneID: paneID)?.surfaces.first(where: {
                $0.id == surfaceID
            }) {
                return descriptor
            }
        }
        return nil
    }

    private func waitpidOwnershipWasConsumed(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        errno = 0
        return Darwin.waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
    }

    private func waitForWaitpidOwnershipToBeConsumed(
        _ pid: pid_t,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var info = siginfo_t()
            errno = 0
            let result = waitid(
                P_PID,
                id_t(pid),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result < 0, errno == ECHILD { return true }
            if result < 0, errno != EINTR { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

@MainActor
private final class DelayedMainTerminationSurface: Surface {
    let descriptor = SurfaceDescriptor(
        id: SurfaceID(),
        type: .terminal,
        title: "termination-probe",
        iconName: "terminal"
    )
    let view = NSView(frame: .zero)
    let isBusy = false
    private let delay: TimeInterval
    private let onStart: () -> Void
    private var barrier: SurfaceTerminationBarrier?

    init(delay: TimeInterval, onStart: @escaping () -> Void) {
        self.delay = delay
        self.onStart = onStart
    }

    func closeForApplicationTermination() -> SurfaceTerminationBarrier? {
        if let barrier { return barrier }
        onStart()
        let group = DispatchGroup()
        group.enter()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            group.leave()
        }
        let barrier = SurfaceTerminationBarrier(groups: [group])
        self.barrier = barrier
        return barrier
    }

    func focus() {}
    func unfocus() {}
    func close() {}
    func sendText(_ text: String) {}
    func readText() -> String { "" }
    func snapshot() -> [String: String] { [:] }
}

private final class EventKindCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var token: UUID?

    init(kinds: Set<String>) {
        let startSequence = EventBus.shared.snapshot().lastSeq
        token = EventBus.shared.subscribe(since: startSequence) { [weak self] event in
            guard kinds.contains(event.kind), let self else { return }
            lock.lock()
            storage.append(event.kind)
            lock.unlock()
        }
    }

    func stop() {
        guard let token else { return }
        EventBus.shared.unsubscribe(token)
        self.token = nil
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class RuntimeHealthCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let surfaceID: SurfaceID
    private let previousSink: (@Sendable (SurfaceID, TerminalRuntimeHealth) -> Void)?
    private var storage: [TerminalRuntimeHealth] = []

    init(surfaceID: SurfaceID) {
        self.surfaceID = surfaceID
        previousSink = SurfaceRuntimeBus.shared.sink
        let previousSink = previousSink
        SurfaceRuntimeBus.shared.sink = { [weak self] id, health in
            if let self, id == self.surfaceID {
                self.lock.lock()
                self.storage.append(health)
                self.lock.unlock()
            }
            previousSink?(id, health)
        }
    }

    func stop() {
        SurfaceRuntimeBus.shared.sink = previousSink
    }

    var values: [TerminalRuntimeHealth] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return false }
        available = false
        return true
    }
}
