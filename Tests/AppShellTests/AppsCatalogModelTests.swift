import XCTest
import CoreModel
import Persistence
import AgentRuntime
@testable import AppShell

private final class CatalogFixtureSecrets: ConnectionSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    var rows: [UUID: [String: String]] = [:]
    var reads = 0
    func load(_ id: UUID) throws -> [String: String] { lock.lock(); defer { lock.unlock() }; reads += 1; return rows[id] ?? [:] }
    func save(_ values: [String: String], for id: UUID) throws { lock.lock(); defer { lock.unlock() }; rows[id] = values }
    func delete(_ id: UUID) throws { lock.lock(); defer { lock.unlock() }; rows.removeValue(forKey: id) }
    func userID() -> String { lock.lock(); defer { lock.unlock() }; return rows.values.first { $0["userID"] != nil }!["userID"]! }
}
private struct CatalogFixtureHTTP: ComposioHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isCatalog = request.url!.path == "/api/v3.1/toolkits"
        let body = isCatalog ? #"{"items":[]}"# : #"{"error":"fixture permission failure"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: isCatalog ? 200 : 403, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor
final class AppsCatalogModelTests: XCTestCase {
    private func fixture() throws -> (AppsCatalogModel, ConnectionStore, CatalogFixtureSecrets, CatalogFixtureSecrets) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("apps-ui-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: path.path).run()
        let store = ConnectionStore(db: db), brokerSecrets = CatalogFixtureSecrets(), projectSecrets = CatalogFixtureSecrets()
        let broker = ConnectionBroker(store: store, secrets: brokerSecrets)
        let coordinator = ComposioOnboardingCoordinator(store: store, broker: broker, secrets: projectSecrets, client: ComposioClient(transport: CatalogFixtureHTTP()))
        return (AppsCatalogModel(store: store, broker: broker, coordinator: coordinator), store, brokerSecrets, projectSecrets)
    }
    func testAccessEditPreservesAccountVerificationAndProtectedCredentials() async throws {
        let (model, store, secrets, _) = try fixture()
        let verified = Date(timeIntervalSince1970: 1000)
        let connection = AppConnection(name: "GitHub", kind: .composio, endpoint: "https://backend.composio.dev/protected-mcp-endpoint",
            status: .tested, testedAt: verified, composio: .init(toolkitSlug: "github", connectedAccountID: "ca_fixture", userID: "fixture-user"))
        try store.save(connection)
        try secrets.save(["__MACCODE_REMOTE_ENDPOINT": "https://backend.composio.dev/tool_router/v3/fixture/mcp", "x-api-key": "fixture-only"], for: connection.id)
        let success = await model.saveAccess(connection, access: .init(botIDs: ["selected-bot"]))
        XCTAssertTrue(success)
        let saved = try XCTUnwrap(store.get(connection.id))
        XCTAssertEqual(saved.status, .tested)
        XCTAssertEqual(saved.testedAt, verified)
        XCTAssertEqual(saved.access.botIDs, ["selected-bot"])
        XCTAssertEqual(secrets.reads, 0, "Changing access must not touch protected endpoints or tokens")
    }
    func testSuccessfulCatalogDoesNotEraseAccountRefreshFailure() async throws {
        let (model, store, _, projectSecrets) = try fixture()
        let configured = await model.setup(key: "fixture-only"); XCTAssertTrue(configured)
        try store.save(AppConnection(name: "GitHub", kind: .composio, endpoint: "https://backend.composio.dev/protected-mcp-endpoint",
            status: .tested, composio: .init(toolkitSlug: "github", connectedAccountID: "ca_fixture", userID: projectSecrets.userID())))
        await model.refresh()
        XCTAssertNotNil(model.error)
        let accountError = model.error
        await model.catalog(search: "", category: nil)
        XCTAssertEqual(model.error, accountError, "A successful toolkit lookup must not hide an account failure")
    }
    func testStaleAccessEditDoesNotOverwriteNewerScopes() async throws {
        let (model, store, _, _) = try fixture()
        let connection = AppConnection(name: "GitHub", kind: .composio, endpoint: "https://backend.composio.dev/protected-mcp-endpoint", status: .tested)
        try store.save(connection)
        var newer = connection; newer.access = .init(botIDs: ["new-owner"])
        try store.save(newer, expectedRevision: connection.revision)
        let saved = await model.saveAccess(connection, access: .init(allRuns: true)); XCTAssertFalse(saved)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try store.get(connection.id)?.access.botIDs, ["new-owner"])
        XCTAssertEqual(try store.get(connection.id)?.access.allRuns, false)
    }
}
