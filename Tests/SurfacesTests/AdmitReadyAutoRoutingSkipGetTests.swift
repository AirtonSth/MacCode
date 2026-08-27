import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// WHY: Auto send heal compiled the 26-column row plus routing JSON after
/// CAS just to copy the healed routing onto the painted rail.
@MainActor
final class AdmitReadyAutoRoutingSkipGetTests: XCTestCase {
    func test_admitReadyHeal_sourceSkipsDurableGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func admitReadyAutoRoutingConfiguration("))
        let end = try XCTUnwrap(source.range(of: "private func startProviderRun("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("setRoutingConfiguration("))
        XCTAssertTrue(body.contains("threads[index].routingConfiguration = healed"))
        XCTAssertFalse(body.contains("threadRepo.get("))
    }

    func test_setRoutingConfiguration_doesNotRewriteChrome() throws {
        let repo = try makeRepo()
        var thread = AgentThread(title: "keep-title", provider: .codex, model: "fake-model")
        thread.color = "purple"
        thread.pinned = true
        thread.hasUnread = true
        thread.status = .running
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = stamped
        let digest = String(repeating: "r", count: 32 * 1024)
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: digest,
            revision: 1,
            updatedAt: stamped
        )
        try repo.upsert(thread)
        let next = try XCTUnwrap(thread.routingConfiguration).replacing(
            expectedRevision: 1,
            mode: .auto,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            manualProviderInstanceId: nil,
            eligibleProviders: AgentProvider.allCases,
            policyDigest: digest,
            updatedAt: Date()
        )
        let getsBefore = repo.durableGetCountForTesting
        try repo.setRoutingConfiguration(next, threadId: thread.id, expectedRevision: 1)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(stored.title, "keep-title")
        XCTAssertEqual(stored.color, "purple")
        XCTAssertTrue(stored.pinned)
        XCTAssertTrue(stored.hasUnread)
        XCTAssertEqual(stored.status, .running)
        XCTAssertEqual(stored.routingConfiguration?.mode, .auto)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
    }

    func test_setRouting_fasterThanSetRoutingPlusGet() throws {
        let repo = try makeRepo()
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        let digest = String(repeating: "r", count: 32 * 1024)
        var configuration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: digest,
            revision: 1
        )
        thread.routingConfiguration = configuration
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
        func bump(_ current: AgentRoutingConfiguration) throws -> AgentRoutingConfiguration {
            try current.replacing(
                expectedRevision: current.revision,
                mode: current.mode,
                manualSelection: current.manualSelection,
                manualProviderInstanceId: current.manualProviderInstanceId,
                eligibleProviders: current.eligibleProviders,
                policyDigest: digest,
                updatedAt: Date()
            )
        }
        for _ in 0..<warmup {
            let next = try bump(configuration)
            try repo.setRoutingConfiguration(next, threadId: thread.id, expectedRevision: configuration.revision)
            configuration = next
            _ = try repo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    let next = try bump(configuration)
                    try repo.setRoutingConfiguration(next, threadId: thread.id, expectedRevision: configuration.revision)
                    configuration = next
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    let next = try bump(configuration)
                    try repo.setRoutingConfiguration(next, threadId: thread.id, expectedRevision: configuration.revision)
                    configuration = next
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
        NSLog("[perf-proof] auto-heal-skip-get %@", line)
        let measured = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("goal/auto-heal-skip-get/measured.txt")
        try? FileManager.default.createDirectory(
            at: measured.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? line.write(to: measured, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "setRoutingConfiguration must beat setRouting+get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepo() throws -> AgentThreadRepository {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return AgentThreadRepository(db: db)
    }
}
