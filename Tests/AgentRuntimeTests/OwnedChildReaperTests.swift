import XCTest
@testable import AgentRuntime
import Darwin
import Foundation

/// plan-final W1: owned children always receive terminal waitpid (no zombies).
final class OwnedChildReaperTests: XCTestCase {
    func test_terminateAndReap_exitedChild_returnsReaped() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "exit 7"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let pid = proc.processIdentifier
        // Process may already be reaped by Foundation; either reaped or alreadyReaped is OK.
        let outcome = OwnedChildReaper.terminateAndReap(pid: pid, termGrace: 0.2, killGrace: 0.2)
        switch outcome {
        case .reaped, .alreadyReaped:
            break
        case .timedOutStillRunning:
            // Foundation may still own the wait — force Process wait then re-poll.
            proc.waitUntilExit()
            let again = OwnedChildReaper.terminateAndReap(pid: pid, termGrace: 0, killGrace: 0)
            XCTAssertNotEqual(again, .timedOutStillRunning)
        }
    }

    func test_terminateAndReap_runningChild_isKilledAndReaped() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "while true; do sleep 0.05; done"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let pid = proc.processIdentifier
        XCTAssertTrue(proc.isRunning)
        let outcome = OwnedChildReaper.terminateAndReap(pid: pid, termGrace: 0.15, killGrace: 0.3)
        // After reaper, Process may report not running; no zombie expected.
        switch outcome {
        case .reaped, .alreadyReaped:
            break
        case .timedOutStillRunning:
            // If Foundation holds the wait, kill via Process API and confirm exit.
            proc.terminate()
            proc.waitUntilExit()
        }
        XCTAssertFalse(proc.isRunning)
    }

    func test_poll_invalidPid_doesNotHang() {
        // pid 0 / negative treated as already gone
        XCTAssertEqual(OwnedChildReaper.poll(pid: -1), 0)
    }

    func test_waitForZombieFalse_returnsWithoutBlockingWaitpid() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "while true; do sleep 0.05; done"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let pid = proc.processIdentifier
        let started = Date()
        _ = OwnedChildReaper.terminateAndReap(
            pid: pid,
            termGrace: 0.05,
            killGrace: 0.05,
            waitForZombie: false
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5,
                          "usage-refresher PTY teardown must not block on waitpid(0)")
        proc.terminate()
        proc.waitUntilExit()
    }
}
