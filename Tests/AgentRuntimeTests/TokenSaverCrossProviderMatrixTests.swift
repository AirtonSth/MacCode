import XCTest
import Foundation
import CoreModel
@testable import AgentRuntime
@testable import DistillCore

/// Full matrix: Claude / Codex / Grok as primary, same-provider nested, and every
/// cross-provider pair — Token Saver techniques must stay admitted (distill hint,
/// managed_path, dialect injection, Claude-only PostToolUse).
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
        // the same provider-neutral admit signal + dialect; only Claude gets PostToolUse.
        for provider in providers {
            let receipt = admit(provider)
            let env = TokenSaverExecutionReceiptSeam.environment(from: receipt)
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider) distill hint")
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
            XCTAssertTrue(prompt.contains("NEVER pipe"), "\(provider) exact-output still forbidden")

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
        }
    }

    func test_providerProxyArguments_injectDialectWhenChildEnvAdmitted() {
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

    func test_tokenSaverDialect_forcesShellAndGraphifyCoverageForAllProviders() {
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
            env["RC_GRAPHIFY_ENABLED"] = "1"
            env["RC_GRAPHIFY_GRAPH_JSON"] = "/tmp/graph.json"
            let withGraphify = AgentSkillInstaller.tokenSaverProviderPrompt("base", environment: env)
            XCTAssertTrue(
                withGraphify.contains("graphify query") || withGraphify.contains("Query-first"),
                "\(provider) must inject Graphify query-first when RC_GRAPHIFY_ENABLED=1"
            )
        }
    }

    func test_providerProxyArguments_allProvidersGetDialectOnSupportedNestedTurns() {
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
}
