import Foundation
import Security
import SocketServer

enum TailcatRuntimeStatus: String, Equatable, Sendable {
    case off
    case requiresSubscription
    case requiresReauthentication
    case checking
    case unavailable
    case active

    /// Green sidebar badge = connected through the DERP relay (.active);
    /// every other state renders yellow.
    var isDERPConnected: Bool { self == .active }

    var displayText: String {
        switch self {
        case .off: return "Off"
        case .requiresSubscription: return "Active subscription required"
        case .requiresReauthentication: return "Sign in required"
        case .checking: return "Checking secure access…"
        case .unavailable: return "Unavailable — retrying securely"
        case .active: return "Available anywhere"
        }
    }
}

/// `tailcat_access_enabled` ("Connect from anywhere") defaults to on: a missing
/// key — fresh install or never touched — means enabled, and only an explicit
/// "0" (the user turned it off) keeps it disabled.
public enum TailcatAccessDefaults {
    public static func isEnabled(_ rawSetting: String?) -> Bool {
        (rawSetting ?? "1") == "1"
    }
}

actor TailcatRuntimeSupervisor {
    typealias SessionProvider = @Sendable () -> PrivateAccountSession?
    typealias TokenRefresh = @Sendable () async -> String?
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
    private let tokenRefresh: TokenRefresh?
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
    private var secureStateLoaded = false
    private var cachedSecureState: TailcatSecureState?
#if DEBUG
    private var pauseNextSuspend = false
    private var suspendPause: CheckedContinuation<Void, Never>?
#endif

    init(
        serverID: String,
        displayName: String,
        bridge: any TailcatBridgeRuntime = LinkedTailcatBridge(),
        catalog: any TailcatCatalogAPI = URLSessionTailcatCatalogAPI(),
        secureStore: any TailcatSecureStateStoring = KeychainTailcatSecureStateStore(),
        sessionProvider: @escaping SessionProvider,
        tokenRefresh: TokenRefresh? = nil,
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
        self.tokenRefresh = tokenRefresh
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
            await deletePublishedHost(accessToken: accessToken)
            await stopRuntime()
            statusHandler(.off)
            lastAccessToken = nil
            return
        }
        statusHandler(.checking)
        lastBackendSuccess = now()
        startPollingLoopIfNeeded()
    }

    /// Sleep: stop sockets/listener but keep identity, intention, published
    /// host, and keys. A later `resume()` invalidates this generation so a
    /// delayed suspend cannot disable after wake.
    func suspend() async {
        generation &+= 1
        let operationGeneration = generation
        loopTask?.cancel()
        loopTask = nil
        lastBackendSuccess = now()
        let pending = beginStopRuntime()
        await testingYieldIfNeeded()
        await finishStopRuntime(pending)
        guard generation == operationGeneration else { return }
    }

    /// Wake: revalidate account/lease/digest and restart with the same keys
    /// when admission is unchanged. No-ops when the user has disabled access.
    func resume() async {
        generation &+= 1
        let operationGeneration = generation
        guard enabled else { return }
        statusHandler(.checking)
        lastBackendSuccess = now()
        startPollingLoopIfNeeded()
        guard enabled, generation == operationGeneration else { return }
        await requestReconcile()
    }

    var isEnabled: Bool { enabled }

#if DEBUG
    func reconcileNowForTesting() async {
        await requestReconcile()
    }

    var hasActiveRuntimeForTesting: Bool { runtime != nil }

    func pauseNextSuspendForTesting() {
        pauseNextSuspend = true
    }

    var isSuspendPausedForTesting: Bool { suspendPause != nil }

    func continuePausedSuspendForTesting() {
        suspendPause?.resume()
        suspendPause = nil
    }
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

    private func startPollingLoopIfNeeded() {
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
            let catalog = self.catalog
            let serverID = self.serverID
            let response = try await withAccessTokenRetry(accessToken: session.accessToken) { token in
                try await catalog.host(serverID: serverID, accessToken: token)
            }
            guard enabled, generation == operationGeneration else { return }
            let stored = try loadSecureState()
            try TailcatAdmission.validate(
                response.snapshot,
                stored: stored,
                accountID: session.user.id
            )
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
            let needsRotation = TailcatAdmission.needsRotation(
                stored: stored,
                snapshot: response.snapshot,
                accountID: session.user.id,
                hostPresent: response.host != nil,
                eTagPresent: response.eTag != nil,
                runtimePresent: runtime != nil
            )

            currentSnapshot = response.snapshot
            if needsRotation {
                let reusableKeys = runtime == nil
                    ? Self.reusableKeys(
                        stored: stored,
                        snapshot: response.snapshot,
                        accountID: session.user.id
                    )
                    : nil
                await rotateAndPublish(
                    snapshot: response.snapshot,
                    session: session,
                    eTag: response.eTag,
                    reuseKeys: reusableKeys
                )
            } else {
                try persistAdmissionFields(snapshot: response.snapshot)
                if let runtime, let eTag = response.eTag,
                   now().timeIntervalSince(lastRenewal ?? .distantPast) >= TailcatTransportContract.renewalInterval {
                    await renew(runtime: runtime, session: session, eTag: eTag)
                } else if runtime != nil {
                    statusHandler(.active)
                }
            }
        } catch let error as TailcatCatalogError where error.requiresReauthentication {
            guard enabled, generation == operationGeneration else { return }
            statusHandler(.requiresReauthentication)
        } catch let error as TailcatCatalogError where error.deniesAuthorization {
            guard enabled, generation == operationGeneration else { return }
            await revoke(clearKeys: true, status: .unavailable)
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

    private func rotateAndPublish(
        snapshot: TailcatAllowlistSnapshot,
        session: PrivateAccountSession,
        eTag: String?,
        reuseKeys: TailcatKeyVersion? = nil
    ) async {
        let operationGeneration = generation
        await stopRuntime()
        statusHandler(.checking)
        do {
            let keys: TailcatKeyVersion
            if let reuseKeys {
                keys = reuseKeys
            } else {
                let stored = try loadSecureState()
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
                keys = TailcatKeyVersion(primary: primaryKey, fallback: fallbackKey)
                try saveSecureState(TailcatSecureState(
                    phase: .publishing,
                    accountID: session.user.id,
                    allowlistEpoch: snapshot.epoch,
                    revision: snapshot.revision,
                    snapshotHash: snapshot.hash,
                    admissionDigest: snapshot.admissionDigest,
                    eTag: eTag,
                    active: old,
                    pending: keys
                ))
            }

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
            let catalog = self.catalog
            let serverID = self.serverID
            let displayName = self.displayName
            let accessToken = lastAccessToken ?? session.accessToken
            let published = try await withAccessTokenRetry(accessToken: accessToken) { token in
                try await catalog.publishHost(
                    serverID: serverID,
                    displayName: displayName,
                    endpoints: started.endpoints,
                    accessToken: token,
                    ifMatch: eTag
                )
            }
            guard enabled, generation == operationGeneration else {
                await stopRuntime()
                return
            }
            lastBackendSuccess = now()
            lastRenewal = now()
            currentETag = published.eTag
            try saveSecureState(TailcatSecureState(
                phase: .active,
                accountID: session.user.id,
                allowlistEpoch: snapshot.epoch,
                revision: snapshot.revision,
                snapshotHash: snapshot.hash,
                admissionDigest: snapshot.admissionDigest,
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
            let catalog = self.catalog
            let serverID = self.serverID
            let displayName = self.displayName
            let accessToken = lastAccessToken ?? session.accessToken
            let published = try await withAccessTokenRetry(accessToken: accessToken) { token in
                try await catalog.publishHost(
                    serverID: serverID,
                    displayName: displayName,
                    endpoints: runtime.endpoints,
                    accessToken: token,
                    ifMatch: eTag
                )
            }
            lastBackendSuccess = now()
            lastRenewal = now()
            currentETag = published.eTag
            if var stored = try loadSecureState() {
                stored.eTag = published.eTag
                if let snapshot = currentSnapshot {
                    stored.snapshotHash = snapshot.hash
                    stored.admissionDigest = snapshot.admissionDigest
                }
                try saveSecureState(stored)
            }
            statusHandler(.active)
        } catch let error as TailcatCatalogError where error.requiresReauthentication {
            statusHandler(.requiresReauthentication)
        } catch let error as TailcatCatalogError where error.deniesAuthorization {
            await revoke(clearKeys: true, status: .unavailable)
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
                try? saveSecureState(TailcatSecureState(
                    phase: .revoked,
                    accountID: accountID,
                    allowlistEpoch: snapshot.epoch,
                    revision: snapshot.revision,
                    snapshotHash: snapshot.hash,
                    admissionDigest: snapshot.admissionDigest,
                    eTag: eTag,
                    active: nil,
                    pending: nil
                ))
            } else {
                try? clearSecureState()
            }
        } else {
            do {
                if var stored = try loadSecureState() {
                    stored.phase = .revoked
                    stored.pending = nil
                    try saveSecureState(stored)
                }
            } catch {
                // A failed durable revoke is fail-closed because the runtime and
                // authenticator contexts were already stopped above.
            }
        }
        statusHandler(status)
    }

    private func persistAdmissionFields(snapshot: TailcatAllowlistSnapshot) throws {
        guard var stored = try loadSecureState() else { return }
        let digest = snapshot.admissionDigest
        let hash = snapshot.hash
        guard stored.snapshotHash != hash || stored.admissionDigest != digest else { return }
        stored.snapshotHash = hash
        stored.admissionDigest = digest
        try saveSecureState(stored)
    }

    private func loadSecureState() throws -> TailcatSecureState? {
        if secureStateLoaded { return cachedSecureState }
        let state = try secureStore.load()
        cachedSecureState = state
        secureStateLoaded = true
        return state
    }

    private func saveSecureState(_ state: TailcatSecureState) throws {
        try secureStore.save(state)
        cachedSecureState = state
        secureStateLoaded = true
    }

    private func clearSecureState() throws {
        try secureStore.clear()
        cachedSecureState = nil
        secureStateLoaded = true
    }

    private struct ClosingRuntime {
        let primary: TailcatRunningServer?
        let fallback: TailcatRunningServer?
    }

    private func beginStopRuntime() -> ClosingRuntime? {
        authenticator.removeAllContexts()
        listener.stop()
        guard let runtime else { return nil }
        self.runtime = nil
        return ClosingRuntime(primary: runtime.primary, fallback: runtime.fallback)
    }

    private func finishStopRuntime(_ pending: ClosingRuntime?) async {
        guard let pending else { return }
        let bridge = self.bridge
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                if let primary = pending.primary {
                    try? bridge.closeServer(handle: primary.handle)
                }
                if let fallback = pending.fallback {
                    try? bridge.closeServer(handle: fallback.handle)
                }
                continuation.resume()
            }
        }
    }

    private func stopRuntime() async {
        await finishStopRuntime(beginStopRuntime())
    }

    private func testingYieldIfNeeded() async {
#if DEBUG
        guard pauseNextSuspend else { return }
        pauseNextSuspend = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            suspendPause = continuation
        }
#endif
    }

    private func deletePublishedHost(accessToken: String?) async {
        guard let accessToken else { return }
        try? await catalog.deleteHost(serverID: serverID, accessToken: accessToken)
    }

    /// Reuse stored identity keys after sleep when account, epoch, revision,
    /// and admission digest are unchanged. Host/runtime absence is not a
    /// rotation reason on wake — we republish the same keys.
    private static func reusableKeys(
        stored: TailcatSecureState?,
        snapshot: TailcatAllowlistSnapshot,
        accountID: String
    ) -> TailcatKeyVersion? {
        guard let stored,
              stored.phase == .active,
              let keys = stored.active,
              stored.accountID == accountID,
              stored.allowlistEpoch == snapshot.epoch,
              stored.revision == snapshot.revision,
              !TailcatAdmission.admittedPeersChanged(stored: stored, snapshot: snapshot)
        else { return nil }
        return keys
    }

    private func withAccessTokenRetry<T: Sendable>(
        accessToken: String,
        operation: @Sendable (String) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(accessToken)
        } catch let error as TailcatCatalogError where error.requiresReauthentication {
            guard let refreshed = await refreshedAccessToken(stale: accessToken) else {
                throw error
            }
            lastAccessToken = refreshed
            return try await operation(refreshed)
        }
    }

    private func refreshedAccessToken(stale: String) async -> String? {
        if let tokenRefresh {
            guard let token = await tokenRefresh(), !token.isEmpty else { return nil }
            return token
        }
        guard let token = sessionProvider()?.accessToken, token != stale, !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw TailcatSecureStateError.keychain(status) }
        return Data(bytes)
    }
}
