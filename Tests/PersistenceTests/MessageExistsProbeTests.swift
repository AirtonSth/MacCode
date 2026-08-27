import XCTest
@testable import Persistence
import CoreModel

/// WHY: startRun compiled the agent_messages body plus attachments JSON via
/// get(id:) just to learn whether the user-row id was already taken.
final class MessageExistsProbeTests: XCTestCase {
    func test_existenceSites_sourceUsesExistsNotGet() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let persist = try slice(coordinator, from: "if recordUserMessage {", to: "if let priorSnapshot {")
        XCTAssertTrue(persist.contains("messageRepo.exists(id: userMsg.id)"))
        XCTAssertFalse(persist.contains("messageRepo.get(id: userMsg.id)"))

        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let send = try slice(surface, from: "let durableUserMessageExists", to: "if !resumeInterrupted && !durableUserMessageExists")
        XCTAssertTrue(send.contains("messageRepo.exists(id:"))
        XCTAssertFalse(send.contains("messageRepo.get(id: AgentMessageID(runId.value))"))

        let queue = try slice(surface, from: "let mirrorId = AgentMessageID(cancelled.id.value)", to: "if queuedMessages.count <= 1")
        XCTAssertTrue(queue.contains("messageRepo.exists(id: mirrorId)"))
        XCTAssertFalse(queue.contains("messageRepo.get(id: mirrorId)"))

        let desk = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let userRow = try slice(desk, from: "if try context.messageRepo.", to: "try context.messageRepo.append(AgentMessage(")
        XCTAssertTrue(userRow.contains("exists(id: messageID)"))
        XCTAssertFalse(userRow.contains("get(id: messageID)"))
    }

    func test_exists_matchesMissingVsPopulatedWithoutDurableGet() throws {
        let (threadRepo, messageRepo) = try makeRepos("match")
        let thread = AgentThread(title: "exists", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let message = AgentMessage(
            threadId: thread.id,
            role: .user,
            content: String(repeating: "m", count: 32 * 1024)
        )
        try messageRepo.append(message)
        let getsBefore = messageRepo.durableGetCountForTesting
        let probesBefore = messageRepo.existsProbeCountForTesting
        XCTAssertTrue(try messageRepo.exists(id: message.id))
        XCTAssertFalse(try messageRepo.exists(id: AgentMessageID()))
        XCTAssertEqual(messageRepo.existsProbeCountForTesting, probesBefore + 2)
        XCTAssertEqual(messageRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(try messageRepo.get(id: message.id)?.content.count, 32 * 1024)
        XCTAssertEqual(messageRepo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_exists_fasterThanDurableGet() throws {
        let (threadRepo, messageRepo) = try makeRepos("bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let message = AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: String(repeating: "m", count: 32 * 1024)
        )
        try messageRepo.append(message)
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
            _ = try messageRepo.exists(id: message.id)
            _ = try messageRepo.get(id: message.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try messageRepo.exists(id: message.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try messageRepo.get(id: message.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] message-exists exists_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "exists must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, AgentMessageRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-msg-exists-" + label + "-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), AgentMessageRepository(db: db))
    }

    private func slice(_ source: String, from: String, to: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: from))
        let end = try XCTUnwrap(source.range(of: to, range: start.lowerBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
