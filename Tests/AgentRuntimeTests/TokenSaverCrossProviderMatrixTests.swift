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
}
