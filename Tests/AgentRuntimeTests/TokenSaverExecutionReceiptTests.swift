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

    func test_reAdmitSidecarIfAvailable_upgradesStickyDegradedReceiptForAllProviders() {
        // WHY: a parent that launched while the sidecar was still starting must not
        // permanently starve primary retries or nested Codex/Claude/Grok children of
        // distill + managed_path after the lease becomes healthy.
        for provider in [AgentProvider.claude, .codex, .grok] {
            let degraded = receipt(provider: provider, sidecarAvailable: false)
            let upgraded = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                receipt: degraded,
                sidecarAvailable: true,
                provider: provider,
                waveLive: "wave-a"
            )
            XCTAssertEqual(upgraded.denialReason, .none, "\(provider)")
            XCTAssertEqual(upgraded.capabilities.distill, true, "\(provider)")
            XCTAssertEqual(upgraded.capabilities.managedPath, true, "\(provider)")
            XCTAssertEqual(upgraded.threadId, threadID)
            XCTAssertEqual(upgraded.rootRunId, rootRunID)
            XCTAssertEqual(upgraded.attemptId, attemptID)
            let env = TokenSaverExecutionReceiptSeam.environment(from: upgraded)
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider)")
            XCTAssertEqual(env["RC_TOKEN_SAVER_WAVE_LIVE"], "wave-a", "\(provider)")
            if provider == .claude {
                XCTAssertEqual(upgraded.capabilities.postToolUse, true)
                XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
            } else {
                XCTAssertNil(upgraded.capabilities.postToolUse)
                XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"])
            }
        }
    }

    func test_reAdmitSidecarIfAvailable_retargetsCrossProviderAndRestoresClaudePostToolUse() {
        // WHY: Grok/Codex parent degraded → Claude child after sidecar recovery must
        // get PostToolUse; Claude parent → Grok child must drop it (no false claim).
        let degradedGrok = receipt(provider: .grok, sidecarAvailable: false)
        let toClaude = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
            receipt: degradedGrok,
            sidecarAvailable: true,
            provider: .claude
        )
        XCTAssertEqual(toClaude.provider, "claude")
        XCTAssertEqual(toClaude.capabilities.distill, true)
        XCTAssertEqual(toClaude.capabilities.postToolUse, true)

        let healthyClaude = receipt(provider: .claude, sidecarAvailable: true)
        let toGrok = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
            receipt: healthyClaude,
            sidecarAvailable: true,
            provider: .grok
        )
        XCTAssertEqual(toGrok.provider, "grok")
        XCTAssertEqual(toGrok.capabilities.distill, true)
        XCTAssertNil(toGrok.capabilities.postToolUse)
    }

    func test_reAdmitSidecarIfAvailable_doesNotInventAdmissionWhenStillUnavailable() {
        // WHY: fail-open while the compressor is dead — no DISTILL_HINT resurrection.
        let degraded = receipt(provider: .codex, sidecarAvailable: false)
        let still = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
            receipt: degraded,
            sidecarAvailable: false,
            provider: .codex
        )
        XCTAssertEqual(still.denialReason, .sidecarUnavailable)
        XCTAssertEqual(still.capabilities.distill, false)
        XCTAssertNil(TokenSaverExecutionReceiptSeam.environment(from: still)["RC_TOKEN_SAVER_DISTILL_HINT"])
    }

    func test_allProvidersEmitDistillHintWhenSidecarAvailable() {
        // WHY: provider-neutral admit signal must not be Claude-only.
        for provider in [AgentProvider.claude, .codex, .grok] {
            let admitted = receipt(provider: provider, sidecarAvailable: true)
            let env = TokenSaverExecutionReceiptSeam.environment(from: admitted)
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider)")
            XCTAssertEqual(admitted.capabilities.managedPath, true, "\(provider)")
            XCTAssertEqual(admitted.capabilities.distill, true, "\(provider)")
        }
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
        let appSupport = "/tmp/rc-token-saver-support"
        let statePath = "\(appSupport)/Distill/DistillCLIState.json"
        overrides["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = appSupport
        overrides["REMOTE_CODE_DISTILL_STATE_PATH"] = statePath
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
        XCTAssertEqual(agent["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"], appSupport)
        XCTAssertEqual(agent["REMOTE_CODE_DISTILL_STATE_PATH"], statePath)
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

        var mismatchedOverrides = overrides
        mismatchedOverrides["REMOTE_CODE_DISTILL_STATE_PATH"] = "/tmp/other/Distill/DistillCLIState.json"
        let mismatched = CodexRunner.processEnvironment(
            overrides: mismatchedOverrides,
            purpose: .agentTurn(.claude),
            base: base
        )
        XCTAssertNil(mismatched["REMOTE_CODE_DISTILL_STATE_PATH"],
                     "receipt propagation must not preserve a state lease outside its app-support namespace")
    }

    func test_processEnvironment_reassertsManagedBinOnPathForAllProviders() throws {
        // WHY: login-shell PATH merge must not bury ~/.remote-code/bin; wrappers and
        // nested provider proxies depend on managed bin winning PATH lookup.
        let managedBin = "/tmp/rc-managed-bin-for-test"
        for provider in [AgentProvider.claude, .codex, .grok] {
            var overrides = TokenSaverExecutionReceiptSeam.environment(
                from: receipt(provider: provider, sidecarAvailable: true)
            )
            overrides["RC_REMOTE_CODE_MANAGED_BIN"] = managedBin
            overrides["PATH"] = "/usr/bin:/bin"
            let env = CodexRunner.processEnvironment(
                overrides: overrides,
                purpose: .agentTurn(provider),
                base: [
                    "HOME": "/tmp/home",
                    "PATH": "/opt/homebrew/bin",
                    "RC_LOGIN_SHELL_ENV_IMPORT": "0",
                ]
            )
            let path = try XCTUnwrap(env["PATH"])
            XCTAssertTrue(path.hasPrefix(managedBin + ":") || path == managedBin, "\(provider): \(path)")
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider)")
        }
    }

    func test_nestedCrossProviderEnvironmentKeepsDistillWhenParentAdmitted() throws {
        // WHY: same-provider and cross-provider nested shapes share the provider-neutral
        // admit signal — never gate on "is subagent".
        let parent = receipt(provider: .codex, sidecarAvailable: true)
        var parentEnv = TokenSaverExecutionReceiptSeam.environment(from: parent)
        parentEnv["REMOTE_CODE_AGENT_PROVIDER"] = "codex"
        parentEnv["RC_REMOTE_CODE_MANAGED_BIN"] = "/tmp/managed"

        // Same-provider nested: propagate rebuilds discrete keys from receipt.
        let same = TokenSaverExecutionReceiptSeam.propagate(into: parentEnv, provider: .codex)
        XCTAssertEqual(same["RC_TOKEN_SAVER_DISTILL_HINT"], "1")

        // Cross-provider: re-admit to Grok keeps distill; no false PostToolUse.
        let toGrok = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
            receipt: parent,
            sidecarAvailable: true,
            provider: .grok
        )
        let grokEnv = TokenSaverExecutionReceiptSeam.environment(from: toGrok)
        XCTAssertEqual(grokEnv["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertNil(grokEnv["RC_TOKEN_SAVER_POST_TOOL_USE"])

        // Cross-provider to Claude restores PostToolUse when sidecar healthy.
        let toClaude = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
            receipt: parent,
            sidecarAvailable: true,
            provider: .claude
        )
        let claudeEnv = TokenSaverExecutionReceiptSeam.environment(from: toClaude)
        XCTAssertEqual(claudeEnv["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(claudeEnv["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
    }

    func test_toolShellHandshakeSurvivesOnlyAdmittedCodexPropagation() throws {
        // WHY: Codex rebuilds its tool-shell environment from the receipt. The
        // host gate must survive that boundary without leaking to other
        // providers or bypassing the lane kill switch.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptPropagationArtifact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("source/RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("runtime-artifact".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let runtime = try XCTUnwrap(installer.runtimeInstaller(for: source))
        let runtimeRoot = runtime.managedCLIBinURL.deletingLastPathComponent().standardizedFileURL
        let binary = runtimeRoot.appendingPathComponent("RemoteCodeDistillService")
        var codexEnvironment = TokenSaverExecutionReceiptSeam.environment(from: receipt())
        codexEnvironment[AgentSkillInstaller.runtimeRootEnvironmentKey] = runtimeRoot.path
        codexEnvironment["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"] = "1"
        codexEnvironment[AgentSkillInstaller.toolShellProtocolEnvironmentKey] =
            AgentSkillInstaller.toolShellProtocolVersion
        codexEnvironment[AgentSkillInstaller.toolShellBinaryEnvironmentKey] = binary.path
        let propagated = TokenSaverExecutionReceiptSeam.propagate(
            into: codexEnvironment,
            provider: .codex
        )
        XCTAssertEqual(propagated["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"], "1")
        XCTAssertEqual(
            propagated[AgentSkillInstaller.toolShellProtocolEnvironmentKey],
            AgentSkillInstaller.toolShellProtocolVersion
        )
        XCTAssertEqual(
            propagated[AgentSkillInstaller.toolShellBinaryEnvironmentKey],
            binary.path
        )

        var staleEnvironment = codexEnvironment
        staleEnvironment[AgentSkillInstaller.toolShellBinaryEnvironmentKey] =
            binary.deletingLastPathComponent()
                .appendingPathComponent("missing-service").path
        let stale = TokenSaverExecutionReceiptSeam.propagate(
            into: staleEnvironment,
            provider: .codex
        )
        XCTAssertNil(stale["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"])
        XCTAssertNil(stale[AgentSkillInstaller.toolShellBinaryEnvironmentKey])

        let disabledReceipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: threadID,
            rootRunId: rootRunID,
            attemptId: attemptID,
            workspaceId: workspaceID,
            projectId: projectID,
            disabledLanes: ["tool_shell"]
        )
        var disabledEnvironment = TokenSaverExecutionReceiptSeam.environment(from: disabledReceipt)
        disabledEnvironment["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"] = "1"
        disabledEnvironment[AgentSkillInstaller.toolShellProtocolEnvironmentKey] =
            AgentSkillInstaller.toolShellProtocolVersion
        disabledEnvironment[AgentSkillInstaller.toolShellBinaryEnvironmentKey] = binary.path
        XCTAssertNil(
            TokenSaverExecutionReceiptSeam.propagate(
                into: disabledEnvironment,
                provider: .codex
            )["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"]
        )

        XCTAssertNil(
            TokenSaverExecutionReceiptSeam.propagate(
                into: codexEnvironment,
                provider: .claude
            )["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"]
        )
    }

    func test_stampIdentityPreservesArtifactScopedToolShellHandshakeOnlyForCoherentRoot() throws {
        // WHY: recovery/restamp crosses a scrub boundary. The absolute Codex
        // tool-shell capability must survive only when the host-selected
        // runtime artifact and its content-addressed root still agree.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptRuntimeArtifact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("source/RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("runtime-artifact".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        let installer = AgentSkillInstaller(homeDirectory: home)
        let runtime = try XCTUnwrap(installer.runtimeInstaller(for: source))
        let runtimeRoot = runtime.managedCLIBinURL.deletingLastPathComponent().standardizedFileURL
        let artifact = runtimeRoot.appendingPathComponent("RemoteCodeDistillService")
        var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt())
        environment["RC_REMOTE_CODE_MANAGED_BIN"] = runtime.managedCLIBinURL.path
        environment[AgentSkillInstaller.runtimeRootEnvironmentKey] = runtimeRoot.path
        environment["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"] = "1"
        environment[AgentSkillInstaller.toolShellProtocolEnvironmentKey] =
            AgentSkillInstaller.toolShellProtocolVersion
        environment[AgentSkillInstaller.toolShellBinaryEnvironmentKey] = artifact.path

        let stamped = TokenSaverExecutionReceiptSeam.stampIdentity(
            environment: environment,
            rootRunId: rootRunID,
            attemptId: "60000000-0000-0000-0000-000000000006",
            provider: .codex
        )
        XCTAssertEqual(stamped["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"], "1")
        XCTAssertEqual(
            stamped[AgentSkillInstaller.toolShellProtocolEnvironmentKey],
            AgentSkillInstaller.toolShellProtocolVersion
        )
        XCTAssertEqual(stamped[AgentSkillInstaller.toolShellBinaryEnvironmentKey], artifact.path)
        XCTAssertEqual(stamped[AgentSkillInstaller.runtimeRootEnvironmentKey], runtimeRoot.path)

        let digest = try XCTUnwrap(AgentSkillInstaller.serviceBinaryIdentity(at: artifact))
        let siblingRoot = home
            .appendingPathComponent("sibling/.remote-code/runtime/\(digest)", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingRoot, withIntermediateDirectories: true)
        let sibling = siblingRoot.appendingPathComponent("RemoteCodeDistillService")
        try FileManager.default.copyItem(at: artifact, to: sibling)
        var adversarial = environment
        adversarial[AgentSkillInstaller.toolShellBinaryEnvironmentKey] = sibling.path

        let rejected = TokenSaverExecutionReceiptSeam.stampIdentity(
            environment: adversarial,
            rootRunId: rootRunID,
            attemptId: "60000000-0000-0000-0000-000000000006",
            provider: .codex
        )
        XCTAssertNil(rejected["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"])
        XCTAssertNil(rejected[AgentSkillInstaller.toolShellProtocolEnvironmentKey])
        XCTAssertNil(rejected[AgentSkillInstaller.toolShellBinaryEnvironmentKey])
        XCTAssertNil(rejected[AgentSkillInstaller.runtimeRootEnvironmentKey])
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
