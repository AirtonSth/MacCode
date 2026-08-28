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

    func test_cappedHaystack_rejectsHugeProseWithoutSplitting() {
        // WHY: live Grok ACP parse spent 100% CPU in components(separatedBy:)
        // on a multi-MB itemDelta body that never contained graphify.
        let huge = String(repeating: "lorem ipsum dolor sit amet\n", count: 20_000)
        XCTAssertGreaterThan(huge.utf8.count, GraphifyUsageDetector.maxHaystackUTF8Bytes)
        XCTAssertFalse(GraphifyUsageDetector.mentionsGraphify(huge))
        XCTAssertTrue(GraphifyUsageDetector.detect(summary: nil, body: huge).isEmpty)
        let capped = GraphifyUsageDetector.cappedHaystack(huge)
        XCTAssertLessThanOrEqual(capped.utf8.count, GraphifyUsageDetector.maxHaystackUTF8Bytes)
        let grown = GraphifyUsageDetector.appendCapped(capped, String(repeating: "x", count: 4096))
        XCTAssertEqual(grown, capped)
    }

    func test_detect_stillMatchesGraphifyInCappedWindow() {
        // Split is on newline/;/|&, so a real invocation must start a segment.
        let prefix = String(repeating: "noise\n", count: 40)
        let body = prefix + "graphify query where is X"
        XCTAssertEqual(
            GraphifyUsageDetector.detect(summary: "Bash", body: body).map(\.subcommand),
            ["query"]
        )
    }

    func test_looksLikeFailure_highConfidenceOnly() {
        // WHY: legit graphify/code output often contains "error:" / "fatal:" / "not found".
        XCTAssertTrue(GraphifyUsageDetector.looksLikeFailure(output: "graphify: command not found"))
        XCTAssertTrue(GraphifyUsageDetector.looksLikeFailure(output: "bash: graphify: command not found\n"))
        XCTAssertFalse(GraphifyUsageDetector.looksLikeFailure(output: "NODE SidebarView …"))
        XCTAssertFalse(
            GraphifyUsageDetector.looksLikeFailure(output: "error: no such module 'Foo'\nfatal: path not found"),
            "Must not delete successful tool results that merely mention errors in content"
        )
    }
}
