import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence
import SocketServer

/// WHY: bot-peer admission used to full-get 26 columns + routing JSON just
/// to learn whether the calling Agent thread still exists.
@MainActor
final class BotPeerCallerStatusProbeTests: XCTestCase {
    private func makeRouter(_ label: String) throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    func test_listBotPeers_missingThread_usesStatusProbeWithoutDurableGet() throws {
        let (ctx, router) = try makeRouter("bot-peer-presence-missing")
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.statusProbeCountForTesting
        XCTAssertThrowsError(
            try router.listBotPeers(callerThread: AgentThreadID(), callerRun: AgentRunID())
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32004)
        }
        XCTAssertEqual(
            ctx.threadRepo.statusProbeCountForTesting,
            probesBefore + 1,
            "missing-thread bot-peer admission must probe status once"
        )
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "missing-thread bot-peer admission must not compile a full 26-column get"
        )
    }

    func test_validatedBotPeerCaller_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func validatedBotPeerCaller("))
        let body = String(source[range.lowerBound...].prefix(1200))
        XCTAssertTrue(body.contains("threadRepo.status(of: threadID)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadID)"))
    }

    func test_statusProbe_fasterThanDurableGet() throws {
        let (ctx, _) = try makeRouter("bot-peer-presence-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
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
            "[perf-proof] bot-peer-presence status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
