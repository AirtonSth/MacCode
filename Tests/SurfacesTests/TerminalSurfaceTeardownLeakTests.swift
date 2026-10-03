import XCTest
import Darwin
import CoreModel
@testable import Persistence
@testable import Surfaces

@MainActor
final class TerminalSurfaceTeardownLeakTests: XCTestCase {
    func test_cloexecSetupFailureNeverStartsIOAndReapsOwnedChild() throws {
        var spawnedPID: pid_t = -1
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "cloexec-failure",
            launch: .shell(cwd: NSTemporaryDirectory()),
            closeOnExecEnabler: { _ in false },
            nonBlockingFailureBarrierFactory: { pid in
                spawnedPID = pid
                let disposition = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
                    pid: pid,
                    foregroundGroup: nil
                )
                return SurfaceTerminationBarrier(
                    groups: [disposition.group],
                    completionChecks: [disposition.succeeded]
                )
            }
        )
        defer { surface.close() }

        XCTAssertGreaterThan(spawnedPID, 0)
        XCTAssertEqual(surface.runtimeHealth().terminalDeadReason, "pty_cloexec_failed")
        XCTAssertFalse(surface.runtimeHealth().processAlive)
        XCTAssertFalse(surface.runtimeHealth().ptyOpen)
        XCTAssertFalse(surface.runtimeHealth().inputAccepting)
        XCTAssertFalse(surface.inputPumpConfiguredForTesting)
        XCTAssertFalse(surface.readerConfiguredForTesting)
        XCTAssertTrue(waitForReaperCompletion(surface, timeout: 2))
        XCTAssertTrue(waitForWaitpidOwnershipToBeConsumed(spawnedPID, timeout: 1))
    }

    func test_newShellDoesNotInheritExistingPTYMaster() throws {
        // WHY: every later exec inherits every earlier master unless FD_CLOEXEC
        // is set immediately. One surviving shell then pins another tab's PTY.
        let first = try makeDeterministicReaperSurface(title: "cloexec-first")
        let second = try makeDeterministicReaperSurface(title: "cloexec-second")
        defer {
            second.close()
            first.close()
        }
        let firstMaster = first.masterFDForTesting
        let firstDescriptorFlags = fcntl(firstMaster, F_GETFD)
        let secondDescriptorFlags = fcntl(second.masterFDForTesting, F_GETFD)
        XCTAssertGreaterThanOrEqual(firstDescriptorFlags, 0)
        XCTAssertGreaterThanOrEqual(secondDescriptorFlags, 0)
        XCTAssertNotEqual(firstDescriptorFlags & FD_CLOEXEC, 0)
        XCTAssertNotEqual(secondDescriptorFlags & FD_CLOEXEC, 0)

        let inherited = "RC2_INHERITED_A_MASTER"
        let isolated = "RC2_NO_INHERITED_A_MASTER"
        let command = "if /usr/sbin/lsof -a -p $$ -d \(firstMaster) -Fn 2>/dev/null | /usr/bin/grep -q '^n/dev/ptmx$'; then echo \(inherited); else echo \(isolated); fi\n"
        XCTAssertEqual(second.sendTextStatus(command), .accepted)
        let snapshot = try waitForSnapshot(second, containing: isolated)
        XCTAssertFalse(snapshot.text.contains(inherited + "\n"))

        let secondPID = try XCTUnwrap(second.runtimeHealth().childPID)
        first.close()
        XCTAssertTrue(waitForReaperCompletion(first, timeout: 2))
        XCTAssertTrue(second.runtimeHealth().processAlive)
        XCTAssertEqual(second.runtimeHealth().childPID, secondPID)
        XCTAssertTrue(second.runtimeHealth().inputAccepting)
    }

    func test_closeDuringReaperMainCallbackGapDoesNotResignalConsumedPID() throws {
        // WHY: waitpid can finish on the reaper queue while childPID remains on
        // MainActor. A second close in that gap must not signal the reused number.
        let surface = try makeDeterministicReaperSurface(title: "reaper-main-gap")
        defer { surface.close() }
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        XCTAssertEqual(processCommandLine(pid: shellPID), "sh")
        let reaperFinished = DispatchSemaphore(value: 0)
        surface.setChildReapCompletionForTesting {
            reaperFinished.signal()
        }
        surface.beginChildReapForTesting(pid: shellPID, sendInitialHangup: false)

        XCTAssertEqual(
            reaperFinished.wait(timeout: .now() + 3),
            .success,
            terminalFailureDiagnostics(surface: surface, childPID: shellPID)
        )
        XCTAssertEqual(
            surface.childPIDForTesting,
            shellPID,
            "the fixture must hold the MainActor cleanup behind the running test"
        )
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(Darwin.waitpid(shellPID, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "the reaper must already have consumed waitpid")

        surface.close()

        XCTAssertEqual(
            surface.processTreeSignalCountForTestingValue,
            0,
            "close must delegate to the in-flight reaper without signalling a stale PID"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(surface.runtimeHealth().childPID)
    }

    func test_tabCloseDoesNotPublishHealthAfterDelayedReaperMainCallback() throws {
        // WHY: waitpid completion can be queued on MainActor behind close. Once
        // the final close health is published, that callback must not resurrect
        // runtime state after surface.closed reaches the iOS mirror.
        let surface = try makeDeterministicReaperSurface(title: "reaper-health-gap")
        let surfaceID = surface.descriptor.id
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        let reaperFinished = DispatchSemaphore(value: 0)
        let health = LockedRuntimeHealthCount()
        let previousSink = SurfaceRuntimeBus.shared.sink
        defer {
            surface.close()
            SurfaceRuntimeBus.shared.sink = previousSink
        }

        surface.setChildReapCompletionForTesting {
            reaperFinished.signal()
        }
        surface.beginChildReapForTesting(pid: shellPID, sendInitialHangup: false)
        XCTAssertEqual(
            reaperFinished.wait(timeout: .now() + 3),
            .success,
            terminalFailureDiagnostics(surface: surface, childPID: shellPID)
        )
        XCTAssertEqual(
            surface.childPIDForTesting,
            shellPID,
            "the fixture must keep the reaper MainActor callback queued behind close"
        )

        SurfaceRuntimeBus.shared.sink = { id, _ in
            health.record(id)
        }
        surface.close()
        let countAfterClose = health.count(for: surfaceID)
        XCTAssertEqual(countAfterClose, 1, "tab close must publish exactly one final health transition")

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            health.count(for: surfaceID),
            countAfterClose,
            "the delayed reaper callback must not publish health after permanent close"
        )
    }

    func test_tabCloseAfterRuntimeRestartRevokesHealthOnlyAtPermanentClose() throws {
        // WHY: runtime restart deliberately retains health ownership until a
        // replacement takes over. A later permanent close enters the already-
        // closing path and must revoke that ownership before it returns.
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "restart-then-close-health",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        let surfaceID = surface.descriptor.id
        let health = LockedRuntimeHealthCount()
        let previousSink = SurfaceRuntimeBus.shared.sink
        defer {
            surface.close()
            SurfaceRuntimeBus.shared.sink = previousSink
        }
        SurfaceRuntimeBus.shared.sink = { id, _ in
            health.record(id)
        }

        _ = surface.closeForRuntimeRestart()
        let countAfterRestartClose = health.count(for: surfaceID)
        surface.markRuntimeRestartDispositionIncomplete()
        XCTAssertEqual(
            health.count(for: surfaceID),
            countAfterRestartClose + 1,
            "runtimeRestart must retain health publication until replacement or permanent close"
        )

        surface.close()
        let countAfterPermanentClose = health.count(for: surfaceID)
        surface.markRuntimeRestartDispositionIncomplete()
        XCTAssertEqual(
            health.count(for: surfaceID),
            countAfterPermanentClose,
            "an already-closing runtime must not publish health after tabClose returns"
        )
    }

    func test_normalReaperResumesAfterApplicationDispositionOwnershipEnds() throws {
        // WHY: restart disposition temporarily owns waitpid. The normal reaper
        // must pause without signalling, then resume if fast disposition gives
        // ownership back; otherwise its in-flight flag blocks every fallback.
        let surface = try makeDeterministicReaperSurface(title: "reaper-ownership-handoff")
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        let reaperFinished = DispatchSemaphore(value: 0)
        surface.setChildReapCompletionForTesting {
            reaperFinished.signal()
        }
        TerminalPTYProcessRuntime.setApplicationTerminationOwnershipForTesting(
            pid: shellPID,
            owned: true
        )
        defer {
            TerminalPTYProcessRuntime.setApplicationTerminationOwnershipForTesting(
                pid: shellPID,
                owned: false
            )
            surface.close()
        }

        surface.beginChildReapForTesting(pid: shellPID, sendInitialHangup: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(reaperFinished.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(surface.childPIDForTesting, shellPID)
        errno = 0
        XCTAssertTrue(Darwin.kill(shellPID, 0) == 0 || errno == EPERM)

        TerminalPTYProcessRuntime.setApplicationTerminationOwnershipForTesting(
            pid: shellPID,
            owned: false
        )
        surface.continueCleanupAfterFailedRuntimeRestart()

        XCTAssertEqual(reaperFinished.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(waitForReaperCompletion(surface, timeout: 1))
        XCTAssertTrue(waitForWaitpidOwnershipToBeConsumed(shellPID, timeout: 1))
    }

    func test_beginChildReapRegistersJoinableWorkAndClearsInFlightOwnership() throws {
        // WHY: tab close / EOF reapers must appear in activeProcessDispositionBarrier
        // after SurfaceRegistry unregister so applicationWillTerminate can join them.
        // Completing the reaper must clear childReapInFlightPID and set the
        // reaped sentinel (-1); a stuck in-flight flag blocks later fallbacks.
        let surface = try makeDeterministicReaperSurface(title: "reaper-joinable-work")
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        let reaperFinished = DispatchSemaphore(value: 0)
        surface.setChildReapCompletionForTesting {
            reaperFinished.signal()
        }
        defer { surface.close() }

        surface.beginChildReapForTesting(pid: shellPID, sendInitialHangup: true)
        XCTAssertNotNil(
            TerminalSurface.activeProcessDispositionBarrier(),
            "beginChildReap must register joinable reaper work for app-exit aggregation"
        )
        XCTAssertEqual(reaperFinished.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(waitForReaperCompletion(surface, timeout: 1))
        XCTAssertTrue(waitForWaitpidOwnershipToBeConsumed(shellPID, timeout: 1))
        XCTAssertEqual(
            surface.childPIDForTesting,
            -1,
            "successful reap uses the reaped sentinel (-1), not a nil optional"
        )
        XCTAssertNil(surface.runtimeHealth().childPID)
    }

    func test_nonblockingSetupFailureNeverStartsIOAndReapsOwnedChild() throws {
        // WHY: a blocking PTY can deadlock both the input pump and reader. The
        // spawn must be aborted before either worker exists, and the owned child
        // must still be proven reaped rather than hidden by clearing its PID.
        var spawnedPID: pid_t = -1
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "nonblocking-failure",
            launch: .shell(cwd: NSTemporaryDirectory()),
            nonBlockingEnabler: { _ in false },
            nonBlockingFailureBarrierFactory: { pid in
                spawnedPID = pid
                let disposition = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
                    pid: pid,
                    foregroundGroup: nil
                )
                return SurfaceTerminationBarrier(
                    groups: [disposition.group],
                    completionChecks: [disposition.succeeded]
                )
            }
        )
        defer { surface.close() }

        XCTAssertGreaterThan(spawnedPID, 0)
        XCTAssertFalse(surface.runtimeHealth().processAlive)
        XCTAssertFalse(surface.runtimeHealth().ptyOpen)
        XCTAssertFalse(surface.runtimeHealth().inputAccepting)
        XCTAssertFalse(surface.inputPumpConfiguredForTesting)
        XCTAssertFalse(surface.readerConfiguredForTesting)
        XCTAssertTrue(waitForReaperCompletion(surface, timeout: 2))
        XCTAssertTrue(
            waitForWaitpidOwnershipToBeConsumed(spawnedPID, timeout: 1),
            "successful nonblocking-failure disposition must consume the child exactly once"
        )
    }

    func test_nonblockingSetupFailurePreservesPIDWhenDispositionFails() throws {
        // WHY: clearing childPID after only waiting for a worker masks a failed
        // reap as success. Health must retain the owned PID and report timeout.
        let dispositionFinished = DispatchGroup()
        dispositionFinished.enter()
        var spawnedPID: pid_t = -1
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "nonblocking-failed-reap",
            launch: .shell(cwd: NSTemporaryDirectory()),
            nonBlockingEnabler: { _ in false },
            nonBlockingFailureBarrierFactory: { pid in
                spawnedPID = pid
                dispositionFinished.leave()
                return SurfaceTerminationBarrier(
                    groups: [dispositionFinished],
                    completionChecks: [{ false }]
                )
            }
        )
        defer {
            _ = Darwin.kill(-spawnedPID, SIGKILL)
            _ = Darwin.kill(spawnedPID, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(spawnedPID, &status, 0)
        }

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline,
              surface.runtimeHealth().terminalDeadReason != "process_reap_timeout" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(surface.runtimeHealth().terminalDeadReason, "process_reap_timeout")
        XCTAssertEqual(surface.runtimeHealth().childPID, spawnedPID)
        XCTAssertFalse(surface.runtimeHealth().processAlive)
        XCTAssertFalse(surface.runtimeHealth().ptyOpen)
        XCTAssertFalse(surface.runtimeHealth().inputAccepting)
        XCTAssertFalse(surface.inputPumpConfiguredForTesting)
        XCTAssertFalse(surface.readerConfiguredForTesting)
    }

    func test_neverCompletingDispositionReportsTimeoutInsteadOfParkingAWorker() throws {
        // WHY: the observer waited with .distantFuture, so a child that never
        // finishes disposition parked one GCD worker forever per terminal and
        // health never reported the stuck reap. Ownership (childPID) must stay.
        let neverFinishes = DispatchGroup()
        neverFinishes.enter()
        var spawnedPID: pid_t = -1
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "never-finishing-disposition",
            launch: .shell(cwd: NSTemporaryDirectory()),
            nonBlockingEnabler: { _ in false },
            nonBlockingFailureBarrierFactory: { pid in
                spawnedPID = pid
                return SurfaceTerminationBarrier(groups: [neverFinishes], completionChecks: [{ true }])
            },
            childDispositionObserverTimeout: 0.3
        )
        defer {
            neverFinishes.leave()
            _ = Darwin.kill(-spawnedPID, SIGKILL)
            _ = Darwin.kill(spawnedPID, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(spawnedPID, &status, 0)
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              surface.runtimeHealth().terminalDeadReason != "process_reap_timeout" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(surface.runtimeHealth().terminalDeadReason, "process_reap_timeout")
        XCTAssertEqual(surface.runtimeHealth().childPID, spawnedPID, "a timed-out observer must not drop child ownership")
    }

    func test_reaperFinishesCapturedForegroundGroupAfterShellWasReaped() throws {
        let surface = try makeDeterministicReaperSurface(title: "foreground-group-reap")
        defer { surface.close() }
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        XCTAssertEqual(
            surface.sendTextStatus(
                "/bin/sh -c 'trap \"\" HUP TERM; while :; do /bin/sleep 30; done'\n"
            ),
            .accepted
        )
        try waitForBusy(surface)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let foregroundPGID = try XCTUnwrap(
            surface.foregroundProcessGroupForTesting,
            "a foreground job must expose its actual controlling-terminal process group"
        )
        XCTAssertNotEqual(
            foregroundPGID,
            shellPID,
            "the regression requires a foreground process group distinct from the interactive shell"
        )
        let target = try XCTUnwrap(
            TerminalPTYProcessRuntime.captureForegroundProcessGroup(
                pgid: foregroundPGID,
                shellPID: shellPID
            )
        )
        defer {
            if TerminalPTYProcessRuntime.currentValidation(of: target) == .active {
                _ = Darwin.kill(-target.pgid, SIGKILL)
            }
        }

        // Force the exact race: the interactive shell exits first while its
        // HUP/TERM-resistant foreground job remains alive in a distinct group.
        // Production observes WNOWAIT and reserves the shell PID until the group
        // finishes, then performs the single final waitpid.
        surface.close()
        XCTAssertTrue(
            waitForShellExitToBeObservedWithoutReaping(shellPID, timeout: 0.6),
            "the shell must exit before foreground-group SIGKILL escalation"
        )
        XCTAssertEqual(
            TerminalPTYProcessRuntime.currentValidation(of: target),
            .active,
            "precondition: the captured foreground group must remain after shell reap and initial HUP"
        )

        XCTAssertTrue(
            waitForCapturedGroupsToDisappear([target], timeout: 4).isEmpty,
            "the independent foreground escalation must remove the HUP/TERM-resistant group"
        )
        XCTAssertTrue(waitForReaperCompletion(surface, timeout: 1))
        XCTAssertTrue(waitForWaitpidOwnershipToBeConsumed(shellPID, timeout: 1),
                      "the shell must be fully waited, not left as a zombie")
    }

    func test_ptyEOFRoutesExitedShellAndDetachedResistantForegroundThroughReaper() throws {
        let surface = try makeDeterministicReaperSurface(title: "foreground-group-eof-reap")
        defer { surface.close() }
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        let releaseFile = "/tmp/rc-eof-\(String(UUID().uuidString.prefix(8))).go"
        defer {
            if FileManager.default.fileExists(atPath: releaseFile) {
                _ = try? FileManager.default.removeItem(atPath: releaseFile)
            }
        }
        XCTAssertEqual(
            surface.sendTextStatus(
                "/bin/sh -c 'trap \"\" 1 15;until [ -f \(releaseFile) ];do /bin/sleep .05;done;exec </dev/null >/dev/null 2>&1;kill -9 \"$PPID\";while :;do /bin/sleep 30;done'\n"
            ),
            .accepted
        )
        try waitForBusy(surface)
        let target = try capturedForegroundGroup(surface: surface, shellPID: shellPID)
        defer {
            if TerminalPTYProcessRuntime.currentValidation(of: target) == .active {
                _ = Darwin.kill(-target.pgid, SIGKILL)
            }
        }

        XCTAssertTrue(FileManager.default.createFile(atPath: releaseFile, contents: Data()))
        _ = try waitForDead(surface, timeout: 3)
        XCTAssertEqual(
            TerminalPTYProcessRuntime.currentValidation(of: target),
            .active,
            "PTY EOF must not falsely imply that a detached foreground process group is gone"
        )
        XCTAssertTrue(
            waitForCapturedGroupsToDisappear([target], timeout: 4).isEmpty,
            "EOF teardown must retain and escalate the captured foreground group after the shell exits"
        )
        XCTAssertTrue(waitForReaperCompletion(surface, timeout: 1))
        XCTAssertTrue(waitForWaitpidOwnershipToBeConsumed(shellPID, timeout: 1))
    }

    func test_capturedGroupValidationRejectsForcedNumericPGIDReuse() {
        let target = TerminalPTYProcessRuntime.CapturedForegroundProcessGroup(
            pgid: 42,
            sessionID: 700
        )

        XCTAssertEqual(
            TerminalPTYProcessRuntime.validation(
                of: target,
                memberPIDs: [101, 102],
                processGroup: { _ in 42 },
                session: { $0 == 101 ? 700 : 701 }
            ),
            .active,
            "one member in the captured session proves the original foreground group is still owned"
        )
        XCTAssertEqual(
            TerminalPTYProcessRuntime.validation(
                of: target,
                memberPIDs: [201, 202],
                processGroup: { _ in 42 },
                session: { _ in 999 }
            ),
            .gone,
            "a reused numeric PGID whose members belong to another session must never be signalled"
        )
    }

    func test_applicationDispositionHandoffMakesNormalReaperStopAfterECHILD() throws {
        // WHY: app disposition and the normal reaper may overlap. Once the app
        // owner consumes waitpid, the resumed normal reaper has no PID/SID anchor
        // and must finish without signalling numeric identifiers from old state.
        let child = TerminalPTYProcessRuntime.spawn(
            cwd: NSTemporaryDirectory(),
            executable: "/bin/sh",
            arguments: ["sh", "-c", "while :; do /bin/sleep 30; done"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        XCTAssertGreaterThan(child.pid, 0)
        XCTAssertGreaterThanOrEqual(child.masterFD, 0)
        defer {
            Darwin.close(child.masterFD)
            _ = Darwin.kill(child.pid, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(child.pid, &status, WNOHANG)
        }

        let normalReaperCompleted = DispatchSemaphore(value: 0)
        TerminalPTYProcessRuntime.reapWithEscalation(
            pid: child.pid,
            foregroundGroup: nil,
            initialHangupAlreadySent: false
        ) { _ in
            normalReaperCompleted.signal()
        }
        let disposition = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
            pid: child.pid,
            foregroundGroup: nil
        )

        XCTAssertEqual(disposition.group.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(disposition.succeeded())
        XCTAssertEqual(normalReaperCompleted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(waitForWaitpidOwnershipToBeConsumed(child.pid, timeout: 1))
    }

    func test_reapPollingHasHardDeadline() {
        XCTAssertEqual(
            TerminalPTYProcessRuntime.reapPollDecision(
                shellExitObserved: false,
                groupValidation: .unverifiable,
                elapsed: 4.99
            ),
            .continuePolling
        )
        XCTAssertEqual(
            TerminalPTYProcessRuntime.reapPollDecision(
                shellExitObserved: false,
                groupValidation: .unverifiable,
                elapsed: 5
            ),
            .beginTimeoutGrace,
            "the hard deadline must issue one final validated SIGKILL before final waitpid"
        )
        XCTAssertEqual(
            TerminalPTYProcessRuntime.reapPollDecision(
                shellExitObserved: false,
                groupValidation: .unverifiable,
                elapsed: 5.49,
                deadlineKillSent: true
            ),
            .continuePolling
        )
        XCTAssertEqual(
            TerminalPTYProcessRuntime.reapPollDecision(
                shellExitObserved: false,
                groupValidation: .unverifiable,
                elapsed: 5.5,
                deadlineKillSent: true
            ),
            .timeout,
            "an unverifiable process group must fail loud at the bounded deadline instead of retaining a forever poll closure"
        )
    }

    func test_finalWaitPollRetainsOwnershipUntilDelayedChildActuallyReaped() throws {
        // WHY: SIGKILL delivery is asynchronous. A single WNOHANG wait can return
        // zero, and dropping the reaper at that point leaves a later zombie.
        let child = TerminalPTYProcessRuntime.spawn(
            cwd: NSTemporaryDirectory(),
            executable: "/bin/sh",
            arguments: ["sh", "-c", "/bin/sleep 0.25; exit 23"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        XCTAssertGreaterThan(child.pid, 0)
        XCTAssertGreaterThanOrEqual(child.masterFD, 0)
        defer {
            Darwin.close(child.masterFD)
            var status: Int32 = 0
            if Darwin.waitpid(child.pid, &status, WNOHANG) == 0 {
                _ = Darwin.kill(child.pid, SIGKILL)
                _ = Darwin.waitpid(child.pid, &status, 0)
            }
        }

        let completed = DispatchSemaphore(value: 0)
        TerminalPTYProcessRuntime.waitUntilChildReaped(
            pid: child.pid,
            pollDelay: .milliseconds(10)
        ) { _ in
            completed.signal()
        }

        XCTAssertEqual(
            completed.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "the reaper must stay pending while waitpid still reports a live child"
        )
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(Darwin.waitpid(child.pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD,
                       "completion is legal only after waitpid consumed the child or proved ECHILD")
    }

    func test_tabCloseRegistersDispositionJoinableByApplicationTermination() throws {
        // WHY: permanentlyCloseRuntimeSurface unregisters immediately after tab
        // close. applicationWillTerminate only joins registered surfaces plus
        // TerminalSurface.activeProcessDispositionBarrier(). A tab-close reaper
        // that is not registered as joinable work leaves still-owned PTY children
        // outside the quit barrier after unregister.
        let surface = try makeDeterministicReaperSurface(title: "tab-close-disposition-visible")
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        XCTAssertEqual(
            surface.sendTextStatus(
                "/bin/sh -c 'trap \"\" HUP TERM; while :; do /bin/sleep 30; done'\n"
            ),
            .accepted
        )
        try waitForBusy(surface)
        let foregroundGroup = try capturedForegroundGroup(surface: surface, shellPID: shellPID)
        defer {
            if TerminalPTYProcessRuntime.currentValidation(of: foregroundGroup) == .active {
                _ = Darwin.kill(-foregroundGroup.pgid, SIGKILL)
            }
            _ = Darwin.kill(shellPID, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(shellPID, &status, WNOHANG)
        }

        surface.close()

        let barrier = try XCTUnwrap(
            TerminalSurface.activeProcessDispositionBarrier(),
            "tab close must publish joinable reaper work so app exit can wait after surface unregister"
        )
        XCTAssertTrue(
            barrier.wait(until: .now() + 2),
            "the registered tab-close reaper must reap a HUP/TERM-resistant tree within the app-exit window"
        )
        XCTAssertEqual(
            TerminalPTYProcessRuntime.currentValidation(of: foregroundGroup),
            .gone,
            "tab-close reaper must clear the captured foreground group, not only the shell"
        )
        XCTAssertTrue(waitForWaitpidOwnershipToBeConsumed(shellPID, timeout: 0.2))
        XCTAssertTrue(waitForReaperCompletion(surface, timeout: 1))
        XCTAssertEqual(surface.childPIDForTesting, -1)
    }

    func test_applicationTerminationBarrierKillsAndReapsHUPTERMResistantProcessTree() throws {
        // WHY: applicationWillTerminate cannot leave the normal async escalation
        // behind when the process exits. The barrier must close the PTY, escalate
        // a resistant foreground group, and consume the shell before returning.
        let surface = try makeDeterministicReaperSurface(title: "application-termination-barrier")
        defer { surface.close() }
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        XCTAssertEqual(
            surface.sendTextStatus(
                "/bin/sh -c 'trap \"\" HUP TERM; while :; do /bin/sleep 30; done'\n"
            ),
            .accepted
        )
        try waitForBusy(surface)
        let foregroundGroup = try capturedForegroundGroup(surface: surface, shellPID: shellPID)
        defer {
            if TerminalPTYProcessRuntime.currentValidation(of: foregroundGroup) == .active {
                _ = Darwin.kill(-foregroundGroup.pgid, SIGKILL)
            }
            _ = Darwin.kill(shellPID, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(shellPID, &status, WNOHANG)
        }

        let barrier = try XCTUnwrap(surface.closeForApplicationTermination())
        XCTAssertTrue(
            barrier.wait(until: .now() + 2),
            "the bounded app-exit barrier must finish every validated terminal target"
        )
        XCTAssertFalse(surface.runtimeHealth().ptyOpen,
                       "the PTY must be closed before applicationWillTerminate returns")
        XCTAssertEqual(
            TerminalPTYProcessRuntime.currentValidation(of: foregroundGroup),
            .gone,
            "a HUP/TERM-resistant foreground group must not survive the app-exit barrier"
        )
        XCTAssertTrue(
            waitForWaitpidOwnershipToBeConsumed(shellPID, timeout: 0.2),
            "the shell must be reaped synchronously instead of becoming a zombie after app exit"
        )
    }

    func test_applicationTerminationBarrierSweepsResistantBackgroundProcessGroupInOwnedSession() throws {
        // WHY: tcgetpgrp exposes only the foreground job. A detached/background
        // group in the same PTY session survives shell+foreground teardown unless
        // app termination enumerates every validated SID-owned process group.
        let surface = try makeDeterministicReaperSurface(
            title: "application-termination-background-session"
        )
        defer { surface.close() }
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        let pidFile = NSTemporaryDirectory() + "RC2-BG-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        XCTAssertEqual(
            surface.sendTextStatus(
                "/bin/sh -c 'trap \"\" HUP TERM; while :; do /bin/sleep 30; done' & echo $! > '\(pidFile)'\n"
            ),
            .accepted
        )

        let deadline = Date().addingTimeInterval(2)
        var backgroundPIDValue: pid_t?
        while Date() < deadline, backgroundPIDValue == nil {
            if let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let parsed = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed > 0 {
                backgroundPIDValue = parsed
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let backgroundPID: pid_t = try XCTUnwrap(backgroundPIDValue)
        let backgroundPGID = Darwin.getpgid(backgroundPID)
        XCTAssertGreaterThan(backgroundPGID, 0)
        XCTAssertNotEqual(backgroundPGID, shellPID)
        let backgroundGroup = TerminalPTYProcessRuntime.CapturedForegroundProcessGroup(
            pgid: backgroundPGID,
            sessionID: shellPID
        )
        XCTAssertEqual(TerminalPTYProcessRuntime.currentValidation(of: backgroundGroup), .active)
        defer {
            if TerminalPTYProcessRuntime.currentValidation(of: backgroundGroup) == .active {
                _ = Darwin.kill(-backgroundPGID, SIGKILL)
            }
            _ = Darwin.kill(shellPID, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(shellPID, &status, WNOHANG)
        }

        let barrier = try XCTUnwrap(surface.closeForApplicationTermination())
        XCTAssertTrue(barrier.wait(until: .now() + 2))
        XCTAssertEqual(
            TerminalPTYProcessRuntime.currentValidation(of: backgroundGroup),
            .gone,
            "the validated background group in SID==shellPID must not survive app termination"
        )
        XCTAssertTrue(waitForWaitpidOwnershipToBeConsumed(shellPID, timeout: 0.2))
    }

    func test_normalReaperRetainsExitedShellUntilRedirectedResistantSessionGroupIsGone() throws {
        // WHY: a background job can close every PTY descriptor before the shell
        // exits. EOF then starts the normal reaper without a foreground target.
        // The shell PID must remain WNOWAIT-owned until every group in its SID is
        // killed, or later app termination can no longer find the orphaned job.
        let surface = try makeDeterministicReaperSurface(
            title: "redirected-background-session-reap"
        )
        defer { surface.close() }
        let shellPID = try XCTUnwrap(surface.runtimeHealth().childPID)
        let handshakeID = String(UUID().uuidString.prefix(8))
        let readyFile = "/tmp/rc-bg-\(handshakeID).ready"
        let pidFile = "/tmp/rc-bg-\(handshakeID).pid"
        let releaseFile = "/tmp/rc-bg-\(handshakeID).go"
        defer {
            if FileManager.default.fileExists(atPath: readyFile) {
                _ = try? FileManager.default.removeItem(atPath: readyFile)
            }
            if FileManager.default.fileExists(atPath: pidFile) {
                _ = try? FileManager.default.removeItem(atPath: pidFile)
            }
            if FileManager.default.fileExists(atPath: releaseFile) {
                _ = try? FileManager.default.removeItem(atPath: releaseFile)
            }
        }
        XCTAssertEqual(surface.sendTextStatus(": > \(readyFile)\n"), .accepted)
        let readyDeadline = Date().addingTimeInterval(6)
        while Date() < readyDeadline,
              !FileManager.default.fileExists(atPath: readyFile) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: readyFile),
            "the interactive shell must consume input before the destructive EOF fixture starts; "
                + terminalFailureDiagnostics(surface: surface, childPID: shellPID)
        )
        guard FileManager.default.fileExists(atPath: readyFile) else { return }

        XCTAssertEqual(
            surface.sendTextStatus(
                "/bin/sh -c 'trap \"\" 1 15;exec </dev/null >/dev/null 2>&1;while :;do /bin/sleep 30;done' & echo $! > \(pidFile);until [ -f \(releaseFile) ];do /bin/sleep .05;done;kill -9 $$\n"
            ),
            .accepted
        )
        let pidDeadline = Date().addingTimeInterval(6)
        var backgroundPIDValue: pid_t?
        while Date() < pidDeadline, backgroundPIDValue == nil {
            if let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let parsed = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed > 0 {
                backgroundPIDValue = parsed
            } else {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        let backgroundPID: pid_t = try XCTUnwrap(backgroundPIDValue)
        XCTAssertGreaterThan(backgroundPID, 0)
        let backgroundPGID = Darwin.getpgid(backgroundPID)
        XCTAssertGreaterThan(backgroundPGID, 0)
        XCTAssertNotEqual(backgroundPGID, shellPID)
        let backgroundGroup = TerminalPTYProcessRuntime.CapturedForegroundProcessGroup(
            pgid: backgroundPGID,
            sessionID: shellPID
        )
        defer {
            if TerminalPTYProcessRuntime.currentValidation(of: backgroundGroup) == .active {
                _ = Darwin.kill(-backgroundPGID, SIGKILL)
            }
            _ = Darwin.kill(shellPID, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(shellPID, &status, WNOHANG)
        }

        XCTAssertEqual(TerminalPTYProcessRuntime.currentValidation(of: backgroundGroup), .active)
        XCTAssertTrue(FileManager.default.createFile(atPath: releaseFile, contents: Data()))
        XCTAssertTrue(
            waitForShellZombieStillOwned(shellPID, timeout: 1),
            "the normal reaper must observe but not consume the exited shell while its SID still owns a live group"
        )
        XCTAssertEqual(
            TerminalPTYProcessRuntime.currentValidation(of: backgroundGroup),
            .active,
            "precondition: HUP/TERM-resistant redirected job must survive until SIGKILL escalation"
        )
        XCTAssertEqual(
            surface.runtimeHealth().childPID,
            shellPID,
            "runtime ownership must remain registered until the complete session is disposed"
        )

        XCTAssertTrue(
            waitForCapturedGroupsToDisappear([backgroundGroup], timeout: 4).isEmpty,
            "normal EOF teardown must sweep every validated group in SID==shellPID"
        )
        XCTAssertTrue(waitForReaperCompletion(surface, timeout: 1))
        XCTAssertTrue(waitForWaitpidOwnershipToBeConsumed(shellPID, timeout: 1))

        if let barrier = surface.closeForApplicationTermination() {
            XCTAssertTrue(barrier.wait(until: .now() + 2))
        }
        XCTAssertEqual(
            TerminalPTYProcessRuntime.currentValidation(of: backgroundGroup),
            .gone,
            "a later application exit must not inherit a redirected orphan from normal EOF teardown"
        )
    }

    func test_applicationTerminationBarrierDoesNotDeadlockOnReaderWaitingForMainHandoff() throws {
        // WHY: the reader intentionally uses main.sync for bounded backpressure.
        // Quit runs on MainActor; waiting for the dispatch-source cancel handler
        // while that reader waits on main is a deterministic circular wait. The
        // bytes already read must also cross the final history barrier.
        let database = try SQLiteDB(path: ":memory:")
        try Schema.migrate(database)
        let repository = TerminalOutputRepository(db: database)
        let surfaceID = SurfaceID()
        let surface = try makeDeterministicReaperSurface(
            title: "application-termination-reader-handoff",
            assignedSurfaceID: surfaceID,
            historyRepo: repository
        )
        defer { surface.close() }
        let preparationDeadline = Date().addingTimeInterval(1)
        while Date() < preparationDeadline {
            if case .ready = surface.historyPreparationStateForTesting { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard case .ready = surface.historyPreparationStateForTesting else {
            XCTFail("history must prepare before the reader handoff fixture")
            return
        }
        let readinessFile = "/tmp/rc-reader-ready-\(UUID().uuidString).flag"
        defer { try? FileManager.default.removeItem(atPath: readinessFile) }
        XCTAssertEqual(
            surface.sendTextStatus("stty -echo; : > \(readinessFile)\n"),
            .accepted
        )
        let readinessDeadline = Date().addingTimeInterval(2)
        while Date() < readinessDeadline,
              !FileManager.default.fileExists(atPath: readinessFile) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: readinessFile),
            "deterministic /bin/sh must disable tty echo before the reader-gap fixture"
        )
        guard FileManager.default.fileExists(atPath: readinessFile) else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let marker = "RC2_READER_QUIT_BARRIER"
        let markerBatchGate = ReaderMarkerBatchGate(marker: Data(marker.utf8))
        let readerReachedHandoff = DispatchSemaphore(value: 0)
        surface.setReaderWillPublishForTesting { output in
            markerBatchGate.observe(output)
        }
        surface.setReaderWillEnterMainHandoffForTesting {
            guard markerBatchGate.claim() else { return }
            readerReachedHandoff.signal()
        }
        XCTAssertEqual(
            surface.sendTextStatus("printf '\(marker)\\n'; /bin/sleep 30\n"),
            .accepted
        )
        XCTAssertEqual(
            readerReachedHandoff.wait(timeout: .now() + 1),
            .success,
            "precondition: the PTY reader must be blocked immediately before main.sync"
        )

        let barrier = try XCTUnwrap(surface.closeForApplicationTermination())
        XCTAssertTrue(
            barrier.wait(until: .now() + 2),
            "lease-serialized PTY close must let the real disposition complete, not merely hit a timeout"
        )
        XCTAssertFalse(surface.runtimeHealth().ptyOpen)
        let history = try repository.readWindow(
            surfaceID: surfaceID.value.uuidString,
            maxBytes: 256 * 1024
        )
        XCTAssertTrue(
            history.text.contains(marker),
            "bytes read before quit must be durable before the termination barrier succeeds; "
                + "historyTail=\(String(history.text.suffix(240))) "
                + "snapshotTail=\(String(surface.readTextSnapshot().text.suffix(240))) "
                + "health=\(surface.runtimeHealth())"
        )
        surface.setReaderWillEnterMainHandoffForTesting(nil)
        surface.setReaderWillPublishForTesting(nil)
    }

    func test_500MixedTerminalTeardownsReapChildrenGroupsAndKeepResourcesBounded() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RC2_TERMINAL_TEARDOWN_MIXED"] == "1" else {
            throw XCTSkip("set RC2_TERMINAL_TEARDOWN_MIXED=1 to run mixed terminal teardown stress")
        }
        let iterations = Int(env["RC2_TERMINAL_TEARDOWN_ITERATIONS"] ?? "500") ?? 500
        let maxFDGrowth = Int(env["RC2_TERMINAL_TEARDOWN_MAX_FD_GROWTH"] ?? "12") ?? 12
        let maxFootprintGrowthMB = UInt64(env["RC2_TERMINAL_TEARDOWN_MAX_FOOTPRINT_MB"] ?? "128") ?? 128

        try warmUpTerminalRuntime()
        let baselineFDs = try openFDCount()
        let baselineFootprint = try currentPhysicalFootprintBytes()
        var childPIDs: [pid_t] = []
        childPIDs.reserveCapacity(iterations)
        var foregroundGroups: [TerminalPTYProcessRuntime.CapturedForegroundProcessGroup] = []
        foregroundGroups.reserveCapacity(iterations * 2 / 3)

        for index in 0..<iterations {
            let captured = try autoreleasepool { () throws -> (
                pid: pid_t,
                foregroundGroup: TerminalPTYProcessRuntime.CapturedForegroundProcessGroup?
            ) in
                let surface = try makeDeterministicReaperSurface(
                    title: "mixed-teardown-\(index)"
                )
                defer { surface.close() }
                let pid = try XCTUnwrap(
                    surface.runtimeHealth().childPID,
                    "every stress surface must expose the child close is responsible for reaping"
                )
                let marker = "RC2_MIXED_TEARDOWN_\(index)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                var foregroundGroup: TerminalPTYProcessRuntime.CapturedForegroundProcessGroup?

                switch index % 3 {
                case 0:
                    XCTAssertEqual(
                        surface.sendTextStatus("printf '\\n\(marker)_EOF\\n'; exit 0\n"),
                        .accepted
                    )
                    _ = try waitForSnapshot(surface, containing: "\(marker)_EOF")
                    _ = try waitForDead(surface)
                case 1:
                    XCTAssertEqual(
                        surface.sendTextStatus("printf '\\n\(marker)_LIVE\\n'; /bin/sleep 30\n"),
                        .accepted
                    )
                    _ = try waitForSnapshot(surface, containing: "\(marker)_LIVE")
                    try waitForBusy(surface)
                    foregroundGroup = try capturedForegroundGroup(surface: surface, shellPID: pid)
                default:
                    XCTAssertEqual(
                        surface.sendTextStatus(
                            "/bin/sh -c 'trap \"\" HUP TERM; printf \"\\n\(marker)_RESISTANT\\n\"; while :; do /bin/sleep 30; done'\n"
                        ),
                        .accepted
                    )
                    try waitForBusy(surface)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    foregroundGroup = try capturedForegroundGroup(surface: surface, shellPID: pid)
                }
                surface.close()
                return (pid, foregroundGroup)
            }
            childPIDs.append(captured.pid)
            if let foregroundGroup = captured.foregroundGroup {
                foregroundGroups.append(foregroundGroup)
            }
            if index % 25 == 0 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }

        let remaining = waitForProcessesAndGroupsToDisappear(childPIDs, timeout: 15)
        XCTAssertTrue(
            remaining.isEmpty,
            "all natural, live-close, and HUP/TERM-resistant process trees must be reaped; remaining=\(remaining.prefix(20))"
        )
        let remainingForegroundGroups = waitForCapturedGroupsToDisappear(
            foregroundGroups,
            timeout: 15
        )
        XCTAssertTrue(
            remainingForegroundGroups.isEmpty,
            "every actual foreground process group captured before close must disappear; remaining=\(remainingForegroundGroups.prefix(20))"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        let finalFDs = try openFDCount()
        let finalFootprint = try currentPhysicalFootprintBytes()
        let fdGrowth = finalFDs - baselineFDs
        let footprintGrowth = finalFootprint > baselineFootprint ? finalFootprint - baselineFootprint : 0
        let maxFootprintGrowthBytes = maxFootprintGrowthMB * 1024 * 1024

        print("TerminalMixedTeardownStress iterations=\(iterations) baselineFDs=\(baselineFDs) finalFDs=\(finalFDs) fdGrowth=\(fdGrowth) baselineFootprint=\(baselineFootprint) finalFootprint=\(finalFootprint) footprintGrowth=\(footprintGrowth)")
        XCTAssertLessThanOrEqual(
            fdGrowth,
            maxFDGrowth,
            "\(iterations) mixed teardown cycles must return file descriptors near the warmed baseline"
        )
        XCTAssertLessThanOrEqual(
            footprintGrowth,
            maxFootprintGrowthBytes,
            "\(iterations) mixed teardown cycles must keep physical footprint growth within \(maxFootprintGrowthMB) MB"
        )
    }

    func test_createStreamCloseTerminalSurfacesKeepsFDsAndFootprintBounded() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RC2_TERMINAL_TEARDOWN_STRESS"] == "1" else {
            throw XCTSkip("set RC2_TERMINAL_TEARDOWN_STRESS=1 to run terminal teardown/leak stress")
        }
        let iterations = Int(env["RC2_TERMINAL_TEARDOWN_ITERATIONS"] ?? "100") ?? 100
        let maxFDGrowth = Int(env["RC2_TERMINAL_TEARDOWN_MAX_FD_GROWTH"] ?? "8") ?? 8
        let maxFootprintGrowthMB = UInt64(env["RC2_TERMINAL_TEARDOWN_MAX_FOOTPRINT_MB"] ?? "96") ?? 96

        let baselineFDs = try openFDCount()
        let baselineFootprint = try currentPhysicalFootprintBytes()

        for index in 0..<iterations {
            try autoreleasepool {
                let surface = try makeDeterministicReaperSurface(title: "teardown-\(index)")
                let marker = "RC2_TEARDOWN_\(index)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                XCTAssertEqual(surface.sendTextStatus("printf '\\n\(marker)\\n'; exit 0\n"), .accepted,
                               "terminal \(index) must accept input before teardown")
                _ = try waitForSnapshot(surface, containing: marker)
                _ = try waitForDead(surface)
                surface.close()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let finalFDs = try openFDCount()
        let finalFootprint = try currentPhysicalFootprintBytes()
        let fdGrowth = finalFDs - baselineFDs
        let footprintGrowth = finalFootprint > baselineFootprint ? finalFootprint - baselineFootprint : 0
        let maxFootprintGrowthBytes = maxFootprintGrowthMB * 1024 * 1024

        print("TerminalTeardownStress iterations=\(iterations) baselineFDs=\(baselineFDs) finalFDs=\(finalFDs) fdGrowth=\(fdGrowth) baselineFootprint=\(baselineFootprint) finalFootprint=\(finalFootprint) footprintGrowth=\(footprintGrowth)")
        XCTAssertLessThanOrEqual(fdGrowth, maxFDGrowth,
                                 "creating/closing \(iterations) terminals must return fd count near baseline")
        XCTAssertLessThanOrEqual(footprintGrowth, maxFootprintGrowthBytes,
                                 "creating/closing \(iterations) terminals must not grow physical footprint beyond \(maxFootprintGrowthMB) MB")
    }

    private func waitForSnapshot(_ surface: TerminalSurface, containing needle: String, timeout: TimeInterval = 6) throws -> TerminalTextSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var last = surface.readTextSnapshot()
        while Date() < deadline {
            last = surface.readTextSnapshot()
            if last.text.contains(needle) { return last }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for terminal output containing \(needle); last tail=\(String(last.text.suffix(240)))")
        throw WaitTimeout(reason: "terminal output \(needle)")
    }

    private func terminalFailureDiagnostics(
        surface: TerminalSurface,
        childPID: pid_t
    ) -> String {
        var processInfo = proc_bsdinfo()
        let processInfoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let processInfoResult = proc_pidinfo(
            childPID,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            processInfoSize
        )
        let processState: String
        if processInfoResult == processInfoSize {
            processState = "ppid=\(processInfo.pbi_ppid) pgid=\(processInfo.pbi_pgid) "
                + "status=\(processInfo.pbi_status)"
        } else {
            processState = "proc_pidinfo=\(processInfoResult) errno=\(errno)"
        }

        let masterFD = surface.masterFDForTesting
        let descriptorFlags = fcntl(masterFD, F_GETFD)
        let statusFlags = fcntl(masterFD, F_GETFL)
        let foregroundGroup = tcgetpgrp(masterFD)
        let snapshotTail = String(surface.readTextSnapshot().text.suffix(240))
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "health=\(surface.runtimeHealth()) pid=\(childPID) \(processState) "
            + "masterFD=\(masterFD) fdFlags=\(descriptorFlags) statusFlags=\(statusFlags) "
            + "foregroundPGID=\(foregroundGroup) pump=\(surface.inputPumpConfiguredForTesting) "
            + "reader=\(surface.readerConfiguredForTesting) activeDispositions="
            + "\(TerminalPTYProcessRuntime.activeProcessDispositionWorksSnapshot().count) "
            + "executableArgs=\(processCommandLine(pid: childPID)) snapshotTail=\(snapshotTail)"
    }

    private func processCommandLine(pid: pid_t) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = output
        guard (try? process.run()) != nil else { return "ps_start_failed" }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "ps_decode_failed"
    }

    private func makeDeterministicReaperSurface(
        workspaceID: WorkspaceID = WorkspaceID(),
        title: String,
        assignedSurfaceID: SurfaceID? = nil,
        historyRepo: TerminalOutputRepository? = nil
    ) throws -> TerminalSurface {
        // WHY: these tests exercise PTY lifecycle/reaping, not cached user-shell
        // startup files. Build the same descriptor-configured prepared runtime
        // used by restart, but with an explicit startup-file-free /bin/sh.
        let spawn = TerminalPTYProcessRuntime.spawn(
            cwd: NSTemporaryDirectory(),
            executable: "/bin/sh",
            arguments: ["sh"],
            environment: [
                "HOME": NSTemporaryDirectory(),
                "LANG": "en_US.UTF-8",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PS1": "",
                "PS2": "",
                "TERM": "xterm-256color",
            ]
        )
        guard spawn.pid > 0, spawn.masterFD >= 0 else {
            if spawn.masterFD >= 0 { Darwin.close(spawn.masterFD) }
            XCTFail("deterministic /bin/sh PTY spawn failed errno=\(errno)")
            throw WaitTimeout(reason: "deterministic /bin/sh PTY spawn")
        }
        let lease = TerminalFileDescriptorLease(fd: spawn.masterFD)
        let descriptorFlagsConfigured =
            TerminalFileDescriptorFlags.enableCloseOnExec(spawn.masterFD)
            && TerminalFileDescriptorFlags.enableNonBlocking(spawn.masterFD)
        let prepared = TerminalPreparedPTYRuntime(
            pid: spawn.pid,
            masterFD: spawn.masterFD,
            lease: lease,
            suspended: false
        )
        guard descriptorFlagsConfigured else {
            if let cleanup = prepared.discard() {
                XCTAssertTrue(cleanup.wait(until: .now() + 2))
            }
            XCTFail("deterministic /bin/sh PTY descriptor setup failed errno=\(errno)")
            throw WaitTimeout(reason: "deterministic /bin/sh PTY descriptor setup")
        }
        return try TerminalSurface(
            workspaceID: workspaceID,
            title: title,
            launch: .shell(cwd: NSTemporaryDirectory()),
            assignedSurfaceID: assignedSurfaceID,
            historyRepo: historyRepo,
            preparedRuntime: prepared
        )
    }

    private func waitForDead(_ surface: TerminalSurface, timeout: TimeInterval = 6) throws -> TerminalRuntimeHealth {
        let deadline = Date().addingTimeInterval(timeout)
        var last = surface.runtimeHealth()
        while Date() < deadline {
            last = surface.runtimeHealth()
            if !last.processAlive { return last }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for terminal process exit; last health=\(last)")
        throw WaitTimeout(reason: "terminal dead")
    }

    private func waitForBusy(_ surface: TerminalSurface, timeout: TimeInterval = 6) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if surface.foregroundJobAliveForTesting { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("timed out waiting for terminal foreground process; health=\(surface.runtimeHealth())")
        throw WaitTimeout(reason: "terminal foreground process")
    }

    private func capturedForegroundGroup(
        surface: TerminalSurface,
        shellPID: pid_t
    ) throws -> TerminalPTYProcessRuntime.CapturedForegroundProcessGroup {
        let captured = try XCTUnwrap(
            surface.capturedForegroundProcessGroupForTesting,
            "waitForBusy must atomically retain the real foreground group identity before it can exit"
        )
        XCTAssertNotEqual(captured.pgid, shellPID,
                          "busy live/resistant jobs must use a foreground PGID distinct from the shell")
        return captured
    }

    private func warmUpTerminalRuntime() throws {
        let surface = try makeDeterministicReaperSurface(title: "teardown warmup")
        XCTAssertEqual(surface.sendTextStatus("exit 0\n"), .accepted)
        _ = try waitForDead(surface)
        surface.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    private func waitForProcessesAndGroupsToDisappear(
        _ pids: [pid_t],
        timeout: TimeInterval
    ) -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = Set(pids)
        while Date() < deadline, !remaining.isEmpty {
            remaining = Set(remaining.filter(processOrGroupExists))
            if !remaining.isEmpty {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        return remaining.sorted()
    }

    private func processOrGroupExists(_ pid: pid_t) -> Bool {
        errno = 0
        if Darwin.kill(pid, 0) == 0 || errno == EPERM { return true }
        errno = 0
        if Darwin.kill(-pid, 0) == 0 || errno == EPERM { return true }
        return false
    }

    private func waitForShellExitToBeObservedWithoutReaping(
        _ pid: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var info = siginfo_t()
            errno = 0
            let result = Darwin.waitid(
                P_PID,
                id_t(pid),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0, info.si_pid == pid { return true }
            if result < 0, errno == ECHILD { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }

    private func waitForShellZombieStillOwned(
        _ pid: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var info = siginfo_t()
            errno = 0
            let result = Darwin.waitid(
                P_PID,
                id_t(pid),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0, info.si_pid == pid { return true }
            if result < 0, errno == ECHILD { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }

    private func waitForWaitpidOwnershipToBeConsumed(
        _ pid: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            errno = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result < 0, errno == ECHILD { return true }
            if result == pid {
                XCTFail("test reaped shell PID \(pid); production reaper left a zombie")
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }

    private func waitForReaperCompletion(
        _ surface: TerminalSurface,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if surface.runtimeHealth().childPID == nil { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }

    private func waitForCapturedGroupsToDisappear(
        _ groups: [TerminalPTYProcessRuntime.CapturedForegroundProcessGroup],
        timeout: TimeInterval
    ) -> [TerminalPTYProcessRuntime.CapturedForegroundProcessGroup] {
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = Set(groups)
        while Date() < deadline, !remaining.isEmpty {
            remaining = Set(remaining.filter {
                TerminalPTYProcessRuntime.currentValidation(of: $0) != .gone
            })
            if !remaining.isEmpty {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        return remaining.sorted { lhs, rhs in
            lhs.pgid == rhs.pgid ? lhs.sessionID < rhs.sessionID : lhs.pgid < rhs.pgid
        }
    }

    private func openFDCount() throws -> Int {
        let entries = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        return entries.compactMap(Int.init).count
    }

    private func currentPhysicalFootprintBytes() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "task_info(TASK_VM_INFO) failed with \(result)"
            ])
        }
        return info.phys_footprint
    }

    private struct WaitTimeout: Error, CustomStringConvertible {
        let reason: String
        var description: String { "timed out waiting for \(reason)" }
    }
}

private final class ReaderMarkerBatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private let marker: Data
    private var trailing = Data()
    private var markerObserved = false
    private var claimed = false

    init(marker: Data) {
        self.marker = marker
    }

    func observe(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !markerObserved else { return }
        var combined = trailing
        combined.append(data)
        markerObserved = combined.range(of: marker) != nil
        trailing = Data(combined.suffix(max(0, marker.count - 1)))
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard markerObserved, !claimed else { return false }
        claimed = true
        return true
    }
}

private final class LockedRuntimeHealthCount: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [SurfaceID: Int] = [:]

    func record(_ surfaceID: SurfaceID) {
        lock.lock()
        counts[surfaceID, default: 0] += 1
        lock.unlock()
    }

    func count(for surfaceID: SurfaceID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[surfaceID, default: 0]
    }
}
