import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: four Token Saver paths still compiled 26 columns + routing JSON
/// after admission already probed identity, just for workspace_id + project_id.
@MainActor
final class TokenSaverLeftoverIdentityProbeTests: XCTestCase {
    func test_leftoverTokenSaverPaths_sourceUsesIdentityProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        func body(_ start: String, _ end: String) throws -> String {
            let startRange = try XCTUnwrap(source.range(of: start))
            let endRange = try XCTUnwrap(source.range(of: end, range: startRange.lowerBound..<source.endIndex))
            return String(source[startRange.lowerBound..<endRange.lowerBound])
        }
        let slices = try [
            body("func recordSessionLearnFromRun(", "private func tokenSaverSessionLearnPrompt("),
            body("private func tokenSaverSessionLearnPrompt(", "public func tokenSaverRolloverAdmission("),
            body("public func tokenSaverRolloverAdmission(", "public func createTokenSaverRollover("),
            body("private func recordTokenSaverPreparedObservation(", "private func appendShadowPolicyEvent("),
        ]
        for slice in slices {
            XCTAssertTrue(slice.contains("threadRepo.identity(of:"))
            XCTAssertFalse(slice.contains("threadRepo.get(id:"))
        }
    }

    func test_recordSessionLearnFromRun_usesIdentityProbeWithoutDurableGet() throws {
        let ctx = try makeContext("learn-run")
        let thread = try insertScopedThread(ctx)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .failed,
            errorMessage: "cannot find symbol Foo"
        )
        try ctx.runRepo.upsert(run)
        try upsertLane(ctx, projectID: thread.projectId!.value.uuidString, lane: "session_learn")
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.identityProbeCountForTesting
        ctx.recordSessionLearnFromRun(runId: run.id, status: .failed)
        XCTAssertGreaterThan(ctx.threadRepo.identityProbeCountForTesting, probesBefore)
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "SessionLearn finish must not compile a full 26-column get just for workspace/project"
        )
        let scope = TokenSaverSessionLearnScope(
            workspaceID: thread.workspaceId!.value.uuidString,
            projectID: thread.projectId!.value.uuidString,
            threadID: thread.id.value.uuidString,
            provider: AgentProvider.codex.rawValue
        )
        let records = try ctx.tokenSaverSessionLearnRepo.topK(scope: scope, byteBudget: 1_024, limit: 5)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].text.contains("cannot find symbol"))
    }

    func test_tokenSaverRolloverAdmission_usesIdentityProbeWithoutDurableGet() throws {
        let ctx = try makeContext("rollover")
        let parent = try insertScopedThread(ctx, title: "admission")
        try upsertLane(ctx, projectID: parent.projectId!.value.uuidString, lane: "rollover_capsule")
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.identityProbeCountForTesting
        let decision = ctx.tokenSaverRolloverAdmission(parentThreadID: parent.id)
        XCTAssertEqual(decision, .init(allowed: true, reason: "admitted"))
        XCTAssertGreaterThan(ctx.threadRepo.identityProbeCountForTesting, probesBefore)
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "rollover admission must not compile a full 26-column get just for workspace/project"
        )
    }

    func test_sessionLearnPrompt_usesIdentityProbeWithoutDurableGet() async throws {
        let ctx = try makeContext("learn-prompt")
        SettingsStore(db: ctx.db).update { $0.sessionLearnEnabled = true }
        let thread = try insertScopedThread(ctx, title: "learn")
        try upsertLane(ctx, projectID: thread.projectId!.value.uuidString, lane: "session_learn")
        let scope = TokenSaverSessionLearnScope(
            workspaceID: thread.workspaceId!.value.uuidString,
            projectID: thread.projectId!.value.uuidString,
            threadID: thread.id.value.uuidString,
            provider: AgentProvider.codex.rawValue
        )
        try ctx.tokenSaverSessionLearnRepo.save(
            text: "preserve browser parity",
            scope: scope,
            attemptID: "prior"
        )
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.identityProbeCountForTesting
        let prompt = "Check browser parity."
        let compressed = await ctx.coordinator.promptCompressor?(prompt, .codex, thread.id, AgentRunID())
        let promoted = try XCTUnwrap(compressed)
        XCTAssertTrue(promoted.contains("preserve browser parity"))
        XCTAssertGreaterThan(ctx.threadRepo.identityProbeCountForTesting, probesBefore)
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "SessionLearn prompt must not compile a full 26-column get just for workspace/project"
        )
    }

    func test_preparedObservation_usesIdentityProbeWithoutDurableGet() async throws {
        let ctx = try makeContext("prepared")
        let thread = try insertScopedThread(ctx, title: "obs")
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "fake-model", status: .running)
        try ctx.runRepo.upsert(run)
        for lane in ["measurement", "semantic_prose", "adaptive_effort", "visual_artifact", "provider_native", "session_learn"] {
            try upsertLane(ctx, projectID: thread.projectId!.value.uuidString, lane: lane, state: "shadow_only")
        }
        let request = AgentRunRequest(
            runId: run.id,
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: "/tmp",
            prompt: "Rename the helper"
        )
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.identityProbeCountForTesting
        await ctx.coordinator.onRunPrepared?(request, request.prompt)
        XCTAssertGreaterThan(ctx.threadRepo.identityProbeCountForTesting, probesBefore)
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "prepared observation must not compile a full 26-column get just for workspace/project"
        )
        let events = try ctx.tokenSaverAttemptLedger.events(attemptID: run.id.value.uuidString)
        XCTAssertTrue(events.map(\.kind).contains("treatment_join"))
    }

    func test_identityProbe_matchesStoredScopeWithoutDurableGet() throws {
        let ctx = try makeContext("match")
        let thread = try insertScopedThread(ctx)
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.identityProbeCountForTesting
        let identity = try XCTUnwrap(ctx.threadRepo.identity(of: thread.id))
        XCTAssertEqual(identity.workspaceId, thread.workspaceId)
        XCTAssertEqual(identity.projectId, thread.projectId)
        XCTAssertEqual(ctx.threadRepo.identityProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try ctx.threadRepo.identity(of: AgentThreadID()))
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_identityProbe_fasterThanDurableGet() throws {
        let ctx = try makeContext("bench")
        let thread = try insertScopedThread(ctx, title: "bench")
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try ctx.threadRepo.identity(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.identity(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] leftover-identity identity_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "identity probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-ts-leftover-identity-\(label)-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        SettingsStore(db: ctx.db).update {
            $0.tokenSaverEnabled = true
            $0.sessionLearnEnabled = true
        }
        return ctx
    }

    private func insertScopedThread(_ ctx: AppContext, title: String = "identity") throws -> AgentThread {
        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: title,
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        try ctx.threadRepo.upsert(thread)
        return thread
    }

    private func upsertLane(
        _ ctx: AppContext,
        projectID: String,
        lane: String,
        state: String = "promoted"
    ) throws {
        try ctx.tokenSaverLaneStateRepo.upsert(.init(
            projectID: projectID,
            lane: lane,
            state: state,
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "Operations Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "leftover-identity"
        ))
    }
}
