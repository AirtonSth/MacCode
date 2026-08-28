import XCTest
@testable import Persistence
import CoreModel

/// WHY: send/configure/first-title compiled the latest agent_messages body
/// plus attachments JSON via listRecent(limit:1) just to learn whether the
/// thread had started.
final class MessageHasAnyProbeTests: XCTestCase {
    func test_existenceSites_sourceUsesHasAnyNotListRecent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let router = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let started = try slice(router, from: "func threadHasStarted() -> Bool {", to: "if let provider, provider != t.provider {")
        XCTAssertTrue(started.contains("messageRepo.hasAny(threadId: thread)"))
        XCTAssertFalse(started.contains("listRecent(threadId: thread, limit: 1)"))

        let execution = try slice(router, from: "public func configureAgentThreadExecution(", to: "if executionMode == .worktree {")
        XCTAssertTrue(execution.contains("messageRepo.hasAny(threadId: thread)"))
        XCTAssertFalse(execution.contains("listRecent(threadId: thread, limit: 1)"))

        let send = try slice(router, from: "let alreadyStarted =", to: "var t = try configureAgentThread(")
        XCTAssertTrue(send.contains("messageRepo.hasAny(threadId: thread)"))
        XCTAssertFalse(send.contains("listRecent(threadId: thread, limit: 1)"))

        let title = try slice(router, from: "if AgentThreadTitle.isPlaceholder(t.title),", to: "t.title = AgentThreadTitle.titleFromFirstMessage(text)")
        XCTAssertTrue(title.contains("alreadyStarted"))
        XCTAssertFalse(title.contains("listRecent(threadId: thread, limit: 1)"))

        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let firstTitle = try slice(
            surface,
            from: "// B5: title a still-default thread from its first message.",
            to: "loadAllMessages(tid)"
        )
        XCTAssertTrue(firstTitle.contains("messageRepo.hasAny(threadId: tid)"))
        XCTAssertFalse(firstTitle.contains("listRecent(threadId: tid, limit: 1)"))
    }

    func test_hasAny_matchesEmptyVsPopulatedWithoutListRecent() throws {
        let (threadRepo, messageRepo) = try makeRepos("match")
        let empty = AgentThread(title: "empty", provider: .codex, model: "fake-model")
        let live = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(empty)
        try threadRepo.upsert(live)
        try messageRepo.append(AgentMessage(
            threadId: live.id,
            role: .assistant,
            content: String(repeating: "m", count: 32 * 1024)
        ))
        let recentBefore = messageRepo.listRecentCountForTesting
        let probeBefore = messageRepo.hasAnyProbeCountForTesting
        XCTAssertFalse(try messageRepo.hasAny(threadId: empty.id))
        XCTAssertTrue(try messageRepo.hasAny(threadId: live.id))
        XCTAssertEqual(messageRepo.hasAnyProbeCountForTesting, probeBefore + 2)
        XCTAssertEqual(messageRepo.listRecentCountForTesting, recentBefore)
        XCTAssertFalse(try messageRepo.hasAny(threadId: AgentThreadID()))
        XCTAssertEqual(messageRepo.listRecentCountForTesting, recentBefore)
        XCTAssertEqual(try messageRepo.listRecent(threadId: live.id, limit: 1).count, 1)
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
            "[perf-proof] message-has-any hasAny_ms=%@ listRecent_ms=%@ improvement_pct=%.2f probe=%@ recent=%@",
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
        let tmp = NSTemporaryDirectory() + "rc2-has-any-" + label + "-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), AgentMessageRepository(db: db))
    }

    private func slice(_ source: String, from: String, to: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: from))
        let end = try XCTUnwrap(source.range(of: to, range: start.lowerBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
