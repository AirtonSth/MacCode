import XCTest
import Foundation
@testable import AppShell

/// Tests the lazy file-tree model that backs the Files sidebar's disclosure tree (P1).
/// These exercise the nesting + lazy-fetch logic in isolation via a stub item and a stub lister,
/// so they assert the tree's CONTRACT (children are fetched only on first expand, nesting matches
/// the listing) rather than re-asserting the production filesystem call.
final class FileTreeStoreTests: XCTestCase {
    /// Minimal stand-in for a file/directory row. Mirrors only what `FileTreeItem` requires, so the
    /// store can be tested without constructing a real `FileEntry` (which decodes from JSON).
    private struct StubItem: FileTreeItem {
        let id: String
        let name: String
        let relativePath: String
        let isDirectory: Bool

        init(_ relativePath: String, isDirectory: Bool) {
            self.id = relativePath
            self.name = (relativePath as NSString).lastPathComponent
            self.relativePath = relativePath
            self.isDirectory = isDirectory
        }
    }

    /// A flat fixture filesystem keyed by directory path -> its direct children, plus a counter so
    /// the test can prove each directory is listed at most once (lazy + cached).
    private final class FakeLister {
        private let listings: [String: [StubItem]]
        private(set) var calls: [String] = []

        init(_ listings: [String: [StubItem]]) { self.listings = listings }

        func list(_ path: String) throws -> [StubItem] {
            calls.append(path)
            return listings[path] ?? []
        }
    }

    func test_setRoots_buildsTopLevelNodesWithoutListingChildren() {
        let lister = FakeLister([:])
        let store = FileTreeStore<StubItem>(lister: lister.list)

        store.setRoots([StubItem("src", isDirectory: true), StubItem("README.md", isDirectory: false)])

        // Seeding the top level must NOT eagerly fetch any directory's children — that is the whole
        // point of lazy loading for deep repos (P1).
        XCTAssertEqual(lister.calls, [], "seeding roots must not trigger any child listing")
        XCTAssertEqual(store.roots.map(\.item.relativePath), ["src", "README.md"])
        XCTAssertTrue(store.roots.allSatisfy { $0.children == nil },
                      "unexpanded rows must carry no children so deep subtrees stay unfetched")
    }

    func test_expand_fetchesChildrenLazilyAndNestsThemUnderTheDirectory() {
        let lister = FakeLister([
            "src": [StubItem("src/app.swift", isDirectory: false), StubItem("src/ui", isDirectory: true)]
        ])
        let store = FileTreeStore<StubItem>(lister: lister.list)
        store.setRoots([StubItem("src", isDirectory: true)])
        let srcNode = store.roots[0]

        let didExpand = store.expand(srcNode)

        XCTAssertTrue(didExpand)
        XCTAssertTrue(srcNode.isExpanded)
        // Children are fetched exactly when (and only when) the directory is expanded, and nested
        // under it with correct parent/child identity (P1).
        XCTAssertEqual(lister.calls, ["src"], "expanding must fetch this directory's children once")
        XCTAssertEqual(srcNode.children?.map(\.item.relativePath), ["src/app.swift", "src/ui"])
        XCTAssertTrue(srcNode.children?.first(where: { $0.item.relativePath == "src/ui" })?.children == nil,
                      "a nested directory must stay unfetched until it too is expanded")
    }

    func test_expand_isCachedAndNotRefetchedOnSecondExpand() {
        let lister = FakeLister(["src": [StubItem("src/app.swift", isDirectory: false)]])
        let store = FileTreeStore<StubItem>(lister: lister.list)
        store.setRoots([StubItem("src", isDirectory: true)])
        let node = store.roots[0]

        store.expand(node)
        store.collapse(node)
        store.expand(node)

        // Collapsing then re-expanding must reuse the cached children, not hit the (potentially
        // expensive, security-scoped) lister again — re-expand is free (P1).
        XCTAssertEqual(lister.calls, ["src"], "re-expanding a previously fetched directory must not refetch")
        XCTAssertTrue(node.isExpanded)
    }

    func test_expand_onNonDirectory_doesNothing() {
        let lister = FakeLister([:])
        let store = FileTreeStore<StubItem>(lister: lister.list)
        store.setRoots([StubItem("README.md", isDirectory: false)])
        let leaf = store.roots[0]

        let didExpand = store.expand(leaf)

        // Leaves can never be expanded; the lister must never be consulted for a file row, or the
        // tree would attempt to list a non-directory path (P1).
        XCTAssertFalse(didExpand)
        XCTAssertFalse(leaf.isExpanded)
        XCTAssertEqual(lister.calls, [])
    }

    func test_expand_whenListerThrows_staysCollapsedAndReportsFailure() {
        struct ListError: Error {}
        let store = FileTreeStore<StubItem>(lister: { _ in throw ListError() })
        store.setRoots([StubItem("secret", isDirectory: true)])
        let node = store.roots[0]

        let didExpand = store.expand(node)

        // A failed listing (e.g. permission denied) must not leave the row claiming to be an
        // expanded-but-empty directory; it stays collapsed so the user can retry (P1).
        XCTAssertFalse(didExpand)
        XCTAssertFalse(node.isExpanded)
        XCTAssertNil(node.children, "a failed fetch must not cache empty children as if confirmed empty")
    }

    func test_forceExpand_refetchesAlreadyLoadedChildren() {
        let lister = FakeLister(["src": [StubItem("src/old.swift", isDirectory: false)]])
        let store = FileTreeStore<StubItem>(lister: lister.list)
        store.setRoots([StubItem("src", isDirectory: true)])
        let node = store.roots[0]

        store.expand(node)
        let didForce = store.expand(node, force: true)

        // After a mutation in a directory, a forced expand must re-list it so the tree reflects the
        // new contents instead of stale cached children (P1).
        XCTAssertTrue(didForce)
        XCTAssertEqual(lister.calls, ["src", "src"], "force must bypass the cache and refetch")
    }

    func test_cachedItem_findsSeededRootWithoutListingChildren() {
        let lister = FakeLister([:])
        let store = FileTreeStore<StubItem>(lister: lister.list)
        store.setRoots([StubItem("src", isDirectory: true)])

        let cached = store.cachedItem(relativePath: "src")

        XCTAssertEqual(cached?.relativePath, "src",
            "sidebar move-drop must resolve top-level drag sources from the already-rendered roots")
        XCTAssertEqual(lister.calls, [],
            "cached lookup must not list directories; it is used during drag/drop hit handling")
    }

    func test_cachedItem_findsExpandedSubtreeChild() {
        let lister = FakeLister([
            "src": [StubItem("src/app.swift", isDirectory: false), StubItem("src/ui", isDirectory: true)]
        ])
        let store = FileTreeStore<StubItem>(lister: lister.list)
        store.setRoots([StubItem("src", isDirectory: true)])

        _ = store.children(at: "src")
        let cached = store.cachedItem(relativePath: "src/app.swift")

        XCTAssertEqual(cached?.relativePath, "src/app.swift",
            "moving a file from an expanded subdirectory must find the cached source row")
        XCTAssertEqual(lister.calls, ["src"],
            "the subtree should be fetched once by expansion and then reused by drag/drop lookup")
    }

    func test_cachedItem_doesNotFetchUncachedSubtree() {
        let lister = FakeLister(["src": [StubItem("src/app.swift", isDirectory: false)]])
        let store = FileTreeStore<StubItem>(lister: lister.list)
        store.setRoots([StubItem("src", isDirectory: true)])

        let cached = store.cachedItem(relativePath: "src/app.swift")

        XCTAssertNil(cached,
            "cached lookup must not perform surprise IO for collapsed subtrees during drop handling")
        XCTAssertEqual(lister.calls, [],
            "uncached subtree lookup must stay read-only so failed drops do not trigger hidden listings")
    }

    func test_childCacheCountLimit_matchesDiscoveryOrder() {
        XCTAssertEqual(FileTreeStore<StubItem>.childCacheCountLimit, 256)
    }

    func test_noteChildCacheEntry_capsDistinctPaths() {
        var cache: [String: [StubItem]] = [:]
        let limit = 4
        for i in 0..<(limit + 10) {
            FileTreeStore<StubItem>.noteChildCacheEntry(
                &cache,
                path: "dir-\(i)",
                items: [StubItem("dir-\(i)/f.swift", isDirectory: false)],
                countLimit: limit
            )
        }
        XCTAssertEqual(cache.count, limit)
        XCTAssertNotNil(cache["dir-\(limit + 9)"])
        let evictedCount = (0..<(limit + 10)).filter {
            cache["dir-\($0)"] == nil
        }.count
        XCTAssertEqual(evictedCount, 10)
    }

    func test_noteChildCacheEntry_updatesExistingWithoutGrowth() {
        var cache: [String: [StubItem]] = [:]
        FileTreeStore<StubItem>.noteChildCacheEntry(
            &cache, path: "src", items: [StubItem("src/a", isDirectory: false)], countLimit: 3
        )
        FileTreeStore<StubItem>.noteChildCacheEntry(
            &cache, path: "src", items: [StubItem("src/b", isDirectory: false)], countLimit: 3
        )
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache["src"]?.map(\.relativePath), ["src/b"])
    }

    func test_fetch_enforcesCapOnLiveStore() {
        var listings: [String: [StubItem]] = [:]
        for i in 0..<20 {
            listings["d\(i)"] = [StubItem("d\(i)/f", isDirectory: false)]
        }
        let lister = FakeLister(listings)
        let store = FileTreeStore<StubItem>(lister: lister.list, childCacheCountLimit: 5)
        store.setRoots((0..<20).map { StubItem("d\($0)", isDirectory: true) })
        for node in store.roots {
            _ = store.expand(node)
        }
        XCTAssertEqual(store.childCacheCountForTesting, 5)
        // Newest still cached (no re-list)
        let callsBefore = lister.calls.count
        _ = store.children(at: "d19")
        XCTAssertEqual(lister.calls.count, callsBefore, "hot path must stay cached under the cap")
        // At least the 15 paths outside the five-entry window must re-list.
        // The cache intentionally makes no promise about which old key is evicted.
        let callsBeforeScan = lister.calls.count
        for index in 0..<19 {
            _ = store.children(at: "d\(index)")
        }
        XCTAssertGreaterThanOrEqual(lister.calls.count - callsBeforeScan, 15)
    }

    func test_retentionEstimate_2kDirsTo256Window() {
        let uncapped = 2_000
        let limit = FileTreeStore<StubItem>.childCacheCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.87)
        XCTAssertEqual(limit, 256)
        // Basis: path key (~40B) + modest listing (~20 entries × ~80B) ≈ ~1.6KB/dir.
        // 2k × 1.6KB ≈ 3.2MB → 256 × 1.6KB ≈ 410KB (−87.2%). Large listings
        // scale with the same path ceiling.
        let perDir = 1_600
        XCTAssertEqual(uncapped * perDir, 3_200_000)
        XCTAssertEqual(limit * perDir, 409_600)
    }
}
