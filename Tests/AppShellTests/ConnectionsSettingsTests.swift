import XCTest
import CoreModel
import Persistence
import AgentRuntime
@testable import AppShell

@MainActor
final class ConnectionsSettingsTests: XCTestCase {
    private func fixture() throws -> (ConnectionsSettingsModel, ConnectionStore, SQLiteDB) {
        let path = NSTemporaryDirectory() + "connection-settings-" + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: path).run()
        let store = ConnectionStore(db: db)
        return (ConnectionsSettingsModel(store: store, broker: ConnectionBroker(store: store)), store, db)
    }
    func testDestinationMountsBeforeReadAndReloadPublishesPersistedRows() async throws {
        let (model, store, _) = try fixture()
        let connection = AppConnection(name: "Fixture", kind: .stdio, endpoint: "/usr/bin/python3")
        try store.save(connection)
        XCTAssertFalse(model.loaded)
        XCTAssertTrue(model.connections.isEmpty)
        await model.reload()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.connections, [connection])
        XCTAssertEqual(SettingsCategory.connections.title, "Connections")
        XCTAssertNotEqual(SettingsCategory.connections, .accounts)
    }
    func testFailedRefreshPreservesVisibleMetadataAndShowsHonestError() async throws {
        let (model, store, db) = try fixture()
        let connection = AppConnection(name: "Fixture", kind: .stdio, endpoint: "/usr/bin/python3")
        try store.save(connection)
        await model.reload()
        try SettingsRepository(db: db).set(ConnectionStore.storageKey, "corrupt")
        await model.reload()
        XCTAssertEqual(model.connections, [connection])
        XCTAssertNotNil(model.error)
    }
    func testCancelledLoadCannotPublishAClosedDestination() async throws {
        let (model, _, _) = try fixture()
        let task = Task { await model.reload() }
        task.cancel()
        await task.value
        XCTAssertFalse(model.loaded)
        XCTAssertTrue(model.connections.isEmpty)
    }
}
