import XCTest
@testable import Persistence
import CoreModel

final class PersistenceTests: XCTestCase {
    func test_bootstrap_freshStart_isEmpty_andTouchesOnlyOwnedPaths() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let bs = Bootstrap(channel: .debug, appSupportOverride: tmp)
        let (rep, db) = try bs.run()
        XCTAssertTrue(rep.firstRun)
        XCTAssertEqual(rep.schemaVersion, Schema.currentVersion)
        // touchedPaths only inside tmp
        for path in rep.touchedPaths {
            XCTAssertTrue(path.hasPrefix(tmp), "touched path \(path) escapes \(tmp)")
        }
        // tables empty
        let projects = try ProjectRepository(db: db).list()
        XCTAssertTrue(projects.isEmpty)
        let threads = try AgentThreadRepository(db: db).list()
        XCTAssertTrue(threads.isEmpty)
    }

    func test_bootstrapDefaultsRemoteAccessOffUntilExplicitOptIn() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()

        let value = try SettingsRepository(db: db).get("remote_access_enabled")
        XCTAssertEqual(value, "0", "LAN pairing must require explicit opt-in before the Mac advertises itself.")
    }

    func test_schemaIsIdempotent() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let bs = Bootstrap(channel: .debug, appSupportOverride: tmp)
        _ = try bs.run()
        // re-open and migrate again
        let (rep2, _) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        XCTAssertFalse(rep2.firstRun)
    }

    func test_threadAndMessage_roundtrip() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let tr = AgentThreadRepository(db: db)
        let t = AgentThread(workspaceId: WorkspaceID(), title: "demo", provider: .codex, model: "gpt-5")
        try tr.upsert(t)
        let list = try tr.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].title, "demo")

        let mr = AgentMessageRepository(db: db)
        try mr.append(AgentMessage(threadId: t.id, role: .user, content: "hi"))
        try mr.append(AgentMessage(threadId: t.id, role: .assistant, content: "hello"))
        let msgs = try mr.list(threadId: t.id)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .user)
    }

    func test_snapshot_roundtrip() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: SurfaceDescriptor(type: .agentApp, title: "a")))
        let snap = SessionSnapshot(layout: s)
        let repo = SessionSnapshotRepository(db: db)
        try repo.save(snap)
        let loaded = try XCTUnwrap(try repo.latest())
        XCTAssertEqual(loaded.layout.window.workspaces.count, 1)
    }

    func test_runReconcile_marksRunningAsInterrupted() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let runs = AgentRunRepository(db: db)
        let r = AgentRun(threadId: AgentThreadID(), provider: .codex, model: "m", status: .running)
        // need parent thread row to satisfy FK
        let tr = AgentThreadRepository(db: db)
        let t = AgentThread(id: r.threadId, title: "t", provider: .codex, model: "m")
        try tr.upsert(t)
        try runs.upsert(r)
        let count = try runs.reconcileRunningOnLaunch()
        XCTAssertEqual(count, 1)
    }

    func test_streamEventReplayIncludesEveryRunForThread() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "history", provider: .codex, model: "m")
        try threads.upsert(thread)

        let firstRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        let secondRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 2))
        try runs.upsert(firstRun)
        try runs.upsert(secondRun)
        try runs.appendStreamEvent(runId: firstRun.id, seq: 1, kind: "turnStarted(first)", payloadJSON: #"{"turnStarted":{"turnId":"first"}}"#)
        try runs.appendStreamEvent(runId: firstRun.id, seq: 2, kind: "error(first)", payloadJSON: #"{"error":{"message":"first update","recoverable":false}}"#)
        try runs.appendStreamEvent(runId: secondRun.id, seq: 1, kind: "turnStarted(second)", payloadJSON: #"{"turnStarted":{"turnId":"second"}}"#)

        let replayed = try runs.listLatestStreamEvents(threadId: thread.id)

        XCTAssertEqual(replayed, [
            .turnStarted(turnId: "first"),
            .error(message: "first update", recoverable: false),
            .turnStarted(turnId: "second")
        ], "reopening or following up must replay every persisted run event, not only the latest response")
    }

    func test_terminalOutputHistoryReadsBoundedOlderWindows() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = UUID().uuidString

        try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: 1, data: Data("older-".utf8))
        try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: 2, data: Data("middle-".utf8))
        try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: 3, data: Data("newest".utf8))

        let latest = try repo.readWindow(surfaceID: surfaceID, maxBytes: 14)

        XCTAssertEqual(latest.text, "middle-newest",
                       "terminal history fetch must return newest DB chunks without loading the whole scrollback into memory")
        XCTAssertTrue(latest.hasMoreOlder, "bounded history windows must expose an older-page cursor for infinite scroll")
        let older = try repo.readWindow(surfaceID: surfaceID, beforeChunkID: latest.nextBeforeChunkID, maxBytes: 64)
        XCTAssertEqual(older.text, "older-",
                       "fetching before the cursor must read the next older DB-backed terminal history page")
        XCTAssertFalse(older.hasMoreOlder)
    }
}
