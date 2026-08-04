import XCTest
@testable import AgentRuntime

/// plan-final W3: only managed inactive unpinned regenerable roots may quarantine.
final class GraphifyRootRetentionTests: XCTestCase {
    func test_activeRoot_kept() {
        let root = GraphifyManagedRoot(
            rootId: "a", path: "/tmp/a", lastUsedAt: .distantPast, isActive: true
        )
        XCTAssertEqual(
            GraphifyRootRetention.decide(root: root, now: Date(), idleAge: 60),
            .keep
        )
    }

    func test_pinnedRoot_kept() {
        let root = GraphifyManagedRoot(
            rootId: "a", path: "/tmp/a", lastUsedAt: .distantPast, isPinned: true
        )
        XCTAssertEqual(
            GraphifyRootRetention.decide(root: root, now: Date(), idleAge: 60),
            .keep
        )
    }

    func test_idleManagedRoot_quarantine() {
        let root = GraphifyManagedRoot(
            rootId: "a",
            path: "/tmp/a",
            lastUsedAt: Date(timeIntervalSince1970: 0),
            isPinned: false,
            isActive: false,
            isManaged: true,
            isRegenerable: true
        )
        XCTAssertEqual(
            GraphifyRootRetention.decide(root: root, now: Date(timeIntervalSince1970: 10_000), idleAge: 60),
            .quarantine
        )
    }

    func test_unmanagedRoot_kept() {
        let root = GraphifyManagedRoot(
            rootId: "a", path: "/tmp/a", lastUsedAt: .distantPast, isManaged: false
        )
        XCTAssertEqual(
            GraphifyRootRetention.decide(root: root, now: Date(), idleAge: 1),
            .keep
        )
    }

    func test_quarantinePath_isRenameNotDelete() {
        let path = GraphifyRootRetention.quarantinePath(for: "/tmp/graph", stamp: "1")
        XCTAssertTrue(path.contains("quarantine-1"))
        XCTAssertTrue(path.hasPrefix("tmp/graph") || path.contains("graph"))
    }
}
