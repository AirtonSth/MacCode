import XCTest
@testable import AppShell
@testable import CoreModel

// Tests for SSHHostRecentPaths (pure, non-MainActor helpers).
//
// WHY each test: see inline comments.
// No @MainActor needed - all helpers are nonisolated static; no UI or
// UserDefaults side-effects in the pure updatedRecentPaths function.

final class SSHHostRecentPathsTests: XCTestCase {

    // WHY: storageKey must embed the profile UUID so paths for different profiles
    // never collide in UserDefaults.  If the key ignored the ID, profile A's
    // persisted path would overwrite profile B's on first write.
    func testStorageKeyEmbedsProfileID() {
        let id = SSHHostID()
        let key = SSHHostRecentPaths.storageKey(profileID: id)
        XCTAssertTrue(
            key.contains(id.value.uuidString),
            "storageKey must embed the UUID so keys are profile-specific"
        )
    }

    // WHY: recentRemotePathsKey must also embed the profile UUID and must be
    // distinct from the storageKey so the path-pair dict and the recent list
    // do not stomp each other in UserDefaults.
    func testRecentRemotePathsKeyEmbedsProfileIDAndDiffersFromStorageKey() {
        let id = SSHHostID()
        let storageKey = SSHHostRecentPaths.storageKey(profileID: id)
        let recentKey = SSHHostRecentPaths.recentRemotePathsKey(profileID: id)
        XCTAssertTrue(
            recentKey.contains(id.value.uuidString),
            "recentRemotePathsKey must embed the UUID"
        )
        XCTAssertNotEqual(
            storageKey, recentKey,
            "storageKey and recentRemotePathsKey must be distinct keys"
        )
    }

    // WHY: two distinct profiles must produce distinct storageKeys so reconnects
    // restore the correct workspace for each host, not a shared last-visited path.
    func testDistinctProfilesProduceDistinctStorageKeys() {
        let idA = SSHHostID()
        let idB = SSHHostID()
        XCTAssertNotEqual(
            SSHHostRecentPaths.storageKey(profileID: idA),
            SSHHostRecentPaths.storageKey(profileID: idB),
            "different profiles must produce different storage keys"
        )
    }

    // WHY: two distinct profiles must produce distinct recentRemotePathsKeys
    // so navigating on profile A does not pollute profile B's history.
    func testDistinctProfilesProduceDistinctRecentKeys() {
        let idA = SSHHostID()
        let idB = SSHHostID()
        XCTAssertNotEqual(
            SSHHostRecentPaths.recentRemotePathsKey(profileID: idA),
            SSHHostRecentPaths.recentRemotePathsKey(profileID: idB),
            "different profiles must produce different recent-paths keys"
        )
    }

    // WHY: adding a path to an empty list must yield [path]; if it returned []
    // the history would never grow and reconnects would always start at "/".
    func testAddingToEmptyListYieldsSingleEntry() {
        let result = SSHHostRecentPaths.updatedRecentPaths([], adding: "/home/alice")
        XCTAssertEqual(result, ["/home/alice"],
                       "adding to empty list must yield a one-element list")
    }

    // WHY: the most-recently-visited path must be at index 0 so the UI can
    // restore the last working directory on reconnect.  If the insertion was
    // appended instead of prepended the wrong path would be shown first.
    func testNewPathIsInsertedAtFront() {
        let existing = ["/var/log", "/etc"]
        let result = SSHHostRecentPaths.updatedRecentPaths(existing, adding: "/home/bob")
        XCTAssertEqual(result[0], "/home/bob",
                       "newly added path must appear at index 0 (most-recent-first)")
    }

    // WHY: re-visiting a path already in the list must move it to the front
    // rather than duplicating it.  Duplicates would bloat the list and surface
    // the same path twice in the UI picker.
    func testRevisitingPathMoveItToFront() {
        let existing = ["/home/alice", "/var/log", "/etc"]
        let result = SSHHostRecentPaths.updatedRecentPaths(existing, adding: "/var/log")
        XCTAssertEqual(result[0], "/var/log",
                       "revisited path must move to front")
        XCTAssertEqual(result.filter { $0 == "/var/log" }.count, 1,
                       "revisited path must not be duplicated")
    }

    // WHY: the list must be bounded at `limit` entries.  An unbounded list would
    // grow indefinitely across long sessions, wasting UserDefaults space and
    // slowing the path-picker UI.
    func testListIsBoundedAtLimit() {
        var current: [String] = []
        let limit = SSHHostRecentPaths.recentPathsLimit
        // Fill the list to capacity.
        for i in 0..<limit {
            current = SSHHostRecentPaths.updatedRecentPaths(
                current, adding: "/dir/\(i)", limit: limit
            )
        }
        XCTAssertEqual(current.count, limit,
                       "list at capacity must have exactly limit entries")
        // Adding one more must trim the oldest entry, keeping count == limit.
        let overflow = SSHHostRecentPaths.updatedRecentPaths(
            current, adding: "/dir/overflow", limit: limit
        )
        XCTAssertEqual(overflow.count, limit,
                       "adding beyond limit must trim oldest entry; count must stay == limit")
        XCTAssertEqual(overflow[0], "/dir/overflow",
                       "newest entry must be at index 0 after trim")
    }

    // WHY: adding an empty string is a no-op - empty paths arise from a
    // freshly-created surface whose remoteSitePath is "" before the first listing.
    // Recording "" would pollute the history with a meaningless entry.
    func testAddingEmptyPathIsNoOp() {
        let current = ["/home/alice"]
        let result = SSHHostRecentPaths.updatedRecentPaths(current, adding: "")
        XCTAssertEqual(result, current,
                       "adding empty path must return the list unchanged")
    }

    // WHY: order must be most-recent-first at all times.  A multi-step session
    // (navigate A -> B -> C) must store [C, B, A], not [A, B, C].  Incorrect
    // order would restore the wrong path on reconnect.
    func testOrderIsMostRecentFirst() {
        var current: [String] = []
        let paths = ["/a", "/b", "/c"]
        for p in paths {
            current = SSHHostRecentPaths.updatedRecentPaths(current, adding: p)
        }
        XCTAssertEqual(current, ["/c", "/b", "/a"],
                       "list must be most-recent-first after sequential additions")
    }

    // WHY: a custom limit of 1 must keep only the single most-recent entry.
    // This exercises the boundary where limit == 1 (used in tests that need
    // the smallest possible bounded list).
    func testLimitOfOneKeepsOnlyMostRecent() {
        let result = SSHHostRecentPaths.updatedRecentPaths(
            ["/old"], adding: "/new", limit: 1
        )
        XCTAssertEqual(result, ["/new"],
                       "limit=1 must retain only the newest entry")
    }
}
