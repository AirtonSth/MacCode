import XCTest
import CoreModel
@testable import Persistence

/// WHY: unselected bot-peer replies compiled the 26-column row plus
/// routing JSON then upserted the full row just to set has_unread.
final class MarkUnreadUpdatingActivityProbeTests: XCTestCase {
    func test_unreadWrites_sourceUsesMarkUnreadNotUpsert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repo = try String(
            contentsOf: root.appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let mark = try slice(repo, from: "public func markUnreadUpdatingActivity(of id: AgentThreadID", to: "public func updatedAt(of id: AgentThreadID")
        XCTAssertTrue(mark.contains("SET has_unread"))
        XCTAssertFalse(mark.contains("guard var t = try get(id: id)"))
        XCTAssertFalse(mark.contains("try upsert(t)"))

        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let ui = try slice(surface, from: "private func presentBotPeerContent(", to: "private func restoreComposerPromptAfterFailedSend(")
        XCTAssertTrue(ui.contains("threadRepo.markUnreadUpdatingActivity("))
        XCTAssertFalse(ui.contains("threadRepo.upsert(thread)"))
        XCTAssertFalse(ui.contains("threadRepo.get(id: threadId)"))

        let bots = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let desk = try slice(bots, from: "private func persistAgentAppProjection(", to: "private func setReply(")
        XCTAssertTrue(desk.contains("threadRepo.markUnreadUpdatingActivity("))
        XCTAssertFalse(desk.contains("threadRepo.upsert(thread)"))
        XCTAssertFalse(desk.contains("threadRepo.get(id: threadID)"))
    }

    func test_markUnread_doesNotRewriteRouting() throws {
        let repo = try makeRepo("match")
        var thread = AgentThread(title: "peer", provider: .codex, model: "fake-model")
        thread.hasUnread = false
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = stamped
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = repo.durableGetCountForTesting
        let marksBefore = repo.markUnreadUpdatingActivityCountForTesting

        XCTAssertEqual(try repo.markUnreadUpdatingActivity(of: thread.id), true)
        XCTAssertEqual(repo.markUnreadUpdatingActivityCountForTesting, marksBefore + 1)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)

        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertTrue(stored.hasUnread)
        XCTAssertGreaterThan(stored.updatedAt.timeIntervalSince1970, stamped.timeIntervalSince1970)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)

        XCTAssertEqual(try repo.markUnreadUpdatingActivity(of: thread.id), false)
        let again = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(again.updatedAt.timeIntervalSince1970, stored.updatedAt.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore + 2)
        XCTAssertNil(try repo.markUnreadUpdatingActivity(of: AgentThreadID()))
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore + 2)
    }

    func test_markUnread_fasterThanGetAndUpsert() throws {
        let repo = try makeRepo("bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.hasUnread = false
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let warmup = 3
        let samples = 5
        let iterations = 400
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
            _ = try repo.markReadPreservingActivity(of: thread.id)
            _ = try repo.markUnreadUpdatingActivity(of: thread.id)
            if var copy = try repo.get(id: thread.id) {
                copy.hasUnread = true
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
                    _ = try repo.markReadPreservingActivity(of: thread.id)
                    _ = try repo.markUnreadUpdatingActivity(of: thread.id)
                }
            })
            upsertSamples.append(try timeMs {
                for n in 0..<iterations {
                    if var copy = try repo.get(id: thread.id) {
                        copy.hasUnread = n % 2 == 0
                        copy.updatedAt = Date()
                        try repo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let upsertMed = median(upsertSamples)
        let improvement = (upsertMed - probeMed) / upsertMed * 100.0
        NSLog(
            "[perf-proof] mark-unread-updating-activity unread_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "markUnread must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
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
