import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// WHY: composer Auto toggle compiled the 26-column row plus routing JSON
/// twice per click (before CAS and after) just to flip routing.mode.
@MainActor
final class SetAutoModelRoutingSkipGetTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    func test_autoToggle_sourceSkipsDurableGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func setAutoModelRoutingEnabled("))
        let end = try XCTUnwrap(source.range(of: "private func restoreThreadConfiguration("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("routingConfiguration(of:"))
        XCTAssertTrue(body.contains("setRoutingConfiguration("))
        XCTAssertTrue(body.contains("threadWithoutRouting(of:"))
        XCTAssertFalse(body.contains("threadRepo.get("))
    }

    func test_autoToggle_doesNotDurableGetAndPreservesChrome() throws {
        let (vm, threadRepo, root) = try makeVM()
        defer { try? FileManager.default.removeItem(atPath: root) }
        vm.createThread(title: "keep-title")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        try threadRepo.setColor(id: tid, color: "purple")
        try threadRepo.setPinned(id: tid, pinned: true)
        try threadRepo.updateStatus(id: tid, status: .running, hasUnread: true)
        let digest = try XCTUnwrap(try threadRepo.routingConfiguration(of: tid)?.policyDigest)
        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.routingConfigurationProbeCountForTesting

        XCTAssertTrue(
            vm.setAutoModelRoutingEnabled(false),
            vm.statusMessage.isEmpty ? "disable Auto" : vm.statusMessage
        )
        XCTAssertTrue(
            vm.setAutoModelRoutingEnabled(true),
            vm.statusMessage.isEmpty ? "enable Auto" : vm.statusMessage
        )

        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertGreaterThanOrEqual(
            threadRepo.routingConfigurationProbeCountForTesting,
            probesBefore + 2
        )
        XCTAssertEqual(vm.routingMode, .auto)
        let rail = try XCTUnwrap(vm.threads.first(where: { $0.id == tid }))
        XCTAssertEqual(rail.effectiveRoutingConfiguration.mode, .auto)
        XCTAssertEqual(rail.title, "keep-title")
        let roundTrip = try XCTUnwrap(try threadRepo.get(id: tid))
        XCTAssertEqual(roundTrip.title, "keep-title")
        XCTAssertEqual(roundTrip.color, "purple")
        XCTAssertTrue(roundTrip.pinned)
        XCTAssertTrue(roundTrip.hasUnread)
        XCTAssertEqual(roundTrip.status, .running)
        XCTAssertEqual(roundTrip.routingConfiguration?.mode, .auto)
        XCTAssertEqual(roundTrip.routingConfiguration?.policyDigest, digest)
    }

    func test_routingConfiguration_fasterThanDurableGet() throws {
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
            _ = try repo.routingConfiguration(of: thread.id)
            _ = try repo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try repo.routingConfiguration(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
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
        NSLog("[perf-proof] auto-toggle-skip-get %@", line)
        let measured = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("goal/auto-toggle-skip-get/measured.txt")
        try? FileManager.default.createDirectory(
            at: measured.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? line.write(to: measured, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "routingConfiguration must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepo() throws -> AgentThreadRepository {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return AgentThreadRepository(db: db)
    }

    private func makeVM() throws -> (AgentAppViewModel, AgentThreadRepository, String) {
        let root = NSTemporaryDirectory() + "rc2-auto-skip-get-" + UUID().uuidString
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
        let runtime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: db),
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false }
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: root,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo,
            initialRoutingMode: .auto,
            orchestrationRuntime: runtime
        )
        vm.providerSnapshots = AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(
                    id: "\(provider.rawValue)-live",
                    label: "Live",
                    provider: provider,
                    supportsReasoning: true,
                    supportedReasoningEfforts: provider == .claude
                        ? AgentReasoningEffort.claudeSupportedCases
                        : AgentReasoningEffort.supportedCases,
                    supportsServiceTier: true
                )],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                capabilitiesOverride: AgentProviderCapabilities(supportsStreaming: true, supportsPlanReview: true),
                modelDiscoverySource: .live
            )
        }
        return (vm, threadRepo, root)
    }
}
