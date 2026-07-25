import XCTest
@testable import AgentRuntime

/// WHY: FSEvents must not treat graphify-out / .git / ArtifactRoot writes as source
/// edits — otherwise writeInRepo or host publishes cause infinite rebuild loops.
final class GraphifyCheckoutWatcherFilterTests: XCTestCase {
    func test_ignoresGraphifyOutAndGitAndNodeModules() {
        let w = GraphifyCheckoutWatcher(path: "/repo", ignoredPathPrefixes: ["/repo/.rc-artifact"]) { }
        XCTAssertFalse(w.shouldNotify(for: "/repo/graphify-out/graph.json"))
        XCTAssertFalse(w.shouldNotify(for: "/repo/.git/objects/aa"))
        XCTAssertFalse(w.shouldNotify(for: "/repo/node_modules/x/index.js"))
        XCTAssertFalse(w.shouldNotify(for: "/repo/.rc-artifact/graph.json"))
        XCTAssertFalse(w.shouldNotify(for: "/repo/.rc-artifact/cache/x"))
        XCTAssertTrue(w.shouldNotify(for: "/repo/src/App.ts"))
        XCTAssertTrue(w.shouldNotify(for: "/repo/package.json"))
    }
}
