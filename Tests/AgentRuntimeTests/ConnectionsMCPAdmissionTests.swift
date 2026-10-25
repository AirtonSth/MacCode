import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

final class ConnectionsMCPAdmissionTests: XCTestCase {
    func testEveryHostProviderAdmitsTheSameAppFacadeWithOnlyRunAuthority() throws {
        let env = [BotPeerDelegation.threadEnvironmentKey: UUID().uuidString, BotPeerDelegation.runEnvironmentKey: UUID().uuidString, BotPeerDelegation.socketEnvironmentKey: "/tmp/fixture.sock", BotPeerDelegation.capabilityEnvironmentKey: "fixture-capability", "COMPOSIO_API_KEY": "must-not-be-forwarded"]
        let cli = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ClaudeRunner.botPeerMCPConfigJSON(environment: env, command: "/fixture/service").utf8)) as? [String: Any])
        let claude = try XCTUnwrap((cli["mcpServers"] as? [String: Any])?[ConnectionMCPCatalog.serverName] as? [String: Any])
        let sdk = try XCTUnwrap(ClaudeAgentSDKBridgeAdapter.botPeerMCPServers(environment: env, command: "/fixture/service")[ConnectionMCPCatalog.serverName] as? [String: Any])
        let cliEnvironment = try XCTUnwrap(claude["env"] as? [String: String])
        XCTAssertEqual(cliEnvironment[BotPeerDelegation.capabilityEnvironmentKey], "${" + BotPeerDelegation.capabilityEnvironmentKey + "}")
        XCTAssertEqual((sdk["env"] as? [String: String])?[BotPeerDelegation.capabilityEnvironmentKey], "fixture-capability")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: claude), as: UTF8.self).contains("fixture-capability"))
        XCTAssertNil((claude["env"] as? [String: String])?["COMPOSIO_API_KEY"])
        for list in [GrokACPClient.sessionMCPServers(command: "/fixture/service", environment: env), DistillACPClient.sessionMCPServers(command: "/fixture/service", environment: env)] {
            let facade = try XCTUnwrap(list.compactMap { $0 as? [String: Any] }.first { $0["name"] as? String == ConnectionMCPCatalog.serverName })
            XCTAssertEqual(facade["args"] as? [String], [ConnectionMCPCatalog.cliArgument])
            let encoded = try JSONSerialization.data(withJSONObject: facade)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("must-not-be-forwarded"))
        }
        let codex = CodexRunner.botCatalogMCPOverrides(command: "/fixture/service", environment: env)
        let appServer = CodexRunner.appServerArguments(command: "/fixture/service", environment: env)
        XCTAssertTrue(codex.contains { $0.contains("mcp_servers.\(ConnectionMCPCatalog.serverName).command=") })
        XCTAssertTrue(appServer.contains { $0.contains("mcp_servers.\(ConnectionMCPCatalog.serverName).command=") })
        XCTAssertFalse((codex + appServer).joined().contains("must-not-be-forwarded"))
        for arguments in [codex, appServer] {
            let connectionArguments = arguments.filter { $0.hasPrefix("mcp_servers.\(ConnectionMCPCatalog.serverName).") }
            XCTAssertFalse(connectionArguments.joined().contains("fixture-capability"))
            XCTAssertTrue(connectionArguments.contains { $0.contains(".env_vars=") && $0.contains(BotPeerDelegation.capabilityEnvironmentKey) })
            XCTAssertFalse(connectionArguments.contains { $0.contains(".env.") })
        }
        let guest = DistillGuestConfig.render(hostConfig: "", gatewayPort: 12345, hostEnvironment: [:])
        XCTAssertTrue(guest.toml.contains("[mcp_servers.\(ConnectionMCPCatalog.serverName)]"))
        XCTAssertTrue(guest.toml.contains("bearer_token_env_var"))
        XCTAssertFalse(guest.toml.contains("fixture-capability"))
    }
}

extension ConnectionsMCPAdmissionTests {
    func testEntireEffectiveCLIArgumentsContainNoCapabilityValuesAndProxyOverlayIsIdempotent() throws {
        let bearer = "whole-argv-private-capability-sentinel"
        let env = [
            BotSelfConfigCatalog.callerEnvironmentKey: UUID().uuidString,
            BotPeerDelegation.threadEnvironmentKey: UUID().uuidString,
            BotPeerDelegation.runEnvironmentKey: UUID().uuidString,
            BotPeerDelegation.socketEnvironmentKey: "/tmp/fixture.sock",
            BotPeerDelegation.capabilityEnvironmentKey: bearer,
            "COMPOSIO_API_KEY": "whole-argv-global-key-sentinel",
        ]
        for resume in [nil, "fixture-session"] as [String?] {
            let claude = AgentRunRequest(threadId: AgentThreadID(), provider: .claude, model: "fixture", cwd: "/tmp", prompt: "Owned fixture", providerThreadId: resume, environment: env)
            let codex = AgentRunRequest(threadId: AgentThreadID(), provider: .codex, model: "fixture", cwd: "/tmp", prompt: "Owned fixture", providerThreadId: resume, environment: env)
            for argv in [ClaudeRunner.buildArgs(claude), ClaudeRunner.buildStreamingArgs(claude), CodexRunner.buildArgs(codex), CodexRunner.appServerArguments(environment: env)] {
                XCTAssertFalse(argv.joined(separator: " ").contains(bearer), "the entire argv must be safe, including legacy bot-self-config")
                XCTAssertFalse(argv.joined(separator: " ").contains("whole-argv-global-key-sentinel"))
            }
        }
        for raw in [["exec", "resume", "fixture-session", "continue"], ["app-server", "--stdio"]] {
            let once = AgentSkillInstaller.providerProxyArguments(provider: .codex, arguments: raw, environment: env)
            let twice = AgentSkillInstaller.providerProxyArguments(provider: .codex, arguments: once, environment: env)
            XCTAssertEqual(once, twice, "env_vars must count as an already-scoped managed overlay")
            XCTAssertFalse(once.joined().contains(bearer))
        }
        let sdk = ClaudeAgentSDKBridgeAdapter.botPeerMCPServers(environment: env)
        for name in [BotSelfConfigMCPAdmit.serverName, ConnectionMCPCatalog.serverName] {
            let config = try XCTUnwrap(sdk[name] as? [String: Any])
            XCTAssertEqual((config["env"] as? [String: String])?[BotPeerDelegation.capabilityEnvironmentKey], bearer, "private SDK input must keep exact fresh per-turn authority")
        }
    }
}
