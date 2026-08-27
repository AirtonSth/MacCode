import XCTest
import CoreModel
@testable import Persistence

/// WHY: persistThreadConfig mutations compiled the 26-column row plus routing
/// JSON then upserted title/status/unread/color/pin/execution just to copy
/// picker/permission/run-as-user and bump routing.manualSelection.
final class PersistPickerConfigPreservingThreadProbeTests: XCTestCase {
    func test_persistMutation_sourceUsesSetPickerConfigNotUpsert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repo = try String(
            contentsOf: root.appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let setPicker = try slice(repo, from: "public func setPickerConfig(", to: "public func setPermissionMode(")
        XCTAssertTrue(setPicker.contains("SET provider"))
        XCTAssertFalse(setPicker.contains("guard var t = try get(id: id)"))
        XCTAssertFalse(setPicker.contains("try upsert(t)"))

        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let persist = try slice(
            surface,
            from: "public func persistThreadConfig() -> Bool {",
            to: "public func setAutoModelRoutingEnabled("
        )
        XCTAssertTrue(persist.contains("threadRepo.setPickerConfig("))
        XCTAssertTrue(persist.contains("threadRepo.setRoutingConfiguration("))
        XCTAssertFalse(persist.contains("threadRepo.upsert(updated)"))
        XCTAssertFalse(persist.contains("guard let stored = try threadRepo.get(id: id)"))
    }

    func test_setPickerConfig_doesNotRewriteThreadChrome() throws {
        let repo = try makeRepo("match")
        var thread = AgentThread(title: "keep-title", provider: .codex, model: "fake-model")
        thread.color = "purple"
        thread.pinned = true
        thread.hasUnread = true
        thread.executionMode = .worktree
        thread.baseBranch = "main"
        thread.worktreePath = "/tmp/wt"
        thread.status = .running
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = stamped
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024),
            revision: 1,
            updatedAt: stamped
        )
        try repo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = repo.durableGetCountForTesting
        let next = Date(timeIntervalSince1970: 1_700_000_100)
        let selection = AgentModelSelection(provider: .claude, modelId: "opus")

        XCTAssertEqual(
            try repo.setPickerConfig(
                of: thread.id,
                provider: .claude,
                providerInstanceId: "claude-work",
                runAsUser: nil,
                model: "opus",
                permissionMode: .fullAccess,
                reasoningEffort: .high,
                serviceTier: .fast,
                modelSelection: selection,
                interactionMode: .plan,
                at: next
            ),
            true
        )
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
        let routing = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: selection,
            manualProviderInstanceId: "claude-work",
            policyDigest: digest ?? "",
            revision: 2,
            updatedAt: next
        )
        try repo.setRoutingConfiguration(routing, threadId: thread.id, expectedRevision: 1)

        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(stored.provider, .claude)
        XCTAssertEqual(stored.model, "opus")
        XCTAssertEqual(stored.permissionMode, .fullAccess)
        XCTAssertEqual(stored.interactionMode, .plan)
        XCTAssertEqual(stored.title, "keep-title")
        XCTAssertEqual(stored.color, "purple")
        XCTAssertTrue(stored.pinned)
        XCTAssertTrue(stored.hasUnread)
        XCTAssertEqual(stored.executionMode, .worktree)
        XCTAssertEqual(stored.baseBranch, "main")
        XCTAssertEqual(stored.worktreePath, "/tmp/wt")
        XCTAssertEqual(stored.status, .running)
        XCTAssertEqual(stored.routingConfiguration?.revision, 2)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
        XCTAssertFalse(try repo.setPickerConfig(
            of: AgentThreadID(),
            provider: .codex,
            providerInstanceId: "codex",
            runAsUser: nil,
            model: "x",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            modelSelection: AgentModelSelection(provider: .codex, modelId: "x"),
            interactionMode: .default
        ))
    }

    func test_setPickerConfig_fasterThanGetAndUpsert() throws {
        let repo = try makeRepo("bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        let routing = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024),
            revision: 1
        )
        thread.routingConfiguration = routing
        try repo.upsert(thread)
        let selection = AgentModelSelection(provider: .codex, modelId: "fake-model")
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
        func persistPicker() throws {
            _ = try repo.setPickerConfig(
                of: thread.id,
                provider: .codex,
                providerInstanceId: "codex",
                runAsUser: nil,
                model: "fake-model",
                permissionMode: .supervised,
                reasoningEffort: .medium,
                serviceTier: .auto,
                modelSelection: selection,
                interactionMode: .default
            )
            try repo.setRoutingConfiguration(routing, threadId: thread.id, expectedRevision: 1)
        }
        for _ in 0..<warmup {
            try persistPicker()
            if var copy = try repo.get(id: thread.id) {
                copy.updatedAt = Date()
                try repo.upsert(copy)
            }
        }
        var probeSamples: [Double] = []
        var upsertSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        upsertSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    try persistPicker()
                }
            })
            upsertSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try repo.get(id: thread.id) {
                        copy.modelSelection = selection
                        copy.updatedAt = Date()
                        copy.routingConfiguration = routing
                        try repo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let upsertMed = median(upsertSamples)
        let improvement = (upsertMed - probeMed) / upsertMed * 100.0
        NSLog(
            "[perf-proof] persist-picker-config-preserving-thread picker+routing_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "setPickerConfig+setRouting must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
        )
    }

    private func makeRepo(_ label: String) throws -> AgentThreadRepository {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        _ = label
        return AgentThreadRepository(db: db)
    }

    private func slice(_ source: String, from: String, to: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: from))
        let end = try XCTUnwrap(source.range(of: to, range: start.lowerBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
