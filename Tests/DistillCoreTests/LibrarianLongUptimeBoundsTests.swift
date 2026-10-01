import XCTest
@testable import DistillCore

final class LibrarianLongUptimeBoundsTests: XCTestCase {
    func test_workspaceIndexCacheKeepsOnlyRecentRoots_becauseEachIndexHoldsTensOfMiB() async {
        // WHY: the shared cache kept one index (text, chunks, vectors) per root the
        // service ever saw; months of switching repos grew the service without bound.
        let cache = LibrarianWorkspaceIndexCache(maxRoots: 3)
        let host = LibrarianHostIO.live
        var first: LibrarianWorkspaceIndex?
        for index in 0..<50 {
            let created = await cache.index(for: "/tmp/rc-root-\(index)", host: host, embedder: nil)
            if index == 0 { first = created }
        }
        let count = await cache.cachedRootCount
        XCTAssertEqual(count, 3)
        let recent = await cache.index(for: "/tmp/rc-root-49", host: host, embedder: nil)
        let recentAgain = await cache.index(for: "/tmp/rc-root-49", host: host, embedder: nil)
        XCTAssertTrue(recent === recentAgain, "recently used roots stay cached")
        let rebuilt = await cache.index(for: "/tmp/rc-root-0", host: host, embedder: nil)
        XCTAssertFalse(rebuilt === first, "an evicted root is rebuilt on demand")
    }
}
