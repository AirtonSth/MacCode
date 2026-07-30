import XCTest
@testable import Persistence
import CoreModel

/// SQLite source bound for agent.thread.read response_version=1.
///
/// WHY: v1 must inspect `LENGTH(payload_json)` and never transfer/decode a
/// newest row that exceeds max_bytes. Count + contiguous-suffix probes stay
/// honest without materializing full history.
final class AgentThreadReadV1StreamLimitTests: XCTestCase {

    private func makeRepos(suffix: String) throws -> (AgentThread, AgentRun, AgentRunRepository, SQLiteDB, String) {
        let tmp = NSTemporaryDirectory() + "RC2ThreadReadV1-" + suffix + "-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "v1-\(suffix)", provider: .codex, model: "m")
        try threads.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        try runs.upsert(run)
        return (thread, run, runs, db, tmp)
    }

    private func insertRawPayload(
        db: SQLiteDB,
        runId: AgentRunID,
        seq: Int,
        kind: String,
        payloadJSON: String
    ) throws {
        // Bypass soft-truncate only for pathological non-decode proofs.
        // Production writers still go through appendStreamEvent.
        let st = try db.prepare("""
            INSERT INTO agent_stream_events(run_id, seq, event_kind, payload_json, created_at)
            VALUES(?, ?, ?, ?, ?);
        """)
        try st.bind(1, runId.value.uuidString)
        try st.bind(2, Int64(seq))
        try st.bind(3, kind)
        try st.bind(4, payloadJSON)
        try st.bind(5, "2026-01-01T00:00:00Z")
        _ = try st.step()
    }

    func test_listLatestStreamEventsLimitLoadsOnlyNewestRowsInChronologicalOrder() throws {
        let (thread, run, runs, _, tmp) = try makeRepos(suffix: "limit")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        for index in 0..<10 {
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "turnStarted(turn-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"turn-\#(index)"}}"#
            )
        }

        // event_limit=3 → host loads limit+1=4 newest rows to probe older history.
        let loaded = try runs.listLatestStreamEvents(threadId: thread.id, limit: 4, strictDecoding: true)
        XCTAssertEqual(loaded.count, 4, "SQL LIMIT must bound decoded rows at the source")
        XCTAssertEqual(loaded.map {
            if case .turnStarted(let id) = $0 { return id }
            return "?"
        }, ["turn-6", "turn-7", "turn-8", "turn-9"],
                       "rows must remain chronological after newest-first SQL selection")

        let hadOlder = loaded.count > 3
        let events = Array(loaded.suffix(3))
        XCTAssertTrue(hadOlder)
        XCTAssertEqual(events.map {
            if case .turnStarted(let id) = $0 { return id }
            return "?"
        }, ["turn-7", "turn-8", "turn-9"])
    }

    func test_listLatestStreamEventsExactFitDoesNotClaimOlderRows() throws {
        let (thread, run, runs, _, tmp) = try makeRepos(suffix: "exact")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        for index in 0..<3 {
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "turnStarted(turn-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"turn-\#(index)"}}"#
            )
        }

        let loaded = try runs.listLatestStreamEvents(threadId: thread.id, limit: 4, strictDecoding: true)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertFalse(loaded.count > 3, "+1 probe must not invent older rows when the stream is short")
    }

    func test_v1MetadataFirstNeverDecodesOversizedNewestIncluding16MiB() throws {
        let (thread, run, runs, db, tmp) = try makeRepos(suffix: "16mib")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Small older row that would decode fine if wrongly selected.
        try runs.appendStreamEvent(
            runId: run.id,
            seq: 1,
            kind: "turnStarted(old)",
            payloadJSON: #"{"turnStarted":{"turnId":"old"}}"#
        )

        // 16 MiB newest payload that is NOT valid AssistantEvent JSON. If v1
        // ever transfers+decodes it under strictDecoding, the call throws.
        let sixteenMiB = 16 * 1_024 * 1_024
        let huge = String(repeating: "X", count: sixteenMiB)
        try insertRawPayload(
            db: db,
            runId: run.id,
            seq: 2,
            kind: "pathological",
            payloadJSON: huge
        )

        let meta = try runs.listLatestStreamEventMetadata(threadId: thread.id, limit: 2)
        XCTAssertEqual(meta.count, 2)
        XCTAssertEqual(meta.last?.payloadBytes, Int64(sixteenMiB))

        let maxBytes = Int64(512 * 1_024)
        let selection = try runs.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id,
            eventLimit: 10,
            maxPayloadBytes: maxBytes,
            strictDecoding: true
        )
        XCTAssertTrue(selection.events.isEmpty, "oversized newest must yield empty window")
        XCTAssertTrue(selection.decodedRowIds.isEmpty, "no payload_json may be transferred")
        XCTAssertTrue(selection.hasMoreOlder)
        let blocked = try XCTUnwrap(selection.blockedNewest)
        XCTAssertEqual(blocked.payloadBytes, Int64(sixteenMiB))
        XCTAssertEqual(blocked.reason, "byte_limit")
        XCTAssertEqual(blocked.id, meta.last?.id)
    }

    func test_v1SelectsContiguousNewestSuffixByPayloadLengthWithoutSkipping() throws {
        let (thread, run, runs, _, tmp) = try makeRepos(suffix: "suffix")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Three small events + one medium: under a tight byte budget only newest fits.
        for index in 0..<4 {
            let pad = String(repeating: "p", count: index == 3 ? 200 : 40)
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "turnStarted(turn-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"turn-\#(index)-\#(pad)"}}"#
            )
        }

        let meta = try runs.listLatestStreamEventMetadata(threadId: thread.id, limit: 10)
        let newestBytes = try XCTUnwrap(meta.last?.payloadBytes)
        // Budget fits newest only (not newest+previous).
        let budget = newestBytes + 10
        let selection = try runs.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id,
            eventLimit: 10,
            maxPayloadBytes: budget,
            strictDecoding: true
        )
        XCTAssertEqual(selection.events.count, 1)
        if case .turnStarted(let id) = selection.events[0] {
            XCTAssertTrue(id.hasPrefix("turn-3-"), "must keep newest contiguous, not skip")
        } else {
            XCTFail("expected turnStarted")
        }
        XCTAssertTrue(selection.hasMoreOlder)
        XCTAssertEqual(selection.decodedRowIds.count, 1)
        XCTAssertEqual(selection.decodedRowIds.first, meta.last?.id)
        XCTAssertNil(selection.blockedNewest)
    }

    func test_v1MultibytePayloadLengthMatchesUTF8BytesAndDoesNotDecodeBlocked() throws {
        let (thread, run, runs, db, tmp) = try makeRepos(suffix: "utf8")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Multibyte characters: LENGTH(CAST AS BLOB) counts UTF-8 bytes.
        let multi = String(repeating: "\u{00F1}", count: 20_000) // 2 bytes each in UTF-8
        let payload = multi // not valid JSON; must not be decoded when blocked
        try insertRawPayload(
            db: db,
            runId: run.id,
            seq: 1,
            kind: "utf8-heavy",
            payloadJSON: payload
        )

        let meta = try runs.listLatestStreamEventMetadata(threadId: thread.id, limit: 1)
        XCTAssertEqual(meta.first?.payloadBytes, Int64(payload.utf8.count))

        let selection = try runs.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id,
            eventLimit: 1,
            maxPayloadBytes: 1_024,
            strictDecoding: true
        )
        XCTAssertTrue(selection.events.isEmpty)
        XCTAssertTrue(selection.decodedRowIds.isEmpty)
        XCTAssertEqual(selection.blockedNewest?.payloadBytes, Int64(payload.utf8.count))
    }

    func test_v1CountProbePreservesContiguousSuffixUnderConcurrentStyleAppends() throws {
        let (thread, run, runs, _, tmp) = try makeRepos(suffix: "append")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        for index in 0..<5 {
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "turnStarted(turn-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"turn-\#(index)"}}"#
            )
        }
        // "Concurrent" append after a first bounded read: second read must see
        // the new newest row and keep chronological contiguous order.
        let first = try runs.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id,
            eventLimit: 3,
            maxPayloadBytes: 512 * 1_024,
            strictDecoding: true
        )
        XCTAssertEqual(first.events.count, 3)
        XCTAssertTrue(first.hasMoreOlder)

        try runs.appendStreamEvent(
            runId: run.id,
            seq: 6,
            kind: "turnStarted(turn-5)",
            payloadJSON: #"{"turnStarted":{"turnId":"turn-5"}}"#
        )
        let second = try runs.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id,
            eventLimit: 3,
            maxPayloadBytes: 512 * 1_024,
            strictDecoding: true
        )
        XCTAssertEqual(second.events.map {
            if case .turnStarted(let id) = $0 { return id }
            return "?"
        }, ["turn-3", "turn-4", "turn-5"])
        XCTAssertTrue(second.hasMoreOlder)
        XCTAssertEqual(second.decodedRowIds.count, 3)
    }
}
