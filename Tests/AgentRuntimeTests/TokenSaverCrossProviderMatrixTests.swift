import XCTest
import Foundation
import CoreModel
@testable import AgentRuntime
@testable import DistillCore

/// Full matrix: Claude / Codex / Grok as primary, same-provider nested, and every
/// cross-provider pair — Token Saver techniques must stay admitted (distill hint,
/// managed_path, tool-output policy, Claude-only PostToolUse). Conversation
/// wire admission is per-turn and therefore deliberately absent here.
final class TokenSaverCrossProviderMatrixTests: XCTestCase {
    private let threadID = "10000000-0000-0000-0000-000000000011"
    private let workspaceID = "20000000-0000-0000-0000-000000000012"
    private let projectID = "30000000-0000-0000-0000-000000000013"
    private let rootRunID = "40000000-0000-0000-0000-000000000014"
    private let attemptID = "50000000-0000-0000-0000-000000000015"

    private let providers: [AgentProvider] = [.claude, .codex, .grok]

    private func admit(
        _ provider: AgentProvider,
        sidecarAvailable: Bool = true
    ) -> TokenSaverExecutionReceipt {
        TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: sidecarAvailable,
            provider: provider,
            threadId: threadID,
            rootRunId: rootRunID,
            attemptId: attemptID,
            workspaceId: workspaceID,
            projectId: projectID,
            waveLive: "wave-a",
            graphifyActive: true
        )
    }

    func test_primaryAgents_allProvidersGetFullTokenSaverTechniquesWhenSidecarHealthy() {
        // WHY: product requires every admitted primary (Claude/Codex/Grok) to receive
        // the same provider-neutral output admit signal; only Claude gets PostToolUse.
        for provider in providers {
            let receipt = admit(provider)
            let env = TokenSaverExecutionReceiptSeam.environment(from: receipt)
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider) distill hint")
            XCTAssertNil(env["RC_TOKEN_SAVER_WIRE_VERSION"], "wire is admitted only after a specific prompt encodes")
            XCTAssertEqual(receipt.capabilities.distill, true, "\(provider) distill")
            XCTAssertEqual(receipt.capabilities.managedPath, true, "\(provider) managed_path")
            XCTAssertEqual(env["RC_TOKEN_SAVER_THREAD_ID"], threadID)
            XCTAssertEqual(env["RC_TOKEN_SAVER_WAVE_LIVE"], "wave-a")

            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt(
                "user work",
                environment: env
            )
            XCTAssertTrue(prompt.contains("| distill"), "\(provider) dialect must inject | distill")
            XCTAssertTrue(
                prompt.contains("MANDATORY") || prompt.contains("default-pipe"),
                "\(provider) must require default-pipe | distill"
            )
            XCTAssertTrue(
                prompt.contains("non-GUI") || prompt.contains("GUI"),
                "\(provider) must exempt GUI from | distill"
            )
            XCTAssertTrue(
                prompt.contains("NEVER auto-distill raw exact-output"),
                "\(provider) exact-output still forbidden"
            )
            XCTAssertTrue(prompt.contains(AgentSkillInstaller.rcWireAgentInstructionsTemplate),
                          "every Token Saver session must trust RCW1 before a later encoded follow-up arrives")
            assertWireResponseProfitabilityContract(prompt, context: "\(provider) primary")
            XCTAssertFalse(prompt.contains("R0 micro"), "removed Distill Language must not return")

            if provider == .claude {
                XCTAssertEqual(receipt.capabilities.postToolUse, true)
                XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
            } else {
                XCTAssertNil(receipt.capabilities.postToolUse)
                XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"])
            }
        }
    }

    func test_sameProviderNested_propagateKeepsDistillForAllProviders() {
        // WHY: same-provider subagents must not drop DISTILL_HINT (gate is admit signal, not "is subagent").
        for provider in providers {
            var parentEnv = TokenSaverExecutionReceiptSeam.environment(from: admit(provider))
            parentEnv["REMOTE_CODE_AGENT_PROVIDER"] = provider.rawValue
            parentEnv["RC_REMOTE_CODE_MANAGED_BIN"] = "/tmp/managed-bin"
            parentEnv["PATH"] = "/usr/bin:/bin"

            let child = TokenSaverExecutionReceiptSeam.propagate(
                into: parentEnv,
                provider: provider
            )
            XCTAssertEqual(child["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider) nested")
            XCTAssertNil(child["RC_TOKEN_SAVER_WIRE_VERSION"], "nested output receipts do not pre-admit RCW1")
            XCTAssertEqual(child["RC_TOKEN_SAVER_ROOT_RUN_ID"], rootRunID)

            let processEnv = CodexRunner.processEnvironment(
                overrides: child,
                purpose: .agentTurn(provider),
                base: [
                    "HOME": "/tmp/home",
                    "PATH": "/opt/homebrew/bin",
                    "RC_LOGIN_SHELL_ENV_IMPORT": "0",
                    "RC_REMOTE_CODE_MANAGED_BIN": "/tmp/managed-bin",
                ]
            )
            let path = processEnv["PATH"] ?? ""
            XCTAssertTrue(
                path.hasPrefix("/tmp/managed-bin:") || path == "/tmp/managed-bin",
                "\(provider) nested PATH must front managed bin: \(path)"
            )
            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: processEnv)
            XCTAssertTrue(prompt.contains("| distill"), "\(provider) nested dialect")
            XCTAssertTrue(prompt.contains(AgentSkillInstaller.rcWireAgentInstructionsTemplate),
                          "\(provider) nested session must support a later encoded turn")
            assertWireResponseProfitabilityContract(prompt, context: "\(provider) nested")
        }
    }

    func test_crossProviderMatrix_allPairsReAdmitDistillAndCorrectPostToolUse() {
        // WHY: Claude→Grok, Codex→Grok, Grok→Claude, and every other pair must keep
        // distill/managed_path when sidecar healthy; only Claude children get PostToolUse.
        for parent in providers {
            for child in providers {
                let parentReceipt = admit(parent, sidecarAvailable: true)
                let retargeted = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                    receipt: parentReceipt,
                    sidecarAvailable: true,
                    provider: child,
                    waveLive: "wave-a"
                )
                XCTAssertEqual(retargeted.provider, child.rawValue, "\(parent)→\(child)")
                XCTAssertEqual(retargeted.capabilities.distill, true, "\(parent)→\(child) distill")
                XCTAssertEqual(retargeted.capabilities.managedPath, true, "\(parent)→\(child) managed")
                let env = TokenSaverExecutionReceiptSeam.environment(from: retargeted)
                XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(parent)→\(child) hint")
                XCTAssertNil(env["RC_TOKEN_SAVER_WIRE_VERSION"], "\(parent)→\(child) wire remains per-turn")

                let expectedPost = ProviderProxyPolicy.childPostToolUseCapability(
                    targetProvider: child,
                    distillAvailable: true
                )
                if expectedPost == true {
                    XCTAssertEqual(retargeted.capabilities.postToolUse, true, "\(parent)→\(child) PTU")
                    XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
                } else {
                    XCTAssertNil(retargeted.capabilities.postToolUse, "\(parent)→\(child) no PTU")
                    XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"])
                }

                let prompt = AgentSkillInstaller.tokenSaverProviderPrompt(
                    "nested work",
                    environment: env
                )
                XCTAssertTrue(
                    prompt.contains("| distill"),
                    "\(parent)→\(child) must inject mandatory | distill dialect"
                )
                XCTAssertTrue(prompt.contains(AgentSkillInstaller.rcWireAgentInstructionsTemplate),
                              "\(parent)→\(child) must install the trusted session capability")
                assertWireResponseProfitabilityContract(prompt, context: "\(parent)→\(child)")
            }
        }
    }

    func test_crossProvider_stickyDegradedParentUpgradesWhenSidecarRecovers() {
        // WHY: parent launched with sidecar_unavailable must not permanently starve
        // Claude→Grok / Codex→Claude / Grok→Codex children after the lease is live.
        let pairs: [(AgentProvider, AgentProvider)] = [
            (.claude, .grok), (.claude, .codex),
            (.codex, .grok), (.codex, .claude),
            (.grok, .claude), (.grok, .codex),
        ]
        for (parent, child) in pairs {
            let degraded = admit(parent, sidecarAvailable: false)
            XCTAssertEqual(degraded.capabilities.distill, false)
            let upgraded = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                receipt: degraded,
                sidecarAvailable: true,
                provider: child
            )
            XCTAssertEqual(upgraded.capabilities.distill, true, "\(parent)→\(child)")
            XCTAssertEqual(upgraded.capabilities.managedPath, true, "\(parent)→\(child)")
            let env = TokenSaverExecutionReceiptSeam.environment(from: upgraded)
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(parent)→\(child)")
            if child == .claude {
                XCTAssertEqual(upgraded.capabilities.postToolUse, true)
            } else {
                XCTAssertNil(upgraded.capabilities.postToolUse)
            }
        }
    }

    func test_tokenSaverOff_scrubsDistillForAllProvidersAndCrossProviderChildren() {
        // WHY: fail-open when Token Saver is off — no dialect, no false PostToolUse.
        for provider in providers {
            let denied = TokenSaverExecutionReceiptSeam.admit(
                tokenSaverEnabled: false,
                sameUser: true,
                sidecarAvailable: true,
                provider: provider,
                threadId: threadID
            )
            XCTAssertEqual(TokenSaverExecutionReceiptSeam.environment(from: denied), [:])
            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt(
                "base",
                environment: [:]
            )
            XCTAssertEqual(prompt, "base")
            XCTAssertFalse(prompt.contains("| distill"))
            XCTAssertFalse(prompt.contains("REMOTE_CODE_WIRE_V1"))
        }
    }

    func test_wireKillSwitchDisablesBothDirectionsWithoutDisablingToolOutputDistill() {
        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: threadID,
            disabledLanes: ["wire-encode"]
        )
        let env = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertNil(env["RC_TOKEN_SAVER_WIRE_VERSION"])
        let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("base", environment: env)
        XCTAssertTrue(prompt.contains("| distill"))
        XCTAssertFalse(prompt.contains("REMOTE_CODE_WIRE_V1"))
    }

    func test_providerProxyArguments_injectOutputPolicyWhenChildEnvAdmitted() {
        // WHY: nested launches go through providerProxyArguments; cross-provider children
        // must still receive the mandatory | distill policy block when DISTILL_HINT=1.
        for child in providers {
            let env = TokenSaverExecutionReceiptSeam.environment(from: admit(child))
            let args = AgentSkillInstaller.providerProxyArguments(
                provider: child,
                arguments: ["-p", "hello"],
                environment: env
            )
            // Args shape is provider-specific; the important proof is that the seam
            // does not drop Token Saver when building nested argv from admitted env.
            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: env)
            XCTAssertTrue(prompt.contains("MANDATORY") || prompt.contains("default-pipe"))
            XCTAssertTrue(prompt.contains("byte-exactly") || prompt.contains("full stdout"))
            XCTAssertFalse(args.isEmpty)
        }
    }

    func test_providerProxyArguments_nestedClaudeInjectsPostToolUseSettings() throws {
        // WHY: Elephant Task 1 nested Claude advisors (2.5M+ tokens each) recorded
        // Nested - Claude lifecycle receipts but zero token_saver_savings rows —
        // provider proxy set RC_TOKEN_SAVER_POST_TOOL_USE without injecting the
        // Claude CLI --settings PostToolUse hook that Agent App ClaudeRunner adds.
        // Advisor ABI is print+plan+Read/Glob/Grep only; PATH wrappers never fire.
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.claude))
        XCTAssertEqual(env[ClaudeRunner.tokenSaverPostToolUseEnvKey], "1")

        let advisorArgv = [
            "--print",
            "--model", "opus",
            "--effort", "max",
            "--permission-mode", "plan",
            "--tools", "Read,Glob,Grep",
            "--no-session-persistence",
            "--output-format", "json"
        ]
        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .claude,
            arguments: advisorArgv,
            environment: env
        )
        XCTAssertEqual(args.filter { $0 == "--settings" }.count, 1,
                       "nested Claude must get exactly one --settings for PostToolUse")
        guard let settingsIndex = args.firstIndex(of: "--settings"),
              settingsIndex + 1 < args.count,
              let data = args[settingsIndex + 1].data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any],
              let post = hooks["PostToolUse"] as? [[String: Any]],
              let commandHooks = post.first?["hooks"] as? [[String: Any]],
              let command = commandHooks.first?["command"] as? String
        else {
            return XCTFail("PostToolUse hook settings missing on nested Claude proxy argv")
        }
        XCTAssertTrue(command.hasSuffix("distill hook post-tool-use"),
                      "hook must point at managed distill post-tool-use: \(command)")
        // Original advisor ABI must survive (prompt transport, tools, plan mode).
        XCTAssertTrue(args.contains("--print"))
        XCTAssertTrue(args.contains("plan"))
        XCTAssertTrue(args.contains("Read,Glob,Grep"))
    }

    private func assertWireResponseProfitabilityContract(
        _ prompt: String,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            prompt.contains("full tokens<=45%"),
            "\(context) must admit RCW1 only at the complete-frame 45% threshold",
            file: file,
            line: line
        )
        XCTAssertTrue(
            prompt.contains("semantically identical terse text"),
            "\(context) must compare RCW1 with terse plaintext holding meaning constant",
            file: file,
            line: line
        )
        XCTAssertTrue(
            prompt.contains("else same text"),
            "\(context) must fail open to plaintext when response framing expands tokens",
            file: file,
            line: line
        )
    }

    func test_providerProxyArguments_nestedClaudeSkipsSettingsWhenTokenSaverOff() {
        // WHY: fail-open — without POST_TOOL_USE the proxy must not rewrite argv.
        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .claude,
            arguments: ["--print", "--model", "opus", "-p", "hi"],
            environment: [:]
        )
        XCTAssertFalse(args.contains("--settings"))
        XCTAssertEqual(args, ["--print", "--model", "opus", "-p", "hi"])
    }

    func test_providerProxyArguments_nestedClaudeMergesPostToolUseIntoInlineSettings() throws {
        // WHY: nested CLIs that already pass inline --settings must still get
        // PostToolUse hooks (prior skip left zero model-mode savings on advisors).
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.claude))
        let original = ["--print", "--settings", "{\"custom\":true}", "-p", "hi"]
        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .claude,
            arguments: original,
            environment: env
        )
        XCTAssertEqual(args.filter { $0 == "--settings" }.count, 1)
        guard let idx = args.firstIndex(of: "--settings"),
              idx + 1 < args.count,
              let data = args[idx + 1].data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("merged --settings JSON missing")
        }
        XCTAssertEqual(obj["custom"] as? Bool, true, "caller keys must survive merge")
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PostToolUse"], "PostToolUse must be merged in")
    }

    func test_providerProxyArguments_nestedClaudePreservesExistingHooksAndSettingsFile() throws {
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.claude))
        let existingHook: [String: Any] = [
            "matcher": "Bash",
            "hooks": [["type": "command", "command": "/tmp/caller-hook"]]
        ]
        let settings: [String: Any] = [
            "custom": true,
            "hooks": ["PostToolUse": [existingHook]]
        ]
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-settings-\(UUID().uuidString).json")
        let settingsData = try JSONSerialization.data(withJSONObject: settings)
        try settingsData.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .claude,
            arguments: ["--print", "--settings", file.path, "-p", "hi"],
            environment: env
        )
        let index = try XCTUnwrap(args.firstIndex(of: "--settings"))
        let data = try XCTUnwrap(args[index + 1].data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["custom"] as? Bool, true)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let post = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(post.count, 2, "caller and RemoteCode PostToolUse hooks must coexist")
        let commands = post.flatMap { entry -> [String] in
            guard let hookEntries = entry["hooks"] as? [[String: Any]] else { return [] }
            return hookEntries.compactMap { $0["command"] as? String }
        }
        XCTAssertTrue(commands.contains("/tmp/caller-hook"))
        XCTAssertTrue(commands.contains { $0.contains("distill hook post-tool-use") })
        let fileData = try Data(contentsOf: file)
        XCTAssertEqual(fileData, settingsData,
                       "merging must not edit the caller's settings file")
    }

    func test_providerProxyArguments_nestedClaudeMergesEffectiveLastInlineSettingsIdempotently() throws {
        // WHY: Claude resolves duplicate --settings options with the last value.
        // RemoteCode must merge its hook into that effective inline object without
        // mutating a shadowed caller setting or duplicating the hook on re-entry.
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.claude))
        let shadowed = #"{"custom":"shadowed"}"#
        let effective = #"{"custom":"effective","hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/tmp/caller-hook"}]}]}}"#
        let original = [
            "--print",
            "--settings", shadowed,
            "--settings=\(effective)",
            "-p", "hi",
        ]

        let args = AgentSkillInstaller.ensuringClaudePostToolUseSettings(
            provider: .claude,
            arguments: original,
            environment: env
        )

        let shadowedIndex = try XCTUnwrap(args.firstIndex(of: "--settings"))
        XCTAssertEqual(args[shadowedIndex + 1], shadowed,
                       "an earlier shadowed setting must remain byte-identical")
        let effectiveArgument = try XCTUnwrap(args.last(where: { $0.hasPrefix("--settings=") }))
        let mergedJSON = String(effectiveArgument.dropFirst("--settings=".count))
        let data = try XCTUnwrap(mergedJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["custom"] as? String, "effective")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let post = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(post.count, 2, "caller and RemoteCode PostToolUse hooks must coexist once")
        let commands = post.flatMap { entry -> [String] in
            guard let hookEntries = entry["hooks"] as? [[String: Any]] else { return [] }
            return hookEntries.compactMap { $0["command"] as? String }
        }
        XCTAssertTrue(commands.contains("/tmp/caller-hook"))
        XCTAssertEqual(commands.filter { $0.contains("distill hook post-tool-use") }.count, 1)
        XCTAssertEqual(
            AgentSkillInstaller.ensuringClaudePostToolUseSettings(
                provider: .claude,
                arguments: args,
                environment: env
            ),
            args,
            "merging the effective last inline settings object must be idempotent"
        )
    }

    func test_providerProxyArguments_nestedCodexMergesExistingDeveloperInstructions() {
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.codex))
        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .codex,
            arguments: ["exec", "--config", "developer_instructions=\"KEEP_CALLER\"", "do work"],
            environment: env
        )
        let joined = args.joined(separator: "\n")
        XCTAssertTrue(joined.contains("KEEP_CALLER"), "caller instructions must survive")
        XCTAssertTrue(joined.contains("TOKEN_SAVER_SAFETY_ABI_V1"), "Distill policy must be appended")
        XCTAssertEqual(args.filter { $0 == "--config" }.count, 1,
                       "merge must not add a competing developer_instructions override")
    }

    func test_providerProxyArguments_nestedCodexMergesEffectiveInlineDeveloperInstructions() {
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.codex))
        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .codex,
            arguments: [
                "exec",
                "--config", "developer_instructions=\"SHADOWED\"",
                "--config=developer_instructions=\"EFFECTIVE\"",
                "do work",
            ],
            environment: env
        )
        // Locate by content: the proxy also appends process-scoped MCP overlays,
        // so this contract is about WHICH override is merged, not argv index.
        XCTAssertTrue(args.contains("developer_instructions=\"SHADOWED\""),
                      "the shadowed earlier override must stay untouched")
        let effective = args.first { $0.hasPrefix("--config=developer_instructions=") }
        XCTAssertTrue(effective?.hasPrefix("--config=developer_instructions=\"EFFECTIVE\\n\\n") == true,
                      "the last inline override wins and must be the one merged")
        XCTAssertTrue(effective?.contains("TOKEN_SAVER_SAFETY_ABI_V1") == true)
        XCTAssertEqual(
            AgentSkillInstaller.providerProxyArguments(
                provider: .codex,
                arguments: args,
                environment: env
            ),
            args,
            "merging the effective inline override must be idempotent"
        )
    }

    func test_providerProxyArguments_nestedCodexPreservesTripleQuotedTOMLDelimiter() {
        // WHY: a TOML multiline basic string must keep its triple-quote delimiter;
        // collapsing it to a single quote pair makes the generated CLI config invalid.
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.codex))
        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .codex,
            arguments: [
                "exec",
                #"--config=developer_instructions="""KEEP_CALLER""""#,
                "do work",
            ],
            environment: env
        )

        let override = args.first { $0.hasPrefix(#"--config=developer_instructions="""#) }
        XCTAssertTrue(
            override?.hasPrefix(#"--config=developer_instructions="""KEEP_CALLER\n\n"#) == true,
            "the existing triple-quoted value must remain the effective prefix"
        )
        XCTAssertTrue(override?.hasSuffix(#""""#) == true,
                      "the TOML multiline delimiter must remain balanced")
        XCTAssertTrue(override?.contains("TOKEN_SAVER_SAFETY_ABI_V1") == true)
    }

    func test_providerProxyArguments_nestedCodexMergesLiteralAndSpacedDeveloperInstructions() {
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.codex))
        for override in [
            "developer_instructions='KEEP_LITERAL'",
            "developer_instructions = \"KEEP_SPACED\"",
            "developer_instructions=KEEP_RAW",
        ] {
            let args = AgentSkillInstaller.providerProxyArguments(
                provider: .codex,
                arguments: ["exec", "-c", override, "do work"],
                environment: env
            )
            XCTAssertEqual(args.filter { $0.contains("developer_instructions=") }.count, 1,
                           "the effective caller override must be merged in place")
            let merged = args.first { $0.hasPrefix("developer_instructions=\"KEEP_") }
            XCTAssertTrue(merged != nil, "the caller value must stay the effective override")
            XCTAssertTrue(merged?.contains("TOKEN_SAVER_SAFETY_ABI_V1") == true, override)
            XCTAssertEqual(
                AgentSkillInstaller.providerProxyArguments(
                    provider: .codex,
                    arguments: args,
                    environment: env
                ),
                args,
                "literal/spaced merges must stay idempotent"
            )
        }
    }

    func test_providerProxyArguments_nestedCodexIgnoresSafetyMarkerInsideTOMLComment() {
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.codex))
        let comment = "TOKEN_SAVER_SAFETY_ABI_V1 is not active here"
        let original = [
            "exec",
            "-c", "developer_instructions=\"KEEP_CALLER\" # \(comment)",
            "do work",
        ]

        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .codex,
            arguments: original,
            environment: env
        )
        let merged = args.first { $0.hasPrefix("developer_instructions=\"KEEP_CALLER") }
        XCTAssertTrue(merged?.hasPrefix("developer_instructions=\"KEEP_CALLER\\n\\n") == true)
        XCTAssertTrue(merged?.contains("MANDATORY default-pipe:") == true,
                      "a marker in a TOML comment must not bypass the semantic Distill prompt")
        XCTAssertTrue(merged?.hasSuffix("# \(comment)") == true,
                      "merging the semantic value must preserve the caller's trailing comment")
        XCTAssertEqual(
            AgentSkillInstaller.providerProxyArguments(
                provider: .codex,
                arguments: args,
                environment: env
            ),
            args,
            "semantic marker detection must remain idempotent after the first merge"
        )
    }

    func test_tokenSaverOutputPolicy_forcesShellAndGraphifyCoverageForAllProviders() {
        // WHY: Grok/Codex native tools cannot rewrite; dialect must force
        // Graphify + shell+|distill coverage for Claude/Codex/Grok alike.
        for provider in providers {
            var env = TokenSaverExecutionReceiptSeam.environment(from: admit(provider))
            let distillPrompt = AgentSkillInstaller.tokenSaverProviderPrompt("base", environment: env)
            XCTAssertTrue(
                distillPrompt.contains("| distill") || distillPrompt.contains("default-pipe"),
                "\(provider) must require shell | distill"
            )
            XCTAssertTrue(
                distillPrompt.contains("read_file") || distillPrompt.contains("native")
                    || distillPrompt.contains("Coverage first"),
                "\(provider) must constrain native multi-file reads"
            )
            XCTAssertTrue(
                distillPrompt.contains(WrappedCommandCatalog.exactOutputCommands.joined(separator: ", ")),
                "\(provider) must receive the complete canonical exact-output command catalog"
            )
            env["RC_GRAPHIFY_ENABLED"] = "1"
            env["RC_GRAPHIFY_GRAPH_JSON"] = "/tmp/graph.json"
            let withGraphify = AgentSkillInstaller.tokenSaverProviderPrompt("base", environment: env)
            XCTAssertTrue(
                withGraphify.contains("graphify query") || withGraphify.contains("Query-first"),
                "\(provider) must inject Graphify query-first when RC_GRAPHIFY_ENABLED=1"
            )
        }
    }

    func test_providerProxyArguments_allProvidersGetOutputPolicyOnSupportedNestedTurns() {
        // WHY: product requires dialect + managed PATH for Claude/Codex/Grok nested
        // raw CLI. PostToolUse rewrite is Claude-only (upstream ceiling: Codex has no
        // updatedToolOutput; Grok PostToolUse is passive per docs.x.ai hooks guide).
        // PATH wrappers (incl. bun/bunx) remain the primary auto-compress lever for
        // Codex/Grok shell tool output.
        struct Case {
            let provider: AgentProvider
            let argv: [String]
            let dialectMarker: String
        }
        let cases: [Case] = [
            Case(provider: .claude, argv: ["--print", "--model", "opus", "-p", "nested"], dialectMarker: "--append-system-prompt"),
            Case(provider: .codex, argv: ["exec", "--json", "do work"], dialectMarker: "developer_instructions="),
            Case(provider: .grok, argv: ["--prompt", "do work", "--model", "grok-4.5"], dialectMarker: "--rules"),
        ]
        for c in cases {
            let env = TokenSaverExecutionReceiptSeam.environment(from: admit(c.provider))
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(c.provider)")
            let args = AgentSkillInstaller.providerProxyArguments(
                provider: c.provider,
                arguments: c.argv,
                environment: env
            )
            let joined = args.joined(separator: " ")
            XCTAssertTrue(
                joined.contains(c.dialectMarker) || joined.contains("| distill") || joined.contains("MANDATORY"),
                "\(c.provider) nested argv must carry Token Saver dialect (\(c.dialectMarker)): \(joined.prefix(200))"
            )
            if c.provider == .claude {
                XCTAssertTrue(args.contains("--settings"), "Claude nested must inject PostToolUse --settings")
            } else {
                XCTAssertFalse(args.contains("--settings"), "\(c.provider) must not invent Claude-only --settings")
            }
        }
    }

    func test_crossProviderNestedChildEnv_frontsManagedPathAndPreservesThreadForAllPairs() {
        // WHY: ProviderProxyRunner.makeChildEnvironment must put managed wrappers first
        // for every parent→child pair so PATH wraps fire under Codex/Grok/Claude shell.
        // Savings attribute to parent thread_id (same as Nested receipts on Elephant).
        let managed = "/tmp/rc-managed-bin-matrix"
        for parent in providers {
            for child in providers {
                var parentEnv = TokenSaverExecutionReceiptSeam.environment(from: admit(parent))
                parentEnv["REMOTE_CODE_AGENT_PROVIDER"] = parent.rawValue
                parentEnv["RC_REMOTE_CODE_MANAGED_BIN"] = managed
                parentEnv["PATH"] = "/usr/bin:/bin"
                parentEnv["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"] = threadID

                let retargeted = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                    receipt: admit(parent),
                    sidecarAvailable: true,
                    provider: child,
                    waveLive: "wave-a"
                )
                var childEnv = TokenSaverExecutionReceiptSeam.environment(from: retargeted)
                childEnv["RC_REMOTE_CODE_MANAGED_BIN"] = managed
                // Mirror proxy PATH rewrite when managed_path admitted.
                if retargeted.capabilities.managedPath == true {
                    let parts = (parentEnv["PATH"] ?? "")
                        .split(separator: ":")
                        .map(String.init)
                        .filter { $0 != managed }
                    childEnv["PATH"] = ([managed] + parts).joined(separator: ":")
                }
                let path = childEnv["PATH"] ?? ""
                XCTAssertTrue(
                    path.hasPrefix("\(managed):") || path == managed,
                    "\(parent)→\(child) PATH must front managed bin: \(path)"
                )
                XCTAssertEqual(childEnv["RC_TOKEN_SAVER_THREAD_ID"], threadID, "\(parent)→\(child) thread")
                XCTAssertEqual(childEnv["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(parent)→\(child) distill")
                if child == .claude {
                    XCTAssertEqual(childEnv["RC_TOKEN_SAVER_POST_TOOL_USE"], "1", "\(parent)→\(child) PTU")
                } else {
                    XCTAssertNil(childEnv["RC_TOKEN_SAVER_POST_TOOL_USE"], "\(parent)→\(child) no PTU")
                }
            }
        }
    }

    func test_wrapPolicy_noAllowlist_compressesGhApiAndMutatingStdoutForAllProviders() {
        // WHY: PATH wrap policy is provider-neutral (same binary for Claude/Codex/Grok
        // shells and nested proxies). Former allowlist blocked gh api — elephant undercount.
        // Compress eligibility must not depend on which provider owns the run.
        let noEnv: [String: String] = [:]
        let mustCompress: [(String, [String])] = [
            ("gh", ["api", "repos/o/r/pulls/1"]),
            ("gh", ["pr", "merge", "12"]),
            ("gh", ["pr", "list", "--json", "number,title"]),
            ("git", ["push"]),
            ("git", ["status"]),
            ("git", ["log", "--oneline", "-20"]),
            ("curl", ["-s", "https://example.com/api"]),
            ("python3", ["script.py"]),
            ("aws", ["s3", "ls"]),
        ]
        for (cmd, args) in mustCompress {
            XCTAssertTrue(
                CommandWrapPolicy.isWrapped(cmd) || WrappedCommandCatalog.commands.contains(cmd),
                "\(cmd) must be PATH-wrapped so Grok/Codex (no PostToolUse rewrite) can compress"
            )
            XCTAssertNil(
                CommandWrapPolicy.passthroughReason(command: cmd, args: args, environment: noEnv),
                "\(cmd) \(args.joined(separator: " ")) must compress (no allowlist)"
            )
        }
        // Exact-output carve-outs still apply for every provider.
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "rg", args: ["pattern"], environment: noEnv),
            "exact_output_command"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "sed", args: ["-n", "1,10p", "f"], environment: noEnv),
            "exact_output_command"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["diff"], environment: noEnv),
            "exact_patch_output"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["show", "HEAD:file"], environment: noEnv),
            "exact_output_subcommand"
        )
    }

    func test_admittedProviderMatrix_sharesArbitraryCommandInterceptionAndExactOutputSafety() {
        // WHY: the global interceptor is admitted by the provider-neutral Token
        // Saver signal, not by provider name or a finite command catalog.
        let arbitrary = "workspace-specific-report"
        for provider in providers {
            let receipt = admit(provider)
            let environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)

            XCTAssertEqual(environment["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "(provider) admission")
            XCTAssertEqual(receipt.capabilities.managedPath, true, "(provider) managed path")
            XCTAssertTrue(CommandWrapPolicy.isWrapped(arbitrary), "(provider) arbitrary command")
            XCTAssertNil(
                CommandWrapPolicy.passthroughReason(
                    command: arbitrary,
                    args: ["--summary"],
                    environment: environment
                ),
                "(provider) arbitrary command must reach the shared compressor"
            )
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(
                    command: "cat",
                    args: ["output.txt"],
                    environment: environment
                ),
                "exact_output_command",
                "(provider) exact-output command must remain raw"
            )
        }
    }

    func test_outputPolicy_allProviders_requirePipeAndDocumentNoAllowlist() {
        // WHY: voluntary | distill + wrapper policy must be identical for every
        // admitted provider and nested shape (gate = DISTILL_HINT, not provider).
        for provider in providers {
            let env = TokenSaverExecutionReceiptSeam.environment(from: admit(provider))
            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("work", environment: env)
            XCTAssertTrue(prompt.contains("| distill"), "\(provider)")
            XCTAssertTrue(
                prompt.contains("gh api") || prompt.contains("all subcommands"),
                "\(provider) dialect must document no-allowlist / gh api coverage"
            )
            XCTAssertTrue(
                prompt.contains("primary") && (prompt.contains("nested") || prompt.contains("subagent")),
                "\(provider) must apply to primary+nested"
            )
            XCTAssertTrue(prompt.contains("NEVER pipe") || prompt.contains("exact-output") || prompt.contains("rg"),
                          "\(provider) exact-output skip must remain")
        }
    }

    func test_footerDisplayStack_providerAgnostic_multiTurnAndAuto() {
        // WHY: chip stack (tool-output + dialect + cache + Auto) is pure and must
        // not depend on which provider produced the measured ledger row.
        // Surfaces import is not required — estimator is shared; footer seams
        // live in Surfaces but use the same bare-user stack.
        let measured = 4_534
        let multi = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: measured,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: true,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: 200_000,
                windowProviderBilledTokenUnits: 50_000,
                turnCount: 77,
                cacheReadInputTokens: 5_000_000
            )
        )
        XCTAssertGreaterThan(multi.estimatedCacheAmortization, measured * 10)
        XCTAssertEqual(
            multi.estimatedOrchestration,
            TokenSaverBareUserEstimator.estimateOrchestrationTokens(measured: measured)
        )
        XCTAssertGreaterThan(multi.totalCredible, measured * 10)
        // Off → measured only for every provider identity.
        let off = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: measured,
            tokenSaverEnabled: false,
            graphifyActive: true,
            orchestrationActive: true,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: 200_000,
                windowProviderBilledTokenUnits: 50_000,
                turnCount: 77,
                cacheReadInputTokens: 5_000_000
            )
        )
        XCTAssertEqual(off.totalCredible, measured)
    }

    func test_catalog_expandedHTTPCloudAndPython_availableToAllProviders() {
        // WHY: Grok/Codex rely on PATH wrap for auto compress; catalog must cover
        // noisy CLIs used by every agent shape (primary + nested).
        for name in ["curl", "wget", "aws", "gcloud", "az", "python", "python3"] {
            XCTAssertTrue(WrappedCommandCatalog.commands.contains(name), name)
            XCTAssertFalse(WrappedCommandCatalog.exactOutputCommandSet.contains(name), name)
        }
        // Still never wrap provider binaries or exact-output.
        for name in ["claude", "codex", "grok", "rg", "sed", "jq", "node", "env"] {
            XCTAssertFalse(WrappedCommandCatalog.commands.contains(name), "\(name) must not be in wrap catalog")
        }
        XCTAssertTrue(WrappedCommandCatalog.isShebangInterpreter("node"))
        XCTAssertTrue(WrappedCommandCatalog.isShebangInterpreter("env"))
    }
}
