import XCTest
@testable import AgentRuntime

/// WHY: the Claude bridge is an ES module (`.mjs`). A Node older than
/// `minimumNodeMajorVersion` runs it through the CommonJS loader and dies with
/// `ERR_REQUIRE_ESM` — the raw Node stack trace a customer saw when a stale
/// system Node (v12) shadowed a modern one on PATH. Resolution must never hand
/// the bridge a too-old Node, must prefer a newer version-manager Node when the
/// PATH Node is too old, and must fail with an actionable upgrade message when
/// no usable Node exists.
final class ClaudeAgentSDKBridgeNodeVersionTests: XCTestCase {
    typealias Adapter = ClaudeAgentSDKBridgeAdapter

    func test_selectNode_prefersPathNodeWhenItMeetsMinimum() {
        let versions = ["/path/node": 20, "/vm/node": 22]
        let result = Adapter.selectNode(candidates: ["/path/node", "/vm/node"]) { versions[$0] }
        // PATH node is first and qualifies — it wins even though a newer VM node exists.
        XCTAssertEqual(result, .ok("/path/node"))
    }

    func test_selectNode_fallsBackToVersionManagerWhenPathNodeTooOld() {
        // Exactly the customer case: a v12 shadowing a modern nvm/brew Node.
        let versions = ["/usr/local/bin/node": 12, "/vm/node": 20]
        let result = Adapter.selectNode(candidates: ["/usr/local/bin/node", "/vm/node"]) { versions[$0] }
        XCTAssertEqual(result, .ok("/vm/node"),
                       "a too-old PATH Node must not shadow a usable version-manager Node")
    }

    func test_selectNode_reportsNewestTooOldWhenNoCandidateQualifies() {
        let versions = ["/a/node": 12, "/b/node": 16]
        let result = Adapter.selectNode(candidates: ["/a/node", "/b/node"]) { versions[$0] }
        // Report the newest too-old Node so the upgrade message names the real version.
        XCTAssertEqual(result, .tooOld(path: "/b/node", major: 16))
    }

    func test_selectNode_missingWhenNoVersionResolves() {
        let result = Adapter.selectNode(candidates: ["/a/node", "/b/node"]) { _ in nil }
        XCTAssertEqual(result, .missing)
    }

    func test_selectNode_missingWhenNoCandidates() {
        XCTAssertEqual(Adapter.selectNode(candidates: []) { _ in 99 }, .missing)
    }

    func test_minimumIsAtLeast14SoESMBridgeCanRun() {
        // The whole point of the gate: below Node 14 the .mjs main module hits
        // the CJS loader and throws ERR_REQUIRE_ESM.
        XCTAssertGreaterThanOrEqual(Adapter.minimumNodeMajorVersion, 14)
    }

    func test_nodeTooOldMessage_isActionable() {
        let message = Adapter.nodeTooOldMessage(path: "/usr/local/bin/node", major: 12)
        XCTAssertTrue(message.contains("\(Adapter.minimumNodeMajorVersion)"),
                      "must state the required major version")
        XCTAssertTrue(message.contains("v12"), "must name the too-old version found")
        XCTAssertTrue(message.lowercased().contains("nodejs.org") || message.lowercased().contains("brew"),
                      "must tell the user how to install a current Node")
        XCTAssertFalse(message.contains("ERR_REQUIRE_ESM"),
                       "must replace the cryptic Node error, not echo it")
    }

    func test_nodeCandidatePaths_explicitPathOverrideIsUsedAsIs() {
        // A non-existent explicit path yields no candidate (still version-gated,
        // never blindly launched); a "/"-containing name never scans PATH.
        XCTAssertTrue(Adapter.nodeCandidatePaths(binary: "/does/not/exist/node").isEmpty)
    }

    func test_resolveNode_onThisMachineExercisesTheRealVersionQuery() {
        // End-to-end: enumerate PATH -> `node --version` -> select. Not flaky:
        // whichever branch fires, the resolved fact must be self-consistent.
        switch Adapter.resolveNode() {
        case .ok(let path):
            let major = Adapter.nodeMajorVersion(at: path)
            XCTAssertNotNil(major, "a resolved .ok node must report its version")
            XCTAssertGreaterThanOrEqual(major ?? 0, Adapter.minimumNodeMajorVersion,
                                        "an .ok node must meet the minimum — never a too-old node")
        case .tooOld(_, let major):
            XCTAssertLessThan(major, Adapter.minimumNodeMajorVersion)
        case .missing:
            break   // acceptable on a machine with no Node at all
        }
    }

    func test_nodeTooOldMessage_scrubsHomeAbsolutePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let message = Adapter.nodeTooOldMessage(path: "\(home)/.nvm/versions/node/v12.0.0/bin/node", major: 12)
        XCTAssertFalse(message.contains(home), "customer-facing text must not leak the home absolute path")
        XCTAssertTrue(message.contains("~/.nvm/versions/node"), "scrubbed path should still be informative")
    }
}
