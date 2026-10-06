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
        XCTAssertEqual(lines, [
            "memory_pressure level=critical ceilingBytes=0 terminalsReclaimed=3 "
                + "terminalBytesBefore=34 terminalBytesAfter=10",
        ])
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
        // WHY (failure path): a terminal mid history replay refuses reclaim. The
        // log must say nothing was reclaimed instead of counting the attempt.
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

    // MARK: - Helpers

    @discardableResult
    private func register(_ owner: PressureOwner, in authority: TerminalMemoryBudgetAuthority) -> UUID {
        authority.register(
            owner: owner,
            retainedBytes: { [weak owner] in owner?.bytes ?? 0 },
            priority: { [weak owner] in owner?.priority ?? 0 },
            reclaim: { [weak owner] in owner?.reclaim() }
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
    private(set) var reclaimCount = 0

    init(bytes: Int, compactedBytes: Int, priority: Int) {
        self.bytes = bytes
        self.compactedBytes = compactedBytes
        self.priority = priority
    }

    func reclaim() {
        reclaimCount += 1
        bytes = compactedBytes
    }
}
