import Foundation
import Security
import SocketServer

enum TailcatRuntimeStatus: Equatable, Sendable {
    case off
    case requiresSubscription
    case checking
    case unavailable
    case active

    var displayText: String {
        switch self {
        case .off: return "Off"
        case .requiresSubscription: return "Active subscription required"
        case .checking: return "Checking secure access…"
        case .unavailable: return "Unavailable — retrying securely"
        case .active: return "Available anywhere"
        }
    }
}

actor TailcatRuntimeSupervisor {
    typealias SessionProvider = @Sendable () -> PrivateAccountSession?
    typealias StatusHandler = @Sendable (TailcatRuntimeStatus) -> Void

    private struct ActiveRuntime: Sendable {
        let primary: TailcatRunningServer?
        let fallback: TailcatRunningServer?
        let endpoints: [TailcatCatalogEndpoint]
    }

    private let serverID: String
    private let displayName: String
    private let bridge: any TailcatBridgeRuntime
    private let catalog: any TailcatCatalogAPI
    private let secureStore: any TailcatSecureStateStoring
    private let sessionProvider: SessionProvider
    private let authenticator: TailcatRemoteConnectionAuthenticator
    private let listener: any TailcatLoopbackListening
    private let statusHandler: StatusHandler
    private let now: @Sendable () -> Date
    private let automaticPolling: Bool
    private var enabled = false
    private var generation: UInt64 = 0
    private var loopTask: Task<Void, Never>?
    private var runtime: ActiveRuntime?
    private var lastBackendSuccess: Date?
    private var lastRenewal: Date?
    private var currentSnapshot: TailcatAllowlistSnapshot?
    private var currentETag: String?
    private var lastAccessToken: String?
    private var reconcilePending = false
    private var reconciling = false

    init(
        serverID: String,
        displayName: String,
        bridge: any TailcatBridgeRuntime = LinkedTailcatBridge(),
        catalog: any TailcatCatalogAPI = URLSessionTailcatCatalogAPI(),
        secureStore: any TailcatSecureStateStoring = KeychainTailcatSecureStateStore(),
        sessionProvider: @escaping SessionProvider,
        authenticator: TailcatRemoteConnectionAuthenticator,
        listener: any TailcatLoopbackListening,
        now: @escaping @Sendable () -> Date = { Date() },
        automaticPolling: Bool = true,
        statusHandler: @escaping StatusHandler
    ) {
        self.serverID = serverID
        self.displayName = displayName
        self.bridge = bridge
        self.catalog = catalog
        self.secureStore = secureStore
        self.sessionProvider = sessionProvider
        self.authenticator = authenticator
        self.listener = listener
        self.now = now
        self.automaticPolling = automaticPolling
        self.statusHandler = statusHandler
    }

    func setEnabled(_ enabled: Bool) async {
        generation &+= 1
        self.enabled = enabled
        if !enabled {
            let accessToken = sessionProvider()?.accessToken ?? lastAccessToken
            loopTask?.cancel()
            loopTask = nil
            await stopRuntime()
            statusHandler(.off)
            await deletePublishedHost(accessToken: accessToken)
            lastAccessToken = nil
            return
        }
        statusHandler(.checking)
        let startedAt = now()
        lastBackendSuccess = startedAt
        guard automaticPolling, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                await self.requestReconcile()
                let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                let interval = UInt64(TailcatTransportContract.pollInterval * 1_000_000_000)
                if elapsed < interval {
                    try? await Task.sleep(nanoseconds: interval - elapsed)
                }
            }
        }
    }

#if DEBUG
    func reconcileNowForTesting() async {
        await requestReconcile()
    }

    var hasActiveRuntimeForTesting: Bool { runtime != nil }
#endif

    func accountChanged() async {
        generation &+= 1
        guard enabled else { return }
        let currentSession = sessionProvider()
        guard let session = currentSession, session.user.subscribed else {
            let accessToken = currentSession?.accessToken ?? lastAccessToken
            await revoke(clearKeys: true, status: .requiresSubscription)
            await deletePublishedHost(accessToken: accessToken)
            lastAccessToken = nil
            return
        }
        lastAccessToken = session.accessToken
        await requestReconcile()
    }

    func shutdown() async {
        generation &+= 1
        let accessToken = sessionProvider()?.accessToken ?? lastAccessToken
        enabled = false
        loopTask?.cancel()
        loopTask = nil
        await stopRuntime()
        statusHandler(.off)
        await deletePublishedHost(accessToken: accessToken)
        lastAccessToken = nil
    }

    private func requestReconcile() async {
        guard enabled else { return }
        reconcilePending = true
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        while reconcilePending, enabled {
            reconcilePending = false
            await tick()
        }
    }

    private func tick() async {
        guard enabled else { return }
        let operationGeneration = generation
        guard let session = sessionProvider(), session.user.subscribed else {
            await revoke(clearKeys: true, status: .requiresSubscription)
            return
        }
        lastAccessToken = session.accessToken
        do {
            let response = try await catalog.host(serverID: serverID, accessToken: session.accessToken)
            guard enabled, generation == operationGeneration else { return }
            try validate(response.snapshot, accountID: session.user.id)
            lastBackendSuccess = now()
            currentETag = response.eTag

            if response.snapshot.admittedNodePublics.isEmpty {
                await revoke(
                    clearKeys: true,
                    status: .unavailable,
                    snapshot: response.snapshot,
                    accountID: session.user.id,
                    eTag: response.eTag
                )
                return
            }

            let stored = try secureStore.load()
            let needsRotation = stored?.accountID != session.user.id
                || stored?.allowlistEpoch != response.snapshot.epoch
                || stored?.revision != response.snapshot.revision
                || stored?.snapshotHash != response.snapshot.hash
                || stored?.phase != .active
                || stored?.active == nil
                || response.host == nil
                || response.eTag == nil
                || runtime == nil

            currentSnapshot = response.snapshot
            if needsRotation {
                await rotateAndPublish(snapshot: response.snapshot, session: session, eTag: response.eTag)
            } else if let runtime, let eTag = response.eTag,
                      now().timeIntervalSince(lastRenewal ?? .distantPast) >= TailcatTransportContract.renewalInterval {
                await renew(runtime: runtime, session: session, eTag: eTag)
            } else if runtime != nil {
                statusHandler(.active)
            }
        } catch let error as TailcatCatalogError where error.deniesSubscription {
            guard enabled, generation == operationGeneration else { return }
            await revoke(clearKeys: true, status: .requiresSubscription)
        } catch {
            guard enabled, generation == operationGeneration else { return }
            if now().timeIntervalSince(lastBackendSuccess ?? .distantPast) >= TailcatTransportContract.hostLease {
                await revoke(clearKeys: false, status: .unavailable)
            } else {
                statusHandler(runtime == nil ? .unavailable : .active)
            }
        }
    }

    private func validate(_ snapshot: TailcatAllowlistSnapshot, accountID: String) throws {
        guard let stored = try secureStore.load(), stored.accountID == accountID else { return }
        guard snapshot.epoch == stored.allowlistEpoch else { return }
        if snapshot.revision < stored.revision { throw TailcatCatalogError.invalidResponse }
        if snapshot.revision == stored.revision, snapshot.hash != stored.snapshotHash {
            throw TailcatCatalogError.invalidResponse
        }
    }

    private func rotateAndPublish(
        snapshot: TailcatAllowlistSnapshot,
        session: PrivateAccountSession,
        eTag: String?
    ) async {
        let operationGeneration = generation
        await stopRuntime()
        statusHandler(.checking)
        do {
            let stored = try secureStore.load()
            // A crash may leave an old active key next to a publishing or
            // revoked phase. Only an explicitly active record may carry that
            // key forward while a replacement is published; fail-closed
            // recovery always rotates away from non-active key material.
            let old = stored?.phase == .active ? stored?.active : nil
            let primaryKey = try await Task.detached { try self.bridge.generateKey() }.value
            let fallbackKey = try await Task.detached { try self.bridge.generateKey() }.value
            guard primaryKey != fallbackKey else {
                throw TailcatBridgeError.rejected("server_key_collision")
            }
            let keys = TailcatKeyVersion(primary: primaryKey, fallback: fallbackKey)
            try secureStore.save(TailcatSecureState(
                phase: .publishing,
                accountID: session.user.id,
                allowlistEpoch: snapshot.epoch,
                revision: snapshot.revision,
                snapshotHash: snapshot.hash,
                eTag: eTag,
                active: old,
                pending: keys
            ))

            let listenerSecret = try Self.randomBytes(count: 32)
            let listenerID = try Self.randomBytes(count: 16)
            let peers = snapshot.admittedNodePublics
            authenticator.replaceContexts([
                .init(
                    serverID: "\(serverID).primary",
                    listenerID: listenerID,
                    secret: listenerSecret,
                    allowedPeerPublic: peers
                ),
                .init(
                    serverID: "\(serverID).fallback",
                    listenerID: listenerID,
                    secret: listenerSecret,
                    allowedPeerPublic: peers
                ),
            ])
            let loopbackPort = try listener.start()

            async let primaryTask: Result<TailcatRunningServer, Error> = Task.detached {
                Result { try self.bridge.startServer(
                    key: keys.primary,
                    allowedNodePublics: peers,
                    secret: listenerSecret,
                    listenerID: listenerID,
                    serverID: "\(self.serverID).primary",
                    loopbackPort: loopbackPort,
                    relay: .primary
                ) }
            }.value
            async let fallbackTask: Result<TailcatRunningServer, Error> = Task.detached {
                Result { try self.bridge.startServer(
                    key: keys.fallback,
                    allowedNodePublics: peers,
                    secret: listenerSecret,
                    listenerID: listenerID,
                    serverID: "\(self.serverID).fallback",
                    loopbackPort: loopbackPort,
                    relay: .publicFallback
                ) }
            }.value
            let startResults = await (primaryTask, fallbackTask)
            let primary = try? startResults.0.get()
            let fallback = try? startResults.1.get()
            guard primary != nil || fallback != nil else {
                throw TailcatBridgeError.rejected("server_start_failed")
            }
            var endpoints: [TailcatCatalogEndpoint] = []
            if let primary {
                endpoints.append(TailcatCatalogEndpoint(kind: .derp, priority: 0, connBlob: primary.connBlob))
            }
            if let fallback {
                endpoints.append(TailcatCatalogEndpoint(kind: .derp, priority: 1, connBlob: fallback.connBlob))
            }
            let started = ActiveRuntime(
                primary: primary,
                fallback: fallback,
                endpoints: endpoints
            )
            runtime = started
            guard enabled, generation == operationGeneration else {
                await stopRuntime()
                return
            }
            let published = try await catalog.publishHost(
                serverID: serverID,
                displayName: displayName,
                endpoints: started.endpoints,
                accessToken: session.accessToken,
                ifMatch: eTag
            )
            guard enabled, generation == operationGeneration else {
                await stopRuntime()
                return
            }
            lastBackendSuccess = now()
            lastRenewal = now()
            currentETag = published.eTag
            try secureStore.save(TailcatSecureState(
                phase: .active,
                accountID: session.user.id,
                allowlistEpoch: snapshot.epoch,
                revision: snapshot.revision,
                snapshotHash: snapshot.hash,
                eTag: published.eTag,
                active: keys,
                pending: nil
            ))
            statusHandler(.active)
        } catch {
            await stopRuntime()
            guard enabled, generation == operationGeneration else { return }
            statusHandler(.unavailable)
        }
    }

    private func renew(runtime: ActiveRuntime, session: PrivateAccountSession, eTag: String) async {
        do {
            let published = try await catalog.publishHost(
                serverID: serverID,
                displayName: displayName,
                endpoints: runtime.endpoints,
                accessToken: session.accessToken,
                ifMatch: eTag
            )
            lastBackendSuccess = now()
            lastRenewal = now()
            currentETag = published.eTag
            if var stored = try secureStore.load() {
                stored.eTag = published.eTag
                try secureStore.save(stored)
            }
            statusHandler(.active)
        } catch let error as TailcatCatalogError where error.deniesSubscription {
            await revoke(clearKeys: true, status: .requiresSubscription)
        } catch let error as TailcatCatalogError where error.isConflict {
            await stopRuntime()
            statusHandler(.checking)
        } catch {
            if now().timeIntervalSince(lastBackendSuccess ?? .distantPast) >= TailcatTransportContract.hostLease {
                await revoke(clearKeys: false, status: .unavailable)
            }
        }
    }

    private func revoke(
        clearKeys: Bool,
        status: TailcatRuntimeStatus,
        snapshot: TailcatAllowlistSnapshot? = nil,
        accountID: String? = nil,
        eTag: String? = nil
    ) async {
        generation &+= 1
        await stopRuntime()
        if clearKeys {
            if let snapshot, let accountID {
                try? secureStore.save(TailcatSecureState(
                    phase: .revoked,
                    accountID: accountID,
                    allowlistEpoch: snapshot.epoch,
                    revision: snapshot.revision,
                    snapshotHash: snapshot.hash,
                    eTag: eTag,
                    active: nil,
                    pending: nil
                ))
            } else {
                try? secureStore.clear()
            }
        } else {
            do {
                if var stored = try secureStore.load() {
                    stored.phase = .revoked
                    stored.pending = nil
                    try secureStore.save(stored)
                }
            } catch {
                // A failed durable revoke is fail-closed because the runtime and
                // authenticator contexts were already stopped above.
            }
        }
        statusHandler(status)
    }

    private func stopRuntime() async {
        authenticator.removeAllContexts()
        listener.stop()
        guard let runtime else { return }
        self.runtime = nil
        _ = await Task.detached {
            if let primary = runtime.primary {
                try? self.bridge.closeServer(handle: primary.handle)
            }
            if let fallback = runtime.fallback {
                try? self.bridge.closeServer(handle: fallback.handle)
            }
        }.value
    }

    private func deletePublishedHost(accessToken: String?) async {
        guard let accessToken else { return }
        try? await catalog.deleteHost(serverID: serverID, accessToken: accessToken)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw TailcatSecureStateError.keychain(status) }
        return Data(bytes)
    }
}
