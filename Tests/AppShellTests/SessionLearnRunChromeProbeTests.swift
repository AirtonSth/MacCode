import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: recordSessionLearnFromRun compiled the 10-column agent_runs row
/// (including error_message) on every SessionLearn-enabled finish just to
/// recover thread_id, then often bailed before using the blob.
@MainActor
final class SessionLearnRunChromeProbeTests: XCTestCase {
    func test_recordSessionLearnFromRun_sourceUsesRunChromeProbes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "func recordSessionLearnFromRun("))
        let end = try XCTUnwrap(source.range(of: "private func tokenSaverSessionLearnPrompt("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("runRepo.threadId(of: runId)"))
        XCTAssertTrue(body.contains("runRepo.errorMessage(of: runId)"))
        XCTAssertTrue(body.contains("runRepo.provider(of: runId)"))
        XCTAssertFalse(body.contains("runRepo.get(id: runId)"))
    }

    func test_failedSave_usesProbesWithoutDurableGet() throws {
        let ctx = try makeContext("learn-fail")
        let thread = try insertScopedThread(ctx)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "fake-model",
            status: .failed,
            errorMessage: "cannot find symbol Foo"
        )
        try ctx.runRepo.upsert(run)
        try upsertLane(ctx, projectID: thread.projectId!.value.uuidString)
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let threadBefore = ctx.runRepo.threadIdProbeCountForTesting
        let errorBefore = ctx.runRepo.errorMessageProbeCountForTesting
        let providerBefore = ctx.runRepo.providerProbeCountForTesting
        ctx.recordSessionLearnFromRun(runId: run.id, status: .failed)
        XCTAssertGreaterThan(ctx.runRepo.threadIdProbeCountForTesting, threadBefore)
        XCTAssertGreaterThan(ctx.runRepo.errorMessageProbeCountForTesting, errorBefore)
        XCTAssertGreaterThan(ctx.runRepo.providerProbeCountForTesting, providerBefore)
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
        let scope = TokenSaverSessionLearnScope(
            workspaceID: thread.workspaceId!.value.uuidString,
            projectID: thread.projectId!.value.uuidString,
            threadID: thread.id.value.uuidString,
            provider: AgentProvider.grok.rawValue
        )
        let records = try ctx.tokenSaverSessionLearnRepo.topK(scope: scope, byteBudget: 1_024, limit: 5)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].text.contains("cannot find symbol"))
    }

    func test_completedCheapPath_skipsErrorMessageAndDurableGet() throws {
        let ctx = try makeContext("learn-ok")
        let thread = try insertScopedThread(ctx)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .completed,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
        try upsertLane(ctx, projectID: thread.projectId!.value.uuidString)
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let errorBefore = ctx.runRepo.errorMessageProbeCountForTesting
        ctx.recordSessionLearnFromRun(runId: run.id, status: .completed)
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(
            ctx.runRepo.errorMessageProbeCountForTesting,
            errorBefore,
            "completed cheap SessionLearn must not read error_message"
        )
    }

    func test_threadIdProbe_fasterThanDurableGet() throws {
        let ctx = try makeContext("bench")
        let thread = try insertScopedThread(ctx, title: "bench")
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .completed,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
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
            _ = try ctx.runRepo.threadId(of: run.id)
            _ = try ctx.runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.runRepo.threadId(of: run.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.runRepo.get(id: run.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] session-learn threadId_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "threadId probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-session-learn-chrome-\(label)-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        SettingsStore(db: ctx.db).update {
            $0.tokenSaverEnabled = true
            $0.sessionLearnEnabled = true
        }
        return ctx
    }

    private func insertScopedThread(_ ctx: AppContext, title: String = "learn") throws -> AgentThread {
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

    private func upsertLane(_ ctx: AppContext, projectID: String) throws {
        try ctx.tokenSaverLaneStateRepo.upsert(.init(
            projectID: projectID,
            lane: "session_learn",
            state: "promoted",
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
            scorecardID: "session-learn-chrome"
        ))
    }
}
