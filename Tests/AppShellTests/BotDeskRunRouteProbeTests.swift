import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// WHY: bot-desk host send and peer @mention compiled the 10-column
/// agent_runs row including error_message just to freeze provider/model.
@MainActor
final class BotDeskRunRouteProbeTests: XCTestCase {
    func test_botDeskCallSites_useRouteProbeNotGet() throws {
        let router = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let sendStart = try XCTUnwrap(router.range(of: "public func sendHostBot("))
        let sendEnd = try XCTUnwrap(router.range(of: "public func createHostBotThread("))
        let sendBody = String(router[sendStart.lowerBound..<sendEnd.lowerBound])
        XCTAssertTrue(sendBody.contains("runRepo.route(of: callerRun)"))
        XCTAssertFalse(sendBody.contains("runRepo.get(id: callerRun)"))

        let bots = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let mentionStart = try XCTUnwrap(bots.range(of: "func submitAgentAppMention("))
        let mentionEnd = try XCTUnwrap(bots.range(of: "func askPeerFromActiveProvider("))
        let mentionBody = String(bots[mentionStart.lowerBound..<mentionEnd.lowerBound])
        XCTAssertTrue(mentionBody.contains("runRepo.route(of: hostRunID)"))
        XCTAssertFalse(mentionBody.contains("runRepo.get(id: hostRunID)"))
    }

    func test_routeProbe_matchesProviderRouteWithoutDurableGet() throws {
        let ctx = try makeContext("match")
        let thread = AgentThread(title: "desk", provider: .claude, model: "keep-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            providerInstanceId: "claude-live",
            model: "keep-model",
            status: .running,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let probesBefore = ctx.runRepo.routeProbeCountForTesting
        let route = try XCTUnwrap(try ctx.runRepo.route(of: run.id))
        XCTAssertEqual(route.threadId, thread.id)
        XCTAssertEqual(route.provider, .claude)
        XCTAssertEqual(route.providerInstanceId, "claude-live")
        XCTAssertEqual(route.model, "keep-model")
        XCTAssertEqual(ctx.runRepo.routeProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try ctx.runRepo.route(of: AgentRunID()))
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_routeProbe_fasterThanDurableGet() throws {
        let ctx = try makeContext("bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
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
            _ = try ctx.runRepo.route(of: run.id)
            _ = try ctx.runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.runRepo.route(of: run.id)
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
            "[perf-proof] bot-desk-run-route route_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "route probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-bot-desk-route-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
