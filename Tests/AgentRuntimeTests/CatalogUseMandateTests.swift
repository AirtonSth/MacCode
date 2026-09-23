import XCTest
@testable import AgentRuntime
import CoreModel

/// Admission is not enough: the 01-catalogo.html librarian only gets used when
/// each paid provider receives the by-default mandate in the prompt it actually
/// runs with, and never while Token Saver is off.
final class CatalogUseMandateTests: XCTestCase {
    private let byDefaultWording = "BY DEFAULT whenever listed, without the user asking"
    private let catalogToolNames = [
        "rc_stats", "rc_search", "rc_catalog", "rc_ask",
        "rc_extract", "rc_digest", "rc_pick", "rc_retrieve", "rc_compress"
    ]

    private func admittedEnvironment() -> [String: String] {
        [
            DistillMCPAdmit.tokenSaverHintEnvironmentKey: "1",
            "RC_TOKEN_SAVER_WORKSPACE_ID": "ws-catalog",
            "RC_TOKEN_SAVER_PROJECT_ID": "proj-catalog",
            "RC_TOKEN_SAVER_THREAD_ID": "thread-catalog",
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
            "RC_TOKEN_SAVER_ATTEMPT_ID": "attempt-catalog",
        ]
    }

    private func request(_ provider: AgentProvider, environment: [String: String]) -> AgentRunRequest {
        AgentRunRequest(
            threadId: AgentThreadID(),
            provider: provider,
            model: provider == .grok ? "grok-4.5" : "gpt-5.5",
            cwd: "/tmp/catalog-mandate",
            prompt: "read the failing test output",
            environment: environment
        )
    }

    private func assertMandate(_ prompt: String, provider: String) {
        XCTAssertTrue(prompt.contains(byDefaultWording),
                      "\(provider) must be told to use the catalog tools by default, without the user asking")
        for tool in catalogToolNames {
            XCTAssertTrue(prompt.contains(tool),
                          "\(provider) mandate must name the \(tool) catalog tool surface")
        }
    }

    func test_catalogMandateReachesEveryProviderPromptWithoutUserRequest() throws {
        let environment = admittedEnvironment()

        // Claude Code CLI, streaming route: `--append-system-prompt`.
        let claudeArgs = ClaudeRunner.buildStreamingArgs(request(.claude, environment: environment))
        let appendIndex = try XCTUnwrap(claudeArgs.firstIndex(of: "--append-system-prompt"))
        assertMandate(claudeArgs[claudeArgs.index(after: appendIndex)], provider: "Claude CLI")

        // Claude Code SDK bridge engine: the `system_prompt` payload field.
        assertMandate(
            ClaudeAgentSDKBridgeAdapter.claudeSystemPrompt(environment: environment),
            provider: "Claude SDK bridge"
        )

        // Codex: `developerInstructions` on the app-server thread start.
        let params = CodexAppServerClient.threadStartParams(
            for: request(.codex, environment: environment)
        )
        let codexInstructions = try XCTUnwrap(params["developerInstructions"] as? String)
        assertMandate(codexInstructions, provider: "Codex developerInstructions")

        // Grok Build: the ACP session/prompt text.
        let blocks = try GrokACPClient.promptBlocks(
            for: request(.grok, environment: environment),
            capabilities: .init(protocolVersion: 1, loadSession: true, embeddedContext: true)
        )
        let grokPrompt = try XCTUnwrap(blocks.first?["text"] as? String)
        assertMandate(grokPrompt, provider: "Grok ACP prompt")
    }

    func test_noCatalogMandateOrLibrarianServerWhenTokenSaverIsOff() throws {
        let environment: [String: String] = [:]

        let claudeArgs = ClaudeRunner.buildStreamingArgs(request(.claude, environment: environment))
        let appendIndex = try XCTUnwrap(claudeArgs.firstIndex(of: "--append-system-prompt"))
        let claudePrompt = claudeArgs[claudeArgs.index(after: appendIndex)]
        XCTAssertFalse(claudePrompt.contains("Distill MCP catalog tools"),
                       "Token Saver off must not deliver the catalog mandate to Claude")
        XCTAssertFalse(GrokACPClient.sessionMCPServers(
            existing: [],
            command: "/tmp/RemoteCodeDistillService",
            environment: environment
        ).contains { ($0 as? [String: Any])?["name"] as? String == DistillMCPAdmit.serverName },
                       "Token Saver off must not admit the librarian into Grok sessions")
        XCTAssertTrue(CodexRunner.distillMCPOverrides(
            command: "/tmp/RemoteCodeDistillService",
            environment: environment
        ).isEmpty,
                      "Token Saver off must not admit the librarian into Codex argv")

        let params = CodexAppServerClient.threadStartParams(
            for: request(.codex, environment: environment)
        )
        let codexInstructions = try XCTUnwrap(params["developerInstructions"] as? String)
        XCTAssertFalse(codexInstructions.contains("Distill MCP catalog tools"),
                       "Token Saver off must not deliver the catalog mandate to Codex")

        let blocks = try GrokACPClient.promptBlocks(
            for: request(.grok, environment: environment),
            capabilities: .init(protocolVersion: 1, loadSession: true, embeddedContext: true)
        )
        let grokPrompt = try XCTUnwrap(blocks.first?["text"] as? String)
        XCTAssertFalse(grokPrompt.contains("Distill MCP catalog tools"),
                       "Token Saver off must not deliver the catalog mandate to Grok")
    }
}
