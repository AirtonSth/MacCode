import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// WHY: color swatch compiled the 26-column row plus routing JSON after the
/// targeted color UPDATE, even though reloadThreads already refreshes the rail.
@MainActor
final class SetThreadColorSkipGetTests: XCTestCase {
    func test_setThreadColor_sourceSkipsDurableGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func setThreadColor("))
        let end = try XCTUnwrap(source.range(of: "public func setThreadPinned("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.setColor("))
        XCTAssertFalse(body.contains("threadRepo.get("))
    }

    func test_setThreadColor_doesNotDurableGetAndPreservesChrome() throws {
        let (vm, threadRepo, root) = try makeVM()
        defer { try? FileManager.default.removeItem(atPath: root) }
        vm.createThread(title: "keep-title")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        try threadRepo.setPinned(id: tid, pinned: true)
        try threadRepo.updateStatus(id: tid, status: .running, hasUnread: true)
        var stored = try XCTUnwrap(try threadRepo.get(id: tid))
        let digest = String(repeating: "r", count: 32 * 1024)
        stored.routingConfiguration = AgentRoutingConfiguration(
            mode: stored.effectiveRoutingConfiguration.mode,
            manualSelection: stored.effectiveRoutingConfiguration.manualSelection,
            manualProviderInstanceId: stored.effectiveRoutingConfiguration.manualProviderInstanceId,
            eligibleProviders: stored.effectiveRoutingConfiguration.eligibleProviders,
            policyDigest: digest,
            revision: stored.effectiveRoutingConfiguration.revision,
            updatedAt: stored.effectiveRoutingConfiguration.updatedAt
        )
        try threadRepo.upsert(stored)
        let getsBefore = threadRepo.durableGetCountForTesting
        let colorsBefore = threadRepo.setColorCountForTesting

        vm.setThreadColor(tid, "purple")

        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(threadRepo.setColorCountForTesting, colorsBefore + 1)
        XCTAssertEqual(vm.threads.first(where: { $0.id == tid })?.color, "purple")
        let roundTrip = try XCTUnwrap(try threadRepo.get(id: tid))
        XCTAssertEqual(roundTrip.title, "keep-title")
        XCTAssertEqual(roundTrip.color, "purple")
        XCTAssertTrue(roundTrip.pinned)
        XCTAssertTrue(roundTrip.hasUnread)
        XCTAssertEqual(roundTrip.status, .running)
        XCTAssertEqual(roundTrip.routingConfiguration?.policyDigest, digest)

        vm.setThreadColor(tid, "")
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore + 1)
        XCTAssertNil(try threadRepo.get(id: tid)?.color)
    }

    func test_setColor_fasterThanSetColorPlusGet() throws {
        let repo = try makeRepo()
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024),
            revision: 1
        )
        try repo.upsert(thread)
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
            try repo.setColor(id: thread.id, color: "purple")
            _ = try repo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for n in 0..<iterations {
                    try repo.setColor(id: thread.id, color: n % 2 == 0 ? "purple" : "blue")
                }
            })
            getSamples.append(try timeMs {
                for n in 0..<iterations {
                    try repo.setColor(id: thread.id, color: n % 2 == 0 ? "purple" : "blue")
                    _ = try repo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        let line = String(
            format: "probe=[%@] | get=[%@]\nmedian_before_ms=%@ median_after_ms=%@ improvement_pct=%.2f\n",
            probeSamples.map { String($0) }.joined(separator: ", "),
            getSamples.map { String($0) }.joined(separator: ", "),
            String(getMed),
            String(probeMed),
            improvement
        )
        NSLog("[perf-proof] color-skip-trailing-get %@", line)
        let measured = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("goal/color-skip-trailing-get/measured.txt")
        try? FileManager.default.createDirectory(
            at: measured.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? line.write(to: measured, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "setColor must beat setColor+get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepo() throws -> AgentThreadRepository {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return AgentThreadRepository(db: db)
    }

    private func makeVM() throws -> (AgentAppViewModel, AgentThreadRepository, String) {
        let root = NSTemporaryDirectory() + "rc2-color-skip-get-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
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
            workspaceID: WorkspaceID(), cwd: root,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo
        )
        return (vm, threadRepo, root)
    }
}
