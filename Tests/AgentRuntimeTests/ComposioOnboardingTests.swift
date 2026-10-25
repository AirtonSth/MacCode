import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

private final class ComposioFixtureSecrets: ConnectionSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: [String: String]] = [:]
    func load(_ id: UUID) throws -> [String: String] { lock.lock(); defer { lock.unlock() }; return values[id] ?? [:] }
    func save(_ values: [String: String], for id: UUID) throws { lock.lock(); defer { lock.unlock() }; self.values[id] = values }
    func delete(_ id: UUID) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id) }
    func project() -> [String: String] { lock.lock(); defer { lock.unlock() }; return values.values.first(where: { $0["apiKey"] != nil }) ?? [:] }
}
private struct ComposioFixtureTransport: ComposioHTTPTransport {
    let reply: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await reply(request) }
}
final class ComposioOnboardingTests: XCTestCase {
    private func response(_ request: URLRequest, _ json: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    // Catches lost category/search filters and accidental API key query-string transport.
    func testCatalogUsesAuthenticatedOfficialHostAndDecodesMetadata() async throws {
        let client = ComposioClient(transport: ComposioFixtureTransport { request in
            XCTAssertEqual(request.url?.host, "backend.composio.dev")
            XCTAssertEqual(request.url?.path, "/api/v3.1/toolkits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-project-key")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "search", value: "Gmail & Docs")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "category", value: "productivity")))
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-project-key"))
            return self.response(request, #"{"items":[{"slug":"gmail","name":"Gmail","composio_managed_auth_schemes":["OAUTH2"],"meta":{"description":"Email.","logo":"https://assets.composio.dev/gmail.png","categories":[{"id":"productivity","name":"Productivity"}]}}],"next_cursor":"page2"}"#)
        })
        let page = try await client.catalog(apiKey: "fixture-project-key", search: "Gmail & Docs", category: "productivity", cursor: nil)
        XCTAssertEqual(page.items.first?.name, "Gmail")
        XCTAssertEqual(page.items.first?.categories.first?.id, "productivity")
        XCTAssertEqual(page.nextCursor, "page2")
        XCTAssertEqual(page.items.first?.supportsManagedAuth, true)
    }
    // Catches server-provided credential exfiltration URLs and runtime account fallback.
    func testRuntimeSessionPinsAccountAndRejectsForeignMCPHost() async throws {
        let client = ComposioClient(transport: ComposioFixtureTransport { request in
            let body = try JSONDecoder().decode([String: ConnectionJSONValue].self, from: request.httpBody!)
            XCTAssertEqual(body["user_id"], .string("maccode-user"))
            XCTAssertEqual(body["toolkits"], .object(["enable": .array([.string("gmail")])]))
            XCTAssertEqual(body["connected_accounts"], .object(["gmail": .array([.string("ca_owned")])]))
            XCTAssertEqual(body["manage_connections"]?.objectValue?["enable"], .bool(false))
            return self.response(request, #"{"session_id":"trs_owned","mcp":{"url":"https://attacker.invalid/mcp"}}"#)
        })
        do { _ = try await client.createSession(apiKey: "fixture-key", userID: "maccode-user", toolkit: "gmail", accountID: "ca_owned"); XCTFail("Foreign MCP URL accepted") }
        catch { XCTAssertEqual(error as? ComposioError, .invalidResponse) }
    }
    func testHTTPErrorNeverLeaksServerBodyOrKey() async throws {
        let client = ComposioClient(transport: ComposioFixtureTransport { request in
            self.response(request, "sensitive-token fixture-key", status: 401)
        })
        do { _ = try await client.catalog(apiKey: "fixture-key", search: "", category: nil, cursor: nil); XCTFail("Unauthorized request accepted") }
        catch { XCTAssertEqual(error as? ComposioError, .invalidAPIKey); XCTAssertFalse(String(describing: error).contains("fixture-key")) }
    }
    private func fixture(transport: ComposioFixtureTransport, secrets: ComposioFixtureSecrets = ComposioFixtureSecrets(), pollAttempts: Int = 90) throws -> (ConnectionStore, ComposioOnboardingCoordinator, ComposioFixtureSecrets) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory.path).run()
        let store = ConnectionStore(db: db)
        return (store, ComposioOnboardingCoordinator(store: store, broker: ConnectionBroker(store: store, secrets: secrets), secrets: secrets, client: ComposioClient(transport: transport), pollAttempts: pollAttempts, pollIntervalNanoseconds: 1), secrets)
    }
    // Catches marking a returned browser redirect connected, and cross-user account admission.
    func testConnectRejectsActiveAccountOwnedByAnotherUserWithoutSaving() async throws {
        let (store, coordinator, _) = try fixture(transport: ComposioFixtureTransport { request in
            switch request.url!.path {
            case "/api/v3.1/toolkits": return self.response(request, #"{"items":[]}"#)
            case "/api/v3.1/tool_router/session": return self.response(request, #"{"session_id":"trs_owned","mcp":{"url":"https://backend.composio.dev/tool_router/v3/trs_owned/mcp"}}"#)
            case "/api/v3.1/tool_router/session/trs_owned/link": return self.response(request, #"{"redirect_url":"https://connect.composio.dev/link/fixture","connected_account_id":"ca_owned"}"#)
            default: return self.response(request, #"{"id":"ca_owned","user_id":"someone-else","toolkit":{"slug":"gmail"},"status":"ACTIVE"}"#)
            }
        })
        try await coordinator.setup(apiKey: "fixture-key")
        do { _ = try await coordinator.connect(toolkit: ComposioToolkit(slug: "gmail", name: "Gmail", description: "Email."), access: ConnectionAccess(), openURL: { _ in }); XCTFail("Foreign account saved") }
        catch { XCTAssertEqual(error as? ComposioError, .accountMismatch) }
        XCTAssertTrue(try store.list().isEmpty)
    }
    func testUnconfiguredConnectIsExplicitAndDoesNotOpenBrowser() async throws {
        let (_, coordinator, _) = try fixture(transport: ComposioFixtureTransport { _ in throw ComposioError.network })
        do { _ = try await coordinator.connect(toolkit: ComposioToolkit(slug: "gmail", name: "Gmail", description: "Email."), access: ConnectionAccess(), openURL: { _ in XCTFail("Opened without setup") }); XCTFail("Missing setup accepted") }
        catch { XCTAssertEqual(error as? ComposioError, .setupRequired) }
    }
    func testCancelledBrowserFlowNeverSavesConnection() async throws {
        let (store, coordinator, _) = try fixture(transport: ComposioFixtureTransport { request in
            if request.url!.path.hasSuffix("toolkits") { return self.response(request, #"{"items":[]}"#) }
            if request.url!.path.hasSuffix("/link") { return self.response(request, #"{"redirect_url":"https://connect.composio.dev/link/fixture","connected_account_id":"ca_owned"}"#) }
            return self.response(request, #"{"session_id":"trs_owned","mcp":{"url":"https://backend.composio.dev/tool_router/v3/trs_owned/mcp"}}"#)
        })
        try await coordinator.setup(apiKey: "fixture-key")
        do { _ = try await coordinator.connect(toolkit: ComposioToolkit(slug: "gmail", name: "Gmail", description: "Email."), access: ConnectionAccess(), openURL: { _ in await coordinator.cancel() }); XCTFail("Cancelled flow saved") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try store.list().isEmpty)
    }
    func testSetupFailurePreservesPreviouslyValidatedProject() async throws {
        let (_, coordinator, secrets) = try fixture(transport: ComposioFixtureTransport { request in
            if request.value(forHTTPHeaderField: "x-api-key") == "wrong-key" { return self.response(request, "private upstream text", status: 401) }
            return self.response(request, #"{"items":[]}"#)
        })
        try await coordinator.setup(apiKey: "working-key")
        let originalUser = secrets.project()["userID"]
        do { try await coordinator.setup(apiKey: "wrong-key"); XCTFail("Invalid project replaced validated key") }
        catch { XCTAssertEqual(error as? ComposioError, .invalidAPIKey) }
        XCTAssertEqual(secrets.project()["apiKey"], "working-key")
        try await coordinator.setup(apiKey: "working-key")
        XCTAssertEqual(secrets.project()["userID"], originalUser)
        let configured = try await coordinator.isConfigured()
        XCTAssertTrue(configured)
    }
    // Removing a foreign/forged metadata row may revoke local access, never someone else's account.
    func testDisconnectMismatchedRemoteIdentityLeavesLocalDisconnectedWithoutDelete() async throws {
        let (store, coordinator, secrets) = try fixture(transport: ComposioFixtureTransport { request in
            if request.url!.path.hasSuffix("toolkits") { return self.response(request, #"{"items":[]}"#) }
            XCTAssertEqual(request.httpMethod, "GET", "Must not DELETE before ownership verification")
            return self.response(request, #"{"id":"ca_owned","user_id":"foreign-user","toolkit":{"slug":"gmail"},"status":"ACTIVE"}"#)
        })
        try await coordinator.setup(apiKey: "fixture-key")
        let connection = AppConnection(name: "Gmail", kind: .composio, endpoint: "https://backend.composio.dev/mcp", status: .tested,
                                       composio: ComposioConnectionMetadata(toolkitSlug: "gmail", connectedAccountID: "ca_owned", userID: try XCTUnwrap(secrets.project()["userID"])))
        try store.save(connection)
        do { try await coordinator.disconnect(connection.id); XCTFail("Foreign identity removal reported success") }
        catch { XCTAssertEqual(error as? ComposioError, .remoteRemovalFailed) }
        XCTAssertEqual(try store.get(connection.id)?.status, .disconnected)
        XCTAssertTrue(try secrets.load(connection.id).isEmpty)
    }
    func testDisconnectRemoteFailureKeepsLocalAccessRevoked() async throws {
        let secrets = ComposioFixtureSecrets()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory.path).run()
        let store = ConnectionStore(db: db)
        let client = ComposioClient(transport: ComposioFixtureTransport { request in
            if request.url!.path.hasSuffix("toolkits") { return self.response(request, #"{"items":[]}"#) }
            if request.httpMethod == "DELETE" { return self.response(request, "remote private error", status: 500) }
            let account: [String: ConnectionJSONValue] = ["id": .string("ca_owned"), "user_id": .string(secrets.project()["userID"]!), "toolkit": .object(["slug": .string("gmail")]), "status": .string("ACTIVE")]
            return (try JSONEncoder().encode(account), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let coordinator = ComposioOnboardingCoordinator(store: store, broker: ConnectionBroker(store: store, secrets: secrets), secrets: secrets, client: client)
        try await coordinator.setup(apiKey: "fixture-key")
        let connection = AppConnection(name: "Gmail", kind: .composio, endpoint: "https://backend.composio.dev/mcp", status: .tested,
                                       composio: ComposioConnectionMetadata(toolkitSlug: "gmail", connectedAccountID: "ca_owned", userID: secrets.project()["userID"]!))
        try store.save(connection)
        try secrets.save(["x-api-key": "fixture-key"], for: connection.id)
        do { try await coordinator.disconnect(connection.id); XCTFail("Remote failure reported success") }
        catch { XCTAssertEqual(error as? ComposioError, .remoteRemovalFailed) }
        XCTAssertEqual(try store.get(connection.id)?.status, .disconnected)
        XCTAssertTrue(try secrets.load(connection.id).isEmpty)
    }

    func testPendingAuthorizationTimesOutWithoutGrantingConnection() async throws {
        let secrets = ComposioFixtureSecrets()
        let (store, coordinator, _) = try fixture(transport: ComposioFixtureTransport { request in
            if request.url!.path.hasSuffix("toolkits") { return self.response(request, #"{"items":[]}"#) }
            if request.httpMethod == "DELETE" { return self.response(request, "{}") }
            if request.url!.path.hasSuffix("/link") { return self.response(request, #"{"redirect_url":"https://connect.composio.dev/link/fixture","connected_account_id":"ca_pending"}"#) }
            if request.url!.path.hasSuffix("/session") { return self.response(request, #"{"session_id":"trs_owned","mcp":{"url":"https://backend.composio.dev/mcp"}}"#) }
            let account: [String: ConnectionJSONValue] = ["id": .string("ca_pending"), "user_id": .string(secrets.project()["userID"]!), "toolkit": .object(["slug": .string("gmail")]), "status": .string("INITIALIZING")]
            return (try JSONEncoder().encode(account), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, secrets: secrets, pollAttempts: 1)
        try await coordinator.setup(apiKey: "fixture-key")
        do { _ = try await coordinator.connect(toolkit: ComposioToolkit(slug: "gmail", name: "Gmail", description: "Email."), access: ConnectionAccess(allRuns: true), openURL: { _ in }); XCTFail("Pending account granted access") }
        catch { XCTAssertEqual(error as? ComposioError, .timeout) }
        XCTAssertTrue(try store.list().isEmpty)
    }

}

extension ComposioOnboardingTests {
    func testLegacyConnectionJSONWithoutComposioStillDecodes() throws {
        let legacy = #"{"id":"568A7D9C-C638-4B53-BDEB-0316900E434B","name":"Legacy","account":"","kind":"remoteMCP","endpoint":"https://example.com/mcp","arguments":[],"access":{"allRuns":false,"botIDs":[],"workspaceIDs":[],"threadIDs":[],"taskIDs":[]},"status":"untested","revision":0}"#
        let connection = try JSONDecoder().decode(AppConnection.self, from: Data(legacy.utf8))
        XCTAssertNil(connection.composio)
        XCTAssertEqual(connection.name, "Legacy")
    }
    // Controlled REST and MCP verification fixture; no live project key is used.
    func testActiveOnboardingPinsAccountAndGrantsOnlyAfterMCPVerification() async throws {
        try await exerciseVerifiedOnboarding(failVerification: false)
    }
    func testMCPVerificationFailureNeverGrantsRequestedAccess() async throws {
        try await exerciseVerifiedOnboarding(failVerification: true)
    }
    private func exerciseVerifiedOnboarding(failVerification: Bool) async throws {
        let secrets = ComposioFixtureSecrets()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory.path).run()
        let store = ConnectionStore(db: db)
        let client = ComposioClient(transport: ComposioFixtureTransport { request in
            if request.httpMethod == "DELETE" { return self.response(request, "{}") }
            if request.url!.path.hasSuffix("toolkits") { return self.response(request, #"{"items":[]}"#) }
            if request.url!.path.hasSuffix("/link") { return self.response(request, #"{"redirect_url":"https://connect.composio.dev/link/fixture","connected_account_id":"ca_verified"}"#) }
            if request.url!.path.hasSuffix("/session") {
                let body = try JSONDecoder().decode([String: ConnectionJSONValue].self, from: request.httpBody!)
                if body["connected_accounts"] != nil {
                    XCTAssertEqual(body["connected_accounts"], .object(["gmail": .array([.string("ca_verified")])]))
                    XCTAssertEqual(body["manage_connections"]?.objectValue?["enable"], .bool(false))
                    XCTAssertTrue(try store.list().isEmpty, "Runtime creation must precede any local grant")
                }
                return self.response(request, #"{"session_id":"trs_verified","mcp":{"url":"https://backend.composio.dev/tool_router/v3/trs_verified/mcp"}}"#)
            }
            let account: [String: ConnectionJSONValue] = ["id": .string("ca_verified"), "user_id": .string(secrets.project()["userID"]!), "toolkit": .object(["slug": .string("gmail")]), "status": .string("ACTIVE"), "alias": .string("Personal Gmail")]
            return (try JSONEncoder().encode(account), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let coordinator = ComposioOnboardingCoordinator(store: store, broker: ConnectionBroker(store: store, secrets: secrets), secrets: secrets, client: client, verifyMCPForTesting: { id in
            let pending = try XCTUnwrap(store.get(id))
            XCTAssertEqual(pending.access, ConnectionAccess(), "Pending verification must never grant provider access")
            XCTAssertEqual(pending.status, .untested)
            XCTAssertEqual(pending.composio?.connectedAccountID, "ca_verified")
            XCTAssertFalse(pending.endpoint.contains("trs_verified"), "Full runtime URL must remain protected")
            XCTAssertEqual(try secrets.load(id)["x-api-key"], "fixture-key")
            if failVerification { throw ConnectionError.unavailable }
            try store.markTest(id, revision: pending.revision, success: true)
            return 1
        })
        try await coordinator.setup(apiKey: "fixture-key")
        let requestedAccess = ConnectionAccess(botIDs: ["fixture-bot"])
        do {
            let connected = try await coordinator.connect(toolkit: ComposioToolkit(slug: "gmail", name: "Gmail", description: "Email."), access: requestedAccess, openURL: { url in
                XCTAssertEqual(url.host, "connect.composio.dev")
                XCTAssertTrue(try store.list().isEmpty)
            })
            XCTAssertFalse(failVerification)
            XCTAssertEqual(connected.status, .tested)
            XCTAssertEqual(connected.access, requestedAccess)
            XCTAssertEqual(connected.account, "Personal Gmail")
            XCTAssertEqual(connected.composio, ComposioConnectionMetadata(toolkitSlug: "gmail", connectedAccountID: "ca_verified", userID: secrets.project()["userID"]!))
            let persisted = try XCTUnwrap(store.get(connected.id))
            XCTAssertEqual(persisted, connected)
            let raw = try XCTUnwrap(SettingsRepository(db: db).get(ConnectionStore.storageKey))
            XCTAssertFalse(raw.contains("fixture-key"))
            XCTAssertFalse(raw.contains("trs_verified"))
        } catch {
            guard failVerification else { throw error }
            XCTAssertEqual(error as? ConnectionError, .unavailable)
            let records = try store.list()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.status, .disconnected)
            XCTAssertEqual(records.first?.access, ConnectionAccess())
            XCTAssertTrue(try secrets.load(records[0].id).isEmpty)
        }
    }
}
