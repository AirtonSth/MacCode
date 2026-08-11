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
        // No hardware tier is published without physical execution evidence.
        XCTAssertTrue(manifest.hardwareTier.allSatisfy { $0.physicallyExecuted == false || $0.physicalMemoryBytes > 0 })
    }

    func test_requiredMetricNull_isFatalOnArtifact() throws {
        let manifest = CapacityQualificationManifest.defaultHardcoreSwarm()
        let samples = manifest.requiredMetrics.map { name in
            CapacityMetricSample(
                name: name,
                value: name == CapacityRequiredMetricKey.appRSSKB.rawValue ? nil : 1,
                unit: "x"
            )
        }
        let artifact = CapacityQualificationArtifact(
            manifestId: manifest.id,
            samples: samples,
            warmedSampleCount: 3,
            physicallyExecutedTier: [],
            createdAtISO8601: "2026-08-11T00:00:00Z"
        )
        XCTAssertThrowsError(try artifact.validate(against: manifest)) { error in
            XCTAssertEqual(
                error as? CapacityContractError,
                .requiredMetricNull(CapacityRequiredMetricKey.appRSSKB.rawValue)
            )
        }
    }

    func test_artifact_requiresMinWarmedSamples() throws {
        let manifest = CapacityQualificationManifest.defaultHardcoreSwarm()
        let samples = manifest.requiredMetrics.map {
            CapacityMetricSample(name: $0, value: 1, unit: "x")
        }
        let artifact = CapacityQualificationArtifact(
            manifestId: manifest.id,
            samples: samples,
            warmedSampleCount: 2,
            physicallyExecutedTier: [],
            createdAtISO8601: "2026-08-11T00:00:00Z"
        )
        XCTAssertThrowsError(try artifact.validate(against: manifest))
    }

    func test_artifact_passesWhenAllRequiredPresent() throws {
        let manifest = CapacityQualificationManifest.defaultHardcoreSwarm()
        let samples = manifest.requiredMetrics.map {
            CapacityMetricSample(name: $0, value: 1, unit: "x")
        }
        let artifact = CapacityQualificationArtifact(
            manifestId: manifest.id,
            samples: samples,
            warmedSampleCount: 3,
            physicallyExecutedTier: [],
            createdAtISO8601: "2026-08-11T00:00:00Z"
        )
        try artifact.validate(against: manifest)
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
        XCTAssertFalse(result.emittedActions.contains(.neverKillActiveTurn))
        state = result.state
        // Idempotent second sample: no action-count inflation with same key path after hold.
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
    }

    func test_pressure_rssEscalation_requiresTwoCompleteSamples() {
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
        state = first.state

        let second = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: t0.addingTimeInterval(5),
                osSignal: .normal,
                managedRSSFraction: thresholds.warningFraction + 0.01,
                isComplete: true
            ),
            thresholds: thresholds,
            now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(second.state.level, .warning)
        XCTAssertTrue(second.levelChanged)
        XCTAssertEqual(second.emittedActions, PressureGovernorStateMachine.warningActions)
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

    func test_pressure_recovery_requiresDwellHysteresisAndThreeSamples() {
        let thresholds = PressureThresholds.default
        let entered = Date(timeIntervalSince1970: 4_000)
        var state = PressureGovernorState(level: .warning, epoch: 5, levelEnteredAt: entered)

        // Too early (no dwell): no recovery.
        let early = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: entered.addingTimeInterval(10),
                osSignal: .normal,
                managedRSSFraction: 0.10,
                isComplete: true
            ),
            thresholds: thresholds,
            now: entered.addingTimeInterval(10)
        )
        XCTAssertEqual(early.state.level, .warning)
        XCTAssertEqual(early.state.consecutiveRecoverSamples, 0)

        // After dwell but need 3 samples below threshold-8pp.
        let exitBand = thresholds.warningFraction - thresholds.exitHysteresisPoints
        XCTAssertLessThan(0.10, exitBand)
        let base = entered.addingTimeInterval(thresholds.minDwellSeconds + 1)
        for i in 0..<2 {
            let r = PressureGovernorStateMachine.apply(
                state: state,
                sample: PressureSample(
                    date: base.addingTimeInterval(Double(i)),
                    osSignal: .normal,
                    managedRSSFraction: 0.10,
                    isComplete: true
                ),
                thresholds: thresholds,
                now: base.addingTimeInterval(Double(i))
            )
            state = r.state
            XCTAssertEqual(state.level, .warning)
        }
        let third = PressureGovernorStateMachine.apply(
            state: state,
            sample: PressureSample(
                date: base.addingTimeInterval(2),
                osSignal: .normal,
                managedRSSFraction: 0.10,
                isComplete: true
            ),
            thresholds: thresholds,
            now: base.addingTimeInterval(2)
        )
        XCTAssertEqual(third.state.level, .normal)
        XCTAssertTrue(third.levelChanged)
        XCTAssertEqual(third.state.epoch, 6)
    }

    func test_pressure_actionSet_neverIncludesKillOrScheduleDeferral() {
        let all = Set(PressureActionKind.allCases)
        XCTAssertTrue(all.contains(.neverKillActiveTurn))
        XCTAssertTrue(all.contains(.neverDeferScheduledOccurrence))
        let live = Set(PressureGovernorStateMachine.warningActions)
            .union(PressureGovernorStateMachine.criticalActions)
        XCTAssertFalse(live.contains(.neverKillActiveTurn))
        XCTAssertFalse(live.contains(.neverDeferScheduledOccurrence))
        XCTAssertFalse(live.contains(where: { $0.rawValue.lowercased().contains("kill") }))
        XCTAssertFalse(live.contains(where: { $0.rawValue.lowercased().contains("defer") && $0 != .deferMaintenancePrune }))
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
        XCTAssertTrue(keys.contains("level"))
        XCTAssertFalse(keys.contains("prompt_text"))
        XCTAssertFalse(keys.contains("api_token"))
        XCTAssertFalse(keys.contains("cwd_path"))
        XCTAssertFalse(keys.contains("tool_handle"))
        XCTAssertFalse(keys.contains("raw_error"))

        let data = try DiagnosticsExportAllowlist.buildExportDocument(
            fields: fields,
            unavailableSections: [.hangWatchdog],
            sessionSalt: Data("session-salt".utf8)
        )
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("sk-secret"))
        XCTAssertFalse(text.contains("[[rc:"))
        XCTAssertFalse(text.contains("prompt_text"))
        XCTAssertTrue(text.contains("unavailable_sections"))
        XCTAssertTrue(text.contains("hangWatchdog") || text.contains("hang_watchdog") || text.contains("hangWatchdog") || text.contains("\"hangWatchdog\""))
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

    private func locateQualificationManifest() -> URL {
        // Prefer source-tree docs path relative to this test file / package root.
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("docs/capacity/qualification-manifest.v1.json"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // CapacityContractAndPressureTests.swift
                .deletingLastPathComponent() // AppShellTests
                .deletingLastPathComponent() // Tests
                .appendingPathComponent("docs/capacity/qualification-manifest.v1.json"),
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            return url
        }
        XCTFail("qualification-manifest.v1.json not found; cwd=\(fm.currentDirectoryPath)")
        return candidates[0]
    }
}
