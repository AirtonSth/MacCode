import XCTest
import CoreModel
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

    func test_admitGrokACPPreservesLeftoverAndIsIdempotent() throws {
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
        let env = try XCTUnwrap(ours?["env"] as? [[String: String]])
        XCTAssertEqual(
            env,
            [["name": BotSelfConfigCatalog.callerEnvironmentKey, "value": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]]
        )
        let emptyEnv = first.compactMap { $0 as? [String: Any] }.first {
            $0["name"] as? String == BotSelfConfigMCPAdmit.serverName
        }
        XCTAssertEqual(emptyEnv?["env"] as? [[String: String]], [])
    }

    func test_grokACPForwardsExactActiveRunContextForAIDelegation() throws {
        // WHY: Grok runs construct MCP servers per session. Without the exact
        // thread/run/socket tuple, the AI-authored tool call cannot be bound to
        // its active primary run and must never fall back to prompt parsing.
        let environment = [
            BotSelfConfigCatalog.callerEnvironmentKey: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": "/tmp/support",
            BotPeerDelegation.threadEnvironmentKey: "11111111-2222-3333-4444-555555555555",
            BotPeerDelegation.runEnvironmentKey: "66666666-7777-8888-9999-aaaaaaaaaaaa",
            BotPeerDelegation.socketEnvironmentKey: "/tmp/remote-code.sock",
            "UNRELATED_SECRET": "must-not-be-forwarded",
        ]
        let server = BotSelfConfigMCPAdmit.grokACPServer(
            command: "/bin/svc",
            environment: environment
        )
        let env = try XCTUnwrap(server["env"] as? [[String: String]])
        let forwarded: [String: String] = Dictionary(uniqueKeysWithValues: env.compactMap { row -> (String, String)? in
            guard let name = row["name"], let value = row["value"] else { return nil }
            return (name, value)
        })
        XCTAssertEqual(forwarded, environment.filter { $0.key != "UNRELATED_SECRET" })
        XCTAssertNil(forwarded["UNRELATED_SECRET"])
    }

    func test_claudeSDKForwardsOnlyExactActiveRunContextAndWaitsForPeer() throws {
        // WHY: Claude's SDK ignores a managed settings entry when an explicit
        // mcpServers map is supplied. Its long-lived query must receive a fresh,
        // always-visible server for each exact primary run, without leaking the
        // rest of the provider environment into the MCP subprocess.
        let environment = [
            BotSelfConfigCatalog.callerEnvironmentKey: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": "/tmp/support",
            BotPeerDelegation.threadEnvironmentKey: "11111111-2222-3333-4444-555555555555",
            BotPeerDelegation.runEnvironmentKey: "66666666-7777-8888-9999-aaaaaaaaaaaa",
            BotPeerDelegation.socketEnvironmentKey: "/tmp/remote-code.sock",
            "UNRELATED_SECRET": "must-not-be-forwarded",
        ]
        let server = BotSelfConfigMCPAdmit.claudeSDKServer(
            command: "/bin/svc",
            environment: environment
        )
        XCTAssertEqual(server["command"] as? String, "/bin/svc")
        XCTAssertEqual(server["args"] as? [String], [BotSelfConfigMCPAdmit.cliArgument])
        XCTAssertEqual(server["alwaysLoad"] as? Bool, true)
        XCTAssertEqual(server["timeout"] as? Int, 600_000)
        let forwarded = try XCTUnwrap(server["env"] as? [String: String])
        XCTAssertEqual(forwarded, environment.filter { $0.key != "UNRELATED_SECRET" })
        XCTAssertNil(forwarded["UNRELATED_SECRET"])
    }
}
