import XCTest
@testable import AppShell

/// Tests for the pure `shouldClosePriorEditSession` helper that decides when to close the
/// previous host-side edit session on a file switch.
///
/// WHY these tests matter:
///  - Browsing N clean files must not accumulate N live host sessions (PERF-MAC_FILES leak).
///    The helper returning `true` is the gate that triggers `filesEditClose`; getting it wrong
///    either leaks sessions (false-negative) or closes sessions the user is still editing
///    (false-positive, losing dirty state).
///  - Dirty sessions must NOT be closed on switch because the snapshotted sessionID is reused
///    on re-select to continue editing without a round-trip to the host. Closing prematurely
///    would invalidate that ID and silently discard unsaved edits.
///  - Same-path re-opens (e.g. navigating to the same file) must not close the session because
///    that is a no-op selection, not a file switch.
final class FilesEditSessionCloseTests: XCTestCase {

    // MARK: - Switching to a different clean file -> close prior session

    func test_differentPath_clean_shouldClose() {
        // User has "a.swift" open (clean). Switching to "b.swift" should release the host
        // session for "a.swift" so the host does not accumulate unbounded open sessions.
        XCTAssertTrue(
            shouldClosePriorEditSession(prevPath: "a.swift", prevIsDirty: false, newPath: "b.swift"),
            "switching from a clean file to a different file must close the prior session"
        )
    }

    // MARK: - Switching to a different DIRTY file -> keep prior session

    func test_differentPath_dirty_shouldNotClose() {
        // User has "a.swift" open with unsaved edits. Switching to "b.swift" must leave the
        // host session for "a.swift" alive; the snapshotted sessionID is reused when the user
        // returns to "a.swift", preserving the dirty draft.
        XCTAssertFalse(
            shouldClosePriorEditSession(prevPath: "a.swift", prevIsDirty: true, newPath: "b.swift"),
            "switching away from a dirty file must NOT close the session (snapshotted ID still needed)"
        )
    }

    // MARK: - Re-opening the SAME file -> no close (same-path no-op)

    func test_samePath_clean_shouldNotClose() {
        // Selecting the currently open clean file again (e.g. clicking the same row) must not
        // trigger a redundant close+open cycle on the host.
        XCTAssertFalse(
            shouldClosePriorEditSession(prevPath: "a.swift", prevIsDirty: false, newPath: "a.swift"),
            "re-selecting the same clean file must not close the session"
        )
    }

    func test_samePath_dirty_shouldNotClose() {
        // Re-selecting the same dirty file must also be a no-op.
        XCTAssertFalse(
            shouldClosePriorEditSession(prevPath: "a.swift", prevIsDirty: true, newPath: "a.swift"),
            "re-selecting the same dirty file must not close the session"
        )
    }

    // MARK: - First open (no prior file) -> no close

    func test_noPrevPath_clean_shouldNotClose() {
        // Opening the first file in a fresh surface has no prior session to close.
        XCTAssertFalse(
            shouldClosePriorEditSession(prevPath: nil, prevIsDirty: false, newPath: "a.swift"),
            "first file open with no prior session must not attempt to close"
        )
    }

    func test_noPrevPath_dirty_shouldNotClose() {
        // Defensive: dirty=true with no prior path is a degenerate state; must not close.
        XCTAssertFalse(
            shouldClosePriorEditSession(prevPath: nil, prevIsDirty: true, newPath: "a.swift"),
            "no prior path (even with dirty flag) must not attempt to close"
        )
    }

    // MARK: - Nested paths (common-prefix trap)

    func test_nestedPath_differentFiles_clean_shouldClose() {
        // "src/index.swift" and "src/index2.swift" share a prefix but are distinct files.
        // The helper must not confuse path-prefix equality with path equality.
        XCTAssertTrue(
            shouldClosePriorEditSession(prevPath: "src/index.swift", prevIsDirty: false, newPath: "src/index2.swift"),
            "two clean files with a common path prefix must still trigger close"
        )
    }

    func test_parentAndChildPath_clean_shouldClose() {
        // "src" and "src/main.swift" differ — switching between them must trigger close.
        XCTAssertTrue(
            shouldClosePriorEditSession(prevPath: "src", prevIsDirty: false, newPath: "src/main.swift"),
            "parent path vs child path are distinct files; clean switch must close"
        )
    }
}
