import XCTest
import Persistence

final class BotComputerMCPAdmitTests: XCTestCase {
    func test_admitPreservesLeftoverServers() {
        let command = "/tmp/RemoteCodeDistillService"
        let claude = BotComputerMCPAdmit.admitClaude(
            existing: ["other": ["command": "x"]],
            command: command
        )
        XCTAssertNotNil(claude["other"])
        XCTAssertTrue(BotComputerMCPAdmit.containsAdmittedClaude(claude))
        XCTAssertEqual(
            (claude[BotComputerMCPAdmit.serverName] as? [String: Any])?["args"] as? [String],
            [BotComputerMCPAdmit.cliArgument]
        )

        let grok = BotComputerMCPAdmit.admitGrokACP(
            existing: [["name": "user-linear"]],
            command: command,
            environment: [:]
        )
        XCTAssertTrue(BotComputerMCPAdmit.containsAdmittedGrokACP(grok))
        let names = grok.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names.filter { $0 == BotComputerMCPAdmit.serverName }.count, 1)
        XCTAssertTrue(names.contains("user-linear"))

        let first = BotComputerMCPAdmit.admitCodexTOML(
            existing: "[mcp_servers.user-linear]\ncommand = \"npx\"\n",
            command: command
        )
        let again = BotComputerMCPAdmit.admitCodexTOML(existing: first, command: command)
        XCTAssertTrue(BotComputerMCPAdmit.containsAdmittedCodexTOML(again))
        XCTAssertEqual(again.components(separatedBy: BotComputerMCPAdmit.tomlBeginMarker).count - 1, 1)
    }
}
