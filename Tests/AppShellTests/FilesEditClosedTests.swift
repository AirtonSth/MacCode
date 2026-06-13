import XCTest
@testable import AppShell

/// Tests for handling `files.edit.closed` events from the host.
///
/// WHY these tests matter:
///  - A closed edit session must not remain marked dirty locally.
///  - Closing a different session should clear path bookkeeping without tearing down the active editor.
final class FilesEditClosedTests: XCTestCase {
    func test_sameSessionCloseClearsDirtyPathAndActiveSession() {
        let update = filesEditClosedUpdate(
            currentSessionID: "session-a",
            currentDirtyPaths: ["src/App.swift", "README.md"],
            closedSessionID: "session-a",
            path: "src/App.swift"
        )

        XCTAssertEqual(update.dirtyPaths, ["README.md"],
            "closed session path must be removed from dirty paths")
        XCTAssertEqual(update.cachePathToRemove, "src/App.swift",
            "session cache for the closed path must be invalidated")
        XCTAssertTrue(update.shouldClearActiveSession,
            "closing the active session must clear the editor's live session id")
    }

    func test_differentSessionCloseKeepsActiveSessionButClearsPathBookkeeping() {
        let update = filesEditClosedUpdate(
            currentSessionID: "session-a",
            currentDirtyPaths: ["src/App.swift", "README.md"],
            closedSessionID: "session-b",
            path: "README.md"
        )

        XCTAssertEqual(update.dirtyPaths, ["src/App.swift"],
            "a different closed session should still clear bookkeeping for its path")
        XCTAssertEqual(update.cachePathToRemove, "README.md",
            "the stale cached draft for the closed path must be removed")
        XCTAssertFalse(update.shouldClearActiveSession,
            "closing another session must not tear down the active editor")
    }

    func test_closeWithoutPathOnlyClearsMatchingActiveSession() {
        let update = filesEditClosedUpdate(
            currentSessionID: "session-a",
            currentDirtyPaths: ["src/App.swift"],
            closedSessionID: "session-a",
            path: nil
        )

        XCTAssertEqual(update.dirtyPaths, ["src/App.swift"],
            "events without a path cannot safely remove dirty-path bookkeeping")
        XCTAssertNil(update.cachePathToRemove,
            "no path means no session-cache key can be invalidated")
        XCTAssertTrue(update.shouldClearActiveSession,
            "the active session should still clear when the session id matches")
    }
}
