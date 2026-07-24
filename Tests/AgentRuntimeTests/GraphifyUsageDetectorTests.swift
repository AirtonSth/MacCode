import XCTest
@testable import AgentRuntime

final class GraphifyUsageDetectorTests: XCTestCase {
    func test_detectsQueryPathExplain_withPathAndEnv() {
        // WHY: agents run absolute graphify + env-wrapped forms from RC_GRAPHIFY_*.
        XCTAssertEqual(
            GraphifyUsageDetector.detect(summary: #"graphify query "where is X""#, body: nil).map(\.subcommand),
            ["query"]
        )
        XCTAssertEqual(
            GraphifyUsageDetector.detect(summary: "/Users/me/.local/bin/graphify explain Foo", body: nil).map(\.subcommand),
            ["explain"]
        )
        XCTAssertEqual(
            GraphifyUsageDetector.detect(summary: "cd /repo && graphify path A B", body: nil).map(\.subcommand),
            ["path"]
        )
        XCTAssertEqual(
            GraphifyUsageDetector.detect(summary: "/usr/bin/env graphify query x", body: nil).map(\.subcommand),
            ["query"]
        )
        XCTAssertEqual(
            GraphifyUsageDetector.detect(summary: "FOO=1 graphify query x", body: nil).map(\.subcommand),
            ["query"]
        )
    }

    func test_rejectsUpdateEchoGrepAndInstall() {
        // WHY: indexing / prose must never become savings signals.
        let negatives = [
            "graphify update",
            #"echo "graphify query x""#,
            "grep -r graphify Sources",
            "uv tool install graphifyy",
            "cat graphify.json",
        ]
        for cmd in negatives {
            let hits = GraphifyUsageDetector.detect(summary: cmd, body: nil)
            XCTAssertTrue(hits.isEmpty, "must not match: \(cmd) → \(hits)")
        }
    }

    func test_claudeBashJSON_commandExtraction() {
        let body = #"{"command":"graphify query SidebarView --graph /tmp/g.json"}"#
        let hits = GraphifyUsageDetector.detect(summary: "Bash", body: body)
        XCTAssertEqual(hits.map(\.subcommand), ["query"])
    }

    func test_explorationToolNames() {
        XCTAssertTrue(GraphifyUsageDetector.isExplorationTool(summary: "Read"))
        XCTAssertTrue(GraphifyUsageDetector.isExplorationTool(summary: "Grep"))
        XCTAssertTrue(GraphifyUsageDetector.isExplorationTool(summary: "Glob"))
        XCTAssertFalse(GraphifyUsageDetector.isExplorationTool(summary: "Bash"))
        XCTAssertFalse(GraphifyUsageDetector.isExplorationTool(summary: "result"))
    }

    func test_tokensFromUTF8Count() {
        XCTAssertEqual(GraphifyUsageDetector.tokensFromUTF8Count(0), 0)
        XCTAssertEqual(GraphifyUsageDetector.tokensFromUTF8Count(400), 100)
    }

    func test_looksLikeFailure() {
        XCTAssertTrue(GraphifyUsageDetector.looksLikeFailure(output: "graphify: command not found"))
        XCTAssertFalse(GraphifyUsageDetector.looksLikeFailure(output: "NODE SidebarView …"))
    }
}
