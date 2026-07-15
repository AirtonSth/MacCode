import XCTest
import Darwin
@testable import AgentRuntime

/// F15: ProcessTerminator.terminateTree used to Thread.sleep for the whole
/// SIGTERM->SIGKILL grace window (2s) on the CALLING thread. Every cancel path
/// (Stop button, queued-message force, idle reap timer) runs on the main actor,
/// so each Stop froze the UI for the grace window. terminateTree must:
///   1. return promptly (SIGTERM sent synchronously, grace wait scheduled off-thread),
///   2. still escalate TERM-ignoring survivors to SIGKILL after the grace window,
///   3. not gate the death of a cooperative (TERM-honoring) process on the grace window.
final class AgentProviderRunnerTerminateTreeTests: XCTestCase {

    private func spawnShell(_ script: String) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        return proc
    }

    private func waitUntilExited(_ proc: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, proc.isRunning {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func test_terminateTree_returnsWithoutBlockingForGraceWindow_andStillEscalatesToSIGKILL() throws {
        // Ignore SIGTERM (SIG_IGN is inherited across exec, so the sleep child
        // ignores it too): only the deferred SIGKILL escalation can end this tree.
        let proc = try spawnShell("trap '' TERM; while :; do sleep 0.1; done")
        defer { kill(proc.processIdentifier, SIGKILL) } // belt-and-braces cleanup
        // Give the shell a beat to install the trap before signalling.
        Thread.sleep(forTimeInterval: 0.3)

        let started = Date()
        ProcessTerminator.terminateTree(proc, grace: 1.0)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.5,
                          "terminateTree must not block the calling thread for the grace window — " +
                          "cancel paths run on the main actor and a blocking wait freezes the UI for every Stop (F15)")

        // The escalation still has to win: the TERM-ignoring root must be
        // SIGKILLed shortly after the 1s grace elapses.
        waitUntilExited(proc, timeout: 5)
        XCTAssertFalse(proc.isRunning,
                       "a SIGTERM-ignoring provider tree must still be SIGKILLed after the grace window — " +
                       "'cancel must always win' may not regress when the wait moves off-thread")
    }

    func test_terminateTree_cooperativeProcessDiesOnSIGTERM_withoutWaitingForGrace() throws {
        // A process that honors SIGTERM must die from the synchronous phase-1
        // signal; its death must NOT be gated on the (long) grace window.
        let proc = try spawnShell("sleep 30")
        defer { kill(proc.processIdentifier, SIGKILL) }
        Thread.sleep(forTimeInterval: 0.2)

        ProcessTerminator.terminateTree(proc, grace: 5.0)

        waitUntilExited(proc, timeout: 2)
        XCTAssertFalse(proc.isRunning,
                       "SIGTERM must be delivered synchronously — a cooperative process has to exit " +
                       "well before the 5s grace window, otherwise graceful shutdown was deferred too")
    }

    func test_terminateTreeImmediatelyKillsTermIgnoringProviderBeforeAppCanExit() throws {
        let proc = try spawnShell("trap '' TERM; while :; do sleep 0.1; done")
        defer { kill(proc.processIdentifier, SIGKILL) }
        Thread.sleep(forTimeInterval: 0.3)

        let started = Date()
        ProcessTerminator.terminateTreeImmediately(proc)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.5,
                          "app termination must synchronously deliver final signals without sleeping on the main actor")
        waitUntilExited(proc, timeout: 2)
        XCTAssertFalse(proc.isRunning,
                       "a provider that ignores SIGTERM must be dead before a fast relaunch can rejoin its stale process")
    }
}
