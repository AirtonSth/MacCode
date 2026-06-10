import XCTest
@testable import AppShell
@testable import CoreModel

// Pure ring-buffer tests: no AppKit, no @MainActor required.
final class ClosedTabRingBufferTests: XCTestCase {

    private static func entry(_ title: String, cwd: String = "/tmp") -> ClosedTabEntry {
        ClosedTabEntry(
            descriptor: SurfaceDescriptor(type: .terminal, title: title),
            workspaceCwd: cwd
        )
    }

    // MARK: - capacity / overflow

    func test_pushBeyondCapacity_dropsOldestEntry() {
        // WHY: the buffer must bound memory; the oldest history entry is
        // sacrificed so the most-recent tabs remain reachable.
        var buf = ClosedTabRingBuffer(capacity: 3)
        let ws = WorkspaceID()
        buf.push(Self.entry("oldest"), for: ws)
        buf.push(Self.entry("middle"), for: ws)
        buf.push(Self.entry("newest"), for: ws)
        // push a 4th -- oldest should be evicted
        buf.push(Self.entry("extra"), for: ws)

        XCTAssertEqual(buf.count(for: ws), 3,
                       "pushing past capacity must drop the oldest entry, not grow unbounded")
        // oldest is gone: pop should yield extra, newest, middle in LIFO order
        XCTAssertEqual(buf.pop(for: ws)?.descriptor.title, "extra")
        XCTAssertEqual(buf.pop(for: ws)?.descriptor.title, "newest")
        XCTAssertEqual(buf.pop(for: ws)?.descriptor.title, "middle")
        XCTAssertNil(buf.pop(for: ws), "\"oldest\" was evicted and must not appear")
    }

    // MARK: - LIFO pop order

    func test_popReturnsMostRecent() {
        // WHY: Cmd+Shift+T must reopen tabs in reverse-close order (most
        // recently closed first), matching every major terminal / browser.
        var buf = ClosedTabRingBuffer(capacity: 10)
        let ws = WorkspaceID()
        buf.push(Self.entry("first"), for: ws)
        buf.push(Self.entry("second"), for: ws)
        buf.push(Self.entry("third"), for: ws)

        XCTAssertEqual(buf.pop(for: ws)?.descriptor.title, "third")
        XCTAssertEqual(buf.pop(for: ws)?.descriptor.title, "second")
        XCTAssertEqual(buf.pop(for: ws)?.descriptor.title, "first")
    }

    func test_popFromEmptyBuffer_returnsNil() {
        // WHY: Cmd+Shift+T on an empty history must no-op (beep) instead
        // of crashing; nil is the contract for \"nothing to reopen\".
        var buf = ClosedTabRingBuffer(capacity: 5)
        let ws = WorkspaceID()
        XCTAssertNil(buf.pop(for: ws))
    }

    // MARK: - per-workspace isolation

    func test_perWorkspaceIsolation() {
        // WHY: closing a tab in workspace A must not pollute workspace B's
        // reopen history; users work in multiple projects simultaneously.
        var buf = ClosedTabRingBuffer(capacity: 10)
        let wsA = WorkspaceID()
        let wsB = WorkspaceID()

        buf.push(Self.entry("A-tab"), for: wsA)
        buf.push(Self.entry("B-tab"), for: wsB)

        XCTAssertEqual(buf.count(for: wsA), 1)
        XCTAssertEqual(buf.count(for: wsB), 1)
        XCTAssertEqual(buf.pop(for: wsA)?.descriptor.title, "A-tab")
        XCTAssertNil(buf.pop(for: wsA), "wsA buffer must be empty after popping its only entry")
        XCTAssertEqual(buf.pop(for: wsB)?.descriptor.title, "B-tab",
                       "wsB history must be unaffected by pops in wsA")
    }

    // MARK: - cwd restoration

    func test_closedTabEntry_preservesCwd() {
        // WHY: Cmd+Shift+T should relaunch the terminal in the same
        // directory it was in when closed, not in the workspace root.
        var buf = ClosedTabRingBuffer(capacity: 5)
        let ws = WorkspaceID()
        buf.push(Self.entry("terminal", cwd: "/Users/dev/project"), for: ws)

        let entry = buf.pop(for: ws)
        XCTAssertEqual(entry?.workspaceCwd, "/Users/dev/project",
                       "the cwd captured at close time must survive the buffer round-trip")
    }

    // MARK: - count bookkeeping

    func test_countReflectsPushAndPop() {
        // WHY: count is used by callers to decide whether to enable the
        // menu item; it must stay consistent with push/pop operations.
        var buf = ClosedTabRingBuffer(capacity: 10)
        let ws = WorkspaceID()
        XCTAssertEqual(buf.count(for: ws), 0)
        buf.push(Self.entry("a"), for: ws)
        buf.push(Self.entry("b"), for: ws)
        XCTAssertEqual(buf.count(for: ws), 2)
        _ = buf.pop(for: ws)
        XCTAssertEqual(buf.count(for: ws), 1)
        _ = buf.pop(for: ws)
        XCTAssertEqual(buf.count(for: ws), 0)
    }
}
