import XCTest
import Foundation
import CoreModel
@testable import AgentRuntime

final class TokenSaverExecutionReceiptTests: XCTestCase {
    private let threadID = "10000000-0000-0000-0000-000000000001"
    private let workspaceID = "20000000-0000-0000-0000-000000000002"
    private let projectID = "30000000-0000-0000-0000-000000000003"
    private let rootRunID = "40000000-0000-0000-0000-000000000004"
    private let attemptID = "50000000-0000-0000-0000-000000000005"

    private func receipt(
        provider: AgentProvider = .codex,
        sidecarAvailable: Bool = true,
        graphifyActive: Bool = true
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
            disabledLanes: ["semantic_prose"],
            enabledLanes: ["deterministic_wrapper"],
            waveLive: "wave-a,wave-b",
            graphifyActive: graphifyActive
        )
    }

    func test_jsonRoundTripIsCompactScopedAndScrubbable() throws {
        // WHY: the receipt crosses process boundaries, so it must survive JSON
        // transport without carrying provider content or changing unrelated env.
        let original = receipt()
        let json = try XCTUnwrap(original.encodedJSONString())
        XCTAssertLessThan(json.utf8.count, TokenSaverExecutionReceiptSeam.maximumEncodedBytes)
        XCTAssertEqual(TokenSaverExecutionReceipt.decode(json: json), original)
        XCTAssertFalse(json.contains("prompt"))
        XCTAssertFalse(json.contains("transcript"))
        XCTAssertFalse(json.contains("raw_output"))

        let scrubbed = TokenSaverExecutionReceiptSeam.scrub([
            TokenSaverExecutionReceipt.envKey: json,
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            "RC_DISTILL_FUTURE": "1",
            "REMOTE_CODE_DISTILL_STATE_PATH": "/tmp/state",
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
            "UNCHANGED": "yes",
        ])
        XCTAssertNil(scrubbed[TokenSaverExecutionReceipt.envKey])
        XCTAssertNil(scrubbed["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertNil(scrubbed["RC_DISTILL_FUTURE"])
        XCTAssertNil(scrubbed["REMOTE_CODE_DISTILL_STATE_PATH"])
        XCTAssertEqual(scrubbed["REMOTE_CODE_AGENT_PROVIDER"], "codex")
        XCTAssertEqual(scrubbed["UNCHANGED"], "yes")
    }

    func test_offAndCrossUserRemainRaw() {
        // WHY: no nested worker may resurrect paid capabilities after any
        // root-level admission gate rejects the run.
        let cases: [(TokenSaverExecutionReceipt, TokenSaverExecutionReceipt.DenialReason)] = [
            (
                TokenSaverExecutionReceiptSeam.admit(
                    tokenSaverEnabled: false,
                    sameUser: true,
                    sidecarAvailable: true,
                    provider: .codex,
                    threadId: threadID
                ),
                .tokenSaverOff
            ),
            (
                TokenSaverExecutionReceiptSeam.admit(
                    tokenSaverEnabled: true,
                    sameUser: false,
                    sidecarAvailable: true,
                    provider: .claude,
                    threadId: threadID
                ),
                .crossUser
            ),
        ]

        for (denied, reason) in cases {
            XCTAssertFalse(denied.admitted)
            XCTAssertEqual(denied.denialReason, reason)
            XCTAssertEqual(denied.capabilities.distill, false)
            XCTAssertEqual(
                TokenSaverExecutionReceiptSeam.environment(from: denied),
                [:],
                "denied receipts are decisions, not child-process capability env"
            )
        }
    }

    func test_sidecarFailureKeepsProviderInputRawButRetainsIndependentScope() {
        // WHY: a dead local compressor must never block or rewrite a provider
        // turn; independent Graphify/recovery identity may remain eligible.
        let degraded = receipt(provider: .claude, sidecarAvailable: false)
        let environment = TokenSaverExecutionReceiptSeam.environment(from: degraded)

        XCTAssertTrue(degraded.admitted)
        XCTAssertEqual(degraded.denialReason, .sidecarUnavailable)
        XCTAssertEqual(degraded.capabilities.distill, false)
        XCTAssertEqual(degraded.capabilities.managedPath, false)
        XCTAssertEqual(degraded.capabilities.postToolUse, false)
        XCTAssertEqual(degraded.capabilities.graphify, true)
        XCTAssertEqual(degraded.capabilities.recoveryScope, true)
        XCTAssertNil(environment["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertNil(environment["RC_TOKEN_SAVER_POST_TOOL_USE"])
        XCTAssertNil(environment["RC_TOKEN_SAVER_WAVE_LIVE"])
        XCTAssertEqual(environment["RC_TOKEN_SAVER_WORKSPACE_ID"], workspaceID)
        XCTAssertNotNil(environment[TokenSaverExecutionReceipt.envKey])
    }

    func test_providerSpecificCapabilitiesKeepUnsupportedValuesUnknown() {
        // WHY: provider-neutral propagation must not claim a Claude-only hook
        // exists on Codex, Grok, or a future provider without explicit support.
        let codex = receipt(provider: .codex)
        let claude = receipt(provider: .claude)
        let grok = receipt(provider: .grok)

        for supported in [codex, claude, grok] {
            XCTAssertEqual(supported.capabilities.distill, true)
            XCTAssertEqual(supported.capabilities.managedPath, true)
            XCTAssertEqual(supported.capabilities.graphify, true)
        }
        XCTAssertNil(codex.capabilities.postToolUse)
        XCTAssertEqual(claude.capabilities.postToolUse, true)
        XCTAssertNil(grok.capabilities.postToolUse)
    }

    func test_nestedPropagationRebuildsOnlyReceiptAuthorizedKeys() throws {
        // WHY: nested workers inherit the root decision, while stale discrete
        // flags cannot widen it and unrelated provider auth stays untouched.
        var rootEnvironment = TokenSaverExecutionReceiptSeam.environment(from: receipt())
        rootEnvironment["RC_TOKEN_SAVER_DISABLED_LANES"] = "stale_lane"
        rootEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"] = "stale-attempt"
        rootEnvironment["RC_TOKEN_SAVER_POST_TOOL_USE"] = "1"
        rootEnvironment["CODEX_API_KEY"] = "provider-secret-stays-outside-receipt"
        rootEnvironment["REMOTE_CODE_AGENT_PROVIDER"] = "codex"

        let child = TokenSaverExecutionReceiptSeam.propagate(
            into: rootEnvironment,
            provider: .codex
        )
        XCTAssertEqual(child["RC_TOKEN_SAVER_DISABLED_LANES"], "semantic_prose")
        XCTAssertEqual(child["RC_TOKEN_SAVER_ROOT_RUN_ID"], rootRunID)
        XCTAssertEqual(child["RC_TOKEN_SAVER_ATTEMPT_ID"], attemptID)
        XCTAssertNil(child["RC_TOKEN_SAVER_POST_TOOL_USE"])
        XCTAssertEqual(child["CODEX_API_KEY"], "provider-secret-stays-outside-receipt")
        XCTAssertEqual(
            TokenSaverExecutionReceiptSeam.propagate(into: child, provider: .codex),
            child,
            "propagation must be idempotent across more than one nested generation"
        )

        let json = try XCTUnwrap(child[TokenSaverExecutionReceipt.envKey])
        XCTAssertFalse(json.contains("provider-secret-stays-outside-receipt"))
    }

    func test_recoveryStampKeepsRootIdentityAndRotatesAttemptIdentity() throws {
        // WHY: crash recovery must attribute work to the durable run while giving
        // the replacement process a distinct attempt for retry diagnostics.
        let recoveryAttempt = "60000000-0000-0000-0000-000000000006"
        let initialEnvironment = TokenSaverExecutionReceiptSeam.environment(from: receipt())
        let recovered = TokenSaverExecutionReceiptSeam.stampIdentity(
            environment: initialEnvironment,
            rootRunId: rootRunID,
            attemptId: recoveryAttempt,
            provider: .codex
        )
        let recoveredReceipt = try XCTUnwrap(
            TokenSaverExecutionReceiptSeam.receipt(from: recovered)
        )

        XCTAssertEqual(recoveredReceipt.rootRunId, rootRunID)
        XCTAssertEqual(recovered["RC_TOKEN_SAVER_ROOT_RUN_ID"], rootRunID)
        XCTAssertEqual(recoveredReceipt.attemptId, recoveryAttempt)
        XCTAssertEqual(recovered["RC_TOKEN_SAVER_ATTEMPT_ID"], recoveryAttempt)
        XCTAssertEqual(recoveredReceipt.threadId, threadID)
    }

    func testPropagationWithoutReceiptScrubsLegacyTokenSaverFlags() {
        // WHY: a provider launch without a valid host receipt must run raw and
        // must not inherit stale local optimization controls.
        let raw = TokenSaverExecutionReceiptSeam.propagate(
            into: [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "RC_TOKEN_SAVER_ROOT_RUN_ID": rootRunID,
                "RC_GRAPHIFY_STATE_PATH": "/tmp/graphify",
                "PROVIDER_AUTH": "preserved"
            ],
            provider: .codex
        )
        XCTAssertNil(raw["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertNil(raw["RC_TOKEN_SAVER_ROOT_RUN_ID"])
        XCTAssertNil(raw["RC_GRAPHIFY_STATE_PATH"])
        XCTAssertEqual(raw["PROVIDER_AUTH"], "preserved")
    }

    func test_centralProcessEnvironmentPropagatesAgentTurnsAndScrubsOtherProcesses() throws {
        // WHY: every real provider adapter uses this seam; support processes and
        // inherited GUI state must not accidentally become Token Saver-enabled.
        let claudeReceipt = receipt(provider: .claude)
        var overrides = TokenSaverExecutionReceiptSeam.environment(from: claudeReceipt)
        overrides["REMOTE_CODE_DISTILL_STATE_PATH"] = "/tmp/distill-state"
        let base = [
            "HOME": "/tmp/home",
            "PATH": "/usr/bin",
            "RC_LOGIN_SHELL_ENV_IMPORT": "0",
            "RC_TOKEN_SAVER_DISTILL_HINT": "stale",
        ]

        let agent = CodexRunner.processEnvironment(
            overrides: overrides,
            purpose: .agentTurn(.claude),
            base: base
        )
        XCTAssertEqual(agent["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(agent["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
        XCTAssertEqual(agent["REMOTE_CODE_DISTILL_STATE_PATH"], "/tmp/distill-state")
        XCTAssertEqual(agent["REMOTE_CODE_AGENT_PROVIDER"], "claude")

        let rawAgent = CodexRunner.processEnvironment(
            overrides: [:],
            purpose: .agentTurn(.grok),
            base: base
        )
        XCTAssertNil(rawAgent["RC_TOKEN_SAVER_DISTILL_HINT"])

        let support = CodexRunner.processEnvironment(
            overrides: overrides,
            purpose: .supportProcess,
            base: base
        )
        XCTAssertNil(support[TokenSaverExecutionReceipt.envKey])
        XCTAssertNil(support["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertNil(support["REMOTE_CODE_DISTILL_STATE_PATH"])
    }

    func test_secretOrContentShapedReceiptIsRejectedAndScrubbed() throws {
        // WHY: an environment receipt is metadata, never a second channel for
        // prompts, transcripts, tokens, raw tool output, or provider secrets.
        let unsafe = TokenSaverExecutionReceipt(
            threadId: threadID,
            provider: "codex",
            admitted: true,
            sameUser: true,
            capabilities: .init(distill: true),
            workspaceId: workspaceID,
            waveLive: "secret"
        )
        XCTAssertNil(unsafe.encodedJSONString())

        let validJSON = try XCTUnwrap(receipt().encodedJSONString())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(validJSON.utf8)) as? [String: Any]
        )
        object["prompt"] = "do not transport me"
        let injected = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        XCTAssertNil(TokenSaverExecutionReceipt.decode(json: injected))

        let scrubbed = TokenSaverExecutionReceiptSeam.propagate(
            into: [
                TokenSaverExecutionReceipt.envKey: injected,
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "UNCHANGED": "yes",
            ],
            provider: .codex
        )
        XCTAssertNil(scrubbed[TokenSaverExecutionReceipt.envKey])
        XCTAssertNil(scrubbed["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertEqual(scrubbed["UNCHANGED"], "yes")
    }

    func test_laneKillSwitchWinsAndReceiptDoesNotDuplicateLossyPolicy() throws {
        // WHY: an incident disable must survive nesting, while Skills and
        // exact-output losslessness remain governed by their existing seams.
        let admitted = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: threadID,
            disabledLanes: ["deterministic_wrapper"],
            enabledLanes: ["deterministic_wrapper", "semantic_prose"]
        )
        XCTAssertEqual(admitted.disabledLanes, ["deterministic_wrapper"])
        XCTAssertEqual(admitted.enabledLanes, ["semantic_prose"])

        let json = try XCTUnwrap(admitted.encodedJSONString())
        XCTAssertFalse(json.contains("skills"))
        XCTAssertFalse(json.contains("exact_output"))
        XCTAssertFalse(json.contains("lossy"))
    }
}
