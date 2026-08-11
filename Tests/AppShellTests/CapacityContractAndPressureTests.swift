import XCTest
@testable import AppLifecycleSupport
import Foundation

/// S1 contract proofs: versioned capacity manifest, required-metric null fatality,
/// pressure pure transition table, diagnostics allowlist + secret canary.
final class CapacityContractAndPressureTests: XCTestCase {

    // MARK: - Manifest / metrics

    func test_defaultHardcoreManifest_validatesAndEncodesRoundTrip() throws {
        let manifest = CapacityQualificationManifest.defaultHardcoreSwarm()
        try manifest.validate()
        XCTAssertEqual(manifest.workload.roots, 32)
        XCTAssertEqual(manifest.workload.nestedNodes, 64)
        XCTAssertEqual(manifest.estimator.minWarmedSamples, 3)
        XCTAssertTrue(manifest.requiredMetrics.contains(CapacityRequiredMetricKey.appRSSKB.rawValue))
        XCTAssertTrue(manifest.requiredMetrics.contains(CapacityRequiredMetricKey.providerTreeRSSKB.rawValue))
        XCTAssertNotEqual(
            CapacityRequiredMetricKey.appRSSKB.rawValue,
            CapacityRequiredMetricKey.providerTreeRSSKB.rawValue,
            "app RSS and provider-tree RSS must remain separate metrics"
        )

        let data = try manifest.encodePretty()
        let decoded = try CapacityQualificationManifest.decodeAndValidate(from: data)
        XCTAssertEqual(decoded, manifest)
    }

    func test_checkedInManifestJSON_parsesAndValidates() throws {
        let url = locateQualificationManifest()
        let data = try Data(contentsOf: url)
        let manifest = try CapacityQualificationManifest.decodeAndValidate(from: data)
        XCTAssertEqual(manifest.schemaVersion, CapacityQualificationManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.workload.roots, 32)
        XCTAssertEqual(manifest.estimator.minWarmedSamples, 3)
        XCTAssertTrue(manifest.hardwareTier.allSatisfy { $0.physicallyExecuted == false || $0.physicalMemoryBytes > 0 })
    }

    func test_requiredMetricNull_isFatalOnArtifact() throws {
        let manifest = CapacityQualificationManifest.defaultHardcoreSwarm()
        let artifact = try makeValidArtifact(manifest: manifest, nullMetric: CapacityRequiredMetricKey.appRSSKB.rawValue)
        XCTAssertThrowsError(try artifact.validate(against: manifest)) { error in
            XCTAssertEqual(
                error as? CapacityContractError,
                .requiredMetricNull(CapacityRequiredMetricKey.appRSSKB.rawValue)
            )
        }
    }

    func test_artifact_requiresMinWarmedSamplesAndVariance() throws {
        let manifest = CapacityQualificationManifest.defaultHardcoreSwarm()
        let artifact = try makeValidArtifact(manifest: manifest, warmedRuns: 2)
        XCTAssertThrowsError(try artifact.validate(against: manifest))
    }

    func test_artifact_passesWhenAllRequiredPresent() throws {
        let manifest = CapacityQualificationManifest.defaultHardcoreSwarm()
        let artifact = try makeValidArtifact(manifest: manifest)
        try artifact.validate(against: manifest)
    }

    func test_artifact_rejectsManifestIdMismatch() throws {
        let manifest = CapacityQualificationManifest.defaultHardcoreSwarm()
        var artifact = try makeValidArtifact(manifest: manifest)
        artifact.manifestId = "other"
        XCTAssertThrowsError(try artifact.validate(against: manifest))
    }

    // MARK: - Pressure state machine

    func test_pressure_osCritical_escalatesImmediately() {
        var state = PressureGovernorState(level: .normal, epoch: 0, levelEnteredAt: Date(timeIntervalSince1970: 0))
        let t0 = Date(timeIntervalSince1970: 1_000)
        let result = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0,
                osSignal: .critical,
                managedRSSFraction: 0.1,
                isComplete: true
            ),
            thresholds: .default,
            now: t0
        )
        XCTAssertEqual(result.state.level, .critical)
        XCTAssertEqual(result.state.epoch, 1)
        XCTAssertTrue(result.levelChanged)
        XCTAssertFalse(result.emittedActions.isEmpty)
        state = result.state
        // Hold samples: no re-emit
        let hold = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0.addingTimeInterval(1),
                osSignal: .critical,
                managedRSSFraction: 0.95,
                isComplete: true
            ),
            now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(hold.state.level, .critical)
        XCTAssertEqual(hold.state.epoch, 1)
        XCTAssertTrue(hold.emittedActions.isEmpty)
        XCTAssertLessThanOrEqual(hold.state.actionsEmittedThisEpoch, PressureGovernorStateMachine.maxActionsPerEpoch)
    }

    func test_pressure_rssEscalation_requiresTwoCompleteSamplesAtSameTier() {
        let thresholds = PressureThresholds.default
        var state = PressureGovernorState(level: .normal, epoch: 0, levelEnteredAt: Date(timeIntervalSince1970: 0))
        let t0 = Date(timeIntervalSince1970: 2_000)
        let first = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0,
                osSignal: .normal,
                managedRSSFraction: thresholds.warningFraction + 0.01,
                isComplete: true
            ),
            thresholds: thresholds,
            now: t0
        )
        XCTAssertEqual(first.state.level, .normal, "single RSS sample must not escalate")
        XCTAssertEqual(first.state.consecutiveEscalateSamples, 1)
        XCTAssertEqual(first.state.escalateTargetLevel, .warning)
        state = first.state

        // Interrupting with a normal sample resets the streak.
        let interrupt = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0.addingTimeInterval(1),
                osSignal: .normal,
                managedRSSFraction: 0.1,
                isComplete: true
            ),
            thresholds: thresholds,
            now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(interrupt.state.consecutiveEscalateSamples, 0)
        state = interrupt.state

        let a = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0.addingTimeInterval(2),
                osSignal: .normal,
                managedRSSFraction: thresholds.warningFraction + 0.01,
                isComplete: true
            ),
            thresholds: thresholds,
            now: t0.addingTimeInterval(2)
        )
        state = a.state
        let b = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0.addingTimeInterval(3),
                osSignal: .normal,
                managedRSSFraction: thresholds.warningFraction + 0.01,
                isComplete: true
            ),
            thresholds: thresholds,
            now: t0.addingTimeInterval(3)
        )
        XCTAssertEqual(b.state.level, .warning)
        XCTAssertTrue(b.levelChanged)
        XCTAssertEqual(b.emittedActions, PressureGovernorStateMachine.warningActions)
        state = b.state

        // Warning → critical needs two critical-tier samples (not one warning + one critical).
        let c1 = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0.addingTimeInterval(4),
                osSignal: .normal,
                managedRSSFraction: thresholds.criticalFraction + 0.01,
                isComplete: true
            ),
            thresholds: thresholds,
            now: t0.addingTimeInterval(4)
        )
        XCTAssertEqual(c1.state.level, .warning, "single critical sample must not jump from warning")
        state = c1.state
        let c2 = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0.addingTimeInterval(5),
                osSignal: .normal,
                managedRSSFraction: thresholds.criticalFraction + 0.01,
                isComplete: true
            ),
            thresholds: thresholds,
            now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(c2.state.level, .critical)
    }

    func test_pressure_incompleteSample_freezesAndNeverClears() {
        let t0 = Date(timeIntervalSince1970: 3_000)
        var state = PressureGovernorState(level: .warning, epoch: 3, levelEnteredAt: t0.addingTimeInterval(-120))
        let result = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0,
                osSignal: .normal,
                managedRSSFraction: nil,
                isComplete: false
            ),
            now: t0
        )
        XCTAssertEqual(result.state.level, .warning, "incomplete sample must not clear pressure")
        XCTAssertTrue(result.state.frozenAccounting)
        XCTAssertEqual(result.ignoredReason, "incomplete_sample")
        XCTAssertTrue(result.emittedActions.isEmpty)
        state = result.state

        let stale = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0.addingTimeInterval(1),
                osSignal: .normal,
                managedRSSFraction: 0.01,
                isComplete: true,
                isStale: true
            ),
            now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(stale.state.level, .warning)
        XCTAssertEqual(stale.ignoredReason, "stale_sample")
    }

    func test_pressure_recovery_stepsOneLevelAtATime() {
        let thresholds = PressureThresholds.default
        let entered = Date(timeIntervalSince1970: 4_000)
        var state = PressureGovernorState(level: .critical, epoch: 5, levelEnteredAt: entered)

        let base = entered.addingTimeInterval(thresholds.minDwellSeconds + 1)
        // Three samples below critical exit band (0.82) but still at/above warning (0.75).
        let mid = 0.80
        XCTAssertGreaterThanOrEqual(mid, thresholds.warningFraction)
        XCTAssertLessThan(mid, thresholds.criticalFraction - thresholds.exitHysteresisPoints)
        for i in 0..<3 {
            let r = PressureGovernorStateMachine.apply(
                state: state,
                sample: PressureSample(
                    date: base.addingTimeInterval(Double(i)),
                    osSignal: .normal,
                    managedRSSFraction: mid,
                    isComplete: true
                ),
                thresholds: thresholds,
                now: base.addingTimeInterval(Double(i))
            )
            state = r.state
        }
        XCTAssertEqual(state.level, .warning, "critical recovers one step to warning, not normal")
        XCTAssertEqual(state.epoch, 6)

        // Then three samples below warning exit band → normal.
        let low = 0.10
        let base2 = base.addingTimeInterval(thresholds.minDwellSeconds + 10)
        state.levelEnteredAt = base // ensure dwell from new level entry; set entered
        // re-enter dwell from current levelEnteredAt which was set on recover
        for i in 0..<3 {
            let now = state.levelEnteredAt.addingTimeInterval(thresholds.minDwellSeconds + Double(i) + 1)
            let r = PressureGovernorStateMachine.apply(
                state: state,
                sample: PressureSample(
                    date: now,
                    osSignal: .normal,
                    managedRSSFraction: low,
                    isComplete: true
                ),
                thresholds: thresholds,
                now: now
            )
            state = r.state
        }
        XCTAssertEqual(state.level, .normal)
    }

    func test_pressure_actionSet_neverIncludesKillOrScheduleDeferral() {
        let all = Set(PressureActionKind.allCases)
        XCTAssertTrue(all.contains(.neverKillActiveTurn))
        XCTAssertTrue(all.contains(.neverDeferScheduledOccurrence))
        let live = Set(PressureGovernorStateMachine.warningActions)
            .union(PressureGovernorStateMachine.criticalActions)
        XCTAssertFalse(live.contains(.neverKillActiveTurn))
        XCTAssertFalse(live.contains(.neverDeferScheduledOccurrence))
    }

    func test_pressure_pacedRecovery_rateLimited() {
        let t0 = Date(timeIntervalSince1970: 5_000)
        var state = PressureGovernorState(level: .normal, epoch: 1, levelEnteredAt: t0)
        let first = PressureGovernorStateMachine.pacedRecoveryTick(state: state, at: t0)
        XCTAssertEqual(first.emittedActions, [.resumeOptionalWorkUnit])
        state = first.state
        let second = PressureGovernorStateMachine.pacedRecoveryTick(
            state: state,
            at: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(second.ignoredReason, "recovery_rate_limited")
        XCTAssertTrue(second.emittedActions.isEmpty)
    }

    func test_pressure_epochFreshness() {
        let state = PressureGovernorState(level: .warning, epoch: 9)
        XCTAssertTrue(PressureGovernorStateMachine.isEpochFresh(state: state, expectedEpoch: 9))
        XCTAssertFalse(PressureGovernorStateMachine.isEpochFresh(state: state, expectedEpoch: 8))
    }

    // MARK: - Diagnostics allowlist

    func test_diagnosticsAllowlist_stripsSecretCanary() throws {
        let fields = DiagnosticsExportAllowlist.secretCanaryPayload()
        let filtered = DiagnosticsExportAllowlist.filter(fields)
        let keys = Set(filtered.map(\.key))
        XCTAssertTrue(keys.contains("app_rss_kb"))
        XCTAssertTrue(keys.contains("level") || filtered.contains(where: { $0.key == "level" && $0.value == "warning" }))
        XCTAssertFalse(keys.contains("prompt_text"))
        XCTAssertFalse(keys.contains("api_token"))
        // filter drops invalid keys; validate only on pure allowlist fields
        let clean = [
            DiagnosticsExportField(section: .capacityMetrics, key: "app_rss_kb", value: "12345"),
            DiagnosticsExportField(section: .pressureState, key: "level", value: "warning"),
        ]
        let data = try DiagnosticsExportAllowlist.buildExportDocument(
            fields: clean,
            unavailableSections: [.hangWatchdog],
            sessionSalt: Data("session-salt".utf8)
        )
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("sk-secret"))
        XCTAssertFalse(text.contains("[[rc:"))
        XCTAssertFalse(text.contains("prompt_text"))
        XCTAssertTrue(text.contains("unavailable_sections"))
        XCTAssertThrowsError(try DiagnosticsExportAllowlist.validate(fields))
    }

    func test_diagnosticsExport_writes0600() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-diag-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("export.json")
        let data = try DiagnosticsExportAllowlist.buildExportDocument(
            fields: [
                DiagnosticsExportField(section: .pressureState, key: "level", value: "normal")
            ],
            unavailableSections: [],
            sessionSalt: Data("salt".utf8)
        )
        try DiagnosticsExportAllowlist.writeExportFile(data: data, to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    // MARK: - Helpers

    private func makeValidArtifact(
        manifest: CapacityQualificationManifest,
        nullMetric: String? = nil,
        warmedRuns: Int = 3
    ) throws -> CapacityQualificationArtifact {
        let samples = manifest.requiredMetrics.map { name in
            CapacityMetricSample(
                name: name,
                value: name == nullMetric ? nil : 1,
                unit: "unit"
            )
        }
        let runs = (0..<warmedRuns).map { idx -> CapacityWarmedRunObservation in
            let metrics = Dictionary(uniqueKeysWithValues: manifest.requiredMetrics.map { name -> (String, Double) in
                // values 1.00, 1.01, 1.02 so variance is deterministic
                (name, 1.0 + Double(idx) * 0.01)
            })
            return CapacityWarmedRunObservation(runIndex: idx, metrics: metrics)
        }
        var variance: [String: Double] = [:]
        for key in manifest.requiredMetrics {
            let values = runs.map { $0.metrics[key]! }
            let lo = values.min()!
            let hi = values.max()!
            variance[key] = hi == 0 ? 0 : (hi - lo) / hi
        }
        let digest = try manifest.contentDigest()
        return CapacityQualificationArtifact(
            manifestId: manifest.id,
            samples: samples,
            warmedSampleCount: warmedRuns,
            physicallyExecutedTier: [],
            createdAtISO8601: "2026-08-11T00:00:00Z",
            manifestDigest: digest,
            warmedRuns: runs,
            metricVarianceMax: variance
        )
    }

    private func locateQualificationManifest() -> URL {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("docs/capacity/qualification-manifest.v1.json"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("docs/capacity/qualification-manifest.v1.json"),
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            return url
        }
        XCTFail("qualification-manifest.v1.json not found; cwd=\(fm.currentDirectoryPath)")
        return candidates[0]
    }
}
