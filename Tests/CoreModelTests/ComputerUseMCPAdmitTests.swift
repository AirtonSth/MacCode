import XCTest
@testable import CoreModel

final class ComputerUseMCPAdmitTests: XCTestCase {
    func test_admitClaudePreservesLeftoverAndAddsComputerUse() {
        let existing: [String: Any] = ["other": ["command": "x"]]
        let admitted = ComputerUseMCPAdmit.admitClaude(existing: existing, command: "/opt/RemoteCodeDistillService")
        XCTAssertNotNil(admitted["other"], "user MCP stays")
        let ours = admitted[ComputerUseMCPAdmit.serverName] as? [String: Any]
        XCTAssertEqual(ours?["command"] as? String, "/opt/RemoteCodeDistillService")
        XCTAssertEqual(ours?["args"] as? [String], [ComputerUseMCPAdmit.cliArgument])
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedClaude(admitted))
    }

    func test_admitCodexTOMLPreservesUserTable() {
        let existing = "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
        let admitted = ComputerUseMCPAdmit.admitCodexTOML(existing: existing, command: "/bin/svc")
        XCTAssertTrue(admitted.contains("model = \"gpt\""))
        XCTAssertTrue(admitted.contains("[mcp_servers.other]"))
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedCodexTOML(admitted))
        let again = ComputerUseMCPAdmit.admitCodexTOML(existing: admitted, command: "/bin/svc")
        XCTAssertEqual(
            again.components(separatedBy: ComputerUseMCPAdmit.tomlBeginMarker).count - 1,
            1,
            "idempotent managed block"
        )
    }

    func test_admitGrokACPPreservesLeftoverAndIsIdempotent() {
        let leftover: [Any] = [["name": "user-linear", "command": "npx"]]
        let first = ComputerUseMCPAdmit.admitGrokACP(existing: leftover, command: "/bin/svc")
        let second = ComputerUseMCPAdmit.admitGrokACP(existing: first, command: "/bin/svc")
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedGrokACP(second))
        let names = second.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names.filter { $0 == ComputerUseMCPAdmit.serverName }.count, 1)
        XCTAssertTrue(names.contains("user-linear"))
    }

    func test_admitGrokACPIncludesRequiredEnvArray() {
        // WHY: live grok 1.0.4 session/new rejects stdio MCP objects that omit
        // env or send a {KEY:value} dict (`untagged enum McpServer`).
        let admitted = ComputerUseMCPAdmit.admitGrokACP(existing: [], command: "/bin/svc")
        let ours = admitted.compactMap { $0 as? [String: Any] }.first {
            $0["name"] as? String == ComputerUseMCPAdmit.serverName
        }
        XCTAssertEqual(ours?["env"] as? [[String: String]], [])
        XCTAssertTrue(GrokACPMcpServer.envIsACPArray(ours?["env"]))
    }
}
