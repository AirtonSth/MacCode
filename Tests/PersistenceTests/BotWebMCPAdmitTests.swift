import XCTest
@testable import Persistence

final class BotWebMCPAdmitTests: XCTestCase {
    func test_admitClaudeCodexAndGrokWithoutClobberingUserServers() {
        let command = "/opt/RemoteCodeDistillService"
        let claude = BotWebMCPAdmit.admitClaude(
            existing: ["user-linear": ["command": "npx"]],
            command: command
        )
        XCTAssertTrue(BotWebMCPAdmit.containsAdmittedClaude(claude))
        XCTAssertEqual(
            (claude[BotWebMCPAdmit.serverName] as? [String: Any])?["args"] as? [String],
            [BotWebMCPAdmit.cliArgument]
        )
        XCTAssertNotNil(claude["user-linear"])

        let grok = BotWebMCPAdmit.admitGrokACP(
            existing: [["name": "user-linear"]],
            command: command,
            environment: [:]
        )
        XCTAssertTrue(BotWebMCPAdmit.containsAdmittedGrokACP(grok))
        let names = grok.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names.filter { $0 == BotWebMCPAdmit.serverName }.count, 1)

        let first = BotWebMCPAdmit.admitCodexTOML(existing: "[mcp_servers.user-linear]\ncommand = \"npx\"\n", command: command)
        let again = BotWebMCPAdmit.admitCodexTOML(existing: first, command: command)
        XCTAssertTrue(BotWebMCPAdmit.containsAdmittedCodexTOML(again))
        XCTAssertEqual(again.components(separatedBy: BotWebMCPAdmit.tomlBeginMarker).count - 1, 1)
        XCTAssertTrue(again.contains("user-linear"))
    }
}
