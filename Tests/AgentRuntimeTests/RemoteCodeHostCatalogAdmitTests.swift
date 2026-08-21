import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

final class RemoteCodeHostCatalogAdmitTests: XCTestCase {
    func test_fourProviderAdmissionsKeepPreviousStableServerAndCLIArgument() throws {
        // WHY: a previous-stable binary still recognizes remotecode-bot-self-config
        // and bot-self-config. New tools are additive on that same process.
        XCTAssertEqual(BotSelfConfigMCPAdmit.serverName, "remotecode-bot-self-config")
        XCTAssertEqual(BotSelfConfigMCPAdmit.cliArgument, "bot-self-config")
        XCTAssertEqual(BotSelfConfigCatalog.serverName, BotSelfConfigMCPAdmit.serverName)
        XCTAssertEqual(BotSelfConfigCatalog.cliArgument, BotSelfConfigMCPAdmit.cliArgument)

        let command = "/opt/RemoteCodeDistillService"
        let capability = String(repeating: "ab", count: 32)
        let environment = [
            BotSelfConfigCatalog.callerEnvironmentKey: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            BotPeerDelegation.threadEnvironmentKey: "11111111-2222-3333-4444-555555555555",
            BotPeerDelegation.runEnvironmentKey: "66666666-7777-8888-9999-aaaaaaaaaaaa",
            BotPeerDelegation.socketEnvironmentKey: "/tmp/remote-code.sock",
            BotPeerDelegation.capabilityEnvironmentKey: capability,
        ]

        let claude = BotSelfConfigMCPAdmit.admitClaude(existing: ["user": ["command": "x"]], command: command)
        XCTAssertEqual(
            (claude[BotSelfConfigMCPAdmit.serverName] as? [String: Any])?["args"] as? [String],
            [BotSelfConfigMCPAdmit.cliArgument]
        )
        XCTAssertNotNil(claude["user"])

        let sdk = BotSelfConfigMCPAdmit.claudeSDKServer(command: command, environment: environment)
        XCTAssertEqual(sdk["args"] as? [String], [BotSelfConfigMCPAdmit.cliArgument])
        let sdkEnv = try XCTUnwrap(sdk["env"] as? [String: String])
        XCTAssertEqual(sdkEnv[BotPeerDelegation.capabilityEnvironmentKey], capability)
        XCTAssertNil(sdkEnv["UNRELATED_SECRET"])

        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "claude-opus-4-7",
            cwd: "/tmp",
            prompt: "do not leak this prompt into MCP config",
            environment: environment
        )
        let cli = ClaudeRunner.buildStreamingArgs(request)
        let allowedIndex = try XCTUnwrap(cli.firstIndex(of: "--allowedTools"))
        let allowed = Set(cli[cli.index(after: allowedIndex)].split(separator: ",").map(String.init))
        XCTAssertEqual(allowed, Set(BotSelfConfigMCPAdmit.claudeAutomaticallyAllowedTools))
        for tool in RemoteCodeHostCatalog.toolNames {
            XCTAssertTrue(allowed.contains("mcp__\(BotSelfConfigMCPAdmit.serverName)__\(tool)"), tool)
        }
        XCTAssertTrue(allowed.contains("mcp__\(BotSelfConfigMCPAdmit.serverName)__\(BotSelfConfigCatalog.askPeer)"))
        XCTAssertTrue(cli.contains { $0.contains(RemoteCodeHostCatalog.providerDirective) })
        XCTAssertTrue(cli.contains { $0.contains(BotPeerDelegation.providerDirective) })
        XCTAssertFalse(cli.contains(request.prompt))

        let sdkPrompt = ClaudeAgentSDKBridgeAdapter.claudeSystemPrompt(environment: environment)
        XCTAssertTrue(sdkPrompt.contains(RemoteCodeHostCatalog.providerDirective))

        let grok = BotSelfConfigMCPAdmit.admitGrokACP(
            existing: [["name": "user-linear"]],
            command: command,
            environment: environment
        )
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedGrokACP(grok))
        let grokServer = try XCTUnwrap(grok.compactMap { $0 as? [String: Any] }.first {
            $0["name"] as? String == BotSelfConfigMCPAdmit.serverName
        })
        XCTAssertEqual(grokServer["args"] as? [String], [BotSelfConfigMCPAdmit.cliArgument])
        let grokEnv = try XCTUnwrap(grokServer["env"] as? [[String: String]])
        XCTAssertTrue(grokEnv.contains {
            $0["name"] == BotPeerDelegation.capabilityEnvironmentKey && $0["value"] == capability
        })

        let toml = BotSelfConfigMCPAdmit.admitCodexTOML(
            existing: "[mcp_servers.user-linear]\ncommand = \"npx\"\n",
            command: command
        )
        XCTAssertTrue(BotSelfConfigMCPAdmit.containsAdmittedCodexTOML(toml))
        XCTAssertTrue(toml.contains("[mcp_servers.\(BotSelfConfigMCPAdmit.serverName)]"))
        XCTAssertTrue(toml.contains("args = [\"\(BotSelfConfigMCPAdmit.cliArgument)\"]"))
        XCTAssertTrue(toml.contains("[mcp_servers.user-linear]"))
    }
}
