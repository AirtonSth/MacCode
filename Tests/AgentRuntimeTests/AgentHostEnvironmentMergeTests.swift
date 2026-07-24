import XCTest
@testable import AgentRuntime

/// WHY: Auto-orchestration must not drop Graphify host injects when a launch
/// config exists — otherwise agents report BANNER_MISSING / no graph.
final class AgentHostEnvironmentMergeTests: XCTestCase {
    func test_preserveHostInjectsKeepsGraphifyWhenLaunchPresent() {
        let launch = ["CODEX_API_KEY": "x", "PATH": "/usr/bin"]
        let request = [
            "RC_GRAPHIFY_ENABLED": "1",
            "RC_GRAPHIFY_GRAPH_JSON": "/tmp/g.json",
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            "PATH": "/old"
        ]
        let merged = AgentHostEnvironmentMerge.preserveHostInjects(launch: launch, request: request)
        XCTAssertEqual(merged["RC_GRAPHIFY_ENABLED"], "1")
        XCTAssertEqual(merged["RC_GRAPHIFY_GRAPH_JSON"], "/tmp/g.json")
        XCTAssertEqual(merged["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(merged["CODEX_API_KEY"], "x")
        XCTAssertEqual(merged["PATH"], "/usr/bin", "launch provider PATH should win")
    }

    func test_preserveHostInjectsWithoutLaunchUsesRequest() {
        let request = ["RC_GRAPHIFY_ENABLED": "1", "FOO": "bar"]
        let merged = AgentHostEnvironmentMerge.preserveHostInjects(launch: nil, request: request)
        XCTAssertEqual(merged, request)
    }

    func test_preserveHostInjectsStripsStaleGraphifyFromLaunchWhenRequestInactive() {
        // WHY: Auto must not resurrect Graphify when Token Saver / Graphify is off
        // but a launch config still carries RC_GRAPHIFY_* from a prior path.
        let launch = [
            "CODEX_API_KEY": "x",
            "RC_GRAPHIFY_ENABLED": "1",
            "RC_GRAPHIFY_GRAPH_JSON": "/stale/g.json"
        ]
        let request = ["PATH": "/usr/bin"] // no host Graphify injects
        let merged = AgentHostEnvironmentMerge.preserveHostInjects(launch: launch, request: request)
        XCTAssertNil(merged["RC_GRAPHIFY_ENABLED"])
        XCTAssertNil(merged["RC_GRAPHIFY_GRAPH_JSON"])
        XCTAssertEqual(merged["CODEX_API_KEY"], "x")
    }
}
