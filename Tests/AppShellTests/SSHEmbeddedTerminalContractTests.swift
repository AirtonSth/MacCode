import XCTest
import Darwin

@testable import AppShell
@testable import CoreModel
@testable import Persistence
@testable import SocketServer
@testable import Surfaces

@MainActor
final class SSHEmbeddedTerminalContractTests: XCTestCase {
    private var surfaces: [SSHSurface] = []
    private var temporaryDirectories: [String] = []

    override func tearDown() async throws {
        let registered = SurfaceRegistry.shared.all()
        registered.forEach { ($0 as? TerminalRuntimeRoutingSurface)?.routedFlushPersistedHistory() }
        let registeredBarriers = registered.compactMap { $0.closeForApplicationTermination() }
        for barrier in registeredBarriers {
            _ = await barrier.waitAsync(until: .now() + 3)
        }
        registered.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        registered.forEach { SurfaceOutputBus.shared.remove(surfaceId: $0.descriptor.id) }
        SurfaceRegistry.shared.setVisibleSurfaceIDs([])
        surfaces.forEach { $0.flushPersistedHistory() }
        let surfaceBarriers = surfaces.compactMap { $0.closeForApplicationTermination() }
        for barrier in surfaceBarriers {
            _ = await barrier.waitAsync(until: .now() + 3)
        }
        surfaces.removeAll()
        temporaryDirectories.forEach { try? FileManager.default.removeItem(atPath: $0) }
        temporaryDirectories.removeAll()
        try await super.tearDown()
    }

    func testHiddenWrapperKeepsNewEmbeddedTerminalHiddenUntilWrapperReveal() async throws {
        // WHY: the embedded TerminalSurface is not registered separately. Its
        // outer SSHSurface must carry registry visibility across delayed connect.
        let surface = try makeSurface()
        surface.didBecomeHidden()

        await surface.connectImmediatelyForTesting(testProfile())

        XCTAssertEqual(surface.embeddedTerminalIDForTesting, surface.descriptor.id)
        XCTAssertEqual(surface.embeddedTerminalLogicalVisibleForTesting, false)

        surface.appendSystemText("RC2_HIDDEN_SSH_OUTPUT\n")
        XCTAssertGreaterThan(
            surface.embeddedOutputPendingBytesForTesting ?? 0,
            0,
            "output received while the SSH tab is hidden must remain pending"
        )

        surface.didBecomeVisible()

        XCTAssertEqual(
            surface.embeddedTerminalLogicalVisibleForTesting,
            true,
            "revealing the registered SSH wrapper must reveal its unregistered embedded terminal"
        )
    }

    func testOuterTabHideParksEmbeddedTerminalAndRevealRehostsIt() async throws {
        // WHY: PaneTabs only rehosts the registered SSHSurface view. Parking
        // reparents the unregistered embedded terminal into a hidden window; on
        // tab return the wrapper must reinstall it or the Connected pane stays blank.
        let surface = try makeSurface()
        try await surface.installEmbeddedPlaceholderForTesting()
        let terminal = try XCTUnwrap(surface.embeddedTerminalForTesting)

        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        let content = NSView(frame: host.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]
        host.contentView = content
        surface.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(surface.view)
        NSLayoutConstraint.activate([
            surface.view.topAnchor.constraint(equalTo: content.topAnchor),
            surface.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            surface.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            surface.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        host.orderFront(nil)
        defer { host.close() }

        XCTAssertTrue(
            terminal.view.isDescendant(of: surface.view),
            "embedded terminal must start hosted under the SSH hierarchy"
        )
        XCTAssertEqual(terminal.runtimeHealth().renderDiagnostics?.parked, false)

        // Real tab switch: hide first, then detach only the outer registered view.
        surface.didBecomeHidden()
        surface.view.removeFromSuperview()

        let parked = await waitUntilAsync(timeout: 2) {
            terminal.runtimeHealth().renderDiagnostics?.parked == true
        }
        XCTAssertTrue(parked, "detached hidden SSH terminal must park Ghostty in a hidden host")
        XCTAssertFalse(
            terminal.view.isDescendant(of: surface.view),
            "parking must reparent the embedded terminal out of the outer SSH view"
        )

        // PaneTabs rehosts only the outer surface, then reveals visibility.
        content.addSubview(surface.view)
        NSLayoutConstraint.activate([
            surface.view.topAnchor.constraint(equalTo: content.topAnchor),
            surface.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            surface.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            surface.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        surface.didBecomeVisible()

        XCTAssertEqual(
            surface.embeddedTerminalLogicalVisibleForTesting,
            true,
            "wrapper reveal must forward visibility to the embedded terminal"
        )
        XCTAssertTrue(
            terminal.view.isDescendant(of: surface.view),
            "wrapper reveal must rehost the parked embedded terminal under the SSH hierarchy"
        )
        let unparked = await waitUntilAsync(timeout: 2) {
            terminal.runtimeHealth().renderDiagnostics?.parked == false
                && terminal.runtimeHealth().renderDiagnostics?.windowAttached == true
        }
        XCTAssertTrue(
            unparked,
            "rehost must leave the parking window so Ghostty paints in the live pane"
        )
    }

    func testEmbeddedOutputAndGeometryUseOuterSurfaceID() async throws {
        // WHY: macOS mirror events are routed by the layout descriptor ID. An
        // independent inner ID makes both output and resize frames invisible to iOS.
        let bus = SurfaceOutputBus(queue: DispatchQueue(label: "ssh-output-contract"), flushDelay: 60)
        var frames: [SurfaceOutputBus.OutputFrame] = []
        bus.sink = { frames.append($0) }
        let surface = try makeSurface(outputBus: bus)
        let outerID = surface.descriptor.id

        await surface.connectImmediatelyForTesting(testProfile())
        surface.appendSystemText("RC2_SSH_MIRROR_MARKER\n")
        bus.flushNow(outerID)

        XCTAssertEqual(surface.embeddedTerminalIDForTesting, outerID)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(
            frames.allSatisfy { $0.surfaceID == outerID },
            "every embedded terminal frame must route under the registered outer SSH surface ID"
        )
        XCTAssertTrue(
            frames.contains { $0.rows != nil && $0.cols != nil },
            "the outer SSH surface ID must receive terminal geometry for iOS grid parity"
        )
        XCTAssertTrue(
            frames.contains { String(decoding: $0.data, as: UTF8.self).contains("RC2_SSH_MIRROR_MARKER") },
            "the outer SSH surface ID must receive live terminal bytes"
        )
    }

    func testReconnectReplaysHistoryUnderStableOuterSurfaceID() async throws {
        // WHY: reconnect replaces the embedded TerminalSurface. The replacement
        // must reuse the outer ID and replay bytes flushed by the prior session.
        let (repository, surface) = try makePersistentSurface()
        let outerID = surface.descriptor.id
        let marker = "RC2_SSH_RECONNECT_\(UUID().uuidString)"

        await surface.connectImmediatelyForTesting(testProfile())
        surface.appendSystemText(marker + "\n")
        let flushed = await surface.flushPersistedHistoryForTesting()
        XCTAssertTrue(flushed)
        XCTAssertGreaterThan(try repository.totalBytes(surfaceID: outerID.value.uuidString), 0)

        surface.disconnectForTesting()
        await surface.connectImmediatelyForTesting(testProfile())

        XCTAssertEqual(surface.embeddedTerminalIDForTesting, outerID)
        let replayed = await waitUntilAsync(timeout: 2) {
            surface.readText().contains(marker)
        }
        XCTAssertTrue(
            replayed,
            "reconnect must restore the prior session history before presenting the replacement terminal"
        )
        XCTAssertEqual(
            surface.readText().components(separatedBy: marker).count - 1,
            1,
            "the stable-ID replay must not duplicate the persisted marker"
        )
    }

    func testReconnectContinuesOuterMirrorSequence() async throws {
        // WHY: iOS rejects frames whose sequence is not greater than the last
        // applied frame. Replacing only the embedded runtime must not reset it.
        let bus = SurfaceOutputBus(queue: DispatchQueue(label: "ssh-sequence-contract"), flushDelay: 60)
        var frames: [SurfaceOutputBus.OutputFrame] = []
        bus.sink = { frames.append($0) }
        let surface = try makeSurface(outputBus: bus)
        let outerID = surface.descriptor.id

        await surface.connectImmediatelyForTesting(testProfile())
        surface.appendSystemText("RC2_SEQUENCE_ONE\n")
        bus.flushNow(outerID)
        surface.appendSystemText("RC2_SEQUENCE_TWO\n")
        bus.flushNow(outerID)
        let beforeReconnect = try XCTUnwrap(frames.last?.sequence)
        XCTAssertGreaterThan(beforeReconnect, 1)

        surface.disconnectForTesting()
        await surface.connectImmediatelyForTesting(testProfile())
        surface.appendSystemText("RC2_SEQUENCE_AFTER_RECONNECT\n")
        bus.flushNow(outerID)

        XCTAssertGreaterThan(
            try XCTUnwrap(frames.last?.sequence),
            beforeReconnect,
            "the first frame from the replacement SSH runtime must continue the outer surface sequence"
        )
    }

    func testReconnectSpawnPreparationFailureKeepsCurrentSSHInteractiveAndRetryable() async throws {
        // WHY: resource exhaustion during forkpty/FD setup must not tear down a
        // working SSH session before a replacement PTY is actually owned.
        let surface = try makeSurface()
        let old = try await surface.installEmbeddedShellForApplicationTerminationTesting()
        let oldPID = try XCTUnwrap(old.runtimeHealth().childPID)
        surface.terminalReplacementRuntimePreparerForTesting = { _, _, _, _ in nil }

        await surface.connectImmediatelyForTesting(testProfile())

        XCTAssertTrue(surface.embeddedTerminalForTesting === old)
        XCTAssertTrue(old.runtimeHealth().processAlive)
        XCTAssertTrue(old.runtimeHealth().inputAccepting)
        XCTAssertEqual(old.runtimeHealth().childPID, oldPID)

        surface.terminalReplacementRuntimePreparerForTesting = { workspace, cwd, _, surfaceID in
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspace,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }
        await surface.connectImmediatelyForTesting(testProfile())

        let replacement = try XCTUnwrap(surface.embeddedTerminalForTesting)
        XCTAssertFalse(replacement === old)
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(replacement.runtimeHealth().inputAccepting)
        let oldProcessDisposed = await waitUntilAsync(timeout: 2) {
            var status: Int32 = 0
            errno = 0
            return Darwin.waitpid(oldPID, &status, WNOHANG) == -1 && errno == ECHILD
        }
        XCTAssertTrue(oldProcessDisposed)
    }

    func testReconnectDispositionFailureInstallsHealthyPartialReplacementAndCanReconnectAgain() async throws {
        // WHY: a false post-teardown cleanup check is irreversible. Retaining
        // the closed embedded runtime makes every later Connect reuse the same
        // failed barrier; the wrapper must detach it and continue cleanup.
        let surface = try makeSurface()
        let old = try await surface.installEmbeddedShellForApplicationTerminationTesting()
        let oldPID = try XCTUnwrap(old.runtimeHealth().childPID)
        old.setRuntimeDispositionBarrierFactoryForTesting { _ in
            let group = DispatchGroup()
            group.enter()
            group.leave()
            return SurfaceTerminationBarrier(
                groups: [group],
                completionChecks: [{ false }]
            )
        }
        surface.terminalReplacementRuntimePreparerForTesting = { workspace, cwd, _, surfaceID in
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspace,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }

        await surface.connectImmediatelyForTesting(testProfile())

        let firstReplacement = try XCTUnwrap(surface.embeddedTerminalForTesting)
        XCTAssertFalse(firstReplacement === old)
        XCTAssertTrue(firstReplacement.runtimeHealth().processAlive)
        XCTAssertTrue(firstReplacement.runtimeHealth().inputAccepting)
        XCTAssertTrue(firstReplacement.runtimeHealth().outputPartial)
        XCTAssertEqual(
            firstReplacement.runtimeHealth().outputPartialReason,
            "runtime_restart_disposition_incomplete"
        )
        let oldRuntimeDisposed = await waitUntilAsync(timeout: 2) {
            old.runtimeHealth().childPID == nil
        }
        XCTAssertTrue(oldRuntimeDisposed)
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(Darwin.waitpid(oldPID, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)

        await surface.connectImmediatelyForTesting(testProfile())

        let secondReplacement = try XCTUnwrap(surface.embeddedTerminalForTesting)
        XCTAssertFalse(secondReplacement === firstReplacement)
        XCTAssertTrue(secondReplacement.runtimeHealth().processAlive)
        XCTAssertTrue(secondReplacement.runtimeHealth().inputAccepting)
    }

    func testReconnectProcessDispositionTimeoutCommitsHealthyReplacementAndContinuesCleanup() async throws {
        // WHY: under global reaper load the process group may outlive the fast
        // two-second observation after history is already final and the old PTY
        // is irreversibly closed. SSH must commit its prepared replacement and
        // retain cleanup ownership instead of leaving the outer surface empty.
        let surface = try makeSurface()
        let old = try await surface.installEmbeddedShellForApplicationTerminationTesting()
        let oldPID = try XCTUnwrap(old.runtimeHealth().childPID)
        let delayedDisposition = DispatchGroup()
        delayedDisposition.enter()
        var dispositionReleased = false
        defer {
            if !dispositionReleased { delayedDisposition.leave() }
        }
        old.setRuntimeDispositionBarrierFactoryForTesting { _ in
            SurfaceTerminationBarrier(
                groups: [delayedDisposition],
                completionChecks: [{ true }]
            )
        }
        surface.terminalReplacementRuntimePreparerForTesting = { workspace, cwd, _, surfaceID in
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspace,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }

        await surface.connectImmediatelyForTesting(testProfile())

        let replacement = try XCTUnwrap(surface.embeddedTerminalForTesting)
        XCTAssertFalse(replacement === old)
        XCTAssertTrue(replacement.runtimeHealth().processAlive)
        XCTAssertTrue(replacement.runtimeHealth().inputAccepting)
        XCTAssertTrue(replacement.runtimeHealth().outputPartial)
        XCTAssertEqual(
            replacement.runtimeHealth().outputPartialReason,
            "runtime_restart_disposition_incomplete"
        )

        delayedDisposition.leave()
        dispositionReleased = true
        let oldRuntimeDisposed = await waitUntilAsync(timeout: 3) {
            old.runtimeHealth().childPID == nil
        }
        XCTAssertTrue(oldRuntimeDisposed)
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(Darwin.waitpid(oldPID, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        await surface.waitForRetirementsForTesting()
        XCTAssertEqual(surface.retirementBarrierCountForTesting, 0)
    }

    func testDelayedConnectCannotOverwriteNewerConnectRequest() async throws {
        // WHY: A can be suspended while its retired runtime drains. A newer B
        // must supersede A without adding another concurrent replacement worker.
        let surface = try makeSurface()
        let old = try await surface.installEmbeddedShellForApplicationTerminationTesting()
        let delayedDisposition = DispatchGroup()
        delayedDisposition.enter()
        old.setRuntimeDispositionBarrierFactoryForTesting { _ in
            SurfaceTerminationBarrier(
                groups: [delayedDisposition],
                completionChecks: [{ true }]
            )
        }
        surface.terminalReplacementRuntimePreparerForTesting = { workspace, cwd, _, surfaceID in
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspace,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }
        let hostA = SSHHostProfile(label: "Delayed A", destination: "a.invalid")
        let hostB = SSHHostProfile(label: "Newer B", destination: "b.invalid")

        surface.connectForRouter(hostA)
        let firstRetirementStarted = await waitUntilAsync(timeout: 2) {
            surface.embeddedTerminalForTesting == nil
        }
        XCTAssertTrue(firstRetirementStarted)
        surface.connectForRouter(hostB)
        delayedDisposition.leave()
        let newerConnectionWon = await waitUntilAsync(timeout: 4) {
            !surface.connectionWorkerActiveForTesting
                && surface.sshTransferProfile?.id == hostB.id
        }
        XCTAssertTrue(newerConnectionWon)

        XCTAssertEqual(
            surface.sshTransferProfile?.id,
            hostB.id,
            "the newest request must win even when an older replacement wait resumes later"
        )
        XCTAssertEqual(surface.snapshot()["ssh_destination"], hostB.destination)
        await surface.waitForRetirementsForTesting()
        XCTAssertEqual(surface.retirementBarrierCountForTesting, 0)
    }

    func testDelayedConnectCannotResurrectAfterExplicitDisconnect() async throws {
        // WHY: disconnect is authoritative. A suspended connect must discard its
        // prepared PTY and must not recreate the terminal after the user leaves.
        let surface = try makeSurface()
        let old = try await surface.installEmbeddedShellForApplicationTerminationTesting()
        let delayedDisposition = DispatchGroup()
        delayedDisposition.enter()
        old.setRuntimeDispositionBarrierFactoryForTesting { _ in
            SurfaceTerminationBarrier(
                groups: [delayedDisposition],
                completionChecks: [{ true }]
            )
        }
        surface.terminalReplacementRuntimePreparerForTesting = { workspace, cwd, _, surfaceID in
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspace,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }

        surface.connectForRouter(SSHHostProfile(label: "Delayed A", destination: "a.invalid"))
        let retirementStarted = await waitUntilAsync(timeout: 2) {
            surface.embeddedTerminalForTesting == nil
        }
        XCTAssertTrue(retirementStarted)
        surface.disconnectForTesting()
        delayedDisposition.leave()
        let workerStopped = await waitUntilAsync(timeout: 4) {
            !surface.connectionWorkerActiveForTesting
        }
        XCTAssertTrue(workerStopped)

        XCTAssertNil(surface.embeddedTerminalForTesting)
        XCTAssertEqual(surface.snapshot()["ssh_status"], "disconnected")
        XCTAssertNil(surface.sshTransferProfile)
        await surface.waitForRetirementsForTesting()
        XCTAssertEqual(surface.retirementBarrierCountForTesting, 0)
    }

    func testApplicationTerminationOwnsDelayedRetirementAndPreparedLoserUntilBothAreReaped() async throws {
        // WHY: app quit can interleave while Connect awaits the old runtime. The
        // outer SSH surface must expose both the old barrier and the stopped
        // prepared child; a local defer is too late once process exit begins.
        let surface = try makeSurface()
        let old = try await surface.installEmbeddedShellForApplicationTerminationTesting()
        let oldPID = try XCTUnwrap(old.runtimeHealth().childPID)
        let delayedRetirement = DispatchGroup()
        delayedRetirement.enter()
        old.setRuntimeDispositionBarrierFactoryForTesting { pid in
            let work = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
                pid: pid,
                foregroundGroup: nil
            )
            return SurfaceTerminationBarrier(
                groups: [delayedRetirement, work.group],
                completionChecks: [work.succeeded]
            )
        }
        surface.terminalReplacementRuntimePreparerForTesting = { workspace, cwd, _, surfaceID in
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspace,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }

        surface.connectForRouter(SSHHostProfile(label: "Delayed quit", destination: "quit.invalid"))
        let replacementPrepared = await waitUntilAsync(timeout: 2) {
            surface.embeddedTerminalForTesting == nil
                && surface.inFlightPreparedPIDForTesting != nil
        }
        XCTAssertTrue(replacementPrepared)
        let preparedPID = try XCTUnwrap(surface.inFlightPreparedPIDForTesting)

        let quitBarrier = try XCTUnwrap(surface.closeForApplicationTermination())
        let quitCompletedWhileOldBarrierHeld = await quitBarrier.waitForGroupsAsync(
            until: .now() + 0.05
        )
        XCTAssertFalse(
            quitCompletedWhileOldBarrierHeld,
            "quit must remain pending while the registered old-runtime barrier is held"
        )
        delayedRetirement.leave()
        let quitCompleted = await quitBarrier.waitAsync(until: .now() + 3)
        XCTAssertTrue(quitCompleted)
        let workerStopped = await waitUntilAsync(timeout: 2) {
            !surface.connectionWorkerActiveForTesting
        }
        XCTAssertTrue(workerStopped)
        XCTAssertNil(surface.embeddedTerminalForTesting)
        XCTAssertTrue(waitpidOwnershipWasConsumed(oldPID))
        XCTAssertTrue(waitpidOwnershipWasConsumed(preparedPID))
    }

    func testPreparationFlagFailureIsTrackedThroughQuitAndRetryWithoutStoppedOrphan() async throws {
        // WHY: a child already exists when PTY flag setup fails. Returning nil
        // without publishing its cleanup lets immediate quit strand that stopped
        // child even though no TerminalSurface was ever committed.
        let surface = try makeSurface()
        surface.terminalReplacementNonBlockingEnablerForTesting = { _ in false }

        surface.connectForRouter(SSHHostProfile(label: "Flag failure", destination: "flags.invalid"))
        let failureObserved = await waitUntilAsync(timeout: 2) {
            surface.preparationFailurePIDForTesting != nil
        }
        XCTAssertTrue(failureObserved)
        let failedPID = try XCTUnwrap(surface.preparationFailurePIDForTesting)
        if let quitBarrier = surface.closeForApplicationTermination() {
            let quitCompleted = await quitBarrier.waitAsync(until: .now() + 3)
            XCTAssertTrue(quitCompleted)
        }
        await surface.waitForRetirementsForTesting()
        XCTAssertTrue(waitpidOwnershipWasConsumed(failedPID))

        surface.terminalReplacementNonBlockingEnablerForTesting = nil
        surface.terminalReplacementRuntimePreparerForTesting = { workspace, cwd, _, surfaceID in
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspace,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }
        await surface.connectImmediatelyForTesting(testProfile())
        XCTAssertTrue(surface.embeddedTerminalForTesting?.runtimeHealth().processAlive == true)
    }

    func testRouterDisconnectWinsDuringDelayedConnectAndReapsBothOwnedChildren() async throws {
        // WHY: the real RPC used generic Surface.close(), leaving connected UI
        // truth and a closing terminal reachable. Route it through the same
        // authoritative disconnect generation gate exercised by the UI.
        let (_, router, _, descriptor, surface) = try makeRouterSSH()
        surface.terminalReplacementRuntimePreparerForTesting = { workspace, cwd, _, surfaceID in
            TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspace,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }
        await surface.connectImmediatelyForTesting(
            SSHHostProfile(label: "Connected", destination: "connected.invalid")
        )
        let old = try XCTUnwrap(surface.embeddedTerminalForTesting)
        let oldPID = try XCTUnwrap(old.runtimeHealth().childPID)
        let delayedRetirement = DispatchGroup()
        delayedRetirement.enter()
        old.setRuntimeDispositionBarrierFactoryForTesting { pid in
            let work = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
                pid: pid,
                foregroundGroup: nil
            )
            return SurfaceTerminationBarrier(
                groups: [delayedRetirement, work.group],
                completionChecks: [work.succeeded]
            )
        }

        surface.connectForRouter(SSHHostProfile(label: "Replacement", destination: "replacement.invalid"))
        let replacementPrepared = await waitUntilAsync(timeout: 2) {
            surface.embeddedTerminalForTesting == nil
                && surface.inFlightPreparedPIDForTesting != nil
        }
        XCTAssertTrue(replacementPrepared)
        let preparedPID = try XCTUnwrap(surface.inFlightPreparedPIDForTesting)

        try router.sshDisconnect(surface: descriptor.id)
        XCTAssertEqual(surface.snapshot()["ssh_status"], "disconnected")
        XCTAssertNil(surface.sshTransferProfile)
        delayedRetirement.leave()
        let disconnected = await waitUntilAsync(timeout: 3) {
            !surface.connectionWorkerActiveForTesting
                && surface.embeddedTerminalForTesting == nil
        }
        XCTAssertTrue(disconnected)
        await surface.waitForRetirementsForTesting()
        XCTAssertEqual(surface.retirementBarrierCountForTesting, 0)
        XCTAssertTrue(waitpidOwnershipWasConsumed(oldPID))
        XCTAssertTrue(waitpidOwnershipWasConsumed(preparedPID))
    }

    func testRouterAndDispatcherExposeDisconnectedOuterSSHTruth() async throws {
        // WHY: the registered wrapper exists while no PTY exists. Generic surface
        // fallbacks previously lied that input was accepted and health was alive.
        let (_, router, _, descriptor, _) = try makeRouterSSH()

        let send = try router.sendTextResult(surface: descriptor.id, text: "echo impossible\n")
        XCTAssertEqual(send.objectValue?["status"], .string(TerminalInputStatus.processExited.rawValue))
        XCTAssertEqual(send.objectValue?["accepted"], .bool(false))

        let health = router.surfaceHealthDetails(surface: descriptor.id)
        XCTAssertEqual(health.objectValue?["alive"], .bool(false))
        XCTAssertEqual(health.objectValue?["process_alive"], .bool(false))
        XCTAssertEqual(health.objectValue?["input_accepting"], .bool(false))
        XCTAssertEqual(health.objectValue?["rows"], .number(0))
        XCTAssertNil(health.objectValue?["surface_type"], "SSH must use terminal health, not generic surface health")

        let snapshot = try router.readTextSnapshot(surface: descriptor.id)
        XCTAssertEqual(snapshot.objectValue?["complete"], .bool(false))
        XCTAssertEqual(snapshot.objectValue?["partial"], .bool(true))
        XCTAssertEqual(snapshot.objectValue?["source"], .string("ssh_disconnected"))
        XCTAssertEqual(snapshot.objectValue?["partial_reason"], .string(TerminalInputStatus.processExited.rawValue))
        XCTAssertEqual(snapshot.objectValue?["rows"], .number(0))

        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "surface.send_text",
            params: [
                "id": .string(descriptor.id.value.uuidString),
                "text": .string("echo impossible\n")
            ]
        ))
        XCTAssertEqual(response.result?.objectValue?["status"], .string(TerminalInputStatus.processExited.rawValue))
        XCTAssertEqual(response.result?.objectValue?["accepted"], .bool(false))

        let healthResponse = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "surface.health",
            params: ["id": .string(descriptor.id.value.uuidString)]
        ))
        XCTAssertEqual(healthResponse.result, health)
    }

    func testRouterHistoryFlushAndClearSerializeEmbeddedWriter() async throws {
        // WHY: read_history and clear_history address the outer ID. They must
        // cross the embedded writer queue before reading/deleting.
        let (context, router, _, descriptor, ssh) = try makeRouterSSH()
        try await ssh.installEmbeddedPlaceholderForTesting()
        let marker = "RC2_ROUTED_HISTORY_\(UUID().uuidString)"
        ssh.appendSystemText(marker + "\n")

        let history = try await router.readTerminalHistory(
            surface: descriptor.id,
            beforeChunkID: nil,
            maxBytes: 256 * 1024
        )
        XCTAssertTrue(history.text.contains(marker), "read_history must flush embedded pending bytes")

        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var blocked = false
        context.db.beforeStatementStepForTesting = { sql in
            guard sql.contains("INSERT"), sql.contains("terminal_output_chunks") else { return }
            hookLock.lock()
            let shouldBlock = !blocked
            blocked = true
            hookLock.unlock()
            guard shouldBlock else { return }
            writeStarted.signal()
            _ = releaseWrite.wait(timeout: .now() + 3)
        }
        ssh.appendSystemText(String(repeating: "z", count: 70 * 1024))
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            releaseWrite.signal()
        }

        router.surfaceClearHistory(surface: descriptor.id)
        context.db.beforeStatementStepForTesting = nil

        let historyCleared = await waitUntilAsync(timeout: 2) {
                (try? context.terminalOutputRepo.totalBytes(
                    surfaceID: descriptor.id.value.uuidString
                )) == 0
        }
        XCTAssertTrue(
            historyCleared,
            "clear_history must not be repopulated by an embedded write that was queued before deletion"
        )
    }

    func testLiveSSHClearIsSoleDeleteOwnerWhileRetireeOnlyDrains() async throws {
        // WHY: reconnect can leave a retired coordinator with the same stable
        // surface ID as the live coordinator. Turning that retiree into a final
        // DELETE races the live clear rotation and can erase its post-clear
        // buffer or invalidate the only active writer.
        let directory = NSTemporaryDirectory() + "RC2SSHClearOwners-" + UUID().uuidString
        temporaryDirectories.append(directory)
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let ssh = try SSHSurface(
            workspaceID: WorkspaceID(),
            cwd: NSTemporaryDirectory(),
            title: "SSH clear owner",
            router: nil,
            historyRepo: context.terminalOutputRepo,
            outputBus: SurfaceOutputBus()
        )
        surfaces.append(ssh)
        let surfaceID = ssh.descriptor.id
        let retiree = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "retiree",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
            assignedSurfaceID: surfaceID,
            historyRepo: nil,
            outputBus: SurfaceOutputBus()
        )
        let current = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "current",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
            assignedSurfaceID: surfaceID,
            historyRepo: context.terminalOutputRepo,
            outputBus: SurfaceOutputBus()
        )
        let ready = await waitUntilAsync(timeout: 2) {
            current.historyWriterGenerationForTesting != nil
        }
        XCTAssertTrue(ready)
        let retirementBarrier = try XCTUnwrap(retiree.closeForRuntimeRestart())
        ssh.installHistoryClearOwnersForTesting(
            current: current,
            retiree: retiree,
            retirementBarrier: retirementBarrier
        )
        let clearStarted = DispatchSemaphore(value: 0)
        let allowClear = DispatchSemaphore(value: 0)
        current.setBeforeLiveHistoryClearForTesting {
            clearStarted.signal()
            _ = allowClear.wait(timeout: .now() + 3)
        }
        let retireeDeleteAttempted = DispatchSemaphore(value: 0)
        ssh.retiredHistoryDeleteAttemptForTesting = {
            retireeDeleteAttempted.signal()
        }

        ssh.routedClearPersistedHistory()

        XCTAssertEqual(clearStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            retireeDeleteAttempted.wait(timeout: .now() + 0.05),
            .timedOut,
            "a live clear must be the sole delete owner; retirees only finish their existing drain"
        )
        let marker = "RC2_SSH_POST_CLEAR_\(UUID().uuidString)"
        ssh.appendSystemText(marker + "\n")
        allowClear.signal()
        let markerPersisted = await waitUntilAsync(timeout: 2) {
            (try? context.terminalOutputRepo.readWindow(
                surfaceID: surfaceID.value.uuidString
            ).text.contains(marker)) == true
        }
        XCTAssertTrue(
            markerPersisted,
            "bytes accepted after live clear starts must become the first durable bytes of the rotated generation"
        )
    }

    func testDisconnectedSSHClearCannotDeleteSuccessorThatPreparesBeforeDrain() throws {
        // WHY: a disconnected SSH wrapper is reusable. Its clear request must
        // rotate/guard history, never enqueue an unconditional final delete
        // that can erase output from a reconnect using the same stable ID.
        let directory = NSTemporaryDirectory() + "RC2SSHDisconnectedClear-" + UUID().uuidString
        temporaryDirectories.append(directory)
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        try context.db.execute("PRAGMA busy_timeout=25;")
        let ssh = try SSHSurface(
            workspaceID: WorkspaceID(),
            cwd: NSTemporaryDirectory(),
            title: "SSH disconnected clear",
            router: nil,
            historyRepo: context.terminalOutputRepo,
            outputBus: SurfaceOutputBus()
        )
        surfaces.append(ssh)
        let surfaceID = ssh.descriptor.id.value.uuidString
        let original = try context.terminalOutputRepo.prepareHistory(surfaceID: surfaceID)
        try context.terminalOutputRepo.append(
            surfaceID: surfaceID,
            workspaceID: nil,
            chunkIndex: original.nextChunkIndex,
            data: Data("OLD_DISCONNECTED_HISTORY".utf8)
        )

        let lockDatabase = try SQLiteDB(path: context.db.path)
        try lockDatabase.execute("BEGIN IMMEDIATE;")
        let deleteAttemptStarted = DispatchSemaphore(value: 0)
        let allowDeleteAttempt = DispatchSemaphore(value: 0)
        TerminalHistoryCoordinator.setBeforePendingFinalDeleteAttemptForTesting {
            deleteAttemptStarted.signal()
            _ = allowDeleteAttempt.wait(timeout: .now() + 3)
        }
        defer {
            allowDeleteAttempt.signal()
            TerminalHistoryCoordinator.setBeforePendingFinalDeleteAttemptForTesting(nil)
            try? lockDatabase.execute("ROLLBACK;")
        }

        ssh.routedClearPersistedHistory()
        XCTAssertEqual(deleteAttemptStarted.wait(timeout: .now() + 2), .success)
        try lockDatabase.execute("ROLLBACK;")

        let successorDatabase = try SQLiteDB(path: context.db.path)
        let successorRepository = TerminalOutputRepository(db: successorDatabase)
        let successorPreparation = try successorRepository.prepareHistory(surfaceID: surfaceID)
        let marker = Data("POST_CLEAR_RECONNECT_MUST_SURVIVE".utf8)
        try successorRepository.append(
            surfaceID: surfaceID,
            workspaceID: nil,
            chunkIndex: successorPreparation.nextChunkIndex,
            data: marker
        )
        allowDeleteAttempt.signal()
        let barrier = try XCTUnwrap(TerminalSurface.pendingHistoryDeleteBarrier())
        XCTAssertTrue(barrier.wait(until: .now() + 3))

        XCTAssertTrue(
            try successorRepository.readWindow(surfaceID: surfaceID).text
                .contains(String(decoding: marker, as: UTF8.self)),
            "the delayed disconnected clear must preserve the reconnect successor"
        )
    }

    func testTerminationBarrierFlushesEmbeddedSSHHistory() async throws {
        // WHY: app termination closes runtimes immediately after this barrier.
        // Pending bytes behind an SSH wrapper must be durable before teardown.
        let (context, _, _, descriptor, ssh) = try makeRouterSSH()
        try await ssh.installEmbeddedPlaceholderForTesting()
        let marker = "RC2_SSH_TERMINATION_\(UUID().uuidString)"
        ssh.appendSystemText(marker + "\n")

        let flushed = await flushPersistedTerminalHistoryForRegisteredSurfaces()
        XCTAssertTrue(flushed)

        let window = try context.terminalOutputRepo.readWindow(
            surfaceID: descriptor.id.value.uuidString,
            maxBytes: 256 * 1024
        )
        XCTAssertTrue(window.text.contains(marker))
    }

    func testOwnerlessSSHDeleteRetriesSidecarCleanupFailureAfterSQLiteCommit() throws {
        // WHY: a disconnected SSH wrapper can be the last history owner. If
        // SQLite commits but C80 sidecar cleanup fails, swallowing that error
        // strands the anchor forever because the wrapper is immediately gone.
        let directory = NSTemporaryDirectory() + "RC2SSHOwnerlessDelete-" + UUID().uuidString
        temporaryDirectories.append(directory)
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let ssh = try SSHSurface(
            workspaceID: WorkspaceID(),
            cwd: NSTemporaryDirectory(),
            title: "SSH ownerless delete",
            router: nil,
            historyRepo: context.terminalOutputRepo,
            outputBus: SurfaceOutputBus()
        )
        surfaces.append(ssh)
        let surfaceID = ssh.descriptor.id.value.uuidString
        let writerGeneration = UUID().uuidString
        try context.terminalOutputRepo.append(
            surfaceID: surfaceID,
            workspaceID: nil,
            chunkIndex: 1,
            data: Data("OWNERLESS_SSH_DELETE\n".utf8)
        )
        try context.terminalOutputRepo.recordFailureAnchor(
            surfaceID: surfaceID,
            writerGeneration: writerGeneration,
            reason: "ownerless_ssh_cleanup_fixture",
            minimumNextChunkIndex: 2
        )
        let ledgerRoot = try XCTUnwrap(
            context.terminalOutputRepo.failureLedgerRootURLForTesting
        )
        let deleteAttemptStarted = DispatchSemaphore(value: 0)
        let allowDeleteAttempt = DispatchSemaphore(value: 0)
        TerminalHistoryCoordinator.setBeforePendingFinalDeleteAttemptForTesting {
            deleteAttemptStarted.signal()
            _ = allowDeleteAttempt.wait(timeout: .now() + 3)
        }
        defer {
            allowDeleteAttempt.signal()
            TerminalHistoryCoordinator.setBeforePendingFinalDeleteAttemptForTesting(nil)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: ledgerRoot.path
            )
        }

        ssh.closeAndDeletePersistedHistory()
        XCTAssertEqual(deleteAttemptStarted.wait(timeout: .now() + 2), .success)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: ledgerRoot.path
        )
        allowDeleteAttempt.signal()

        let firstBarrier = try XCTUnwrap(
            TerminalSurface.pendingHistoryDeleteBarrier(),
            "failed ownerless cleanup must remain globally joinable"
        )
        XCTAssertFalse(
            firstBarrier.wait(until: .now() + 3),
            "the first disposition must fail explicitly while ledger cleanup is denied"
        )
        TerminalHistoryCoordinator.setBeforePendingFinalDeleteAttemptForTesting(nil)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: ledgerRoot.path
        )
        XCTAssertEqual(
            try context.terminalOutputRepo.totalBytes(surfaceID: surfaceID),
            0,
            "SQLite delete must already be committed before sidecar cleanup failure"
        )
        XCTAssertFalse(
            try context.terminalOutputRepo.failureAnchors(surfaceID: surfaceID).isEmpty,
            "the denied sidecar cleanup fixture must leave an anchor for retry"
        )
        let replacementMarker = "OWNERLESS_SSH_REPLACEMENT_\(UUID().uuidString)"
        try context.terminalOutputRepo.append(
            surfaceID: surfaceID,
            workspaceID: nil,
            chunkIndex: 1,
            data: Data((replacementMarker + "\n").utf8)
        )

        XCTAssertTrue(
            closeSurfacesForApplicationTermination([], timeout: 2),
            "a later real quit pass must retry the retained ownerless disposition"
        )
        XCTAssertTrue(
            try context.terminalOutputRepo.failureAnchors(surfaceID: surfaceID).isEmpty,
            "the successful retry must remove the C80 sidecar anchor"
        )
        XCTAssertTrue(
            try context.terminalOutputRepo.readWindow(
                surfaceID: surfaceID
            ).text.contains(replacementMarker),
            "retry after SQLite commit must not delete a replacement writer's newer bytes"
        )
    }

    func testAppDelegateTerminationBarrierDisposesEmbeddedSSHProcessTree() async throws {
        // WHY: only the outer SSHSurface is registered. AppDelegate must route
        // its bounded termination barrier into the unregistered inner terminal.
        let (_, _, _, _, ssh) = try makeRouterSSH()
        let terminal = try await ssh.installEmbeddedShellForApplicationTerminationTesting()
        let shellPID = try XCTUnwrap(terminal.runtimeHealth().childPID)
        XCTAssertEqual(
            terminal.sendTextStatus(
                "/bin/sh -c 'trap \"\" HUP TERM; while :; do /bin/sleep 30; done'\n"
            ),
            .accepted
        )
        let terminalBecameBusy = await waitUntilAsync(timeout: 2) { terminal.foregroundJobAliveForTesting }
        XCTAssertTrue(terminalBecameBusy)
        let foregroundPGID = try XCTUnwrap(terminal.foregroundProcessGroupForTesting)
        let foregroundGroup = try XCTUnwrap(
            TerminalPTYProcessRuntime.captureForegroundProcessGroup(
                pgid: foregroundPGID,
                shellPID: shellPID
            )
        )
        defer {
            if TerminalPTYProcessRuntime.currentValidation(of: foregroundGroup) == .active {
                _ = Darwin.kill(-foregroundGroup.pgid, SIGKILL)
            }
            _ = Darwin.kill(shellPID, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(shellPID, &status, WNOHANG)
        }

        XCTAssertTrue(
            closeSurfacesForApplicationTermination([ssh], timeout: 2),
            "the same batch barrier called by AppDelegate must await the embedded SSH terminal"
        )
        XCTAssertFalse(terminal.runtimeHealth().ptyOpen)
        XCTAssertEqual(TerminalPTYProcessRuntime.currentValidation(of: foregroundGroup), .gone)
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(Darwin.waitpid(shellPID, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testSelectedSSHForwardsFocusRepairAndHeartbeatIncludesEmbeddedHealth() async throws {
        // WHY: wrapper indirection must not exclude SSH from focus self-healing
        // or from memory/backlog diagnostics used to diagnose long sessions.
        let (_, router, workspace, _, ssh) = try makeRouterSSH()
        try await ssh.installEmbeddedPlaceholderForTesting()

        router.repairSelectedTerminalFocus(workspace: workspace.id, reason: "test")
        XCTAssertEqual(ssh.terminalFocusRepairForwardCountForTesting, 1)

        ssh.didBecomeHidden()
        ssh.appendSystemText("RC2_SSH_DIAGNOSTICS_PENDING\n")
        let snapshot = AppDiagnostics.aggregateSurfaceSnapshot([ssh])
        XCTAssertEqual(snapshot.surfaceCount, 1)
        XCTAssertEqual(snapshot.terminalCount, 1)
        XCTAssertEqual(snapshot.runningTerminals, 0)
        XCTAssertGreaterThan(snapshot.pendingBytes, 0)
    }

    private func makeSurface(outputBus: SurfaceOutputBus = SurfaceOutputBus()) throws -> SSHSurface {
        let surface = try SSHSurface(
            workspaceID: WorkspaceID(),
            cwd: NSTemporaryDirectory(),
            title: "SSH",
            router: nil,
            outputBus: outputBus
        )
        surfaces.append(surface)
        return surface
    }

    private func makePersistentSurface() throws -> (TerminalOutputRepository, SSHSurface) {
        let directory = NSTemporaryDirectory() + "RC2SSHHistory-" + UUID().uuidString
        temporaryDirectories.append(directory)
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let surface = try SSHSurface(
            workspaceID: WorkspaceID(),
            cwd: NSTemporaryDirectory(),
            title: "SSH",
            router: nil,
            historyRepo: context.terminalOutputRepo,
            outputBus: SurfaceOutputBus()
        )
        surfaces.append(surface)
        return (context.terminalOutputRepo, surface)
    }

    private func makeRouterSSH() throws -> (
        AppContext,
        AppCommandRouter,
        Workspace,
        SurfaceDescriptor,
        SSHSurface
    ) {
        let directory = NSTemporaryDirectory() + "RC2SSHRouter-" + UUID().uuidString
        temporaryDirectories.append(directory)
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "ssh", cwd: NSTemporaryDirectory())
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .ssh,
            paneID: nil,
            title: "ssh"
        )
        let ssh = try XCTUnwrap(SurfaceRegistry.shared.surface(descriptor.id) as? SSHSurface)
        return (context, router, workspace, descriptor, ssh)
    }

    private func testProfile() -> SSHHostProfile {
        SSHHostProfile(label: "Local refusal", destination: "127.0.0.1", port: 1)
    }

    private func waitUntilAsync(
        timeout: TimeInterval,
        predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }

    private func waitpidOwnershipWasConsumed(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        errno = 0
        return Darwin.waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
    }
}
