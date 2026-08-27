import XCTest
@testable import AppShell
@testable import AgentRuntime
@testable import SocketServer
import CoreModel
import Persistence

/// WHY: JSON-RPC/iOS Continue used to full-get 26 columns + routing JSON
/// just to refuse a durable `.running` thread as already active.
@MainActor
final class ContinueAgentRunStatusProbeTests: XCTestCase {
    func test_continueAgentRun_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "public func continueAgentRun(thread: AgentThreadID)"))
        let body = String(source[range.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("threadRepo.status(of: thread)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: thread)"))
    }

    func test_continueAgentRun_runningThread_usesStatusProbeWithoutDurableGet() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-continue-status-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        var thread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        thread.status = .running
        try ctx.threadRepo.upsert(thread)
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.statusProbeCountForTesting
        do {
            _ = try await router.continueAgentRun(thread: thread.id)
            XCTFail("Continue must reject a durable running thread")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("active run"))
            XCTAssertEqual(error.code, -32000)
        }
        XCTAssertEqual(
            ctx.threadRepo.statusProbeCountForTesting,
            probesBefore + 1,
            "Continue already-active guard must probe status once"
        )
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "Continue must not compile a full 26-column get just to read status"
        )
    }

    func test_statusProbe_fasterThanDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-continue-status-bench-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.status = .running
        try ctx.threadRepo.upsert(thread)
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
            _ = try ctx.threadRepo.status(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.status(of: thread.id)
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
            "[perf-proof] continue-status status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
