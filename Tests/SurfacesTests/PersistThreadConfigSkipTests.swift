import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// WHY: composer send compiled the 26-column agent_threads row plus routing
/// JSON then upserted (bumping routing revision) even when the painted rail
/// already held the picker/permission/run-as-user persist would write.
@MainActor
final class PersistThreadConfigSkipTests: XCTestCase {
    func test_persistThreadConfig_sourceSkipsGetWhenPaintedMatches() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func persistThreadConfig() -> Bool {"))
        let end = try XCTUnwrap(source.range(of: "public func setAutoModelRoutingEnabled("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("paintedThreadMatchesPersistedConfig"))
        let skip = try XCTUnwrap(body.range(of: "paintedThreadMatchesPersistedConfig"))
        let get = try XCTUnwrap(body.range(of: "threadRepo.get(id: id)"))
        XCTAssertLessThan(skip.lowerBound, get.lowerBound)
    }

    func test_persistThreadConfig_matchingPaintedSkipsDurableGetAndStillWritesOnChange() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "persist-skip")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertTrue(vm.threads.contains(where: { $0.id == tid }))
        let getsBefore = threadRepo.durableGetCountForTesting
        XCTAssertTrue(vm.persistThreadConfig())
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "matching painted config must not compile a 26-column get"
        )
        let stored = try XCTUnwrap(try threadRepo.get(id: tid))
        let digest = stored.routingConfiguration?.policyDigest
        let revision = stored.routingConfiguration?.revision
        let pickersBefore = threadRepo.setPickerConfigCountForTesting
        let routingWritesBefore = threadRepo.setRoutingConfigurationCountForTesting
        vm.model = "changed-model-must-write"
        XCTAssertTrue(vm.persistThreadConfig())
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore + 1,
            "picker mutation must not compile a 26-column get"
        )
        XCTAssertEqual(threadRepo.setPickerConfigCountForTesting, pickersBefore + 1)
        XCTAssertEqual(threadRepo.setRoutingConfigurationCountForTesting, routingWritesBefore + 1)
        let updated = try XCTUnwrap(try threadRepo.get(id: tid))
        XCTAssertEqual(updated.model, "changed-model-must-write")
        XCTAssertEqual(updated.routingConfiguration?.policyDigest, digest)
        XCTAssertEqual(updated.routingConfiguration?.revision, (revision ?? 0) + 1)
    }

    func test_persistThreadConfig_skipFasterThanGetAndUpsert() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "persist-bench")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        var stored = try XCTUnwrap(try threadRepo.get(id: tid))
        stored.routingConfiguration = AgentRoutingConfiguration(
            mode: stored.effectiveRoutingConfiguration.mode,
            manualSelection: stored.effectiveRoutingConfiguration.manualSelection,
            manualProviderInstanceId: stored.effectiveRoutingConfiguration.manualProviderInstanceId,
            eligibleProviders: stored.effectiveRoutingConfiguration.eligibleProviders,
            policyDigest: String(repeating: "r", count: 32 * 1024),
            revision: stored.effectiveRoutingConfiguration.revision,
            updatedAt: stored.effectiveRoutingConfiguration.updatedAt
        )
        try threadRepo.upsert(stored)
        if let index = vm.threads.firstIndex(where: { $0.id == tid }) {
            vm.threads[index] = stored
        }
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
            _ = vm.persistThreadConfig()
            if var copy = try threadRepo.get(id: tid) {
                copy.updatedAt = Date()
                let routing = copy.effectiveRoutingConfiguration
                copy.routingConfiguration = try routing.replacing(
                    expectedRevision: routing.revision,
                    mode: routing.mode,
                    manualSelection: routing.manualSelection,
                    manualProviderInstanceId: routing.manualProviderInstanceId,
                    eligibleProviders: routing.eligibleProviders,
                    policyDigest: routing.policyDigest,
                    updatedAt: copy.updatedAt
                )
                try threadRepo.upsert(copy)
                if let index = vm.threads.firstIndex(where: { $0.id == tid }) {
                    vm.threads[index] = copy
                }
            }
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = vm.persistThreadConfig()
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try threadRepo.get(id: tid) {
                        copy.updatedAt = Date()
                        let routing = copy.effectiveRoutingConfiguration
                        copy.routingConfiguration = try routing.replacing(
                            expectedRevision: routing.revision,
                            mode: routing.mode,
                            manualSelection: routing.manualSelection,
                            manualProviderInstanceId: routing.manualProviderInstanceId,
                            eligibleProviders: routing.eligibleProviders,
                            policyDigest: routing.policyDigest,
                            updatedAt: copy.updatedAt
                        )
                        try threadRepo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] persist-thread-config-skip persist_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "matching persistThreadConfig must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeVM() throws -> (AgentAppViewModel, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-persist-skip-" + UUID().uuidString
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
}
