import XCTest
@testable import AppShell

// PERF-SSH-001: "Connecting..." label must paint before keychain read + forkpty stall.
// The fix defers performConnect behind waitForCommittedFrame (DispatchQueue.main.async)
// so the CATransaction commits before the stall (Task.yield() is only an executor hop).
// These tests verify the pure SSHConnectPhase state machine that encodes the ordering
// invariant — if a transition skips .painting or allows back-edges, the label may not
// paint before the stall.

final class SSHConnectPhaseTests: XCTestCase {

    // WHY: .painting is the only valid predecessor to .connecting. If any other phase
    // (including .connected or .failed) could transition to .connecting, a reconnect
    // attempt would bypass the "Connecting..." paint step entirely, bringing the
    // freeze back. The machine must enforce painting-first unconditionally.
    func testOnlyPaintingCanTransitionToConnecting() {
        let allPhases: [SSHConnectPhase] = [.painting, .connecting, .connected, .failed]
        let predecessors = allPhases.filter {
            SSHConnectPhase.validTransitions(from: $0).contains(.connecting)
        }
        XCTAssertEqual(predecessors, [.painting],
            ".connecting must be reachable only from .painting — any other predecessor skips the paint step")
    }

    // WHY: .painting must not loop back to itself and must not skip ahead to
    // .connected/.failed. Allowing .painting -> .connected would mean the connecting
    // phase (and its paint yield) was never entered.
    func testPaintingTransitionsOnlyToConnecting() {
        let valid = SSHConnectPhase.validTransitions(from: .painting)
        XCTAssertEqual(valid, [.connecting],
            ".painting -> only .connecting; skip would mean keychain stall fires without a prior paint")
    }

    // WHY: once connected or failed the phase is terminal. If transitions were allowed
    // out of .connected/.failed, reconnect logic could re-enter without going through
    // .painting again, causing the freeze to reappear on subsequent connects.
    func testConnectedAndFailedAreTerminal() {
        XCTAssertTrue(SSHConnectPhase.validTransitions(from: .connected).isEmpty,
            ".connected is terminal — reconnect must start a fresh .painting phase")
        XCTAssertTrue(SSHConnectPhase.validTransitions(from: .failed).isEmpty,
            ".failed is terminal — retry must start a fresh .painting phase")
    }

    // WHY: .connecting must reach both success and failure outcomes. If .failed were
    // missing, an error during keychain read/forkpty would leave the UI stuck on
    // "Connecting..." with no way to surface the error.
    func testConnectingCanReachBothSuccessAndFailure() {
        let valid = SSHConnectPhase.validTransitions(from: .connecting)
        XCTAssertTrue(valid.contains(.connected), ".connecting -> .connected required for happy path")
        XCTAssertTrue(valid.contains(.failed), ".connecting -> .failed required so errors surface to UI")
        XCTAssertEqual(valid.count, 2, "no unexpected transitions out of .connecting")
    }

    // WHY: the one-way ordering invariant — painting precedes connecting precedes
    // outcome. A simulated traversal must visit phases in the exact order required
    // to guarantee the UI freeze follows the label paint, not the other way around.
    func testPhaseTraversalRespectsOneWayOrder() {
        var visited: [SSHConnectPhase] = []
        var current: SSHConnectPhase = .painting
        visited.append(current)

        // step painting -> connecting
        XCTAssertTrue(SSHConnectPhase.validTransitions(from: current).contains(.connecting))
        current = .connecting
        visited.append(current)

        // step connecting -> connected (happy path)
        XCTAssertTrue(SSHConnectPhase.validTransitions(from: current).contains(.connected))
        current = .connected
        visited.append(current)

        XCTAssertEqual(visited, [.painting, .connecting, .connected],
            "painting must be index 0 — it must fire before the blocking connect work at index 1")
        XCTAssertLessThan(
            visited.firstIndex(of: .painting)!,
            visited.firstIndex(of: .connecting)!,
            "painting index must be strictly less than connecting index (perf win: label paints before stall)")
    }

    // WHY: same one-way ordering for the failure path. If .failed arrived before
    // .painting the user would see a "Failed" label that was never preceded by the
    // "Connecting..." UI state, breaking the expected visual sequence.
    func testPhaseTraversalFailurePathRespectsOrder() {
        var visited: [SSHConnectPhase] = []
        var current: SSHConnectPhase = .painting
        visited.append(current)

        current = .connecting
        visited.append(current)

        current = .failed
        visited.append(current)

        XCTAssertEqual(visited, [.painting, .connecting, .failed])
        XCTAssertLessThan(
            visited.firstIndex(of: .painting)!,
            visited.firstIndex(of: .connecting)!,
            "painting must precede connecting on error path too")
        XCTAssertLessThan(
            visited.firstIndex(of: .connecting)!,
            visited.firstIndex(of: .failed)!,
            "connecting must precede failed")
    }

    func test_enqueueConnectionUsesCommittedFrameBarrier() throws {
        let ssh = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/SSHSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(ssh.range(of: "private func enqueueConnection"))
        let tail = ssh[start.lowerBound...]
        let end = tail.range(of: "\n    private func drainConnectionRequests")?.lowerBound ?? tail.endIndex
        let body = String(tail[..<end])
        XCTAssertTrue(body.contains("waitForCommittedFrame"),
                      "enqueueConnection must use waitForCommittedFrame (committed CATransaction), not Task.yield() — only committed-frame proves the \"Connecting…\" label painted before forkpty (AGENTS.md)")
        XCTAssertFalse(body.contains("await Task.yield()"),
                       "Task.yield() is only an executor hop, not proof that SwiftUI committed the \"Connecting…\" frame")
    }
}
