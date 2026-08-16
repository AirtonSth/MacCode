import XCTest
@testable import Persistence

final class BotSelfConfigMCPAdmitTests: XCTestCase {
    func test_admitClaudePreservesLeftoverAndAddsSelfConfig() {
        let existing: [String: Any] = ["other": ["command": "x"]]
        let admitted = BotSelfConfigMCPAdmit.admitClaude(existing: existing, command: "/opt/RemoteCodeDistillService")
        XCTAssertNotNil(admitted["other"], "user MCP stays")
        let ours = admitted[BotSelfConfigMCPAdmit.serverName] as? [String: Any]
        XCTAssertEqual(ours?["command"] as? String, "/opt/RemoteCodeDistillService")
        XCTAssertEqual(ours?["args"] as? [String], [BotSelfConfigMCPAdmit.cliArgument])
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedClaude(admitted))
        XCTAssertNil((ours?["env"] as? [String: Any])?[BotSelfConfigCatalog.callerEnvironmentKey])
    }

    func test_admitCodexTOMLPreservesUserTable() {
        let existing = "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
        let admitted = BotSelfConfigMCPAdmit.admitCodexTOML(existing: existing, command: "/bin/svc")
        XCTAssertTrue(admitted.contains("model = \"gpt\""))
        XCTAssertTrue(admitted.contains("[mcp_servers.other]"))
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedCodexTOML(admitted))
        let again = BotSelfConfigMCPAdmit.admitCodexTOML(existing: admitted, command: "/bin/svc")
        XCTAssertEqual(
            again.components(separatedBy: BotSelfConfigMCPAdmit.tomlBeginMarker).count - 1,
            1,
            "idempotent managed block"
        )
    }

    func test_admitGrokACPPreservesLeftoverAndIsIdempotent() {
        let leftover: [Any] = [["name": "user-linear", "command": "npx"]]
        let first = BotSelfConfigMCPAdmit.admitGrokACP(
            existing: leftover,
            command: "/bin/svc",
            environment: [:]
        )
        let second = BotSelfConfigMCPAdmit.admitGrokACP(
            existing: first,
            command: "/bin/svc",
            environment: [BotSelfConfigCatalog.callerEnvironmentKey: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]
        )
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedGrokACP(second))
        let names = second.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names.filter { $0 == BotSelfConfigMCPAdmit.serverName }.count, 1)
        XCTAssertTrue(names.contains("user-linear"))
        let ours = second.compactMap { $0 as? [String: Any] }.first {
            $0["name"] as? String == BotSelfConfigMCPAdmit.serverName
        }
        XCTAssertEqual(
            (ours?["env"] as? [String: String])?[BotSelfConfigCatalog.callerEnvironmentKey],
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
    }
}
