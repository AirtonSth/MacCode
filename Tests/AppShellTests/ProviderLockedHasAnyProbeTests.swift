import XCTest
@testable import AppShell
@testable import Persistence
import CoreModel

/// WHY: single-thread payload encode compiled the latest agent_messages body
/// via listAgentMessages(limit:1) just to set provider_locked.
@MainActor
final class ProviderLockedHasAnyProbeTests: XCTestCase {
    func test_providerLocked_sourceUsesHasAnyNotListRecent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let router = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let payload = try slice(router, from: "private func agentThreadPayload(_ thread: AgentThread)", to: "var payload: [String: JSONValue] = [")
        XCTAssertTrue(payload.contains("messageRepo.hasAny(threadId: thread.id)"))
        XCTAssertFalse(payload.contains("listAgentMessages(thread: thread.id, limit: 1)"))

        let hasMessages = try slice(router, from: "public func agentThreadHasMessages(thread: AgentThreadID)", to: "public func threadIdsWithMessages() throws")
        XCTAssertTrue(hasMessages.contains("messageRepo.hasAny(threadId: thread)"))
        XCTAssertFalse(hasMessages.contains("listRecent"))

        let dispatcher = try String(
            contentsOf: root.appendingPathComponent("Sources/SocketServer/Dispatcher.swift"),
            encoding: .utf8
        )
        let locked = try slice(dispatcher, from: "private func providerLocked(_ thread: AgentThread)", to: "}\n")
        XCTAssertTrue(locked.contains("agentThreadHasMessages(thread: thread.id)"))
        XCTAssertFalse(locked.contains("listAgentMessages(thread: thread.id, limit: 1)"))
    }

    func test_hasAny_matchesListRecentEmptinessWithoutListRecent() throws {
        let (threadRepo, messageRepo) = try makeRepos("match")
        let empty = AgentThread(title: "empty", provider: .codex, model: "fake-model")
        let live = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(empty)
        try threadRepo.upsert(live)
        try messageRepo.append(AgentMessage(
            threadId: live.id,
            role: .user,
            content: String(repeating: "m", count: 32 * 1024)
        ))
        let recentBefore = messageRepo.listRecentCountForTesting
        XCTAssertFalse(try messageRepo.hasAny(threadId: empty.id))
        XCTAssertTrue(try messageRepo.hasAny(threadId: live.id))
        XCTAssertEqual(messageRepo.listRecentCountForTesting, recentBefore)
        XCTAssertTrue(try messageRepo.listRecent(threadId: live.id, limit: 1).isEmpty == false)
    }

    func test_hasAny_fasterThanListRecentLimitOne() throws {
        let (threadRepo, messageRepo) = try makeRepos("bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        try messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: String(repeating: "m", count: 32 * 1024)
        ))
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
            _ = try messageRepo.hasAny(threadId: thread.id)
            _ = try messageRepo.listRecent(threadId: thread.id, limit: 1)
        }
        var probeSamples: [Double] = []
        var recentSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        recentSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try messageRepo.hasAny(threadId: thread.id)
                }
            })
            recentSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try messageRepo.listRecent(threadId: thread.id, limit: 1)
                }
            })
        }
        let probeMed = median(probeSamples)
        let recentMed = median(recentSamples)
        let improvement = (recentMed - probeMed) / recentMed * 100.0
        NSLog(
            "[perf-proof] provider-locked-has-any hasAny_ms=%@ listRecent_ms=%@ improvement_pct=%.2f probe=%@ recent=%@",
            String(probeMed), String(recentMed), improvement,
            String(describing: probeSamples),
            String(describing: recentSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "hasAny must beat listRecent(limit:1) by ≥5% (got \(improvement)%; probe=\(probeMed)ms recent=\(recentMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, AgentMessageRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-locked-" + label + "-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), AgentMessageRepository(db: db))
    }

    private func slice(_ source: String, from: String, to: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: from))
        let end = try XCTUnwrap(source.range(of: to, range: start.lowerBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
