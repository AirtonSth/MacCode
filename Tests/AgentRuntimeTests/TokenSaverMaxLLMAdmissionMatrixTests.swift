import XCTest
import Foundation
import CoreModel
@testable import AgentRuntime
@testable import DistillCore

/// Claude / Codex / Grok primary + nested Distill admission, and Token Saver-off inert.
final class TokenSaverMaxLLMAdmissionMatrixTests: XCTestCase {
    private let threadID = "10000000-0000-0000-0000-000000000041"
    private let workspaceID = "20000000-0000-0000-0000-000000000042"
    private let projectID = "30000000-0000-0000-0000-000000000043"
    private let rootRunID = "40000000-0000-0000-0000-000000000044"
    private let attemptID = "50000000-0000-0000-0000-000000000045"

    private let providers: [AgentProvider] = [.claude, .codex, .grok]

    private func admit(
        _ provider: AgentProvider,
        tokenSaverEnabled: Bool = true,
        sidecarAvailable: Bool = true,
        graphifyActive: Bool = true
    ) -> TokenSaverExecutionReceipt {
        TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: tokenSaverEnabled,
            sameUser: true,
            sidecarAvailable: sidecarAvailable,
            provider: provider,
            threadId: threadID,
            rootRunId: rootRunID,
            attemptId: attemptID,
            workspaceId: workspaceID,
            projectId: projectID,
            waveLive: "wave-a",
            graphifyActive: graphifyActive
        )
    }

    func test_tokenSaverOffStaysInert() async {
        // WHY: Token Saver is paid. Off must scrub Distill hint, wrap compression,
        // dialect / SR1 humanize, and Graphify runtime so a leftover symlink or
        // inherited env cannot compress provider turns for free.
        for provider in providers {
            let denied = admit(provider, tokenSaverEnabled: false, graphifyActive: true)
            let env = TokenSaverExecutionReceiptSeam.environment(from: denied)
            XCTAssertEqual(env, [:], "\(provider) denied receipts emit no capability env")
            XCTAssertNil(env["RC_TOKEN_SAVER_DISTILL_HINT"])
            XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"])
            XCTAssertEqual(denied.capabilities.distill, false)
            XCTAssertEqual(denied.capabilities.graphify, false)
            XCTAssertNotEqual(denied.capabilities.postToolUse, true)

            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("base", environment: [:])
            XCTAssertEqual(prompt, "base")
            XCTAssertFalse(prompt.contains("| distill"))
            XCTAssertFalse(prompt.contains("SR1"))
            XCTAssertFalse(prompt.contains("humanize"))
            XCTAssertFalse(prompt.contains("TOKEN_SAVER_SAFETY_ABI_V1"))
            XCTAssertFalse(prompt.contains("REMOTE_CODE_WIRE_V1"))
            XCTAssertFalse(prompt.contains("graphify query"))
            XCTAssertFalse(prompt.contains("Query-first"))

            XCTAssertEqual(
                ShellDistillPipeAdmission.decide(
                    admitted: env["RC_TOKEN_SAVER_DISTILL_HINT"] == "1",
                    toolName: "Bash",
                    command: "swift test",
                    distillExecutable: "/opt/rc-bin/distill",
                    distillExists: true
                ),
                .skipNotAdmitted,
                "\(provider) must not auto-pipe | distill when Token Saver is off"
            )
        }

        let raw = Data("verbose wrap-eligible build output that must stay original\n".utf8)
        let calls = WrapCallCounter()
        let cli = ManagedDistillCLI(
            arguments: ["summarize the command output"],
            stdin: raw,
            state: ManagedDistillCLI.State(baseURL: "http://127.0.0.1:9", authToken: "t"),
            distillAdmission: { false }
        ) { _ in
            await calls.increment()
            return nil
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw, "wrap compression must fail open when Token Saver is off")
        let transportCalls = await calls.count()
        XCTAssertEqual(transportCalls, 0)
    }

    func test_admittedShapesShareDistillHintPostToolUseClaudeOnly() {
        // WHY: Distill hint is provider-neutral (primary, same-provider nested,
        // every cross-provider pair). PostToolUse rewrite is Claude-only because
        // Codex/Grok cannot replace tool output. Exact-output remains forbidden.
        for provider in providers {
            let receipt = admit(provider)
            let env = TokenSaverExecutionReceiptSeam.environment(from: receipt)
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider) primary")
            XCTAssertEqual(receipt.capabilities.distill, true, "\(provider) distill")
            XCTAssertEqual(receipt.capabilities.managedPath, true, "\(provider) managed_path")

            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("user work", environment: env)
            XCTAssertTrue(prompt.contains("| distill"), "\(provider) dialect")
            XCTAssertTrue(
                prompt.contains("NEVER auto-distill raw exact-output"),
                "\(provider) exact-output still forbidden"
            )
            XCTAssertFalse(prompt.contains("R0 micro"))

            if provider == .claude {
                XCTAssertEqual(receipt.capabilities.postToolUse, true)
                XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
            } else {
                XCTAssertNil(receipt.capabilities.postToolUse)
                XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"])
            }

            var parentEnv = env
            parentEnv["REMOTE_CODE_AGENT_PROVIDER"] = provider.rawValue
            let nested = TokenSaverExecutionReceiptSeam.propagate(into: parentEnv, provider: provider)
            XCTAssertEqual(nested["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider) nested propagate")
            XCTAssertEqual(nested["RC_TOKEN_SAVER_ROOT_RUN_ID"], rootRunID)
            let nestedPrompt = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: nested)
            XCTAssertTrue(nestedPrompt.contains("| distill"), "\(provider) nested dialect")
            XCTAssertTrue(nestedPrompt.contains("NEVER auto-distill raw exact-output"))
            if provider == .claude {
                XCTAssertEqual(nested["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
            } else {
                XCTAssertNil(nested["RC_TOKEN_SAVER_POST_TOOL_USE"])
            }
        }

        for parent in providers {
            for child in providers {
                let retargeted = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                    receipt: admit(parent),
                    sidecarAvailable: true,
                    provider: child,
                    waveLive: "wave-a"
                )
                XCTAssertEqual(retargeted.provider, child.rawValue, "\(parent)→\(child)")
                XCTAssertEqual(retargeted.capabilities.distill, true, "\(parent)→\(child) distill")
                let env = TokenSaverExecutionReceiptSeam.environment(from: retargeted)
                XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(parent)→\(child) hint")
                let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("nested work", environment: env)
                XCTAssertTrue(prompt.contains("| distill"), "\(parent)→\(child) dialect")
                XCTAssertTrue(
                    prompt.contains("NEVER auto-distill raw exact-output"),
                    "\(parent)→\(child) exact-output still forbidden"
                )
                if child == .claude {
                    XCTAssertEqual(retargeted.capabilities.postToolUse, true, "\(parent)→\(child) PTU")
                    XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
                } else {
                    XCTAssertNil(retargeted.capabilities.postToolUse, "\(parent)→\(child) no PTU")
                    XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"])
                }
            }
        }
    }
}

private actor WrapCallCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func count() -> Int {
        value
    }
}
