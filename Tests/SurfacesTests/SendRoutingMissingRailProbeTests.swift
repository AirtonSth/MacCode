import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// WHY: send/queue compiled the 26-column agent_threads row plus routing JSON
/// when the painted rail did not already hold the thread, just to copy
/// effectiveRoutingConfiguration.
@MainActor
final class SendRoutingMissingRailProbeTests: XCTestCase {
    private func makeVM() throws -> (AgentAppViewModel, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-send-routing-miss-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo
        )
        return (vm, threadRepo)
    }

    private func fatThread(title: String, mode: AgentRoutingMode) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: mode,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        return thread
    }

    func test_routingConfigurationForSend_sourceUsesRoutingProbeOffRail() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func routingConfigurationForSend(threadId:"))
        let end = try XCTUnwrap(source.range(of: "func routingConfigurationForSendForTesting(threadId:"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.routingConfiguration(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_missingRail_usesRoutingProbeWithoutDurableGet() throws {
        let (vm, threadRepo) = try makeVM()
        let auto = fatThread(title: "off-rail", mode: .auto)
        try threadRepo.upsert(auto)
        XCTAssertFalse(vm.threads.contains(where: { $0.id == auto.id }))
        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.routingConfigurationProbeCountForTesting
        let routing = vm.routingConfigurationForSendForTesting(threadId: auto.id)
        XCTAssertEqual(routing.mode, .auto)
        XCTAssertEqual(threadRepo.routingConfigurationProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        let missing = AgentThreadID()
        let fallback = vm.routingConfigurationForSendForTesting(threadId: missing)
        XCTAssertEqual(fallback.mode, .manual)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_routingConfigurationProbe_fasterThanDurableGet() throws {
        let (_, threadRepo) = try makeVM()
        let thread = fatThread(title: "bench", mode: .manual)
        try threadRepo.upsert(thread)
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
            _ = try threadRepo.routingConfiguration(of: thread.id)
            _ = try threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.routingConfiguration(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] send-routing-miss routingConfiguration_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "routingConfiguration probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
