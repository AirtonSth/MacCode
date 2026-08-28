import XCTest
@testable import DistillCore

final class TokenSaverT003ProgramTests: XCTestCase {
    func test_claimPolicy_allowsBillingClaimsOnlyFromJoinedProviderUsage() {
        XCTAssertFalse(
            TokenSaverClaimPolicy.evaluate(.providerUsage).billingClaimAllowed,
            "unjoined provider usage with unavailable semantics is not billing evidence"
        )
        XCTAssertTrue(TokenSaverClaimPolicy.evaluate(
            .providerUsage,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true
        ).billingClaimAllowed)
        for level in TokenSaverEvidenceLevel.allCases where level != .providerUsage {
            let decision = TokenSaverClaimPolicy.evaluate(level)
            XCTAssertFalse(decision.billingClaimAllowed, "\(level) must never support billing or money claims")
            XCTAssertFalse(decision.defaultPromotionAllowed, "unverified evidence must not default-enable a lane")
        }
    }

    func test_projectRuntimeAdmission_requiresExactPromotedOwnedEvidenceAndNoBreaker() {
        let admitted = TokenSaverProjectRuntimeSnapshot(
            globallyEnabled: true,
            hasExactProjectScope: true,
            laneState: "promoted",
            evidenceLevel: "provider_usage",
            ownerRole: "Operations Owner:test",
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "scorecard-1"
        )
        XCTAssertTrue(TokenSaverProjectRuntimeAdmissionPolicy.evaluate(admitted).allowed)

        for weakEvidence in [nil, "unknown", "diagnostic_heuristic", "hypothesis", "provider_tokenized_payload"] {
            let weak = TokenSaverProjectRuntimeSnapshot(
                globallyEnabled: true,
                hasExactProjectScope: true,
                laneState: "promoted",
                evidenceLevel: weakEvidence,
                ownerRole: "owner",
                optedOut: false,
                killSwitchActive: false,
                attributionJoined: true,
                reconciliationPassed: true,
                usageSemanticsAvailable: true,
                scorecardID: "scorecard-1"
            )
            XCTAssertEqual(
                TokenSaverProjectRuntimeAdmissionPolicy.evaluate(weak).reason,
                "evidence_not_authoritative"
            )
        }

        for missingReceipt in [
            (false, true, true),
            (true, false, true),
            (true, true, false),
        ] {
            let unjoined = TokenSaverProjectRuntimeSnapshot(
                globallyEnabled: true,
                hasExactProjectScope: true,
                laneState: "promoted",
                evidenceLevel: "provider_usage",
                ownerRole: "owner",
                optedOut: false,
                killSwitchActive: false,
                attributionJoined: missingReceipt.0,
                reconciliationPassed: missingReceipt.1,
                usageSemanticsAvailable: missingReceipt.2,
                scorecardID: "scorecard-1"
            )
            XCTAssertEqual(
                TokenSaverProjectRuntimeAdmissionPolicy.evaluate(unjoined).reason,
                "promotion_receipt_not_reconciled"
            )
        }
        let missingScorecard = TokenSaverProjectRuntimeSnapshot(
            globallyEnabled: true,
            hasExactProjectScope: true,
            laneState: "promoted",
            evidenceLevel: "provider_usage",
            ownerRole: "owner",
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: " "
        )
        XCTAssertEqual(
            TokenSaverProjectRuntimeAdmissionPolicy.evaluate(missingScorecard).reason,
            "promotion_receipt_missing_scorecard"
        )

        let denied: [TokenSaverProjectRuntimeSnapshot] = [
            .init(globallyEnabled: false, hasExactProjectScope: true, laneState: "promoted", evidenceLevel: "provider_usage", ownerRole: "owner", optedOut: false, killSwitchActive: false),
            .init(globallyEnabled: true, hasExactProjectScope: false, laneState: "promoted", evidenceLevel: "provider_usage", ownerRole: "owner", optedOut: false, killSwitchActive: false),
            .init(globallyEnabled: true, hasExactProjectScope: true, laneState: "off", evidenceLevel: "provider_usage", ownerRole: "owner", optedOut: false, killSwitchActive: false),
            .init(globallyEnabled: true, hasExactProjectScope: true, laneState: "promoted", evidenceLevel: "unavailable", ownerRole: "owner", optedOut: false, killSwitchActive: false),
            .init(globallyEnabled: true, hasExactProjectScope: true, laneState: "promoted", evidenceLevel: "provider_usage", ownerRole: "unassigned:owner", optedOut: false, killSwitchActive: false),
            .init(globallyEnabled: true, hasExactProjectScope: true, laneState: "promoted", evidenceLevel: "provider_usage", ownerRole: "owner", optedOut: true, killSwitchActive: false),
            .init(globallyEnabled: true, hasExactProjectScope: true, laneState: "promoted", evidenceLevel: "provider_usage", ownerRole: "owner", optedOut: false, killSwitchActive: true),
        ]
        XCTAssertTrue(denied.allSatisfy { !TokenSaverProjectRuntimeAdmissionPolicy.evaluate($0).allowed })
    }

    func test_globalScorecard_promotesOnlyWhenEveryBindingGatePasses() {
        let passing = TokenSaverPromotionScorecard.passingFixture(laneClass: .deterministic)
        XCTAssertEqual(TokenSaverPromotionPolicy.evaluate(passing).state, .promoted)

        let underpowered = passing.replacing(power: 0.79)
        XCTAssertEqual(TokenSaverPromotionPolicy.evaluate(underpowered).state, .shadowOnly)
        XCTAssertTrue(TokenSaverPromotionPolicy.evaluate(underpowered).reasons.contains("power_below_0_80"))

        let unknownVersion = passing.replacing(providerVersionKnown: false)
        XCTAssertEqual(TokenSaverPromotionPolicy.evaluate(unknownVersion).state, .off)
        XCTAssertTrue(TokenSaverPromotionPolicy.evaluate(unknownVersion).reasons.contains("unknown_provider_version"))
    }

    func test_globalScorecard_usesLaneSpecificLatencyBudgets() {
        let deterministic = TokenSaverPromotionScorecard.passingFixture(laneClass: .deterministic).replacing(p95Milliseconds: 50.1)
        XCTAssertEqual(TokenSaverPromotionPolicy.evaluate(deterministic).state, .shadowOnly)

        let encoder = TokenSaverPromotionScorecard.passingFixture(laneClass: .encoder).replacing(p95Milliseconds: 300.1)
        XCTAssertEqual(TokenSaverPromotionPolicy.evaluate(encoder).state, .shadowOnly)

        let auxiliary = TokenSaverPromotionScorecard.passingFixture(laneClass: .auxiliaryMLX).replacing(p95Milliseconds: 2_000.1)
        XCTAssertEqual(TokenSaverPromotionPolicy.evaluate(auxiliary).state, .shadowOnly)

        let hotPath = TokenSaverPromotionScorecard.passingFixture(laneClass: .mlxProviderHotPath).replacing(p95Milliseconds: 500.1)
        XCTAssertEqual(TokenSaverPromotionPolicy.evaluate(hotPath).state, .off)
    }

    func test_crossoverHarness_rejectsUnisolatedOrDuplicatedExternalEffects() {
        let readOnly = TokenSaverCrossoverReceipt(
            taskClass: .readOnly,
            baselineStateHash: "same",
            treatmentStateHash: "same",
            resetReceipt: nil,
            authorizedExternalEffects: 0,
            observedExternalEffects: 0,
            shadowCompared: true
        )
        XCTAssertTrue(TokenSaverCrossoverPolicy.evaluate(readOnly).eligibleForPromotion)

        let unsafe = TokenSaverCrossoverReceipt(
            taskClass: .externallyMutating,
            baselineStateHash: "a",
            treatmentStateHash: "b",
            resetReceipt: nil,
            authorizedExternalEffects: 1,
            observedExternalEffects: 2,
            shadowCompared: false
        )
        let decision = TokenSaverCrossoverPolicy.evaluate(unsafe)
        XCTAssertFalse(decision.eligibleForPromotion)
        XCTAssertTrue(decision.reasons.contains("duplicated_external_effect"))
        XCTAssertTrue(decision.reasons.contains("external_mutation_requires_shadow"))
    }

    func test_recoveryScope_requiresExactWorkspaceProjectThreadProviderAndAttempt() {
        let owner = TokenSaverRecoveryScope(workspaceID: "w", projectID: "p", threadID: "t", provider: "claude", attemptID: "a")
        XCTAssertTrue(owner.authorizes(owner))
        XCTAssertFalse(owner.authorizes(TokenSaverRecoveryScope(workspaceID: "w", projectID: "p", threadID: "other", provider: "claude", attemptID: "a")))
        XCTAssertFalse(owner.authorizes(TokenSaverRecoveryScope(workspaceID: "w", projectID: "p", threadID: "t", provider: "codex", attemptID: "a")))
        XCTAssertFalse(owner.authorizes(TokenSaverRecoveryScope(workspaceID: "w", projectID: "p", threadID: "t", provider: "claude", attemptID: "other")))
    }

    func test_envelope_supportsOnlyCurrentAndPreviousVersions_andEscapesLiteralMarkers() throws {
        XCTAssertTrue(TokenSaverEnvelopeCompatibility.supports(version: TokenSaverEnvelope.currentVersion))
        XCTAssertTrue(TokenSaverEnvelopeCompatibility.supports(version: TokenSaverEnvelope.currentVersion - 1))
        XCTAssertFalse(TokenSaverEnvelopeCompatibility.supports(version: TokenSaverEnvelope.currentVersion + 1))

        let literal = "user typed [[rc:not-a-capability]] literally"
        let escaped = TokenSaverMarkerCodec.escapeLiterals(in: literal)
        XCTAssertFalse(escaped.contains("[[rc:"))
        XCTAssertEqual(TokenSaverMarkerCodec.unescapeLiterals(in: escaped), literal)
    }

    func test_outbox_neverReplaysAmbiguousMutation() {
        XCTAssertTrue(TokenSaverOutboxPolicy.canTransition(from: .prepared, to: .delivered))
        XCTAssertTrue(TokenSaverOutboxPolicy.canTransition(from: .delivered, to: .acked))
        XCTAssertFalse(TokenSaverOutboxPolicy.canTransition(from: .acked, to: .delivered))
        XCTAssertFalse(TokenSaverOutboxPolicy.mayReplayMutation(after: .sentUnknown))
        XCTAssertFalse(TokenSaverOutboxPolicy.mayReplayMutation(after: .acked))
        XCTAssertTrue(TokenSaverOutboxPolicy.mayReplayMutation(after: .notSent))
        XCTAssertTrue(TokenSaverOutboxPolicy.mayReplayMutation(after: .failed),
                      "core replay policy must match the durable safe-failure state")
    }

    func test_admissionPolicy_enforcesAllInitialHardLimitsAndDiskFloor() {
        let ok = TokenSaverAdmissionSnapshot(
            objectBytes: 1,
            threadBytes: 1,
            projectBytes: 1,
            globalBytes: 1,
            freeDiskBytes: 20 * 1_024 * 1_024 * 1_024,
            totalDiskBytes: 100 * 1_024 * 1_024 * 1_024
        )
        XCTAssertTrue(TokenSaverAdmissionPolicy.evaluate(ok).allowed)

        XCTAssertFalse(TokenSaverAdmissionPolicy.evaluate(ok.replacing(objectBytes: TokenSaverAdmissionPolicy.maxObjectBytes + 1)).allowed)
        XCTAssertFalse(TokenSaverAdmissionPolicy.evaluate(ok.replacing(threadBytes: TokenSaverAdmissionPolicy.maxThreadBytes + 1)).allowed)
        XCTAssertFalse(TokenSaverAdmissionPolicy.evaluate(ok.replacing(projectBytes: TokenSaverAdmissionPolicy.maxProjectBytes + 1)).allowed)
        XCTAssertFalse(TokenSaverAdmissionPolicy.evaluate(ok.replacing(globalBytes: TokenSaverAdmissionPolicy.maxGlobalBytes + 1)).allowed)
        XCTAssertFalse(TokenSaverAdmissionPolicy.evaluate(ok.replacing(freeDiskBytes: TokenSaverAdmissionPolicy.minimumFreeDiskBytes - 1)).allowed)
        XCTAssertFalse(TokenSaverAdmissionPolicy.evaluate(.init(
            objectBytes: 2,
            threadBytes: 0,
            projectBytes: 0,
            globalBytes: 0,
            freeDiskBytes: TokenSaverAdmissionPolicy.minimumFreeDiskBytes + 1,
            totalDiskBytes: 10 * TokenSaverAdmissionPolicy.minimumFreeDiskBytes
        )).allowed, "the new object must fit above the post-write disk floor")
    }

    /// WHY: `max(5 GiB, 10% of volume)` on a ~4 TB disk required ~372 GiB free and
    /// discarded every lossy Distill handle while ~14 GiB remained. Admission
    /// uses the same fixed 5 GiB floor as the recovery store.
    func test_admissionPolicy_diskFloorIsFixedFiveGiBNotPercentOfVolume() {
        let fourTiB: Int64 = 4 * 1_024 * 1_024 * 1_024 * 1_024
        let fourteenGiB: Int64 = 14 * 1_024 * 1_024 * 1_024
        let largeVolume = TokenSaverAdmissionSnapshot(
            objectBytes: 1,
            threadBytes: 1,
            projectBytes: 1,
            globalBytes: 1,
            freeDiskBytes: fourteenGiB,
            totalDiskBytes: fourTiB
        )
        XCTAssertTrue(
            TokenSaverAdmissionPolicy.evaluate(largeVolume).allowed,
            "14 GiB free on a 4 TiB disk must admit; a 10%-of-volume floor would deny"
        )
        XCTAssertEqual(TokenSaverAdmissionPolicy.evaluate(largeVolume).reason, "admitted")

        let belowFixedFloor = TokenSaverAdmissionSnapshot(
            objectBytes: 1,
            threadBytes: 1,
            projectBytes: 1,
            globalBytes: 1,
            freeDiskBytes: TokenSaverAdmissionPolicy.minimumFreeDiskBytes - 1,
            totalDiskBytes: fourTiB
        )
        let denied = TokenSaverAdmissionPolicy.evaluate(belowFixedFloor)
        XCTAssertFalse(denied.allowed)
        XCTAssertEqual(denied.reason, "free_disk_floor")
    }

    func test_safetyABI_isVersionedMinimalAndRouteEquivalent() {
        let block = TokenSaverSafetyABI.block
        XCTAssertTrue(block.contains("TOKEN_SAVER_SAFETY_ABI_V1"))
        XCTAssertTrue(block.contains("fail open"))
        XCTAssertTrue(block.contains("scope-authorized"))
        XCTAssertTrue(block.contains("unresolved recovery markers"))
        XCTAssertTrue(TokenSaverSafetyABI.isRouteEquivalent(effectiveInstruction: "prefix\n\(block)\nsuffix"))
        XCTAssertFalse(TokenSaverSafetyABI.isRouteEquivalent(effectiveInstruction: "\(block)\n\(block)"))
        XCTAssertFalse(TokenSaverSafetyABI.isRouteEquivalent(effectiveInstruction: "mutable project prose only"))
    }

    func test_providerCompatibility_unknownVersionsRemainOffForClaudeCodexAndGrok() {
        let matrix = TokenSaverProviderCompatibilityMatrix(entries: [
            .init(provider: "claude", current: "2", previous: "1"),
            .init(provider: "codex", current: "4", previous: "3"),
            .init(provider: "grok", current: "6", previous: "5")
        ])
        for provider in ["claude", "codex", "grok"] {
            XCTAssertTrue(matrix.supports(provider: provider, version: provider == "claude" ? "2" : provider == "codex" ? "4" : "6"))
            XCTAssertFalse(matrix.supports(provider: provider, version: "unknown"))
        }
    }

    func test_providerNativeLanesNeverAssumeUnavailableOrRemovedSurfaces() {
        let unknown = TokenSaverProviderNativePolicy.evaluate(
            provider: "codex",
            providerVersionKnown: false,
            toolSearchExposedByActiveAdapter: true,
            promptCacheBehaviorProven: true,
            recoveryProven: true
        )
        XCTAssertEqual(unknown.state, .off)

        let codexUnexposed = TokenSaverProviderNativePolicy.evaluate(
            provider: "codex",
            providerVersionKnown: true,
            toolSearchExposedByActiveAdapter: false,
            promptCacheBehaviorProven: true,
            recoveryProven: false
        )
        XCTAssertFalse(codexUnexposed.toolSearchAllowed)
        XCTAssertFalse(codexUnexposed.lowVerbosityCanaryAllowed)
        XCTAssertFalse(codexUnexposed.removedCLIFlagsAllowed)
    }

    func test_fileFingerprintRequiresExactScopeAndProtectsLatestWorkingSet() {
        var registry = TokenSaverFileFingerprintRegistry(protectedRecentCount: 1)
        let scope = TokenSaverRecoveryScope(workspaceID: "w", projectID: "p", threadID: "t", provider: "claude", attemptID: "a")
        let otherThread = TokenSaverRecoveryScope(workspaceID: "w", projectID: "p", threadID: "other", provider: "claude", attemptID: "a")
        XCTAssertEqual(registry.register(path: "/repo/A.swift", bytes: Data("same".utf8), scope: scope), .sendFull)
        XCTAssertEqual(registry.register(path: "/repo/A.swift", bytes: Data("same".utf8), scope: scope), .sendFull,
                       "latest working set stays verbatim")
        _ = registry.register(path: "/repo/B.swift", bytes: Data("other".utf8), scope: scope)
        let unchanged = registry.register(path: "/repo/A.swift", bytes: Data("same".utf8), scope: scope)
        guard case .unchanged(let fingerprint) = unchanged else { return XCTFail("expected unchanged marker") }
        XCTAssertFalse(fingerprint.isEmpty)
        XCTAssertEqual(registry.register(path: "/repo/A.swift", bytes: Data("same".utf8), scope: otherThread), .sendFull)
    }

    func test_lexicalEmbeddingAndMaskingPromotionGatesAreBinding() {
        let lexical = TokenSaverLexicalScorecard(
            optedIn: true,
            repeatedReadShare: 0.05,
            netTokenReductionPerTask: 0.03,
            recallAt5: 0.95,
            p95Milliseconds: 100,
            crossScopeLeaks: 0
        )
        XCTAssertTrue(TokenSaverLexicalPromotionPolicy.evaluate(lexical).promotable)
        XCTAssertFalse(TokenSaverLexicalPromotionPolicy.evaluate(lexical.replacing(recallAt5: 0.949)).promotable)
        XCTAssertFalse(TokenSaverLexicalPromotionPolicy.evaluate(lexical.replacing(optedIn: false)).promotable)
        XCTAssertFalse(TokenSaverEmbeddingPromotionPolicy.mayPrototype(
            lexicalGapProven: false,
            manifestApproved: true,
            noBuildControlPassed: true
        ))
        XCTAssertFalse(TokenSaverReadMaskingPolicy.evaluate(
            scopedCapabilityAvailable: true,
            criticalFailures: 0,
            recentWorkingSetProtected: true,
            breakerActive: true
        ).allowed)
    }

    func test_rolloverCapsule_isSelfContainedBoundedAndLeavesParentUntouched() throws {
        let parent = [
            TokenSaverCapsuleMessage(role: "user", text: "Fix /tmp/exact-path and keep literal ABC-123."),
            TokenSaverCapsuleMessage(role: "assistant", text: "Decision: preserve browser parity. [[rc:legacy]]")
        ]
        let before = parent
        let capsule = try TokenSaverRolloverCapsuleBuilder.build(
            parentThreadID: "parent",
            childThreadID: "child",
            messages: parent,
            maxBytes: 1_024
        )
        XCTAssertEqual(parent, before, "capsule creation must not mutate the old thread")
        XCTAssertLessThanOrEqual(capsule.text.utf8.count, 1_024)
        XCTAssertFalse(capsule.text.contains("[[rc:"), "self-contained capsule cannot inherit unresolved authority")
        XCTAssertTrue(capsule.text.contains("/tmp/exact-path"))
        XCTAssertTrue(capsule.text.contains("ABC-123"))
        XCTAssertEqual(capsule.parentThreadID, "parent")
        XCTAssertEqual(capsule.childThreadID, "child")
    }

    func test_rolloverCapsule_keepsCompleteNewestMessagesAndReportsOmittedOlderMessages() throws {
        let messages = [
            TokenSaverCapsuleMessage(role: "user", text: String(repeating: "old filler ", count: 80)),
            TokenSaverCapsuleMessage(role: "assistant", text: "recent complete decision ABC-RECENT"),
            TokenSaverCapsuleMessage(role: "user", text: "latest complete requirement XYZ-LATEST"),
        ]
        let capsule = try TokenSaverRolloverCapsuleBuilder.build(
            parentThreadID: "parent",
            childThreadID: "child",
            messages: messages,
            maxBytes: 256
        )
        XCTAssertLessThanOrEqual(capsule.text.utf8.count, 256)
        XCTAssertTrue(capsule.text.contains("TRUNCATED: true"))
        XCTAssertTrue(capsule.text.contains("OMITTED_OLDER_MESSAGES: 1"))
        XCTAssertFalse(capsule.text.contains("old filler"))
        XCTAssertTrue(capsule.text.contains("ABC-RECENT"))
        XCTAssertTrue(capsule.text.contains("XYZ-LATEST"))
    }

    func test_rolloverCapsule_oversizedNewestMessageKeepsUtf8SafeTailAndMarker() throws {
        let newestTail = "LATEST-DECISION-🧪"
        let capsule = try TokenSaverRolloverCapsuleBuilder.build(
            parentThreadID: "parent",
            childThreadID: "child",
            messages: [.init(role: "user", text: String(repeating: "old-prefix-", count: 80) + newestTail)],
            maxBytes: 256
        )
        XCTAssertLessThanOrEqual(capsule.text.utf8.count, 256)
        XCTAssertTrue(capsule.text.contains("OVERSIZED_NEWEST_MESSAGE_TAIL"))
        XCTAssertTrue(capsule.text.hasSuffix(newestTail))
        XCTAssertNotNil(capsule.text.data(using: .utf8))
    }

    func test_sessionLearnSelector_enforcesScopeTopKAndByteBudget() {
        let owner = TokenSaverRecoveryScope(workspaceID: "w", projectID: "p", threadID: "t", provider: "grok", attemptID: "a")
        let other = TokenSaverRecoveryScope(workspaceID: "w", projectID: "other", threadID: "t", provider: "grok", attemptID: "a")
        let records = [
            TokenSaverSessionLearnRecord(id: "1", scope: owner, text: "swift compiler actor isolation fix"),
            TokenSaverSessionLearnRecord(id: "2", scope: owner, text: "swift compiler sendable warning"),
            TokenSaverSessionLearnRecord(id: "3", scope: owner, text: "unrelated design note"),
            TokenSaverSessionLearnRecord(id: "leak", scope: other, text: "swift compiler secret")
        ]
        let selected = TokenSaverSessionLearnSelector.select(records: records, scope: owner, query: "swift compiler", topK: 2, byteBudget: 80)
        XCTAssertLessThanOrEqual(selected.count, 2)
        XCTAssertLessThanOrEqual(selected.reduce(0) { $0 + $1.text.utf8.count }, 80)
        XCTAssertFalse(selected.contains { $0.id == "leak" })
    }

    func test_semanticLane_isShadowOnlyProseAndFailsOpenOnAnyGateError() {
        let manifest = TokenSaverModelManifest.approvedFixture()
        let admitted = TokenSaverAcceleratorDecision(admitted: true, reason: "admitted")
        let prose = TokenSaverSemanticShadowOrchestrator.evaluate(
            input: "RemoteCode should preserve the original provider input when uncertain.",
            candidate: "RemoteCode preserves input when uncertain.",
            contentType: .prose,
            language: "en",
            hardwareAvailable: true,
            acceleratorDecision: admitted,
            manifest: manifest,
            classifierSucceeded: true
        )
        XCTAssertEqual(prose.liveOutput, prose.input, "Wave 4 remains shadow-only")
        XCTAssertNotNil(prose.shadowCandidate)

        for protected in TokenSaverSemanticContentType.allCases where protected != .prose {
            let decision = TokenSaverSemanticShadowOrchestrator.evaluate(
                input: "exact bytes",
                candidate: "lossy",
                contentType: protected,
                language: "en",
                hardwareAvailable: true,
                acceleratorDecision: admitted,
                manifest: manifest,
                classifierSucceeded: true
            )
            XCTAssertEqual(decision.liveOutput, "exact bytes")
            XCTAssertNil(decision.shadowCandidate)
        }

        let failedGate = TokenSaverSemanticShadowOrchestrator.evaluate(
            input: "prose original",
            candidate: "candidate",
            contentType: .prose,
            language: "en",
            hardwareAvailable: true,
            acceleratorDecision: admitted,
            manifest: manifest,
            classifierSucceeded: false
        )
        XCTAssertEqual(failedGate.liveOutput, "prose original")
        XCTAssertNil(failedGate.shadowCandidate)

        let resourceBlocked = TokenSaverSemanticShadowOrchestrator.evaluate(
            input: "prose original",
            candidate: "candidate",
            contentType: .prose,
            language: "en",
            hardwareAvailable: true,
            acceleratorDecision: .init(admitted: false, reason: "thermal_serious"),
            manifest: manifest,
            classifierSucceeded: true
        )
        XCTAssertEqual(resourceBlocked.liveOutput, "prose original")
        XCTAssertNil(resourceBlocked.shadowCandidate)
    }

    func test_acceleratorScheduler_isSingleLeaseAndFailsOpenForThermalOrMemoryPressure() async {
        let scheduler = TokenSaverAcceleratorScheduler()
        let healthy = TokenSaverAcceleratorSnapshot(
            hardwareSupported: true,
            thermalState: .nominal,
            availableMemoryBytes: 4_000,
            requiredMemoryBytes: 2_000
        )
        let first = await scheduler.acquire(healthy)
        let busy = await scheduler.acquire(healthy)
        XCTAssertTrue(first.admitted)
        XCTAssertEqual(busy.reason, "accelerator_busy")
        await scheduler.release()
        let thermal = await scheduler.acquire(healthy.replacing(thermalState: .serious))
        let memory = await scheduler.acquire(healthy.replacing(availableMemoryBytes: 1_000))
        XCTAssertEqual(thermal.reason, "thermal_serious")
        XCTAssertEqual(memory.reason, "insufficient_memory")
    }

    func test_modelManifest_blocksMissingSupplyChainApproval() {
        XCTAssertTrue(TokenSaverModelManifest.approvedFixture().isActivatable)
        XCTAssertFalse(TokenSaverModelManifest.approvedFixture().replacing(licenseApproved: false).isActivatable)
        XCTAssertFalse(TokenSaverModelManifest.approvedFixture().replacing(bomApproved: false).isActivatable)
        XCTAssertFalse(TokenSaverModelManifest.approvedFixture().replacing(signatureValid: false).isActivatable)
        XCTAssertFalse(TokenSaverModelManifest.approvedFixture().replacing(checksumValid: false).isActivatable)
    }

    func test_adaptiveEffort_neverOverridesPersistentUserChoice() {
        XCTAssertEqual(
            TokenSaverAdaptiveEffortPolicy.evaluate(taskClass: .mechanical, confidence: 0.99, persistentUserOverride: "high").action,
            .preserveUserOverride
        )
        XCTAssertEqual(
            TokenSaverAdaptiveEffortPolicy.evaluate(taskClass: .mechanical, confidence: 0.99, persistentUserOverride: nil).action,
            .shadowSuggestion
        )
        XCTAssertEqual(
            TokenSaverAdaptiveEffortPolicy.evaluate(taskClass: .reasoning, confidence: 1.0, persistentUserOverride: nil).action,
            .noChange
        )
    }

    func test_imageDedup_isExactSameThreadOnlyAndExplicitResendWins() {
        var registry = TokenSaverImageDedupRegistry()
        let scope = TokenSaverRecoveryScope(workspaceID: "w", projectID: "p", threadID: "t", provider: "codex", attemptID: "a")
        let otherThread = TokenSaverRecoveryScope(workspaceID: "w", projectID: "p", threadID: "other", provider: "codex", attemptID: "a")
        XCTAssertEqual(registry.register(hash: "h", scope: scope, explicitResend: false), .sendOriginal)
        XCTAssertEqual(registry.register(hash: "h", scope: scope, explicitResend: false), .deduplicateExact)
        XCTAssertEqual(registry.register(hash: "h", scope: otherThread, explicitResend: false), .sendOriginal)
        XCTAssertEqual(registry.register(hash: "h", scope: scope, explicitResend: true), .sendOriginal)
    }

    func test_visualLaneRequiresFivePercentMaterialityAndNeverReplacesOriginal() {
        XCTAssertFalse(TokenSaverVisualMaterialityPolicy.evaluate(visualProviderTokens: 49, totalProviderTokens: 1_000).eligibleForExperiment)
        let threshold = TokenSaverVisualMaterialityPolicy.evaluate(visualProviderTokens: 50, totalProviderTokens: 1_000)
        XCTAssertTrue(threshold.eligibleForExperiment)
        XCTAssertFalse(threshold.mayReplaceOriginal)
        XCTAssertEqual(threshold.evidenceLevel, .providerUsage)
    }
}
