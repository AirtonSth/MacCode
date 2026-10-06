import XCTest
import AppKit
@testable import CoreModel
@testable import Surfaces

/// S-F4a. Before this monitor the app ignored OS memory-pressure events, and the
/// terminal budget only reclaimed once CPU text bytes crossed 64 MiB, which
/// eight ordinary terminals never reach. These tests pin what a pressure event
/// may and may not reclaim.
@MainActor
final class MemoryPressureMonitorTests: XCTestCase {

    func test_criticalPressureReclaimsEveryHiddenTerminalOnceEvenUnderTheNormalBudget() {
        // WHY: the normal budget sees 34 of 64 bytes and does nothing. Critical
        // pressure must still release every hidden terminal, but only one step
        // each: a second step would make a tab dormant and drop its mirror.
        let authority = TerminalMemoryBudgetAuthority(maxRetainedBytes: 64)
        let hidden = (0..<3).map { _ in PressureOwner(bytes: 10, compactedBytes: 2, priority: 0) }
        let visible = PressureOwner(bytes: 4, compactedBytes: 0, priority: 1)
        for owner in hidden + [visible] { register(owner, in: authority) }
        authority.enforceBudget()
        XCTAssertEqual(hidden.map(\.reclaimCount), [0, 0, 0], "fixture must sit under the normal budget")

        var lines: [String] = []
        MemoryPressureMonitor(authority: authority, log: { lines.append($0) }).handle(.critical)

        XCTAssertEqual(hidden.map(\.reclaimCount), [1, 1, 1])
        XCTAssertEqual(visible.reclaimCount, 0, "a visible terminal must never rebuild under the user")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.hasPrefix(
            "memory_pressure level=critical ceilingBytes=0 terminalsReclaimed=3 "
                + "terminalBytesBefore=34 terminalBytesAfter=10 durationMs="
        ), true, "the log must carry the handler's main-thread cost; got \(lines)")
    }

    func test_repeatedPressureNeverTakesACompactedTerminalASecondStep() {
        // WHY: a second step on a compacted hidden terminal makes it dormant, a
        // 1x1 mirror, so its reveal comes back blank and output that arrives
        // meanwhile is lost. Repeated criticals, and the usual warning ->
        // critical escalation, must leave compacted terminals alone.
        let authority = TerminalMemoryBudgetAuthority(maxRetainedBytes: 64)
        let hidden = (0..<2).map { _ in PressureOwner(bytes: 10, compactedBytes: 2, priority: 0) }
        for owner in hidden { register(owner, in: authority) }

        var lines: [String] = []
        let monitor = MemoryPressureMonitor(authority: authority, log: { lines.append($0) })
        monitor.handle(.warning)
        XCTAssertEqual(hidden.map(\.reclaimCount), [0, 0], "20 bytes already sit under the 32-byte warning ceiling")
        monitor.handle(.critical)
        XCTAssertEqual(hidden.map(\.reclaimCount), [1, 1])
        monitor.handle(.critical)
        XCTAssertEqual(hidden.map(\.reclaimCount), [1, 1], "the second critical must skip compacted terminals")

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.last?.contains("terminalsReclaimed=0"), true)

        let escalated = TerminalMemoryBudgetAuthority(maxRetainedBytes: 16)
        let old = PressureOwner(bytes: 12, compactedBytes: 2, priority: 0)
        register(old, in: escalated)
        let escalation = MemoryPressureMonitor(authority: escalated, log: { _ in })
        escalation.handle(.warning)
        escalation.handle(.critical)
        XCTAssertEqual(old.reclaimCount, 1, "warning compacts above the halved ceiling; critical must not step it again")
    }

    func test_warningSparesHiddenTerminalsRunningAProgramAndCriticalReleasesThem() {
        // WHY: a released surface answers no DSR/DA/kitty queries and loses
        // input modes on rebuild. A warning is common on 8-16 GB Macs, so it
        // must not do that to a running TUI or agent CLI in a background tab.
        // A critical event still may.
        let authority = TerminalMemoryBudgetAuthority(maxRetainedBytes: 16)
        let running = PressureOwner(bytes: 12, compactedBytes: 2, priority: 0)
        running.liveForegroundJob = true
        let idle = PressureOwner(bytes: 12, compactedBytes: 2, priority: 0)
        register(running, in: authority)
        register(idle, in: authority)

        let monitor = MemoryPressureMonitor(authority: authority, log: { _ in })
        monitor.handle(.warning)
        XCTAssertEqual(running.reclaimCount, 0)
        XCTAssertEqual(idle.reclaimCount, 1)

        monitor.handle(.critical)
        XCTAssertEqual(running.reclaimCount, 1)
        XCTAssertEqual(idle.reclaimCount, 1)
    }

    func test_replayBackpressuredTerminalIsNeverReclaimedByPressure() {
        // WHY: a hidden terminal mid history replay reports priority 3
        // (`historyReplayBackpressureActive`). Pressure only takes priority 0.
        let authority = TerminalMemoryBudgetAuthority(maxRetainedBytes: 64)
        let replaying = PressureOwner(bytes: 20, compactedBytes: 2, priority: 3)
        register(replaying, in: authority)

        var lines: [String] = []
        MemoryPressureMonitor(authority: authority, log: { lines.append($0) }).handle(.critical)

        XCTAssertEqual(replaying.reclaimCount, 0)
        XCTAssertEqual(lines.first?.contains("terminalsReclaimed=0"), true)
    }

    func test_warningPressureReclaimsLeastRecentlyUsedHiddenTerminalsDownToHalfTheBudget() {
        // WHY: a warning is common on small Macs. It should cost the oldest
        // background tabs, and stop as soon as the halved ceiling is met so a
        // recently used tab stays warm.
        let authority = TerminalMemoryBudgetAuthority(maxRetainedBytes: 64)
        let owners = (0..<4).map { _ in PressureOwner(bytes: 12, compactedBytes: 0, priority: 0) }
        let tokens = owners.map { register($0, in: authority) }
        // Most recently used last: owners[3] then owners[2] are the warm ones.
        for token in tokens { authority.touch(token, enforce: false) }

        var lines: [String] = []
        MemoryPressureMonitor(authority: authority, log: { lines.append($0) }).handle(.warning)

        XCTAssertEqual(owners.map(\.reclaimCount), [1, 1, 0, 0])
        XCTAssertLessThanOrEqual(authority.retainedBytesForTesting, 32)
        XCTAssertEqual(lines.first?.contains("level=warning ceilingBytes=32 terminalsReclaimed=2"), true)
    }

    func test_pressureReportsZeroWhenAHiddenTerminalCannotShrink() {
        // WHY (failure path): a priority-0 terminal can still refuse to shrink,
        // e.g. `reclaimTerminalMemoryUnderPressure` returns early while owner
        // held handoffs are pending. The log must say nothing was reclaimed
        // instead of counting the attempt.
        let authority = TerminalMemoryBudgetAuthority(maxRetainedBytes: 64)
        let stuck = PressureOwner(bytes: 20, compactedBytes: 20, priority: 0)
        register(stuck, in: authority)

        var lines: [String] = []
        MemoryPressureMonitor(authority: authority, log: { lines.append($0) }).handle(.critical)

        XCTAssertEqual(stuck.reclaimCount, 1)
        XCTAssertEqual(lines.first?.contains("terminalsReclaimed=0"), true)
        XCTAssertEqual(lines.first?.contains("terminalBytesAfter=20"), true)
    }

    func test_startIsIdempotentAndStopReleasesTheSource() {
        let monitor = MemoryPressureMonitor(
            authority: TerminalMemoryBudgetAuthority(maxRetainedBytes: 64),
            log: { _ in }
        )
        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isRunningForTesting)
        monitor.stop()
        XCTAssertFalse(monitor.isRunningForTesting)
    }

    func test_criticalPressureReleasesAHiddenTerminalAndItsRevealRestoresOutput() throws {
        // WHY: the end-to-end contract. Pressure must actually free a real
        // hidden terminal's native surface and mirror, keep the visible one
        // untouched, and the reclaimed tab must come back with its output in
        // order when the user selects it again.
        let hidden = try makeSurface("pressure hidden")
        defer { hidden.close() }
        let visible = try makeSurface("pressure visible")
        defer { visible.close() }
        let beforeMarker = "RC2_BEFORE_PRESSURE_\(UUID().uuidString)"
        hidden.appendSystemText(
            (0..<600).map { "row \($0) " + String(repeating: "x", count: 80) }
                .joined(separator: "\r\n") + "\r\n\(beforeMarker)\r\n"
        )
        _ = hidden.readTextSnapshot()
        hidden.didBecomeHidden()
        visible.didBecomeVisible()
        visible.appendSystemText("visible\r\n")
        let hiddenBefore = hidden.terminalMemoryRetainedBytesForTesting

        // This uses the process-wide `.shared` authority, so it also reclaims
        // hidden surfaces other tests leaked. Assertions stay on these two.
        MemoryPressureMonitor(log: { _ in }).handle(.critical)

        XCTAssertTrue(hidden.terminalMemoryWasReclaimedForTesting)
        XCTAssertLessThan(hidden.terminalMemoryRetainedBytesForTesting, hiddenBefore)
        XCTAssertFalse(visible.terminalMemoryWasReclaimedForTesting)

        let afterMarker = "RC2_AFTER_PRESSURE_\(UUID().uuidString)"
        hidden.appendSystemText("\r\n\(afterMarker)\r\n")
        hidden.didBecomeVisible()

        XCTAssertFalse(hidden.terminalMemoryWasReclaimedForTesting)
        let rebuilt = hidden.readTextSnapshot().text
        let before = try XCTUnwrap(rebuilt.range(of: beforeMarker))
        let after = try XCTUnwrap(rebuilt.range(of: afterMarker))
        XCTAssertLessThan(before.lowerBound, after.lowerBound)
    }

    func test_repeatedCriticalPressureKeepsAHiddenTerminalsOutputThroughReveal() throws {
        // WHY: the regression for the dormant walk. Before the fix, a second
        // critical replaced the mirror with a 1x1 renderer: the reveal was
        // blank and output that arrived meanwhile was lost.
        let hidden = try makeSurface("pressure repeated")
        defer { hidden.close() }
        let beforeMarker = try fillAndHide(hidden)

        let monitor = MemoryPressureMonitor(log: { _ in })
        monitor.handle(.critical)
        XCTAssertTrue(hidden.terminalMemoryWasReclaimedForTesting)
        monitor.handle(.critical)

        try assertRevealKeepsOutput(hidden, beforeMarker: beforeMarker)
    }

    func test_warningThenCriticalAboveTheWarningCeilingKeepsAHiddenTerminalsOutput() throws {
        // WHY: the common escalation. With terminal bytes above the 32 MiB
        // warning ceiling, the warning compacts the hidden tab and the critical
        // that follows must not step it to dormant.
        let hidden = try makeSurface("pressure escalation")
        defer { hidden.close() }
        let beforeMarker = try fillAndHide(hidden)
        let ballast = PressureOwner(bytes: 33 * 1024 * 1024, compactedBytes: 33 * 1024 * 1024, priority: 4)
        let ballastToken = register(ballast, in: .shared)
        defer { TerminalMemoryBudgetAuthority.shared.unregister(ballastToken) }

        let monitor = MemoryPressureMonitor(log: { _ in })
        monitor.handle(.warning)
        XCTAssertTrue(hidden.terminalMemoryWasReclaimedForTesting, "bytes above the warning ceiling must compact the hidden tab")
        monitor.handle(.critical)

        try assertRevealKeepsOutput(hidden, beforeMarker: beforeMarker)
    }

    func test_warningSparesAHiddenTerminalRunningAForegroundJob() throws {
        // WHY: the real wiring of the warning exemption. A background tab
        // running a program keeps its native surface on a warning, and gives it
        // up only on a critical event.
        let running = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "pressure running job",
            launch: .shell(cwd: NSTemporaryDirectory()),
            outputBus: SurfaceOutputBus(flushDelay: 0)
        )
        defer { running.close() }
        XCTAssertEqual(running.sendTextStatus("sleep 30\n"), .accepted)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !running.foregroundJobAliveForTesting {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(running.foregroundJobAliveForTesting, "fixture needs a live foreground job")
        running.didBecomeHidden()
        let ballast = PressureOwner(bytes: 33 * 1024 * 1024, compactedBytes: 33 * 1024 * 1024, priority: 4)
        let ballastToken = register(ballast, in: .shared)
        defer { TerminalMemoryBudgetAuthority.shared.unregister(ballastToken) }

        let monitor = MemoryPressureMonitor(log: { _ in })
        monitor.handle(.warning)
        XCTAssertFalse(running.terminalMemoryWasReclaimedForTesting)
        monitor.handle(.critical)
        XCTAssertTrue(running.terminalMemoryWasReclaimedForTesting)
    }

    // MARK: - Helpers

    private func fillAndHide(_ surface: TerminalSurface) throws -> String {
        let marker = "RC2_BEFORE_PRESSURE_\(UUID().uuidString)"
        surface.appendSystemText(
            (0..<50).map { "row \($0) " + String(repeating: "x", count: 40) }
                .joined(separator: "\r\n") + "\r\n\(marker)\r\n"
        )
        _ = surface.readTextSnapshot()
        surface.didBecomeHidden()
        return marker
    }

    private func assertRevealKeepsOutput(
        _ surface: TerminalSurface,
        beforeMarker: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let duringMarker = "RC2_DURING_PRESSURE_\(UUID().uuidString)"
        surface.appendSystemText("\r\n\(duringMarker)\r\n")
        surface.didBecomeVisible()
        let rebuilt = surface.readTextSnapshot().text
        let before = try XCTUnwrap(rebuilt.range(of: beforeMarker), "output from before pressure was lost", file: file, line: line)
        let during = try XCTUnwrap(rebuilt.range(of: duringMarker), "output from while hidden was lost", file: file, line: line)
        XCTAssertLessThan(before.lowerBound, during.lowerBound, file: file, line: line)
    }

    @discardableResult
    private func register(_ owner: PressureOwner, in authority: TerminalMemoryBudgetAuthority) -> UUID {
        authority.register(
            owner: owner,
            retainedBytes: { [weak owner] in owner?.bytes ?? 0 },
            priority: { [weak owner] in owner?.priority ?? 0 },
            reclaim: { [weak owner] in owner?.reclaim() },
            pressureState: { [weak owner] in
                guard let owner, !owner.compacted else { return .compacted }
                return owner.liveForegroundJob ? .liveForegroundJob : .reclaimable
            }
        )
    }

    private func makeSurface(_ title: String) throws -> TerminalSurface {
        try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: title,
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
            outputBus: SurfaceOutputBus(flushDelay: 0)
        )
    }
}

private final class PressureOwner {
    var bytes: Int
    let compactedBytes: Int
    let priority: Int
    var liveForegroundJob = false
    private(set) var reclaimCount = 0
    private(set) var compacted = false

    init(bytes: Int, compactedBytes: Int, priority: Int) {
        self.bytes = bytes
        self.compactedBytes = compactedBytes
        self.priority = priority
    }

    func reclaim() {
        reclaimCount += 1
        if compactedBytes < bytes { compacted = true }
        bytes = compactedBytes
    }
}
