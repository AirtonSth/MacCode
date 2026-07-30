import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Coordinator-level bound for agent.thread.read response_version=1.
///
/// WHY: the Dispatcher must not be the first place that discards old events.
/// v1 uses metadata-first selection under the mirror lock so oversized newest
/// rows never decode and full history is never materialized.
final class MirrorEventSnapshotLimitTests: XCTestCase {
    func test_withMirrorEventSnapshotHonorsLimitWithoutLoadingFullHistory() throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-limit-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "mirror-limit", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "fake-model", startedAt: Date(timeIntervalSince1970: 10))
        try runRepo.upsert(run)
        for index in 0..<20 {
            try runRepo.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "turnStarted(turn-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"turn-\#(index)"}}"#
            )
        }

        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )

        // event_limit=5 → load 6 newest rows.
        let loaded = try coordinator.withMirrorEventSnapshot(threadId: thread.id, limit: 6) { $0 }
        XCTAssertEqual(loaded.count, 6)
        XCTAssertEqual(loaded.first, .turnStarted(turnId: "turn-14"))
        XCTAssertEqual(loaded.last, .turnStarted(turnId: "turn-19"))

        let full = try coordinator.withMirrorEventSnapshot(threadId: thread.id) { $0 }
        XCTAssertEqual(full.count, 20, "unbounded snapshot must still see the full stream")
    }

    func test_withMirrorEventSnapshotForThreadReadV1NeverDecodesOversizedNewest() throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-v1-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "mirror-v1", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "fake-model", startedAt: Date(timeIntervalSince1970: 10))
        try runRepo.upsert(run)

        try runRepo.appendStreamEvent(
            runId: run.id,
            seq: 1,
            kind: "turnStarted(ok)",
            payloadJSON: #"{"turnStarted":{"turnId":"ok"}}"#
        )
        // Invalid oversized newest: decode would throw under strictDecoding.
        let huge = String(repeating: "Z", count: 2 * 1_024 * 1_024)
        let st = try db.prepare("""
            INSERT INTO agent_stream_events(run_id, seq, event_kind, payload_json, created_at)
            VALUES(?, ?, ?, ?, ?);
        """)
        try st.bind(1, run.id.value.uuidString)
        try st.bind(2, Int64(2))
        try st.bind(3, "huge")
        try st.bind(4, huge)
        try st.bind(5, "2026-01-01T00:00:00Z")
        _ = try st.step()

        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let selection = try coordinator.withMirrorEventSnapshotForThreadReadV1(
            threadId: thread.id,
            eventLimit: 50,
            maxPayloadBytes: 64 * 1_024
        ) { $0 }
        XCTAssertTrue(selection.events.isEmpty)
        XCTAssertTrue(selection.decodedRowIds.isEmpty)
        XCTAssertEqual(selection.blockedNewest?.payloadBytes, Int64(huge.utf8.count))
        XCTAssertTrue(selection.hasMoreOlder)
    }
}
