import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: Token Saver run-id observation/admission compiled the 10-column
/// agent_runs row (including error_message) just to recover thread_id.
@MainActor
final class TokenSaverRunThreadIdProbeTests: XCTestCase {
    func test_runIdHelpers_sourceUsesThreadIdProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let obsStart = try XCTUnwrap(source.range(of: "private func tokenSaverProjectObservation(runId: AgentRunID"))
        let admStart = try XCTUnwrap(source.range(of: "private func tokenSaverProjectAdmission(\n        runId: AgentRunID"))
        let end = try XCTUnwrap(source.range(of: "/// task-08:", range: admStart.lowerBound..<source.endIndex))
        let obs = String(source[obsStart.lowerBound..<admStart.lowerBound])
        let adm = String(source[admStart.lowerBound..<end.lowerBound])
        for body in [obs, adm] {
            XCTAssertTrue(body.contains("runRepo.threadId(of: runId)"))
            XCTAssertFalse(body.contains("runRepo.get(id: runId)"))
        }
    }

    func test_missingRun_usesThreadIdProbeWithoutDurableGet() throws {
        let ctx = try makeContext("missing")
        SettingsStore(db: ctx.db).update {
            $0.tokenSaverEnabled = true
            $0.sessionLearnEnabled = true
        }
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let probesBefore = ctx.runRepo.threadIdProbeCountForTesting
        ctx.recordSessionLearnFromRun(runId: AgentRunID(), status: .failed)
        XCTAssertEqual(ctx.runRepo.threadIdProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(
            ctx.runRepo.durableGetCountForTesting,
            getsBefore,
            "missing-run Token Saver lookup must not compile a full 10-column get"
        )
    }

    func test_threadIdProbe_matchesStoredThreadWithoutDurableGet() throws {
        let ctx = try makeContext("match")
        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "learn",
            provider: .codex,
            model: "fake-model"
        )
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .failed,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let probesBefore = ctx.runRepo.threadIdProbeCountForTesting
        XCTAssertEqual(try ctx.runRepo.threadId(of: run.id), thread.id)
        XCTAssertEqual(ctx.runRepo.threadIdProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try ctx.runRepo.threadId(of: AgentRunID()))
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_threadIdProbe_fasterThanDurableGet() throws {
        let ctx = try makeContext("bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .failed,
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
            "[perf-proof] token-saver-run threadId_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
        let tmp = NSTemporaryDirectory() + "rc2-ts-run-thread-id-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
