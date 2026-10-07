import XCTest
@testable import Persistence
import CoreModel

/// C3: paired-device reads (thread list, running-workspace projection,
/// agent.thread.read v1 stream rows) run on the WAL reader, so a long writer
/// transaction (stream batch, receipt finalize, pruning) cannot hold them.
/// Each test also proves the reader returns exactly the committed rows.
final class ReadGatewayWALReaderTests: XCTestCase {
    private struct Connections {
        let writer: SQLiteDB
        let reader: SQLiteDB
    }

    private func makeConnections() throws -> Connections {
        let dir = NSTemporaryDirectory() + "RC2ReadGatewayWAL-" + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let (_, writer) = try Bootstrap(channel: .debug, appSupportOverride: dir).run()
        let reader = try SQLiteDB(path: writer.path, readonly: true)
        return Connections(writer: writer, reader: reader)
    }

    /// Holds the writer connection inside BEGIN IMMEDIATE on another thread,
    /// like a long stream batch does, until `release` is signalled.
    private func holdWriter(_ writer: SQLiteDB) -> (release: DispatchSemaphore, done: DispatchSemaphore) {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            writer.performSync { db in
                try? db.execute("BEGIN IMMEDIATE;")
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                try? db.execute("COMMIT;")
            }
            done.signal()
        }
        started.wait()
        return (release, done)
    }

    private func elapsedMs(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    func test_threadListGateway_readsWhileWriterHeld() async throws {
        let c = try makeConnections()
        let threads = AgentThreadRepository(db: c.writer)
        let workspace = WorkspaceID(UUID())
        var running = AgentThread(workspaceId: workspace, title: "running", provider: .codex, model: "m")
        running.status = .running
        try threads.upsert(running)
        try threads.upsert(AgentThread(title: "idle", provider: .codex, model: "m"))
        let gateway = AgentThreadListGateway(db: c.writer, readDB: c.reader)

        let held = holdWriter(c.writer)
        let t0 = DispatchTime.now()
        let listed = try await gateway.list()
        let busy = try await gateway.runningWorkspaceIDs(in: [workspace, WorkspaceID(UUID())])
        let ms = elapsedMs(t0)
        held.release.signal()
        held.done.wait()

        XCTAssertEqual(Set(listed.map(\.title)), ["running", "idle"])
        XCTAssertEqual(busy, [workspace])
        XCTAssertLessThan(ms, 250, "list reads must not wait for the writer transaction (took \(ms) ms)")
    }

    /// Without a reader the gateway keeps its old single-connection behavior.
    func test_threadListGateway_defaultsToTheWriterConnection() async throws {
        let c = try makeConnections()
        try AgentThreadRepository(db: c.writer).upsert(AgentThread(title: "only", provider: .codex, model: "m"))
        let listed = try await AgentThreadListGateway(db: c.writer).list()
        XCTAssertEqual(listed.map(\.title), ["only"])
    }

    func test_threadReadV1StreamRows_readWhileWriterHeld_andMatchTheWriterView() throws {
        let c = try makeConnections()
        let thread = AgentThread(title: "v1", provider: .codex, model: "m")
        try AgentThreadRepository(db: c.writer).upsert(thread)
        let writerRuns = AgentRunRepository(db: c.writer)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        try writerRuns.upsert(run)
        for index in 0..<6 {
            try writerRuns.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "turnStarted(turn-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"turn-\#(index)"}}"#
            )
        }
        let readerRuns = AgentRunRepository(db: c.writer, readDB: c.reader)
        let expected = try writerRuns.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id, eventLimit: 4, maxPayloadBytes: 1_000_000
        )

        let held = holdWriter(c.writer)
        let t0 = DispatchTime.now()
        let selection = try readerRuns.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id, eventLimit: 4, maxPayloadBytes: 1_000_000
        )
        let ms = elapsedMs(t0)
        held.release.signal()
        held.done.wait()

        XCTAssertLessThan(ms, 250, "v1 stream reads must not wait for the writer transaction (took \(ms) ms)")
        XCTAssertEqual(selection.decodedRowIds, expected.decodedRowIds)
        XCTAssertEqual(selection.hasMoreOlder, expected.hasMoreOlder)
        XCTAssertEqual(selection.events.map { event -> String in
            if case .turnStarted(let id) = event { return id }
            return "?"
        }, ["turn-2", "turn-3", "turn-4", "turn-5"])
    }

    /// The reader sees exactly what has committed: rows written by a
    /// transaction that is still open are not served, and appear right after.
    func test_threadReadV1StreamRows_neverServeUncommittedRows() throws {
        let c = try makeConnections()
        let thread = AgentThread(title: "v1-commit", provider: .codex, model: "m")
        try AgentThreadRepository(db: c.writer).upsert(thread)
        let writerRuns = AgentRunRepository(db: c.writer)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        try writerRuns.upsert(run)
        try writerRuns.appendStreamEvent(runId: run.id, seq: 1, kind: "turnStarted(a)",
                                         payloadJSON: #"{"turnStarted":{"turnId":"a"}}"#)
        let readerRuns = AgentRunRepository(db: c.writer, readDB: c.reader)

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            c.writer.performSync { db in
                try? db.execute("BEGIN IMMEDIATE;")
                let st = try? db.prepare("INSERT INTO agent_stream_events(run_id, seq, event_kind, payload_json, created_at) VALUES(?, 2, 'turnStarted(b)', ?, '2026-01-01T00:00:00Z');")
                try? st?.bind(1, run.id.value.uuidString)
                try? st?.bind(2, #"{"turnStarted":{"turnId":"b"}}"#)
                _ = try? st?.step()
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                try? db.execute("COMMIT;")
            }
            done.signal()
        }
        started.wait()
        let during = try readerRuns.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id, eventLimit: 10, maxPayloadBytes: 1_000_000
        )
        release.signal()
        done.wait()
        let after = try readerRuns.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id, eventLimit: 10, maxPayloadBytes: 1_000_000
        )
        XCTAssertEqual(during.events.count, 1, "an open writer transaction is not visible")
        XCTAssertEqual(after.events.count, 2, "the committed row is served on the next read")
    }
}
