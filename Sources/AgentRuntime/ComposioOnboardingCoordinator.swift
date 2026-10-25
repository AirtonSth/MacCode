import Foundation
import CoreModel
import Persistence

/// Owns app account onboarding; provider runtimes only see the existing ConnectionBroker facade.
/// The project key and stable user ID never enter SQLite, shell arguments or model context.
public actor ComposioOnboardingCoordinator {
    private static let projectRecord = UUID(uuidString: "65D093D6-BC31-4571-A546-69342DCF2139")!
    private let store: ConnectionStore
    private let broker: ConnectionBroker
    private let secrets: any ConnectionSecretStore
    private let client: ComposioClient
    private let verifyMCP: @Sendable (UUID) async throws -> Int
    private let pollAttempts: Int
    private let pollIntervalNanoseconds: UInt64
    private var generation: UInt64 = 0

    public init(store: ConnectionStore, broker: ConnectionBroker,
                secrets: any ConnectionSecretStore = ConnectionKeychainSecretStore(service: (Bundle.main.bundleIdentifier ?? "io.remotecode.desktop") + ".composio.v1"),
                client: ComposioClient = ComposioClient(), pollAttempts: Int = 90, pollIntervalNanoseconds: UInt64 = 2_000_000_000) {
        self.store = store; self.broker = broker; self.secrets = secrets; self.client = client
        self.pollAttempts = max(1, min(pollAttempts, 300)); self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.verifyMCP = { try await broker.test($0) }
    }
    /// Internal fixture seam; the public initializer always verifies through the real MCP broker.
    init(store: ConnectionStore, broker: ConnectionBroker, secrets: any ConnectionSecretStore,
         client: ComposioClient, verifyMCPForTesting: @escaping @Sendable (UUID) async throws -> Int) {
        self.store = store; self.broker = broker; self.secrets = secrets; self.client = client
        self.pollAttempts = 1; self.pollIntervalNanoseconds = 1; self.verifyMCP = verifyMCPForTesting
    }
    public func isConfigured() throws -> Bool {
        let record = try secrets.load(Self.projectRecord)
        return !(record["apiKey"] ?? "").isEmpty && !(record["userID"] ?? "").isEmpty
    }
    /// Validate against the real catalog before committing the Keychain record.
    public func setup(apiKey: String) async throws {
        generation &+= 1; let token = generation
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try secrets.load(Self.projectRecord)
        if let previous = existing["apiKey"], previous != key,
           try store.list().contains(where: { $0.composio != nil && $0.status != .disconnected }) { throw ComposioError.projectInUse }
        _ = try await client.catalog(apiKey: key)
        try check(token)
        try secrets.save(["apiKey": key, "userID": existing["userID"] ?? "maccode-" + UUID().uuidString.lowercased()], for: Self.projectRecord)
    }
    public func catalog(search: String = "", category: String? = nil, cursor: String? = nil) async throws -> ComposioCatalogPage {
        let project = try project()
        return try await client.catalog(apiKey: project.key, search: search, category: category, cursor: cursor)
    }
    /// Invalidates all pending authorization completions, even if a transport ignores Task cancellation.
    public func cancel() { generation &+= 1 }

    public func connect(toolkit: ComposioToolkit, access: ConnectionAccess,
                        openURL: @escaping @Sendable (URL) async throws -> Void) async throws -> AppConnection {
        let project = try project()
        generation &+= 1; let token = generation
        let authSession = try await client.createSession(apiKey: project.key, userID: project.user, toolkit: toolkit.slug)
        try check(token)
        let link: ComposioAuthLink
        do { link = try await client.link(apiKey: project.key, sessionID: authSession.id, toolkit: toolkit.slug) }
        catch { await retireSession(authSession.id, key: project.key); throw error }
        do {
            try check(token)
            try await openURL(link.redirectURL)
            try check(token)
            var authorized: ComposioAccount?
            let deadline = ContinuousClock.now.advanced(by: .seconds(180))
            for attempt in 0..<pollAttempts {
                try check(token)
                guard ContinuousClock.now < deadline else { throw ComposioError.timeout }
                let account = try await client.account(apiKey: project.key, id: link.accountID)
                try check(token)
                try verify(account, metadata: ComposioConnectionMetadata(toolkitSlug: toolkit.slug, connectedAccountID: link.accountID, userID: project.user))
                if account.isActive { authorized = account; break }
                if ["FAILED", "EXPIRED", "REVOKED", "INACTIVE", "DELETED", "DISABLED"].contains(account.status) || account.disabled { throw ComposioError.authorizationFailed }
                if attempt + 1 < pollAttempts { try await Task.sleep(nanoseconds: pollIntervalNanoseconds) }
            }
            guard let account = authorized else { throw ComposioError.timeout }
            try check(token)
            // A separate runtime session has an exact account pin and no in-tool connection creation.
            let runtime = try await client.createSession(apiKey: project.key, userID: project.user, toolkit: toolkit.slug, accountID: account.id)
            do {
                try check(token)
                let metadata = ComposioConnectionMetadata(toolkitSlug: toolkit.slug, connectedAccountID: account.id, userID: project.user)
                let connection = AppConnection(name: toolkit.name, account: account.alias ?? account.id, kind: .composio,
                                               endpoint: runtime.mcpURL.absoluteString, access: ConnectionAccess(), composio: metadata)
                do {
                    try await broker.save(connection, credentials: ["x-api-key": project.key])
                    try check(token)
                    _ = try await verifyMCP(connection.id)
                    try check(token)
                    guard var saved = try store.get(connection.id), saved.status == .tested else { throw ConnectionError.stale }
                    await retireSession(authSession.id, key: project.key)
                    try check(token)
                    // Grant access only after browser, account and MCP verification. No await may follow this commit.
                    saved.access = access
                    try store.save(saved, expectedRevision: saved.revision)
                    guard let committed = try store.get(connection.id) else { throw ConnectionError.stale }
                    return committed
                } catch {
                    // Each attempt owns a fresh UUID: stale cleanup cannot disconnect a newer attempt.
                    try? await broker.disconnect(connection.id)
                    throw error
                }
            } catch {
                await retireSession(runtime.id, key: project.key)
                throw error
            }
        } catch {
            await retireSession(authSession.id, key: project.key)
            throw error
        }
    }

    /// Local capability revocation happens first. Remote removal is attempted only after exact ownership verification.
    public func disconnect(_ id: UUID) async throws {
        generation &+= 1
        guard let connection = try store.get(id) else { throw ConnectionError.unavailable }
        try await broker.disconnect(id)
        guard let metadata = connection.composio else { return }
        do {
            let project = try project()
            guard metadata.userID == project.user else { throw ComposioError.accountMismatch }
            let remote: ComposioAccount
            do { remote = try await client.account(apiKey: project.key, id: metadata.connectedAccountID) }
            catch ComposioError.notFound { return }
            try verify(remote, metadata: metadata)
            try await client.deleteAccount(apiKey: project.key, id: metadata.connectedAccountID)
        } catch {
            // Do not imply provider permission revocation when only local access has been removed.
            throw ComposioError.remoteRemovalFailed
        }
    }

    /// Rechecks only accounts saved by this app. ACTIVE never promotes an untested MCP transport to Tested.
    public func refreshAccounts() async throws -> [AppConnection] {
        let project = try project(), token = generation
        for connection in try store.list() where connection.composio != nil && connection.status != .disconnected {
            guard let metadata = connection.composio else { continue }
            guard metadata.userID == project.user else { throw ComposioError.accountMismatch }
            do {
                let account = try await client.account(apiKey: project.key, id: metadata.connectedAccountID)
                try check(token)
                try verify(account, metadata: metadata)
                if !account.isActive { try store.markTest(connection.id, revision: connection.revision, success: false) }
            } catch ComposioError.notFound {
                try check(token)
                try store.markTest(connection.id, revision: connection.revision, success: false)
            }
        }
        return try store.list()
    }
    private func project() throws -> (key: String, user: String) {
        let record = try secrets.load(Self.projectRecord)
        guard let key = record["apiKey"], !key.isEmpty, let user = record["userID"], !user.isEmpty else { throw ComposioError.setupRequired }
        return (key, user)
    }
    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }
    private func verify(_ account: ComposioAccount, metadata: ComposioConnectionMetadata) throws {
        guard account.id == metadata.connectedAccountID, account.userID == metadata.userID, account.toolkitSlug == metadata.toolkitSlug else { throw ComposioError.accountMismatch }
    }
    private func retireSession(_ id: String, key: String) async {
        // Session cleanup is best effort and never retries execution. Parent task cancellation must not block cleanup.
        let client = client
        await Task.detached { try? await client.deleteSession(apiKey: key, id: id) }.value
    }
}
