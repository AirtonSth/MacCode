import XCTest
import CoreModel
@testable import Persistence

final class ConnectionStoreTests: XCTestCase {
    func testMetadataRoundTripAndRevocationUseCurrentGrants() throws {
        let directory = NSTemporaryDirectory() + "connections-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory).run()
        let store = ConnectionStore(db: db)
        let bot = UUID().uuidString.lowercased()
        let scope = ConnectionScope(botID: bot, workspaceID: nil, threadID: UUID().uuidString)
        var connection = AppConnection(name: "Fixture", kind: .stdio, endpoint: "/usr/bin/python3", arguments: ["fixture.py"], access: ConnectionAccess(botIDs: [bot]))
        try store.save(connection)
        XCTAssertEqual(try ConnectionStore(db: db).list(), [connection])
        XCTAssertTrue(connection.access.allows(scope))
        connection.access = ConnectionAccess()
        try store.save(connection)
        XCTAssertFalse(try XCTUnwrap(store.get(connection.id)).access.allows(scope))
        try store.disconnect(connection.id)
        XCTAssertEqual(try store.get(connection.id)?.status, .disconnected)
    }

    func testRejectsCredentialURLsAndCorruptStoreDoesNotBecomeEmpty() throws {
        let directory = NSTemporaryDirectory() + "connections-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory).run()
        let store = ConnectionStore(db: db)
        XCTAssertThrowsError(try store.save(AppConnection(name: "Bad", kind: .remoteMCP, endpoint: "https://host/mcp?api_key=secret")))
        try SettingsRepository(db: db).set(ConnectionStore.storageKey, "broken")
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.save(AppConnection(name: "New", kind: .stdio, endpoint: "/bin/cat")))
    }
}

extension ConnectionStoreTests {
    func testTaskAndWorkspaceGrantsAreIndependentOfProviderAndFailClosedByDefault() {
        let scope = ConnectionScope(botID: "bot", workspaceID: "workspace", threadID: "thread", taskID: "task")
        XCTAssertFalse(ConnectionAccess().allows(scope))
        XCTAssertTrue(ConnectionAccess(taskIDs: ["task"]).allows(scope))
        XCTAssertFalse(ConnectionAccess(taskIDs: ["other-task"]).allows(scope))
        XCTAssertTrue(ConnectionAccess(workspaceIDs: ["workspace"]).allows(scope))
        XCTAssertTrue(ConnectionAccess(botIDs: ["bot"]).allows(scope))
    }
}

extension ConnectionStoreTests {
    func testTaskGrantOnlyResolvesForExactActiveOccurrenceAndRun() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let connections = ConnectionStore(db: db), schedules = ScheduledTaskStore(db: db)
        let task = ScheduledTask(title: "Fixture", prompt: "Read fixture", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp", runAsUser: "fixture", runAsUID: 501, provider: .distill, providerInstanceID: "distill", model: "fixture", reasoningEffort: .medium, recurrence: .daily(at: ScheduledLocalTime(hour: 8, minute: 15)!), timeZoneIdentifier: "UTC")
        try schedules.save(task)
        let occurrence = try schedules.claimManual(taskID: task.id, owner: "fixture")
        let thread = AgentThreadID(), activeRun = AgentRunID()
        try schedules.attachThread(runID: occurrence.run.id, threadID: thread)
        XCTAssertNil(try connections.scheduledTaskID(forThreadID: thread, activeRunID: activeRun), "queued thread link is not active run authority")
        try schedules.markStarted(runID: occurrence.run.id, threadID: thread, agentRunID: activeRun)
        XCTAssertEqual(try connections.scheduledTaskID(forThreadID: thread, activeRunID: activeRun), task.id.uuidString.lowercased())
        XCTAssertNil(try connections.scheduledTaskID(forThreadID: thread, activeRunID: AgentRunID()))
        XCTAssertNil(try connections.scheduledTaskID(forThreadID: AgentThreadID(), activeRunID: activeRun))
        try schedules.finish(runID: occurrence.run.id, status: .completed)
        XCTAssertNil(try connections.scheduledTaskID(forThreadID: thread, activeRunID: activeRun))
    }
}
