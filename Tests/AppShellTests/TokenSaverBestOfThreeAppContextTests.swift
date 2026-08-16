import XCTest
import CryptoKit
import Darwin
import CoreModel
@testable import AgentRuntime
import DistillCore
import Persistence
@testable import AppShell

/// C9: AppContext-owned exact-counter / envelope / recovery foundation.
/// Ranking stays in TokenSaverBestOfThreeSelector; these tests prove host seams.
@MainActor
final class TokenSaverBestOfThreeAppContextTests: XCTestCase {
    func test_defaultAppContextDoesNotInstallTypedSelector() throws {
        let context = try makeContext()
        defer { cleanup(context) }

        XCTAssertNil(
            context.coordinator.tokenSaverOutboundSelector,
            "default construction must leave the typed selector unset so C9 cannot change production prompts"
        )
        XCTAssertNil(context.tokenSaverExactRuntimeCapabilityForTesting)
    }

    func test_completeTestCapabilityInstallsTypedSelectorWithoutChangingCanonicalHumanDisplay() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }

        let human = repeatedHuman
        let threadID = try makeAdmittedThread(in: context)
        let adapter = C9CapturingAdapter()
        context.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(exactCapability())))
        XCTAssertNotNil(context.coordinator.tokenSaverOutboundSelector)
        XCTAssertNotNil(context.tokenSaverExactRuntimeCapabilityForTesting)

        let runID = AgentRunID()
        _ = try await context.coordinator.startRun(.init(
            runId: runID,
            threadId: threadID,
            provider: .codex,
            model: "test-model",
            cwd: context.appSupportDirectory.path,
            prompt: human
        ))

        XCTAssertEqual(
            try context.messageRepo.get(id: AgentMessageID(runID.value))?.content,
            human,
            "canonical Human display/persistence must stay byte-identical"
        )
        XCTAssertNotEqual(
            adapter.request?.prompt,
            "COMPRESSOR-MUST-NOT-RUN",
            "typed installation must not fall back to inventing a second Human"
        )
    }

    func test_exactCounterTargetMismatchOrMissingCapabilityChoosesHumanWithoutCandidateFinalization() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        let adapter = C9CapturingAdapter()
        context.coordinator.replaceProviderAdapter(.codex, adapter: adapter)

        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(provider: "claude", resolvedModel: "other-model")
        )))
        XCTAssertNotNil(context.coordinator.tokenSaverOutboundSelector)

        let runID = AgentRunID()
        _ = try await context.coordinator.startRun(.init(
            runId: runID,
            threadId: threadID,
            provider: .codex,
            model: "test-model",
            cwd: context.appSupportDirectory.path,
            prompt: repeatedHuman
        ))

        XCTAssertEqual(adapter.request?.prompt, repeatedHuman)
        XCTAssertEqual(try context.messageRepo.get(id: AgentMessageID(runID.value))?.content, repeatedHuman)
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 0)
        XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 0)

        context.installTokenSaverExactRuntimeCapability(nil)
        XCTAssertNil(context.coordinator.tokenSaverOutboundSelector)
        XCTAssertNil(context.tokenSaverExactRuntimeCapabilityForTesting)
    }

    func test_estimatedOrUnknownCounterCannotBeInstalledOrAdmitted() throws {
        let context = try makeContext()
        defer { cleanup(context) }

        for quality in [
            TokenSaverBestOfThreeSelector.CounterQuality.estimated,
            .unknown,
        ] {
            XCTAssertNil(
                TokenSaverExactRuntimeCapability.admitted(
                    provider: "codex",
                    resolvedModel: "test-model",
                    counterID: "c9-counter",
                    counterRevision: "1",
                    encoding: "fixture",
                    quality: quality,
                    count: { _ in 1 }
                ),
                "\(quality.rawValue) must never satisfy the exact capability seam"
            )
        }

        XCTAssertFalse(context.installTokenSaverExactRuntimeCapability(
            TokenSaverExactRuntimeCapability.admitted(
                provider: "codex",
                resolvedModel: "test-model",
                counterID: "c9-counter",
                counterRevision: "1",
                encoding: "fixture",
                quality: .estimated,
                count: { _ in TokenEstimator.estimate("x") }
            )
        ))
        XCTAssertNil(context.coordinator.tokenSaverOutboundSelector)
        XCTAssertNil(context.tokenSaverExactRuntimeCapabilityForTesting)
    }

    func test_humanAndRCW1ProjectedEnvelopesShareFinalEnvelopeUniverseWithoutDoubleCountingABIOrHandle() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        let probe = C9CountProbe()
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(count: { try probe.count($0) })
        )))
        let selector = try XCTUnwrap(context.coordinator.tokenSaverOutboundSelector)
        let runID = AgentRunID()
        let env = [
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey: "1",
        ]
        let request = TokenSaverOutboundSelectionRequest(
            canonicalHuman: repeatedHuman,
            admittedRequest: .init(
                runId: runID,
                threadId: threadID,
                provider: .codex,
                model: "test-model",
                cwd: context.appSupportDirectory.path,
                prompt: repeatedHuman,
                environment: env
            ),
            autoRoute: nil,
            admittedEnvironment: env
        )

        let decision = await selector(request)
        let humanCost = try XCTUnwrap(decision.cost(.human))
        let rcw1Cost = try XCTUnwrap(decision.cost(.rcw1))
        let humanProjection = try XCTUnwrap(
            TokenSaverProviderVisibleEnvelopeProjector.project(
                format: .human,
                payload: repeatedHuman,
                request: request
            )
        )
        XCTAssertEqual(decision.selectedFormat, .rcw1, "\(decision.reason.rawValue)")
        let rcw1Projection = try XCTUnwrap(
            TokenSaverProviderVisibleEnvelopeProjector.project(
                format: .rcw1,
                payload: decision.selectedPayload,
                request: request
            )
        )

        XCTAssertTrue(probe.texts.contains(humanProjection.effectiveEnvelope))
        XCTAssertTrue(probe.texts.contains(rcw1Projection.effectiveEnvelope))
        XCTAssertEqual(humanCost.effectiveEnvelopeSHA256, sha256Hex(humanProjection.effectiveEnvelope))
        XCTAssertEqual(rcw1Cost.effectiveEnvelopeSHA256, sha256Hex(rcw1Projection.effectiveEnvelope))
        XCTAssertEqual(humanCost.effectiveEnvelopeTokens, C9CountProbe.humanEnvelopeTokens)
        XCTAssertEqual(rcw1Cost.effectiveEnvelopeTokens, C9CountProbe.rcw1EnvelopeTokens)
        XCTAssertEqual(humanCost.abiTokens, 0, "Human ABI is diagnostic-zero in the selector Cost; ranking is the envelope")
        XCTAssertEqual(rcw1Cost.payloadSHA256, sha256Hex(decision.selectedPayload))
        XCTAssertNotEqual(
            rcw1Cost.payloadTokensIncludingHandle + rcw1Cost.handleTokens + rcw1Cost.abiTokens,
            rcw1Cost.effectiveEnvelopeTokens,
            "ranking must count the full envelope once; ABI/handle are not added again"
        )
        XCTAssertGreaterThan(rcw1Cost.handleTokens, 0)
        XCTAssertGreaterThan(rcw1Cost.abiTokens, 0)
        XCTAssertTrue(decision.selectedPayload.contains("[[rc:"))
        let rcs1Arm = try XCTUnwrap(decision.arm(.rcs1))
        XCTAssertFalse(rcs1Arm.eligible, "disabled RCS1 must not become a selectable winner")
        XCTAssertEqual(
            rcs1Arm.producerID,
            TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID
        )
        XCTAssertNil(
            TokenSaverProviderVisibleEnvelopeProjector.project(
                format: .rcs1,
                payload: "unused",
                request: request
            ),
            "RCS1 has no proven production envelope"
        )
    }

    func test_disabledRCS1CandidateIsUnavailableWithFailedGatesAndDoesNotInstallThirdPartyProducer() {
        let source = String(repeating: "ab", count: 32)
        let candidate = TokenSaverExactRuntimeSupport.disabledRCS1Candidate(sourceSHA256: source)
        XCTAssertEqual(candidate.format, .rcs1)
        XCTAssertEqual(candidate.sourceSHA256, source)
        XCTAssertNil(candidate.handle)
        XCTAssertEqual(candidate.generation, .failed)
        XCTAssertEqual(candidate.structural, .failed)
        XCTAssertEqual(candidate.semantic, .failed)
        XCTAssertEqual(candidate.recovery, .failed)
        XCTAssertEqual(candidate.producerID, "remotecode-rcs1-unavailable")
        XCTAssertEqual(candidate.payload, "RCS1_RUNTIME_UNAVAILABLE")
        XCTAssertEqual(candidate.abi, "RCS1_ABI_UNAVAILABLE")
    }

    func test_selectedRCW1ProvisionalIsFinalizedExactlyOnce() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        let adapter = C9CapturingAdapter()
        context.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(count: { C9CountProbe.rcw1Wins($0) })
        )))

        let runID = AgentRunID()
        _ = try await context.coordinator.startRun(.init(
            runId: runID,
            threadId: threadID,
            provider: .codex,
            model: "test-model",
            cwd: context.appSupportDirectory.path,
            prompt: repeatedHuman
        ))

        let sent = try XCTUnwrap(adapter.request?.prompt)
        XCTAssertTrue(RCWireProtocol.isWire(sent))
        XCTAssertEqual(try context.messageRepo.get(id: AgentMessageID(runID.value))?.content, repeatedHuman)
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 1)
        XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 0)
        XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 1)
        let handle = try recoveryHandle(from: sent)
        let scope = try recoveryScope(in: context, threadID: threadID, runID: runID)
        XCTAssertEqual(
            try TokenSaverScopedRecoveryStore(db: context.db).retrieve(capability: handle, scope: scope),
            Data(repeatedHuman.utf8)
        )
    }

    func test_humanTieOrCounterErrorDiscardsRCW1ProvisionalAndNeverFinalizes() async throws {
        let cases: [(String, @Sendable (String) async throws -> Int)] = [
            ("human", { C9CountProbe.humanWins($0) }),
            ("tie", { C9CountProbe.tie($0) }),
            ("counter-error", { _ in throw C9CounterError.boom }),
        ]
        for (name, count) in cases {
            let context = try makeContext(suffix: name)
            defer { cleanup(context) }
            SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
            let server = try await startDistill(on: context)
            defer { server.stop() }
            let threadID = try makeAdmittedThread(in: context)
            XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
                exactCapability(count: count)
            )))
            let selector = try XCTUnwrap(context.coordinator.tokenSaverOutboundSelector)
            let runID = AgentRunID()
            let env = [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey: "1",
            ]
            let decision = await selector(TokenSaverOutboundSelectionRequest(
                canonicalHuman: repeatedHuman,
                admittedRequest: .init(
                    runId: runID,
                    threadId: threadID,
                    provider: .codex,
                    model: "test-model",
                    cwd: context.appSupportDirectory.path,
                    prompt: repeatedHuman,
                    environment: env
                ),
                autoRoute: nil,
                admittedEnvironment: env
            ))

            XCTAssertEqual(decision.selectedFormat, .human, name)
            XCTAssertEqual(decision.selectedPayload, repeatedHuman, name)
            XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 0, name)
            XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 1, name)
            XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 0, name)
            XCTAssertFalse(decision.billingClaim)
        }
    }

    func test_legacyTokenSaverCompressFinalizesValidRCW1ThroughSplitLifecycle() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        let runID = AgentRunID()

        XCTAssertNil(context.coordinator.tokenSaverOutboundSelector)
        let adopted = await context.tokenSaverCompress(
            prompt: repeatedHuman,
            provider: .codex,
            threadId: threadID,
            runId: runID
        )

        XCTAssertTrue(RCWireProtocol.isWire(adopted))
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 1)
        XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 0)
        XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 1)
        let handle = try recoveryHandle(from: adopted)
        let scope = try recoveryScope(in: context, threadID: threadID, runID: runID)
        XCTAssertEqual(
            try TokenSaverScopedRecoveryStore(db: context.db).retrieve(capability: handle, scope: scope),
            Data(repeatedHuman.utf8),
            "legacy compress must still finalize its sole validated RCW1 candidate through the split"
        )
    }

    func test_c9IntroducesNoCavemanBinaryProcessOrNetworkPath() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Sources/AppShell/TokenSaverExactRuntimeCapability.swift",
            "Sources/AppShell/TokenSaverProviderVisibleEnvelopeProjector.swift",
            "Sources/AppShell/AppContext.swift",
        ]
        let forbidden = [
            "caveman-engine",
            "engine/cmd/caveman",
            "./engine/cmd/caveman-engine",
            "CavemanEngine",
            "installCaveman",
            "install-caveman",
        ]
        for rel in files {
            let text = try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
            for needle in forbidden {
                XCTAssertFalse(text.contains(needle), "\(rel) must not introduce \(needle)")
            }
        }
        let capability = try String(
            contentsOf: repo.appendingPathComponent("Sources/AppShell/TokenSaverExactRuntimeCapability.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            capability.contains("TokenEstimator"),
            "exact capability must not wrap TokenEstimator as a CounterCapability"
        )
        let appContext = try String(
            contentsOf: repo.appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let typedStart = try XCTUnwrap(appContext.range(of: "func encodeProvisionalRCW1("))
        let typedEnd = try XCTUnwrap(appContext.range(of: "func tokenSaverCompress("))
        XCTAssertLessThan(typedStart.lowerBound, typedEnd.lowerBound)
        let typedGate = appContext[typedStart.lowerBound..<typedEnd.lowerBound]
        XCTAssertFalse(
            typedGate.contains("TokenEstimator"),
            "typed exact generation must not apply the legacy 80-token estimator floor"
        )
        let legacyGate = appContext[typedEnd.lowerBound...]
        XCTAssertTrue(
            legacyGate.contains("TokenEstimator.estimate(prompt)"),
            "legacy tokenSaverCompress must keep its estimator-backed economics"
        )
    }

    func test_autoRouteRanksAndSendsTheHostOwnedAutoWireConstraint() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        let adapter = C9CapturingAdapter()
        context.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        let probe = C9CountProbe()
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(count: { try probe.count($0) })
        )))
        let route = autoRoute()
        let installed = try XCTUnwrap(context.coordinator.tokenSaverOutboundSelector)
        var captured: TokenSaverBestOfThreeSelector.Decision?
        var capturedRequest: TokenSaverOutboundSelectionRequest?
        context.coordinator.tokenSaverOutboundSelector = { request in
            let injected = TokenSaverOutboundSelectionRequest(
                canonicalHuman: request.canonicalHuman,
                admittedRequest: request.admittedRequest,
                autoRoute: route,
                admittedEnvironment: request.admittedEnvironment
            )
            capturedRequest = injected
            let decision = await installed(injected)
            captured = decision
            return decision
        }
        let autoHuman = AgentOrchestrationRuntime.autoOrchestrateProviderPrompt(
            userPrompt: repeatedHuman,
            admittedRoute: route
        )
        let runID = AgentRunID()
        _ = try await context.coordinator.startRun(.init(
            runId: runID,
            threadId: threadID,
            provider: .codex,
            model: "test-model",
            cwd: context.appSupportDirectory.path,
            prompt: autoHuman,
            userMessageContent: repeatedHuman
        ))

        let sent = try XCTUnwrap(adapter.request?.prompt)
        let decision = try XCTUnwrap(captured)
        let request = try XCTUnwrap(capturedRequest)
        let constraint = expectedAutoWireConstraint(route: route)
        XCTAssertEqual(decision.selectedFormat, .rcw1, "\(decision.reason.rawValue)")
        XCTAssertEqual(sent, decision.selectedPayload)
        XCTAssertTrue(RCWireProtocol.isWire(sent))
        XCTAssertTrue(sent.contains(constraint), "ranked/sent RCW1 must carry the host-owned Auto constraint")
        XCTAssertFalse(repeatedHuman.contains(constraint))
        XCTAssertFalse(autoHuman.contains(constraint))
        let projected = try XCTUnwrap(
            TokenSaverProviderVisibleEnvelopeProjector.project(
                format: .rcw1,
                payload: sent,
                request: request
            )
        )
        XCTAssertEqual(sent, projected.payload)
        XCTAssertTrue(probe.texts.contains(projected.effectiveEnvelope))
        XCTAssertEqual(
            decision.cost(.rcw1)?.effectiveEnvelopeSHA256,
            sha256Hex(projected.effectiveEnvelope)
        )
        XCTAssertEqual(try context.messageRepo.get(id: AgentMessageID(runID.value))?.content, repeatedHuman)
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 1)
    }

    func test_unprovableHumanEnvelopeFailsClosedWithoutRCW1CountOrDistill() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        let projector = C9CallProbe()
        let counter = C9CallProbe()
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(
                count: { text in
                    counter.record()
                    return C9CountProbe.rcw1Wins(text)
                },
                projectEnvelope: { format, payload, request in
                    projector.record()
                    if format == .human { return nil }
                    return TokenSaverProviderVisibleEnvelopeProjector.project(
                        format: format,
                        payload: payload,
                        request: request
                    )
                }
            )
        )))
        let selector = try XCTUnwrap(context.coordinator.tokenSaverOutboundSelector)
        let runID = AgentRunID()
        let decision = await selector(selectionRequest(
            human: repeatedHuman,
            threadID: threadID,
            runID: runID,
            includeRCW1Capability: true
        ))

        XCTAssertEqual(decision.selectedFormat, .human)
        XCTAssertEqual(decision.selectedPayload, repeatedHuman)
        XCTAssertEqual(decision.reason, .candidateError)
        XCTAssertTrue(decision.costs.isEmpty, "unprovable Human must keep a content-free receipt")
        XCTAssertTrue(decision.arms.isEmpty)
        XCTAssertNil(decision.counter)
        XCTAssertFalse(decision.billingClaim)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(context.tokenSaverDistillPrepareInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 0)
        XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 0)
        XCTAssertEqual(projector.count, 1, "Human projection nil must stop before RCW1 projection")
    }

    func test_unprovableRCW1EnvelopeAfterPrepareDiscardsProvisionalWithoutSendingWire() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        let projector = C9CallProbe()
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(
                projectEnvelope: { format, payload, request in
                    projector.record()
                    if format == .rcw1 { return nil }
                    return TokenSaverProviderVisibleEnvelopeProjector.project(
                        format: format,
                        payload: payload,
                        request: request
                    )
                }
            )
        )))
        let selector = try XCTUnwrap(context.coordinator.tokenSaverOutboundSelector)
        let runID = AgentRunID()
        let decision = await selector(selectionRequest(
            human: repeatedHuman,
            threadID: threadID,
            runID: runID,
            includeRCW1Capability: true
        ))

        XCTAssertEqual(decision.selectedFormat, .human)
        XCTAssertEqual(decision.selectedPayload, repeatedHuman)
        XCTAssertFalse(
            RCWireProtocol.isWire(decision.selectedPayload),
            "prepared RCW1 must not be selected or sent after its envelope cannot be proven"
        )
        XCTAssertGreaterThan(context.tokenSaverDistillPrepareInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 1)
        XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 0)
        XCTAssertEqual(
            projector.count,
            2,
            "Human projection must succeed and RCW1 projection must still run after prepare"
        )
    }

    func test_tokenSaverDisabledWithInstalledCapabilitySkipsProjectorCounterAndDistill() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = false }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        let adapter = C9CapturingAdapter()
        context.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        let projector = C9CallProbe()
        let counter = C9CallProbe()
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(
                count: { text in
                    counter.record()
                    return C9CountProbe.rcw1Wins(text)
                },
                projectEnvelope: { format, payload, request in
                    projector.record()
                    return TokenSaverProviderVisibleEnvelopeProjector.project(
                        format: format,
                        payload: payload,
                        request: request
                    )
                }
            )
        )))
        let runID = AgentRunID()
        _ = try await context.coordinator.startRun(.init(
            runId: runID,
            threadId: threadID,
            provider: .codex,
            model: "test-model",
            cwd: context.appSupportDirectory.path,
            prompt: repeatedHuman
        ))

        XCTAssertEqual(adapter.request?.prompt, repeatedHuman)
        XCTAssertEqual(try context.messageRepo.get(id: AgentMessageID(runID.value))?.content, repeatedHuman)
        XCTAssertEqual(projector.count, 0)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(context.tokenSaverDistillPrepareInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 0)
        XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 0)
    }

    func test_sameUserDeniedWithInstalledCapabilitySkipsProjectorCounterAndDistill() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context, runAsUser: foreignRunAsUser())
        let adapter = C9CapturingAdapter()
        context.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        let projector = C9CallProbe()
        let counter = C9CallProbe()
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(
                count: { text in
                    counter.record()
                    return C9CountProbe.rcw1Wins(text)
                },
                projectEnvelope: { format, payload, request in
                    projector.record()
                    return TokenSaverProviderVisibleEnvelopeProjector.project(
                        format: format,
                        payload: payload,
                        request: request
                    )
                }
            )
        )))
        let runID = AgentRunID()
        _ = try await context.coordinator.startRun(.init(
            runId: runID,
            threadId: threadID,
            provider: .codex,
            model: "test-model",
            cwd: context.appSupportDirectory.path,
            prompt: repeatedHuman
        ))

        XCTAssertEqual(adapter.request?.prompt, repeatedHuman)
        XCTAssertEqual(try context.messageRepo.get(id: AgentMessageID(runID.value))?.content, repeatedHuman)
        XCTAssertEqual(projector.count, 0)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(context.tokenSaverDistillPrepareInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 0)
        XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 0)
    }

    func test_missingRCW1WireCapabilityDoesNotPrepareOrFinalizeRecovery() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(count: { C9CountProbe.rcw1Wins($0) })
        )))
        let selector = try XCTUnwrap(context.coordinator.tokenSaverOutboundSelector)
        let runID = AgentRunID()
        let decision = await selector(selectionRequest(
            human: repeatedHuman,
            threadID: threadID,
            runID: runID,
            includeRCW1Capability: false
        ))

        XCTAssertEqual(decision.selectedFormat, .human)
        XCTAssertEqual(decision.selectedPayload, repeatedHuman)
        XCTAssertEqual(context.tokenSaverDistillPrepareInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 0)
        XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 0)
    }

    func test_typedExactPathAttemptsRCW1BelowLegacyEstimatorFloor() async throws {
        let unit = "Verbose English guidance carries recoverable contextual explanation. "
        var repeats = 2
        var short = String(repeating: unit, count: repeats)
        while TokenEstimator.estimate(String(repeating: unit, count: repeats + 1)) < 80 {
            repeats += 1
            short = String(repeating: unit, count: repeats)
        }
        XCTAssertLessThan(TokenEstimator.estimate(short), 80)

        let typed = try makeContext(suffix: "typed-short")
        defer { cleanup(typed) }
        SettingsStore(db: typed.db).update { $0.tokenSaverEnabled = true }
        let typedServer = try await startDistill(on: typed)
        defer { typedServer.stop() }
        let typedThread = try makeAdmittedThread(in: typed)
        XCTAssertTrue(typed.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(count: { text in
                if text.contains("RCW1\t") && text.contains("REMOTE_CODE_WIRE_V1") { return 10 }
                return 50
            })
        )))
        let selector = try XCTUnwrap(typed.coordinator.tokenSaverOutboundSelector)
        let typedRun = AgentRunID()
        let typedDecision = await selector(selectionRequest(
            human: short,
            threadID: typedThread,
            runID: typedRun,
            includeRCW1Capability: true
        ))
        XCTAssertGreaterThan(typed.tokenSaverDistillPrepareInvocationsForTesting, 0)
        XCTAssertEqual(typedDecision.selectedFormat, .rcw1, "\(typedDecision.reason.rawValue)")
        XCTAssertTrue(RCWireProtocol.isWire(typedDecision.selectedPayload))
        XCTAssertEqual(typed.tokenSaverRCW1FinalizeInvocationsForTesting, 1)
        XCTAssertEqual(try liveRecoveryCount(in: typed, attemptID: typedRun.value.uuidString), 1)

        let legacy = try makeContext(suffix: "legacy-short")
        defer { cleanup(legacy) }
        SettingsStore(db: legacy.db).update { $0.tokenSaverEnabled = true }
        let legacyServer = try await startDistill(on: legacy)
        defer { legacyServer.stop() }
        let legacyThread = try makeAdmittedThread(in: legacy)
        let adopted = await legacy.tokenSaverCompress(
            prompt: short,
            provider: .codex,
            threadId: legacyThread,
            runId: AgentRunID()
        )
        XCTAssertEqual(adopted, short)
        XCTAssertEqual(legacy.tokenSaverDistillPrepareInvocationsForTesting, 0)
        XCTAssertEqual(legacy.tokenSaverRCW1FinalizeInvocationsForTesting, 0)
    }

    func test_autoWireTransformFailureDiscardsProvisionalAndReturnsHuman() async throws {
        let context = try makeContext()
        defer { cleanup(context) }
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let server = try await startDistill(on: context)
        defer { server.stop() }
        let threadID = try makeAdmittedThread(in: context)
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(
            exactCapability(count: { C9CountProbe.rcw1Wins($0) })
        )))
        context.tokenSaverAutoWireTransformForTesting = { _, _ in
            throw C9CounterError.boom
        }
        let selector = try XCTUnwrap(context.coordinator.tokenSaverOutboundSelector)
        let runID = AgentRunID()
        let route = autoRoute()
        let autoHuman = AgentOrchestrationRuntime.autoOrchestrateProviderPrompt(
            userPrompt: repeatedHuman,
            admittedRoute: route
        )
        let request = TokenSaverOutboundSelectionRequest(
            canonicalHuman: repeatedHuman,
            admittedRequest: .init(
                runId: runID,
                threadId: threadID,
                provider: .codex,
                model: "test-model",
                cwd: context.appSupportDirectory.path,
                prompt: autoHuman,
                userMessageContent: repeatedHuman
            ),
            autoRoute: route,
            admittedEnvironment: [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey: "1",
            ]
        )
        let decision = await selector(request)

        XCTAssertEqual(decision.selectedFormat, .human)
        XCTAssertEqual(decision.selectedPayload, autoHuman)
        XCTAssertGreaterThan(context.tokenSaverDistillPrepareInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1FinalizeInvocationsForTesting, 0)
        XCTAssertEqual(context.tokenSaverRCW1DiscardInvocationsForTesting, 1)
        XCTAssertEqual(try liveRecoveryCount(in: context, attemptID: runID.value.uuidString), 0)
    }

    // MARK: - Helpers

    private var repeatedHuman: String {
        String(repeating: "Verbose English guidance carries recoverable contextual explanation. ", count: 90)
    }

    private func makeContext(suffix: String = UUID().uuidString) throws -> AppContext {
        let appSupport = NSTemporaryDirectory() + "RC2C9Best3-" + suffix
        return try AppContext(channel: .debug, appSupportOverride: appSupport)
    }

    private func cleanup(_ context: AppContext) {
        try? FileManager.default.removeItem(at: context.appSupportDirectory)
    }

    @discardableResult
    private func makeAdmittedThread(
        in context: AppContext,
        runAsUser: AgentRunAsUser? = nil
    ) throws -> AgentThreadID {
        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "c9 token saver",
            provider: .codex,
            model: "test-model",
            runAsUser: runAsUser
        )
        try context.threadRepo.upsert(thread)
        for lane in ["wire-encode", "wire-render-english"] {
            try context.tokenSaverLaneStateRepo.upsert(.init(
                projectID: thread.projectId!.value.uuidString,
                lane: lane,
                state: "promoted",
                reason: "test_scorecard_passed",
                evidenceLevel: "provider_usage",
                ownerRole: "Operations Owner:test",
                permissionBoundary: "project",
                retentionDays: 30,
                optedOut: false,
                killSwitchActive: false,
                attributionJoined: true,
                reconciliationPassed: true,
                usageSemanticsAvailable: true,
                scorecardID: "c9-scorecard"
            ))
        }
        return thread.id
    }

    private func startDistill(on context: AppContext) async throws -> DistillHTTPServer {
        let configuration = try DistillServiceConfiguration(
            authToken: "c9-token",
            appSupportDirectory: context.appSupportDirectory.path
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(
                runtime: LocalDistillRuntime(),
                maxConcurrentRequests: 2,
                resultCacheCapacity: 0
            ),
            scopedRecoveryStore: C9RecoveryStore(db: context.db)
        )
        let ready = try await server.start()
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "c9-token")
        return server
    }

    private func exactCapability(
        provider: String = "codex",
        resolvedModel: String = "test-model",
        count: @escaping @Sendable (String) async throws -> Int = { C9CountProbe.rcw1Wins($0) },
        projectEnvelope: @escaping @Sendable (
            TokenSaverBestOfThreeSelector.Format,
            String,
            TokenSaverOutboundSelectionRequest
        ) -> TokenSaverProviderVisibleEnvelope? = TokenSaverProviderVisibleEnvelopeProjector.project
    ) -> TokenSaverExactRuntimeCapability? {
        TokenSaverExactRuntimeCapability.admitted(
            provider: provider,
            resolvedModel: resolvedModel,
            counterID: "c9-counter",
            counterRevision: "1",
            encoding: "fixture",
            quality: .exactLocalTokenizer,
            count: count,
            projectEnvelope: projectEnvelope
        )
    }

    private func selectionRequest(
        human: String,
        threadID: AgentThreadID,
        runID: AgentRunID,
        includeRCW1Capability: Bool
    ) -> TokenSaverOutboundSelectionRequest {
        var env = ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
        if includeRCW1Capability {
            env[TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey] = "1"
        }
        return TokenSaverOutboundSelectionRequest(
            canonicalHuman: human,
            admittedRequest: .init(
                runId: runID,
                threadId: threadID,
                provider: .codex,
                model: "test-model",
                cwd: NSTemporaryDirectory(),
                prompt: human
            ),
            autoRoute: nil,
            admittedEnvironment: env
        )
    }

    private func autoRoute() -> AgentOrchestrationRoute {
        AgentOrchestrationRoute(
            provider: .codex,
            providerInstanceId: "codex-live",
            capabilitySnapshotId: "c9-auto-cap",
            selection: AgentModelSelection(
                provider: .codex,
                modelId: "gpt-5.6-luna",
                reasoningEffort: .medium,
                serviceTier: .auto
            )
        )
    }

    private func expectedAutoWireConstraint(route: AgentOrchestrationRoute) -> String {
        let host = AgentOrchestrationRuntime.orchestrateHostKey(for: route.provider)
        return """
        Run $\(AgentOrchestrationRuntime.orchestrateSkillInvocationName) controller-only. Auto is on. Follow the complete installed orchestration skill. Host runtime receipt is authoritative: active_host=\(host); provider=\(route.provider.rawValue); provider_instance_id=\(route.providerInstanceId); controller_model=\(route.selection.effectiveModel); controller_effort=\(route.selection.reasoningEffort.rawValue). Bind workers and reviewers only from the host-runtime-matrix row for active_host=\(host). Treat the G, C, K, and X records in this frame as the user request. Distill applies only to eligible ordinary tool output when Token Saver is active, never to skill content.
        """
    }

    private func foreignRunAsUser() -> AgentRunAsUser {
        let current = getuid()
        return AgentRunAsUser(
            generatedUID: "c9-foreign-user",
            shortName: "c9foreign",
            uid: current == 501 ? 502 : 501,
            gid: getgid(),
            homePath: "/Users/c9foreign"
        )
    }

    private func liveRecoveryCount(in context: AppContext, attemptID: String) throws -> Int {
        let statement = try context.db.prepare("""
            SELECT COUNT(*) FROM token_saver_recovery_objects
            WHERE attempt_id = ? AND tombstoned_at_ms IS NULL;
            """)
        try statement.bind(1, attemptID)
        XCTAssertTrue(try statement.step())
        return Int(statement.columnInt64(0))
    }

    private func recoveryHandle(from wire: String) throws -> String {
        let frame = try XCTUnwrap(RCWireProtocol.parse(wire).first)
        let marker = try XCTUnwrap(frame.records.last(where: { $0.kind == .exact })?.value)
        XCTAssertTrue(marker.hasPrefix("[[rc:"))
        XCTAssertTrue(marker.hasSuffix("]]"))
        return String(marker.dropFirst(5).dropLast(2))
    }

    private func recoveryScope(
        in context: AppContext,
        threadID: AgentThreadID,
        runID: AgentRunID
    ) throws -> TokenSaverPersistentScope {
        let thread = try XCTUnwrap(context.threadRepo.get(id: threadID))
        return TokenSaverPersistentScope(
            workspaceID: try XCTUnwrap(thread.workspaceId?.value.uuidString),
            projectID: try XCTUnwrap(thread.projectId?.value.uuidString),
            threadID: threadID.value.uuidString,
            provider: AgentProvider.codex.rawValue,
            attemptID: runID.value.uuidString
        )
    }
}

private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private enum C9CounterError: Error { case boom }

private final class C9CallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func record() {
        lock.lock()
        _count += 1
        lock.unlock()
    }
}

private final class C9CountProbe: @unchecked Sendable {
    static let humanEnvelopeTokens = 120
    static let rcw1EnvelopeTokens = 40
    static let rcw1PayloadTokens = 22
    static let rcw1ABITokens = 11
    static let handleTokens = 5

    private let lock = NSLock()
    private var _texts: [String] = []
    var texts: [String] { lock.withLock { _texts } }

    func count(_ text: String) throws -> Int {
        lock.lock()
        _texts.append(text)
        lock.unlock()
        return Self.rcw1Wins(text)
    }

    static func rcw1Wins(_ text: String) -> Int {
        classify(text, humanEnvelope: humanEnvelopeTokens, rcw1Envelope: rcw1EnvelopeTokens)
    }

    static func humanWins(_ text: String) -> Int {
        classify(text, humanEnvelope: 20, rcw1Envelope: 80)
    }

    static func tie(_ text: String) -> Int {
        classify(text, humanEnvelope: 50, rcw1Envelope: 50)
    }

    private static func classify(_ text: String, humanEnvelope: Int, rcw1Envelope: Int) -> Int {
        if text.contains("RCS1_RUNTIME_UNAVAILABLE") || text.contains("RCS1_ABI_UNAVAILABLE") {
            return 90
        }
        if text.contains("RCW1\t") && text.contains("REMOTE_CODE_WIRE_V1") {
            return rcw1Envelope
        }
        if text.contains("RCW1\t") {
            return rcw1PayloadTokens
        }
        if text.contains("REMOTE_CODE_WIRE_V1") {
            return rcw1ABITokens
        }
        if text.hasPrefix("rcv1.") && !text.contains(" ") {
            return handleTokens
        }
        if text.contains("Verbose English guidance") && text.contains("TOKEN_SAVER_SAFETY_ABI_V1") {
            return humanEnvelope
        }
        if text.contains("Verbose English guidance") {
            return max(humanEnvelope - 15, 8)
        }
        return 8
    }
}

private final class C9CapturingAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var _request: AgentRunRequest?
    var request: AgentRunRequest? { lock.withLock { _request } }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        if let permit = request.acceptancePermit {
            try permit.withAcceptance { lock.withLock { _request = request } }
        } else {
            lock.withLock { _request = request }
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private final class C9RecoveryStore: TokenSaverScopedRecoveryStoring, @unchecked Sendable {
    private let store: TokenSaverScopedRecoveryStore

    init(db: SQLiteDB) {
        store = TokenSaverScopedRecoveryStore(db: db)
    }

    private func scope(_ context: TokenSaverRecoveryRequestContext) -> TokenSaverPersistentScope {
        .init(
            workspaceID: context.workspaceID,
            projectID: context.projectID,
            threadID: context.threadID,
            provider: context.provider,
            attemptID: context.attemptID
        )
    }

    func prepareOriginal(
        _ data: Data,
        context: TokenSaverRecoveryRequestContext,
        lane: String
    ) throws -> TokenSaverScopedPreparation {
        let prepared = try store.prepare(
            data,
            scope: scope(context),
            operationID: context.operationID,
            lane: lane,
            expiresAt: Date().addingTimeInterval(7 * 86_400),
            disk: .init(freeBytes: 40 * 1_024 * 1_024 * 1_024, totalBytes: 100 * 1_024 * 1_024 * 1_024)
        )
        return .init(
            capability: prepared.capability,
            idempotencyKey: prepared.idempotencyKey,
            readBackVerified: prepared.readBackVerified
        )
    }

    func retrieveOriginal(capability: String, context: TokenSaverRecoveryRequestContext) throws -> Data? {
        try store.retrieve(capability: capability, scope: scope(context))
    }

    func markDelivered(
        capability: String,
        idempotencyKey: String,
        context: TokenSaverRecoveryRequestContext,
        outcome: TokenSaverScopedDeliveryOutcome
    ) throws -> Bool {
        let mapped: TokenSaverRecoveryTransportOutcome
        switch outcome {
        case .notSent: mapped = .notSent
        case .sentUnknown: mapped = .sentUnknown
        case .acked: mapped = .acked
        case .failed: mapped = .failed
        }
        return try store.markDelivered(
            capability: capability,
            scope: scope(context),
            idempotencyKey: idempotencyKey,
            outcome: mapped
        )
    }

    func ack(
        capability: String,
        idempotencyKey: String,
        context: TokenSaverRecoveryRequestContext
    ) throws -> Bool {
        try store.ack(capability: capability, scope: scope(context), idempotencyKey: idempotencyKey)
    }
}
