import Foundation
import Darwin
import CryptoKit
import Persistence
import AgentRuntime

/// Minimal HTTP/1.1 + WebSocket-stub server used as the desktop-side
/// foundation for a future direct-VPN/LAN mobile client. The intent is
/// architectural readiness (no relay, no cloud broker, loopback-only by
/// default); not to ship a full WebSocket protocol implementation in V1.
///
/// Endpoints in V1:
/// - GET  /v1/discovery
/// - GET  /v1/capabilities
/// - GET  /healthz
/// - GET  /__rc2_static/<grant>/<relative-path>
public protocol DirectAuthProvider: AnyObject {
    func verify(token: String) -> Bool
    func createPairingCode() -> String?
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)?
    /// Device-initiated: create a request and surface a Mac-side
    /// approve/deny modal. Returns the request id + the code to display.
    func createPairingRequest(deviceName: String) -> (requestId: String, code: String)?
    func createPairingRequest(deviceName: String, privateAccountAccessToken: String?) -> (requestId: String, code: String)?
    func createPairingRequest(deviceName: String, clientDeviceID: String?, privateAccountAccessToken: String?) -> (requestId: String, code: String)?
    /// Poll a request. `token` is non-nil exactly once, on the first
    /// poll after approval, and is never persisted server-side.
    func pairingRequestStatus(requestId: String) -> (status: String, deviceId: String?, token: String?)?
    /// Device-initiated cancel of an outstanding pairing request. Returns
    /// true when a known request was moved to a terminal state, false when
    /// the request is unknown/expired. Mirrors the approve/deny store edit
    /// so a later `pairingRequestStatus` reports the terminal state.
    func cancelPairingRequest(requestId: String) -> Bool
    func listDevices() -> [[String: Any]]
    func revokeDevice(_ id: String)
}

/// Defaulted so existing conformers (e.g. test doubles) need no change
/// until they opt into the request/approve flow.
public extension DirectAuthProvider {
    func createPairingRequest(deviceName: String) -> (requestId: String, code: String)? { nil }
    func createPairingRequest(deviceName: String, privateAccountAccessToken: String?) -> (requestId: String, code: String)? {
        createPairingRequest(deviceName: deviceName)
    }
    func createPairingRequest(deviceName: String, clientDeviceID: String?, privateAccountAccessToken: String?) -> (requestId: String, code: String)? {
        createPairingRequest(deviceName: deviceName, privateAccountAccessToken: privateAccountAccessToken)
    }
    func pairingRequestStatus(requestId: String) -> (status: String, deviceId: String?, token: String?)? { nil }
    func cancelPairingRequest(requestId: String) -> Bool { false }
}

/// Thread-safe counters for active WS connections, backpressure, and
/// slow-client evictions. Used by /v1/health to answer \"why is sync slow\".
/// Public so the test suite can inject controlled values.
public final class WSConnectionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _activeClients: Int = 0
    private var _totalQueuedBytes: Int = 0
    private var _slowClientDrops: Int = 0

    public init() {}

    public var activeClients: Int {
        lock.lock(); defer { lock.unlock() }
        return _activeClients
    }

    public var totalQueuedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _totalQueuedBytes
    }

    public var slowClientDrops: Int {
        lock.lock(); defer { lock.unlock() }
        return _slowClientDrops
    }

    /// Called when a WS connection is established.
    public func clientConnected() {
        lock.lock(); _activeClients += 1; lock.unlock()
    }

    /// Called when a WS connection exits. `queuedBytes` is the final
    /// snapshot of the outbound queue for this connection.
    public func clientDisconnected(queuedBytes: Int) {
        lock.lock()
        _activeClients = max(0, _activeClients - 1)
        _totalQueuedBytes = max(0, _totalQueuedBytes - queuedBytes)
        lock.unlock()
    }

    /// Called when the outbound queue for a connection changes (sampled on
    /// enqueue). Replaces the previous sample for this connection.
    public func updateQueuedBytes(previous: Int, current: Int) {
        lock.lock()
        _totalQueuedBytes = max(0, _totalQueuedBytes - previous + current)
        lock.unlock()
    }

    /// Called when the WS outbound queue drops a slow client.
    public func recordSlowClientDrop() {
        lock.lock(); _slowClientDrops += 1; lock.unlock()
    }
}

/// Pure helper: assembles the `connections` sub-object for /v1/health from
/// plain counter inputs. No I/O, no actor, fully unit-testable.
public func connectionMetricsJSON(
    activeClients: Int,
    totalQueuedBytes: Int,
    slowClientDrops: Int
) -> [String: Any] {
    return [
        "active_clients": activeClients,
        "total_queued_bytes": totalQueuedBytes,
        "slow_client_drops": slowClientDrops
    ]
}

/// Pure helper: builds the `WWW-Authenticate` header value for 401 responses.
/// Extracted so callers can unit-test the scheme/realm without a live socket.
public func wwwAuthenticateHeaderValue(scheme: String, realm: String) -> String {
    return "\(scheme) realm=\"\(realm)\""
}

/// Pure helper: builds the `server.listener` EventBus event payload.
/// `bound`=true on success; `address`+`port` reflect the actual bind address.
/// Extracted for unit-testability - no I/O, no actor.
public func serverListenerEventPayload(bound: Bool, address: String, port: UInt16) -> [String: Any] {
    return [
        "bound": bound,
        "address": address,
        "port": Int(port)
    ]
}

/// Pure helper: builds the JSON error body for pairing HTTP error responses.
/// CONTRACT (:23):
///   - HTTP status caller must use: 503 for pairing_disabled, 410 for code_expired / code_invalid,
///     500 for pairing_unavailable.
///   - `code` values are PINNED stable machine codes iOS switches on:
///       "pairing_disabled"    -- auth provider absent (pairing truly off)
///       "pairing_unavailable" -- auth provider errored internally; retry is the fix
///       "code_expired"        -- code was already redeemed or has expired
///       "code_invalid"        -- code was never valid (not currently emitted; reserved)
///   - `message` is a human-localizable string safe to show in iOS UI.
/// Response shape: `{"error":{"code":"<code>","message":"<human>"}}`
/// Extracted as a pure nonisolated function for unit-testability: no I/O, no actor.
public func pairingErrorPayload(code: String) -> [String: Any] {
    let message: String
    switch code {
    case "pairing_disabled":
        message = "Pairing is not available on this Mac."
    case "pairing_unavailable":
        message = "The Mac could not create the pairing request. Try again."
    case "code_expired":
        message = "The pairing code has expired or was already used."
    case "code_invalid":
        message = "The pairing code is not valid."
    default:
        message = "Pairing failed (\(code))."
    }
    return ["error": ["code": code, "message": message]]
}

/// Negotiated WebSocket liveness budget for one connection (C-06).
public struct WebSocketHeartbeatProfile: Equatable, Sendable {
    public let interval: TimeInterval
    public let timeout: TimeInterval

    public init(interval: TimeInterval, timeout: TimeInterval) {
        self.interval = interval
        self.timeout = timeout
    }

    public var intervalMs: Int64 { Int64((interval * 1_000).rounded()) }
    public var timeoutMs: Int64 { Int64((timeout * 1_000).rounded()) }
}

/// One-shot flag for DispatchSource ready waits (C-02). Event and timeout
/// races must signal the waiter at most once.
private final class SocketReadyOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return set
    }

    func trySet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}

final class WebSocketLivenessState: @unchecked Sendable {
    enum Action: Equatable {
        case none
        case ping(Data)
        case timedOut
    }

    private let lock = NSLock()
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private let nonce: @Sendable () -> Data
    private var lastProofAt: TimeInterval
    private var lastPingAt: TimeInterval
    private var outstandingPing: Data?

    init(
        now: TimeInterval,
        interval: TimeInterval,
        timeout: TimeInterval,
        nonce: @escaping @Sendable () -> Data = { Data(UUID().uuidString.utf8) }
    ) {
        self.interval = interval
        self.timeout = timeout
        self.nonce = nonce
        self.lastProofAt = now
        self.lastPingAt = now
    }

    func nextAction(now: TimeInterval) -> Action {
        lock.lock(); defer { lock.unlock() }
        if now - lastProofAt >= timeout { return .timedOut }
        // Real inbound traffic (or a recent pong) is liveness: do not emit a
        // spurious RFC ping while the peer is already proving the path.
        guard outstandingPing == nil,
              now - lastProofAt >= interval,
              now - lastPingAt >= interval else { return .none }
        let payload = nonce().prefix(125)
        let ping = Data(payload)
        outstandingPing = ping
        lastPingAt = now
        return .ping(ping)
    }

    /// C-19: seconds until the next ping or hard timeout. Host timer schedules
    /// only this interest (not a 250 ms poll) so wakeups/conn/min drop ~240 → ~12.
    func nextWakeDelay(now: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let timeoutAt = lastProofAt + timeout
        if outstandingPing != nil {
            return max(0, timeoutAt - now)
        }
        let nextPingAt = max(lastProofAt + interval, lastPingAt + interval)
        return max(0, min(nextPingAt, timeoutAt) - now)
    }

    @discardableResult
    func acceptPong(_ payload: Data, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now - lastProofAt < timeout,
              payload == outstandingPing else { return false }
        outstandingPing = nil
        lastProofAt = now
        lastPingAt = now
        return true
    }

    /// Count any inbound frame as liveness proof (not only matching pongs).
    /// WHY: snapshot/RPC/control traffic already proves the radio path is up;
    /// requiring a dedicated pong forces idle-radio wakeups on 3G (C-06).
    func noteInboundTraffic(now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        lastProofAt = now
        lastPingAt = now
        outstandingPing = nil
    }
}

public final class DirectHTTPServer: @unchecked Sendable {
    enum ConnectionReadWaitStageForTesting: Hashable, Sendable {
        case header(bufferedBytes: Int)
        case body(bufferedBytes: Int, expectedBytes: Int)
        case webSocket
    }

    static let maxRequestHeaderBytes = 64 * 1024
    static let maxRequestBodyBytes = 2 * 1024 * 1024
    /// 25 MiB decoded attachment + base64 expansion + bounded JSON envelope.
    /// The dispatcher/store still enforce the authoritative decoded-byte cap.
    static let maxAttachmentUploadRequestBodyBytes = 36 * 1024 * 1024
    static let maxClientFramePayloadBytes = 1024 * 1024
    public static let maxWebSocketOutboundQueuedBytes = 1024 * 1024
    /// Wi-Fi / unmetered default: snappy dead-peer detection without thrashing radio idle.
    public static let wsHeartbeatProfileWiFi = WebSocketHeartbeatProfile(interval: 10, timeout: 30)
    /// Cellular / Low Data (`X-RC2-WS-Filter: cellular-safe`): tolerate 3G RRC promotion
    /// and allow the radio to sleep between bursts (C-06).
    public static let wsHeartbeatProfileCellular = WebSocketHeartbeatProfile(interval: 25, timeout: 90)
    /// Back-compat aliases → Wi-Fi profile (default when no filter is negotiated).
    public static let wsHeartbeatInterval: TimeInterval = wsHeartbeatProfileWiFi.interval
    public static let wsHeartbeatTimeout: TimeInterval = wsHeartbeatProfileWiFi.timeout
    /// C-03: snapshot progress-idle budgets (ms). Independent of heartbeatTimeoutMs.
    /// Wi-Fi 15s / cellular 45s / Low Data client may propose up to 60s.
    public static let wsSnapshotTimeoutWiFiMs: Int64 = 15_000
    public static let wsSnapshotTimeoutCellularMs: Int64 = 45_000
    public static let wsSnapshotTimeoutMinMs: Int64 = 5_000
    public static let wsSnapshotTimeoutMaxMs: Int64 = 60_000
    /// Socket SO_RCVTIMEO fallback must exceed the longest negotiated heartbeat timeout
    /// so RFC pong / traffic liveness remains authoritative (not the read timeout).
    static let wsSocketReadTimeout: TimeInterval = 120
    /// C-02: fail a write only after this long with *zero* bytes accepted by the
    /// kernel. Large frames on slow uplinks may take longer than 5 s wall time;
    /// progress (any short write) resets the idle clock. Not a total duration budget.
    static let writeProgressIdleTimeout: TimeInterval = 60
    /// C-07: default idle between keep-alive HTTP requests when the server is
    /// constructed without an explicit `clientReceiveTimeoutSeconds`. ~5s closes
    /// abandoned sockets quickly while still covering typical mobile RRC gaps.
    public static let httpKeepAliveIdleTimeoutSeconds = 5

    /// Select the host heartbeat offer from the client's WS filter proposal.
    /// `cellular-safe` → cellular budget; otherwise Wi-Fi. Pure for unit tests.
    nonisolated static func heartbeatProfile(
        forWSFilter filter: EventStreamFilter
    ) -> WebSocketHeartbeatProfile {
        switch filter {
        case .cellularSafe:
            return wsHeartbeatProfileCellular
        case .full:
            return wsHeartbeatProfileWiFi
        }
    }

    /// Negotiate snapshot progress-idle budget (C-03). Client proposes via
    /// `X-RC2-Snapshot-Timeout-Ms`; host clamps to [5s, 60s] and defaults by filter.
    /// Never derived from heartbeatTimeoutMs.
    nonisolated static func negotiateSnapshotTimeoutMs(
        filter: EventStreamFilter,
        proposedMs: Int64?
    ) -> Int64 {
        let offer: Int64 = filter == .cellularSafe
            ? wsSnapshotTimeoutCellularMs
            : wsSnapshotTimeoutWiFiMs
        guard let proposedMs, proposedMs > 0 else { return offer }
        return min(wsSnapshotTimeoutMaxMs, max(wsSnapshotTimeoutMinMs, proposedMs))
    }

    /// Clamp an optional client proposal into the host profile offer.
    /// Client proposes (headers or policy); host accepts within profile, or counters
    /// by the profile ceiling. Missing proposal → host profile defaults.
    nonisolated static func negotiateHeartbeatProfile(
        filter: EventStreamFilter,
        proposedIntervalMs: Int64?,
        proposedTimeoutMs: Int64?
    ) -> WebSocketHeartbeatProfile {
        let offer = heartbeatProfile(forWSFilter: filter)
        let minInterval: TimeInterval = 1
        let interval: TimeInterval
        if let proposedIntervalMs, proposedIntervalMs > 0 {
            interval = min(offer.interval, max(minInterval, TimeInterval(proposedIntervalMs) / 1_000))
        } else {
            interval = offer.interval
        }
        let timeout: TimeInterval
        if let proposedTimeoutMs, proposedTimeoutMs > 0 {
            // Timeout must stay strictly above interval; cap at profile ceiling.
            let proposed = TimeInterval(proposedTimeoutMs) / 1_000
            timeout = min(offer.timeout, max(interval + 1, proposed))
        } else {
            timeout = offer.timeout
        }
        // If clamping made timeout <= interval (extreme proposals), fall back to offer.
        if timeout > interval {
            return WebSocketHeartbeatProfile(interval: interval, timeout: timeout)
        }
        return offer
    }

    /// Pure helper: decides whether the `/v1/ws` upgrade must present a valid
    /// bearer token. Mirrors the HTTP `/v1/*` auth gate: loopback-only binds are
    /// trusted (open), and a missing auth provider means auth is disabled.
    /// Extracted so the gate decision is unit-testable without a live socket.
    nonisolated static func wsUpgradeRequiresToken(loopbackOnly: Bool, hasAuthProvider: Bool) -> Bool {
        !loopbackOnly && hasAuthProvider
    }

    /// Pre-token `/v1/*` paths that must stay open even on a non-loopback bind
    /// (the mobile client fetches these before a token exists). GAP-9.
    nonisolated static let authExemptV1Paths: Set<String> = [
        "/v1/discovery", "/v1/capabilities",
        "/v1/pair", "/v1/pair/redeem", "/v1/pair/status", "/v1/pair/cancel"
    ]

    /// Pure helper: decides whether an HTTP `/v1/*` request must present a valid
    /// bearer token. Mirrors the gate below: loopback-only binds are trusted
    /// (open), pre-token paths are exempt, and a missing auth provider disables
    /// the gate. Extracted so the auth decision is unit-testable without a live
    /// socket (a loopback test client is always treated as trusted, so a real
    /// socket cannot exercise the non-loopback gate).
    nonisolated static func httpAuthGateRequiresToken(loopbackOnly: Bool, path: String, hasAuthProvider: Bool) -> Bool {
        !loopbackOnly && path.hasPrefix("/v1") && !authExemptV1Paths.contains(path) && hasAuthProvider
    }

    nonisolated static func isAttachmentUploadRPCEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "agent.attachment.upload"
    }

    /// Pure helper: search `buf` for the CRLFCRLF header terminator starting
    /// at byte index `from`. The caller must pass
    ///   from = max(0, previousBufferCount - (terminator.count - 1))
    /// so that a terminator split across two consecutive appends is never
    /// missed while each call only scans newly-appended bytes (plus a small
    /// overlap). No I/O; extracted for unit-testability.
    nonisolated static func nextHeaderTerminatorRange(
        in buf: Data,
        from: Int
    ) -> Range<Data.Index>? {
        let terminator = Data("\r\n\r\n".utf8)
        let searchStart = buf.index(buf.startIndex, offsetBy: from)
        let slice = buf[searchStart...]
        guard let r = slice.range(of: terminator) else { return nil }
        return r
    }

    public let port: UInt16
    public let bindLoopbackOnly: Bool
    public let dispatcher: JSONRPCDispatcher
    public let commandReceiptMetrics: CommandReceiptMetrics
    public weak var auth: DirectAuthProvider?
    /// Stable, persisted host identity. iOS pins this (RCA-022); it must
    /// survive process restarts or every relaunch looks like a different
    /// Mac and forces a re-pair (GAP-2).
    public let serverId: String
    public let bootEpoch: UInt64

    /// Per-peer brute-force brake for the LAN pairing endpoints. The 6-digit
    /// code is brute-forceable over LAN without this throttle.
    let pairingThrottle = PairingThrottle()

    /// Live connection-level metrics surfaced via /v1/health.
    let wsTracker = WSConnectionTracker()
    private let activeWebSocketConnections = ActiveWebSocketConnectionRegistry()
    private let receiveTimeoutSeconds: Int
    private let webSocketOutboundMaxQueuedBytes: Int

    private var listenFD: Int32 = -1
    private var accept: Thread?
    private let acceptedSockets = AcceptedSocketRegistry()

    static let maximumAcceptedConnections = AcceptedSocketRegistry.defaultMaximumDescriptors
    var acceptedSocketCountForTests: Int { acceptedSockets.count }
    var afterWelcomeWriteForTests: ((String) -> Void)?
    var acceptedFDObserverForTesting: (@Sendable (Int32) -> Void)?
    var connectionReadWaitObserverForTesting: (@Sendable (Int32, ConnectionReadWaitStageForTesting) -> Void)?

    public init(port: UInt16 = 18217, loopbackOnly: Bool = true, dispatcher: JSONRPCDispatcher, auth: DirectAuthProvider? = nil, serverId: String = ProcessInfo.processInfo.globallyUniqueString, bootEpoch: UInt64, clientReceiveTimeoutSeconds: Int = DirectHTTPServer.httpKeepAliveIdleTimeoutSeconds, webSocketOutboundMaxQueuedBytes: Int = DirectHTTPServer.maxWebSocketOutboundQueuedBytes) {
        self.port = port
        self.bindLoopbackOnly = loopbackOnly
        self.dispatcher = dispatcher
        self.commandReceiptMetrics = dispatcher.commandReceiptMetrics
        self.auth = auth
        self.serverId = serverId
        self.bootEpoch = bootEpoch
        self.receiveTimeoutSeconds = max(1, clientReceiveTimeoutSeconds)
        self.webSocketOutboundMaxQueuedBytes = max(1, webSocketOutboundMaxQueuedBytes)
    }

    public func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        if listenFD < 0 { throw POSIXError(.EIO) }
        // Close-on-exec: forkpty terminal shells (and any other spawned child)
        // must not inherit the listener, or an orphaned child keeps port 18217
        // bound after the app stops and every rebind fails EADDRINUSE while
        // iOS connects hang in a backlog nobody accepts.
        guard Self.enableCloseOnExec(listenFD) else {
            let savedErrno = errno
            close(listenFD)
            listenFD = -1
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = bindLoopbackOnly ? inet_addr("127.0.0.1") : INADDR_ANY.bigEndian
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, addrLen) }
        }
        if rc < 0 {
            let savedErrno = errno
            let msg = String(cString: strerror(savedErrno))
            close(listenFD); listenFD = -1
            let bindAddr = bindLoopbackOnly ? "127.0.0.1" : "0.0.0.0"
            let failPayload = serverListenerEventPayload(bound: false, address: bindAddr, port: port)
            EventBus.shared.publish(kind: "server.listener", payload: .object(failPayload.mapValues { v in
                if let b = v as? Bool { return .bool(b) }
                if let i = v as? Int { return .number(Double(i)) }
                if let s = v as? String { return .string(s) }
                return .string("\(v)")
            }))
            throw NSError(domain: "RC2.HTTP", code: Int(savedErrno), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        if Darwin.listen(listenFD, 32) < 0 {
            let savedErrno = errno
            close(listenFD); listenFD = -1
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
        let acceptanceGeneration = acceptedSockets.activate()
        let listenerDescriptor = listenFD
        let t = Thread { [weak self] in
            self?.acceptLoop(
                listenerDescriptor: listenerDescriptor,
                acceptanceGeneration: acceptanceGeneration
            )
        }
        t.name = "RC2.HTTPAccept"
        t.start()
        accept = t
        let bindAddr = bindLoopbackOnly ? "127.0.0.1" : "0.0.0.0"
        let successPayload = serverListenerEventPayload(bound: true, address: bindAddr, port: port)
        EventBus.shared.publish(kind: "server.listener", payload: .object(successPayload.mapValues { v in
            if let b = v as? Bool { return .bool(b) }
            if let i = v as? Int { return .number(Double(i)) }
            if let s = v as? String { return .string(s) }
            return .string("\(v)")
        }))
    }

    public func stop() {
        // Gate accepted ownership before closing the listener. A concurrent
        // accept may still return, but its generation-aware registration will
        // reject and close the descriptor instead of reviving it on restart.
        acceptedSockets.shutdownAll()
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop(listenerDescriptor: Int32, acceptanceGeneration: UInt64) {
        let registry = acceptedSockets
        while registry.isAccepting(generation: acceptanceGeneration) {
            var caddr = sockaddr()
            var clen = socklen_t(MemoryLayout<sockaddr>.size)
            let fd = Darwin.accept(listenerDescriptor, &caddr, &clen)
            if fd < 0 {
                if !registry.isAccepting(generation: acceptanceGeneration) { return }
                continue
            }
            // Same close-on-exec rule as the listener: a child spawned while a
            // request is in flight must not hold the client connection open.
            guard Self.enableCloseOnExec(fd) else {
                let savedErrno = errno
                shutdown(fd, SHUT_RDWR)
                close(fd)
                EventBus.shared.publish(kind: "diagnostic.http_cloexec_failed", payload: .object([
                    "errno": .number(Double(savedErrno))
                ]))
                continue
            }
            disableSIGPIPE(fd: fd)
            switch registry.register(fd, generation: acceptanceGeneration) {
            case .accepted:
                break
            case .inactive:
                continue
            case let .atCapacity(active, limit, shouldPublishDiagnostic):
                if shouldPublishDiagnostic {
                    EventBus.shared.publish(kind: "diagnostic.http_connection_limit", payload: .object([
                        "active_connections": .number(Double(active)),
                        "maximum_connections": .number(Double(limit))
                    ]))
                }
                continue
            }
            let peer = Self.peerIP(caddr)
            acceptedFDObserverForTesting?(fd)
            // C-25: dedicated Thread per accepted connection (not GCD global).
            // WS sessions park for minutes; HTTP keep-alive can too. Pool workers
            // must stay free for short bursts (RPC tasks, outbound writes).
            let thread = Thread { [weak self] in
                guard let self else {
                    registry.close(fd)
                    return
                }
                self.handle(fd: fd, peer: peer)
            }
            thread.name = "rc2.conn.\(fd)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func disableSIGPIPE(fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    @discardableResult
    static func enableCloseOnExec(
        _ fd: Int32,
        getFlags: (Int32) -> Int32 = { fcntl($0, F_GETFD) },
        setFlags: (Int32, Int32) -> Int32 = { fcntl($0, F_SETFD, $1) }
    ) -> Bool {
        guard fd >= 0 else { return false }
        let flags = getFlags(fd)
        guard flags >= 0 else { return false }
        guard flags & FD_CLOEXEC == 0 else { return true }
        return setFlags(fd, flags | FD_CLOEXEC) == 0
    }

    /// C-02: non-blocking sockets surface a full send buffer as EAGAIN instead of
    /// a fatal SO_SNDTIMEO failure mid-frame.
    @discardableResult
    static func enableNonBlocking(
        _ fd: Int32,
        getFlags: (Int32) -> Int32 = { fcntl($0, F_GETFL) },
        setFlags: (Int32, Int32) -> Int32 = { fcntl($0, F_SETFL, $1) }
    ) -> Bool {
        guard fd >= 0 else { return false }
        let flags = getFlags(fd)
        guard flags >= 0 else { return false }
        guard flags & O_NONBLOCK == 0 else { return true }
        return setFlags(fd, flags | O_NONBLOCK) == 0
    }

    /// C-07: restore blocking mode after `writeAll` (C-02) so the keep-alive
    /// idle wait can use `SO_RCVTIMEO` instead of spinning on EAGAIN.
    @discardableResult
    static func enableBlocking(
        _ fd: Int32,
        getFlags: (Int32) -> Int32 = { fcntl($0, F_GETFL) },
        setFlags: (Int32, Int32) -> Int32 = { fcntl($0, F_SETFL, $1) }
    ) -> Bool {
        guard fd >= 0 else { return false }
        let flags = getFlags(fd)
        guard flags >= 0 else { return false }
        guard flags & O_NONBLOCK != 0 else { return true }
        return setFlags(fd, flags & ~O_NONBLOCK) == 0
    }

    @inline(__always)
    static func readRetryingInterrupts(_ operation: () -> Int) -> Int {
        while true {
            let count = operation()
            if count < 0, errno == EINTR { continue }
            return count
        }
    }

    /// C-02: park until the kernel reports the socket is writable (or timeout).
    /// Uses `DispatchSourceWrite` so a full send buffer is a wait, not a close.
    static func waitForWritable(fd: Int32, timeout: TimeInterval) -> Bool {
        waitForSocketReady(fd: fd, interest: .writable, timeout: timeout)
    }

    /// Readable counterpart for O_NONBLOCK WS/HTTP reads after C-02.
    static func waitForReadable(fd: Int32, timeout: TimeInterval) -> Bool {
        waitForSocketReady(fd: fd, interest: .readable, timeout: timeout)
    }

    private enum SocketReadyInterest {
        case readable
        case writable
    }

    private static func waitForSocketReady(
        fd: Int32,
        interest: SocketReadyInterest,
        timeout: TimeInterval
    ) -> Bool {
        guard fd >= 0, timeout > 0 else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "rc2.socket.ready.\(fd)")
        let source: DispatchSourceProtocol
        switch interest {
        case .readable:
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        case .writable:
            source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        }
        let fired = SocketReadyOnceFlag()
        source.setEventHandler {
            if fired.trySet() {
                source.cancel()
                semaphore.signal()
            }
        }
        source.setCancelHandler {}
        source.resume()
        let result = semaphore.wait(timeout: .now() + timeout)
        if !fired.isSet {
            source.cancel()
        }
        // Flush cancel so GCD releases its ref on the fd before the caller closes.
        queue.sync {}
        return result == .success && fired.isSet
    }

    /// Numeric source IP of an accepted connection, used as the throttle key.
    /// Falls back to "unknown" so a peer we can't parse still shares a single
    /// throttle bucket rather than bypassing the limiter.
    static func peerIP(_ addr: sockaddr) -> String {
        var addr = addr
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(addr.sa_len)
        let rc = withUnsafePointer(to: &addr) { ptr in
            getnameinfo(ptr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
        return rc == 0 ? String(cString: host) : "unknown"
    }

    private func handle(fd: Int32, peer: String) {
        // C-07: entry owns close; RPC handoff re-enters via `serveHTTPSession`.
        serveHTTPSession(fd: fd, peer: peer, initialBuffer: Data(), ownsClose: true)
    }

    /// C-07: HTTP keep-alive session. Serves request after request on one TCP
    /// connection until idle `SO_RCVTIMEO`, peer close, protocol error, client
    /// `Connection: close`, or WebSocket upgrade. `ownsClose` is false only when
    /// a parent already registered a defer/close owner (unused today; reserved
    /// for nested call sites).
    private func serveHTTPSession(fd: Int32, peer: String, initialBuffer: Data, ownsClose: Bool) {
        var subID: UUID?
        // PERF-114: when the /v1/rpc handler hands the fd off to an async
        // Task, that Task owns the fd lifecycle (send + close). The defer
        // must NOT also close it, or we double-close. handedOff gates that.
        var handedOff = false
        defer {
            if ownsClose && !handedOff {
                if let s = subID { EventBus.shared.unsubscribe(s) }
                acceptedSockets.close(fd)
            }
        }
        var buffer = initialBuffer
        var tmp = [UInt8](repeating: 0, count: 4096)
        let terminatorLength = 4 // "\r\n\r\n"

        // C-07: one TCP connection → many HTTP requests.
        while acceptedSockets.isActive(fd) {
        // C-07 / C-02: `writeAll` leaves the socket O_NONBLOCK. Restore
        // blocking + SO_RCVTIMEO so idle keep-alive waits for the next
        // request (or times out) instead of treating EAGAIN as peer close.
        _ = Self.enableBlocking(fd)
        var rcvTimeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))
        // headerSearchOffset: start each scan from (prevCount - 3) so a
        // terminator split across two reads is never missed, while avoiding
        // re-scanning bytes already checked. The overlap is terminatorLength-1
        // = 3 bytes; without it "\r\n" at the end of one read and "\r\n" at
        // the start of the next would be invisible to the scanner.
        // Check buffer first so pipelined leftovers do not block on read.
        var headerSearchOffset = 0
        while acceptedSockets.isActive(fd),
              Self.nextHeaderTerminatorRange(in: buffer, from: 0) == nil {
            let prevCount = buffer.count
            let n = Self.readRetryingInterrupts {
                Darwin.read(fd, &tmp, tmp.count)
            }
            // n <= 0: peer FIN, SO_RCVTIMEO idle (EAGAIN/ETIMEDOUT), or hard error.
            if n <= 0 { return }
            buffer.append(tmp, count: n)
            if buffer.count > Self.maxRequestHeaderBytes {
                send(fd: fd, status: 431, contentType: "text/plain", body: Data("request header too large\n".utf8))
                return
            }
            headerSearchOffset = max(0, prevCount - (terminatorLength - 1))
            if Self.nextHeaderTerminatorRange(in: buffer, from: headerSearchOffset) != nil { break }
            connectionReadWaitObserverForTesting?(
                fd,
                .header(bufferedBytes: buffer.count)
            )
        }
        guard acceptedSockets.isActive(fd) else { return }
        guard let headerEnd = Self.nextHeaderTerminatorRange(in: buffer, from: 0) else { return }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return }
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let requestTarget = String(parts[1])
        let path = requestTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestTarget

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let r = line.range(of: ":") {
                let k = String(line[..<r.lowerBound]).lowercased().trimmingCharacters(in: .whitespaces)
                let v = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        let presentedBearerToken = Self.bearerToken(from: headers)
        let clientRequestsClose = Self.httpClientRequestsClose(headers)

        // Read remaining body bytes if Content-Length declares more
        // than we already have.
        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsed = Int(rawContentLength), parsed >= 0 else {
                send(fd: fd, status: 400, contentType: "text/plain", body: Data("bad content length\n".utf8))
                return
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        let requestedAttachmentUpload = method == "POST"
            && path == "/v1/rpc"
            && headers["x-remotecode-attachment-upload"] == "1"
        let largeBodyAuthorized: Bool
        if Self.httpAuthGateRequiresToken(
            loopbackOnly: bindLoopbackOnly,
            path: path,
            hasAuthProvider: auth != nil
        ), let auth {
            if let presentedBearerToken {
                largeBodyAuthorized = auth.verify(token: presentedBearerToken)
            } else {
                largeBodyAuthorized = false
            }
        } else {
            largeBodyAuthorized = true
        }
        let requestBodyLimit = requestedAttachmentUpload && largeBodyAuthorized
            ? Self.maxAttachmentUploadRequestBodyBytes
            : Self.maxRequestBodyBytes
        guard contentLength <= requestBodyLimit else {
            send(fd: fd, status: 413, contentType: "text/plain", body: Data("request body too large\n".utf8))
            return
        }
        let bodyStartAbsolute = headerEnd.upperBound
        var bodyHave = buffer.count - bodyStartAbsolute
        while acceptedSockets.isActive(fd), bodyHave < contentLength {
            connectionReadWaitObserverForTesting?(
                fd,
                .body(bufferedBytes: bodyHave, expectedBytes: contentLength)
            )
            let n = Self.readRetryingInterrupts {
                Darwin.read(fd, &tmp, tmp.count)
            }
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            bodyHave += n
        }
        guard bodyHave >= contentLength, acceptedSockets.isActive(fd) else { return }
        // Bytes after this request's body belong to the next pipelined request.
        let bodyEndAbsolute = bodyStartAbsolute + contentLength
        let leftoverBuffer: Data = bodyEndAbsolute < buffer.count
            ? Data(buffer[bodyEndAbsolute..<buffer.endIndex])
            : Data()

        // WebSocket upgrade
        if method == "GET", path == "/v1/ws",
           headers["upgrade"]?.lowercased() == "websocket",
           let key = headers["sec-websocket-key"] {
            // SECURITY (P1, worst defect found): gate the /v1/ws upgrade with the
            // SAME bearer-token check as the other /v1/* routes below. The upgrade
            // block runs before the HTTP auth gate and returns, so without this an
            // unauthenticated non-loopback LAN peer could subscribe to /v1/ws and
            // receive terminal output, agent messages, and file-edit contents.
            // Loopback-only mode stays open, matching the HTTP gate (loopback is
            // trusted) and preserving the loopbackOnly: true test harness.
            if Self.wsUpgradeRequiresToken(loopbackOnly: bindLoopbackOnly, hasAuthProvider: auth != nil),
               let auth = auth {
                guard let token = presentedBearerToken, auth.verify(token: token) else {
                    send(fd: fd, status: 401, contentType: "text/plain",
                         body: "unauthorized\n".data(using: .utf8)!,
                         additionalHeaders: ["WWW-Authenticate": wwwAuthenticateHeaderValue(scheme: "Bearer", realm: "RC2")]); return
                }
            }
            let webSocketOwnerFingerprint = Self.connectionOwnerFingerprint(
                token: presentedBearerToken
            )
            performWSHandshake(fd: fd, key: key)
            // C-02: non-blocking after upgrade so full send buffers yield EAGAIN
            // (retry via DispatchSourceWrite) instead of fatal mid-frame closes.
            _ = Self.enableNonBlocking(fd)
            let wsCompressionEnabled = headers["x-rc2-ws-encoding"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(PayloadCodec.lzfse.wireName) == true
            let wsFilter = EventStreamFilter.parse(headers["x-rc2-ws-filter"])
            // C-06: client proposes via filter (+ optional heartbeat headers); host
            // accepts within the network profile or counters with the profile ceiling.
            let proposedIntervalMs = headers["x-rc2-heartbeat-interval-ms"]
                .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            let proposedTimeoutMs = headers["x-rc2-heartbeat-timeout-ms"]
                .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            let heartbeat = Self.negotiateHeartbeatProfile(
                filter: wsFilter,
                proposedIntervalMs: proposedIntervalMs,
                proposedTimeoutMs: proposedTimeoutMs
            )
            // C-03: snapshot progress budget is negotiated separately from heartbeat.
            let proposedSnapshotTimeoutMs = headers["x-rc2-snapshot-timeout-ms"]
                .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            let snapshotTimeoutMs = Self.negotiateSnapshotTimeoutMs(
                filter: wsFilter,
                proposedMs: proposedSnapshotTimeoutMs
            )
            // RFC ping/pong + inbound traffic own liveness. SO_RCVTIMEO is only a
            // fallback and must exceed the negotiated timeout so 1012 remains the
            // authoritative dead-peer close (not a silent read timeout).
            let receiveTimeoutSeconds = max(
                Self.wsSocketReadTimeout,
                heartbeat.timeout + heartbeat.interval
            )
            var wsReceiveTimeout = timeval(
                tv_sec: Int(receiveTimeoutSeconds.rounded(.up)),
                tv_usec: 0
            )
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &wsReceiveTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            )
            let frameWriter = WebSocketConnectionWriter { [weak self] opcode, data in
                guard let self else { return false }
                return self.sendWSFrame(fd: fd, opcode: opcode, data: data)
            }
            let connectionId = UUID().uuidString
            let eventSnapshot = EventBus.shared.snapshotMetadata()
            let requestedSinceSequence = headers["x-rc2-since-seq"]
                .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            let wsSinceSeq = min(max(0, requestedSinceSequence), eventSnapshot.sequence)
            let sequenceWatermark = ConnectionSequenceWatermark(initialSequence: wsSinceSeq)
            let welcome = ConnectionTransportFrame.welcome(ConnectionWelcomeFrame(
                protocolVersion: ConnectionTransportFrame.protocolVersion,
                type: "welcome",
                connectionId: connectionId,
                hostId: serverId,
                bootEpoch: bootEpoch,
                serverTimeEpochMs: Int64(Date().timeIntervalSince1970 * 1_000),
                heartbeatIntervalMs: heartbeat.intervalMs,
                heartbeatTimeoutMs: heartbeat.timeoutMs,
                snapshotTimeoutMs: snapshotTimeoutMs,
                currentSequence: eventSnapshot.sequence,
                oldestReplaySequence: eventSnapshot.oldestReplaySequence,
                // Wave 4: rpc.websocket + snapshot.incremental advertised so
                // clients can hydrate without new TCP and request domain deltas.
                capabilities: [
                    "events.replay", "jsonrpc.batch", "snapshot.v3",
                    "rpc.websocket", "snapshot.incremental",
                ]
            ))
            activeWebSocketConnections.insert(
                connectionId,
                ownerFingerprint: webSocketOwnerFingerprint,
                watermark: sequenceWatermark
            )
            defer { activeWebSocketConnections.remove(connectionId) }
            guard let welcomeData = try? welcome.encoded(),
                  frameWriter.send(opcode: 0x1, data: welcomeData) else {
                return
            }
            afterWelcomeWriteForTests?(connectionId)
            let subIDBox = LockedSubscriberID()
            let writeFailureClosing = connectionClosingData(
                connectionId: connectionId,
                reason: "write_failed",
                code: 1011,
                retryable: true,
                retryAfterMs: 1_000
            ) ?? Data()
            let outbound = WebSocketOutboundQueue(
                maxQueuedBytes: webSocketOutboundMaxQueuedBytes,
                applicationWriter: { [weak self] data in
                    guard let self else { return false }
                    return self.sendWSEvent(
                        writer: frameWriter,
                        data: data,
                        compressed: wsCompressionEnabled
                    )
                },
                controlWriter: { opcode, data in
                    frameWriter.send(opcode: opcode, data: data)
                },
                writeFailureClosingData: writeFailureClosing,
                onTerminal: { [weak self] reason in
                    // C-04: queue_full no longer terminates. Only true write
                    // failures close the socket.
                    guard reason == "write_failed" else { return }
                    NSLog("[RC2.WS] slow-client close: reason=%@ baseline_required=true", reason)
                    if let id = subIDBox.value { EventBus.shared.unsubscribe(id) }
                    self?.wsTracker.recordSlowClientDrop()
                    EventBus.shared.publish(kind: "diagnostic.ws_slow_client", payload: .object([
                        "reason": .string(reason),
                        "baseline_required": .bool(true)
                    ]))
                },
                didSendTerminal: { [weak self] in
                    self?.activeWebSocketConnections.remove(connectionId)
                    shutdown(fd, SHUT_RDWR)
                }
            )
            // C-04: pressure baseline_required ≤1/s, never as a close reason.
            let pressureBaselineGate = OutboundPressureBaselineGate()
            let emitPressureBaseline: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                guard pressureBaselineGate.tryAcquire() else { return }
                let current = sequenceWatermark.value
                guard let baselineData = self.connectionBaselineRequiredData(
                    connectionId: connectionId,
                    requestedAfterSequence: current,
                    currentSequence: current
                ) else { return }
                switch outbound.enqueueApplication(baselineData) {
                case .accepted:
                    break
                case .queueFull:
                    _ = outbound.degrade()
                    _ = outbound.enqueueApplication(baselineData)
                case .closed:
                    return
                }
                NSLog(
                    "[RC2.WS] outbound pressure: baseline_required without close seq=%lld",
                    current
                )
                EventBus.shared.publish(kind: "diagnostic.ws_outbound_pressure", payload: .object([
                    "reason": .string("outbound_queue_pressure"),
                    "baseline_required": .bool(true),
                    "current_sequence": .number(Double(current))
                ]))
            }
            let recordAcceptedEvent: @Sendable (Data) -> Void = { data in
                if case .event(let frame) = try? ConnectionTransportFrame.decodeStrict(data) {
                    if case .gap(let expected, let received) = sequenceWatermark.recordEnqueuedEvent(
                        sequence: frame.sequence
                    ) {
                        _ = outbound.terminate(
                            errorData: nil,
                            closingData: self.connectionClosingData(
                                connectionId: connectionId,
                                reason: "eventGap_\(expected)_\(received)",
                                code: 1012,
                                retryable: true,
                                retryAfterMs: 0
                            ),
                            reason: "event_gap"
                        )
                    }
                }
            }
            /// C-04 degrade ladder: never close on queueFull.
            let enqueueApplicationOrDegrade: @Sendable (Data) -> Void = { data in
                switch outbound.enqueueApplication(data) {
                case .accepted:
                    recordAcceptedEvent(data)
                case .queueFull:
                    let outcome = outbound.degrade()
                    if outcome.needsBaselineRequired {
                        emitPressureBaseline()
                    }
                    // Prefer shedding bulk/diagnostic arrivals over closing.
                    if WebSocketOutboundQueue.isSheddableApplicationFrame(data) {
                        if let sequence = WebSocketOutboundQueue.eventSequence(in: data) {
                            sequenceWatermark.recordFilteredEvent(sequence: sequence)
                        }
                        emitPressureBaseline()
                        return
                    }
                    switch outbound.enqueueApplication(data) {
                    case .accepted:
                        recordAcceptedEvent(data)
                    case .queueFull:
                        // Still saturated after degrade: drop with filtered
                        // watermark accounting; socket stays open.
                        if let sequence = WebSocketOutboundQueue.eventSequence(in: data) {
                            sequenceWatermark.recordFilteredEvent(sequence: sequence)
                        }
                        emitPressureBaseline()
                    case .closed:
                        break
                    }
                case .closed:
                    break
                }
            }
            // C-14: keyed summary batching only on cellular-safe (collapses
            // terminal.output.summary per surface → ≥5× fewer summaries/sec).
            // C-15: coalesce agent.item.delta on all links; cellular uses a longer
            // window (100ms) so ~10× fewer frames than one-frame-per-token.
            let coalescingDelayMs = wsFilter == .cellularSafe ? 100 : 15
            let batcher = WebSocketEventBatcher(
                enabled: wsFilter == .cellularSafe,
                filter: wsFilter,
                delay: TimeInterval(coalescingDelayMs) / 1000.0,
                // PERF: coalesce per-token agent.item.delta frames; non-delta
                // events flush immediately when only streaming coalescing is active.
                coalescesStreamingDeltas: true,
                // C-14: LWW-collapsed summary frames never leave the host; advance
                // the gap watermark so zero new 1012 closes in soak.
                onCoalescedAway: { data in
                    if let sequence = WebSocketOutboundQueue.eventSequence(in: data) {
                        sequenceWatermark.recordFilteredEvent(sequence: sequence)
                    }
                }
            ) { data in
                enqueueApplicationOrDegrade(data)
            }
            // PERF-MAC_SOCKET-:110 -- honor the client's last-seen seq so a
            // reconnect receives only the delta (events after that seq), not the
            // full retained backlog (~4 MiB on a busy session).
            // Slice boundary: EventBus.subscribe delivers event.seq > since, so
            // the first event the client receives is the first it has NOT yet seen.
            // A missing or non-numeric header falls back to 0 (full backlog) so
            // first-connect and legacy clients continue to work correctly.
            let id = EventBus.shared.subscribeDetectingReplayExpiry(
                since: wsSinceSeq,
                filter: wsFilter,
                onReplayExpired: { metadata in
                    // The delivery cursor re-anchored to the live head
                    // (metadata.sequence); the gap watermark must follow BEFORE
                    // any live event is enqueued, or the first event after
                    // baselineRequired reads as a gap and closes 1012.
                    sequenceWatermark.reanchorForExpiredReplay(
                        sequence: metadata.sequence
                    )
                    guard let data = self.connectionBaselineRequiredData(
                        connectionId: connectionId,
                        requestedAfterSequence: wsSinceSeq,
                        currentSequence: metadata.sequence
                    ) else { return }
                    // C-04: never close for queue pressure; degrade and retry.
                    switch outbound.enqueueApplication(data) {
                    case .accepted:
                        break
                    case .queueFull:
                        _ = outbound.degrade()
                        if outbound.enqueueApplication(data) == .queueFull {
                            emitPressureBaseline()
                        }
                    case .closed:
                        break
                    }
                },
                onFilteredEvent: { sequence in
                    // A seq dropped by this connection's negotiated filter is
                    // not a gap; account for it so the next delivered event
                    // stays contiguous instead of closing 1012.
                    sequenceWatermark.recordFilteredEvent(sequence: sequence)
                }
            ) { ev in
                let frame = ConnectionTransportFrame.event(ConnectionEventFrame(
                    protocolVersion: ConnectionTransportFrame.protocolVersion,
                    type: "event",
                    connectionId: connectionId,
                    hostId: self.serverId,
                    bootEpoch: self.bootEpoch,
                    sequence: ev.seq,
                    eventId: "\(self.bootEpoch):\(ev.seq)",
                    occurredAtEpochMs: Int64(ev.ts * 1_000),
                    kind: ev.kind,
                    payload: ev.payload
                ))
                guard let data = try? frame.encoded() else {
                    _ = outbound.terminate(
                        errorData: nil,
                        closingData: self.connectionClosingData(
                            connectionId: connectionId,
                            reason: "invalidEvent",
                            code: 1011,
                            retryable: true,
                            retryAfterMs: 1_000
                        ),
                        reason: "invalidEvent"
                    )
                    return
                }
                batcher.enqueue(event: ev, data: data)
            }
            subIDBox.value = id
            subID = id
            // METRICS: track active client count for /v1/health.
            wsTracker.clientConnected()
            let liveness = WebSocketLivenessState(
                now: Date().timeIntervalSinceReferenceDate,
                interval: heartbeat.interval,
                timeout: heartbeat.timeout
            )
            // C-19: one-shot schedule at next interest (ping or timeout), not a
            // 250 ms poll. ~1–2 wakeups per interval instead of 240/min forever.
            let heartbeatTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            let scheduleHeartbeatWake: () -> Void = { [liveness] in
                let now = Date().timeIntervalSinceReferenceDate
                let delay = max(0.05, liveness.nextWakeDelay(now: now))
                // Generous leeway (1–2 s) so the kernel can coalesce with other work.
                let leewaySeconds = min(2.0, max(1.0, delay * 0.1))
                heartbeatTimer.schedule(
                    deadline: .now() + delay,
                    repeating: .never,
                    leeway: .milliseconds(Int(leewaySeconds * 1_000))
                )
            }
            heartbeatTimer.setEventHandler { [weak self] in
                guard let self else { return }
                switch liveness.nextAction(now: Date().timeIntervalSinceReferenceDate) {
                case .none:
                    scheduleHeartbeatWake()
                case .ping(let payload):
                    defer { scheduleHeartbeatWake() }
                    guard let nonce = String(data: payload, encoding: .utf8),
                          let heartbeatData = self.connectionHeartbeatData(
                              connectionId: connectionId,
                              nonce: nonce,
                              lastReceivedSequence: sequenceWatermark.value
                          ) else {
                        return
                    }
                    // C-04/C-20: app heartbeat rides the control queue so it is
                    // not blocked behind a full application backlog. Control ping
                    // is independent of app enqueue success.
                    switch outbound.enqueueControl(opcode: 0x1, data: heartbeatData) {
                    case .accepted:
                        _ = outbound.enqueueControl(opcode: 0x9, data: payload)
                    case .queueFull:
                        _ = outbound.degrade()
                        if outbound.enqueueControl(opcode: 0x1, data: heartbeatData) == .accepted {
                            _ = outbound.enqueueControl(opcode: 0x9, data: payload)
                        } else if outbound.enqueueControl(opcode: 0x9, data: payload) == .queueFull {
                            // Still full after degrade: skip this tick; do not close.
                            emitPressureBaseline()
                        }
                    case .closed:
                        break
                    }
                case .timedOut:
                    _ = outbound.terminate(
                        errorData: nil,
                        closingData: self.connectionClosingData(
                            connectionId: connectionId,
                            reason: "heartbeatTimeout",
                            code: 1012,
                            retryable: true,
                            retryAfterMs: 1_000
                        ),
                        reason: "heartbeatTimeout"
                    )
                }
            }
            scheduleHeartbeatWake()
            heartbeatTimer.resume()
            // keep connection open; read incoming frames (ping/pong/close/rpc)
            // C-25: this runs on a dedicated connection Thread (see accept loop),
            // not a GCD global-pool worker — so long-lived WS sessions cannot
            // exhaust the shared pool.
            wsServeLoop(
                fd: fd,
                connectionId: connectionId,
                outbound: outbound,
                liveness: liveness,
                ownerFingerprint: webSocketOwnerFingerprint
            )
            heartbeatTimer.cancel()
            batcher.stop()
            outbound.close()
            outbound.finish()
            wsTracker.clientDisconnected(queuedBytes: outbound.queuedByteCount)
            return
        }

        if method == "GET", path.hasPrefix(DirectStaticFileRegistry.routePrefix) {
            guard let file = DirectStaticFileRegistry.shared.resolve(routePath: path) else {
                send(fd: fd, status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
                return
            }
            sendFile(fd: fd, status: 200, contentType: file.contentType, url: file.url)
            if clientRequestsClose { return }
            buffer = leftoverBuffer
            continue
        }

        // Auth gate: when not loopback-only, require valid token for /v1/*
        // except the pre-token discovery/pairing surface. GAP-9:
        // /v1/capabilities is fetched UNauthenticated by the mobile
        // client before a token exists (mirrors /v1/discovery); gating
        // it makes every LAN connect fail with 401 → permanent
        // "Not authorized". It must be exempt like discovery.
        if Self.httpAuthGateRequiresToken(loopbackOnly: bindLoopbackOnly, path: path, hasAuthProvider: auth != nil),
           let auth = auth {
            if let token = presentedBearerToken, auth.verify(token: token) {
                // ok
            } else {
                send(fd: fd, status: 401, contentType: "text/plain",
                     body: "unauthorized\n".data(using: .utf8)!,
                additionalHeaders: ["WWW-Authenticate": wwwAuthenticateHeaderValue(scheme: "Bearer", realm: "RC2")]); return
            }
        }
        let requestOwnerFingerprint = Self.connectionOwnerFingerprint(
            token: presentedBearerToken
        )

        // POST body for pair endpoints; honor Content-Length read above.
        var bodyData = buffer.subdata(in: bodyStartAbsolute..<min(bodyStartAbsolute + contentLength, buffer.endIndex))
        if let contentEncoding = headers["content-encoding"], !contentEncoding.isEmpty {
            do {
                bodyData = try PayloadCodec.codec(for: contentEncoding).decode(
                    bodyData,
                    expectedSize: nil,
                    maximumSize: requestBodyLimit
                )
            } catch PayloadCodecError.outputTooLarge {
                send(fd: fd, status: 413, contentType: "text/plain", body: Data("request body too large\n".utf8))
                return
            } catch {
                send(fd: fd, status: 400, contentType: "text/plain", body: Data("bad encoded body\n".utf8))
                return
            }
            guard bodyData.count <= requestBodyLimit else {
                send(fd: fd, status: 413, contentType: "text/plain", body: Data("request body too large\n".utf8))
                return
            }
        }
        if bodyData.count > Self.maxRequestBodyBytes,
           (!requestedAttachmentUpload || !Self.isAttachmentUploadRPCEnvelope(bodyData)) {
            send(fd: fd, status: 413, contentType: "text/plain", body: Data("request body too large\n".utf8))
            return
        }

        switch (method, path) {
        case ("GET", "/healthz"):
            send(fd: fd, status: 200, contentType: "text/plain", body: "ok\n".data(using: .utf8)!)
        case ("GET", "/v1/health"):
            // IMP-MAC_SERVER_SYNC-009: authenticated sync diagnostics so
            // power users / support can answer "why is sync slow". Gated by
            // the /v1 auth check above (not in the exempt list). Sourced from
            // EventBus's public snapshot — last emitted seq plus the retained
            // replay window (count + encoded bytes) the client re-baselines
            // against. Connection-level metrics (active WS clients, backpressure,
            // slow-client evictions) are sourced from wsTracker.
            let snap = EventBus.shared.snapshot()
            let retainedBytes = snap.recent.reduce(0) { acc, ev in
                acc + ((try? JSONEncoder().encode(ev).count) ?? 0)
            }
            let receiptMetrics = commandReceiptMetrics.snapshot()
            let body: [String: Any] = [
                "status": "ok",
                "server_id": serverId,
                "server_time": Date().timeIntervalSince1970,
                "events": [
                    "last_seq": snap.lastSeq,
                    "retained_count": snap.recent.count,
                    "retained_bytes": retainedBytes,
                    "oldest_retained_seq": snap.recent.first?.seq ?? 0
                ],
                "connections": connectionMetricsJSON(
                    activeClients: wsTracker.activeClients,
                    totalQueuedBytes: wsTracker.totalQueuedBytes,
                    slowClientDrops: wsTracker.slowClientDrops
                ),
                "command_receipts": [
                    "claims_total": receiptMetrics.claimsTotal,
                    "new_claims_total": receiptMetrics.newClaimsTotal,
                    "claim_failures_total": receiptMetrics.claimFailuresTotal,
                    "duplicates": [
                        "in_progress_total": receiptMetrics.duplicatesInProgressTotal,
                        "committed_total": receiptMetrics.duplicatesCommittedTotal,
                        "unknown_total": receiptMetrics.duplicatesUnknownTotal
                    ],
                    "rejected_claims_total": receiptMetrics.rejectedClaimsTotal,
                    "unknown_outcomes_total": receiptMetrics.unknownOutcomesTotal,
                    "claim_latency_ms": [
                        "count": receiptMetrics.claimLatency.count,
                        "total": receiptMetrics.claimLatency.totalMilliseconds,
                        "max": receiptMetrics.claimLatency.maxMilliseconds
                    ],
                    "finalization": [
                        "success_total": receiptMetrics.finalizationSuccessesTotal,
                        "failure_total": receiptMetrics.finalizationFailuresTotal,
                        "latency_ms": [
                            "count": receiptMetrics.finalizationLatency.count,
                            "total": receiptMetrics.finalizationLatency.totalMilliseconds,
                            "max": receiptMetrics.finalizationLatency.maxMilliseconds
                        ]
                    ]
                ]
            ]
            sendJSON(fd: fd, status: 200, body: body, acceptEncoding: headers["accept-encoding"])
        case ("POST", "/v1/rpc"):
            // GAP-1: the authenticated JSON-RPC surface the mobile client
            // uses for every feature call. Routes to the same dispatcher
            // the Unix socket uses, hopping to the main actor.
            //
            // PERF-114: dispatch on the pure-async seam in a detached Task
            // instead of parking this global-pool worker (and one of the
            // bounded gate slots) for the full RPC duration. The Task owns
            // the fd from here on (send + keep-alive or close); we set
            // handedOff so the defer skips its close, then RETURN so the
            // read loop / defer never touch the fd again. C-07: after the
            // response the Task continues the keep-alive session instead of
            // closing, so subsequent RPCs reuse this TCP connection.
            // Only Sendable values are captured by value; subID is nil on
            // this path and is intentionally not touched by the Task.
            handedOff = true
            let ae = headers["accept-encoding"]
            let registry = acceptedSockets
            let rpcLeftover = leftoverBuffer
            let rpcClientClose = clientRequestsClose
            Task { [weak self] in
                guard let self else {
                    registry.close(fd)
                    return
                }
                let respData = await self.dispatchRPC(
                    bodyData: bodyData,
                    ownerFingerprint: requestOwnerFingerprint
                )
                guard registry.isActive(fd) else {
                    registry.close(fd)
                    return
                }
                self.send(fd: fd, status: 200, contentType: "application/json", body: respData, acceptEncoding: ae)
                if rpcClientClose || !registry.isActive(fd) {
                    registry.close(fd)
                    return
                }
                // C-07: continue keep-alive on this Task (owns close).
                self.serveHTTPSession(
                    fd: fd,
                    peer: peer,
                    initialBuffer: rpcLeftover,
                    ownsClose: true
                )
            }
            return
        case ("POST", "/v1/pair"):
            // Device-initiated request → Mac shows an approve/deny modal.
            // Returns immediately; the device polls /v1/pair/status. The
            // server never blocks on the user's decision.
            guard let auth = auth else {
                // CONTRACT (:23): machine code "pairing_disabled" so iOS can
                // distinguish this from "code_expired" across localizations.
                sendJSON(fd: fd, status: 503, body: pairingErrorPayload(code: "pairing_disabled"), acceptEncoding: headers["accept-encoding"]); return
            }
            // Cap simultaneously-outstanding requests per peer so one device
            // cannot flood the approve/deny queue.
            guard pairingThrottle.reserveOutstanding(peer: peer) else {
                send(fd: fd, status: 429, contentType: "text/plain", body: "too many outstanding pairing requests\n".data(using: .utf8)!); return
            }
            let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            let deviceName = (obj?["device_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed device"
            let privateAccountAccessToken = (obj?["private_account_access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let clientDeviceID = (obj?["client_device_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let r = auth.createPairingRequest(deviceName: deviceName, clientDeviceID: clientDeviceID, privateAccountAccessToken: privateAccountAccessToken) else {
                pairingThrottle.releaseOutstanding(peer: peer)
                // nil means the provider errored internally (LocalAuthAdapter
                // never "declines"). 500 pairing_unavailable tells iOS to say
                // "try again" — 503 pairing_disabled sent users to toggle a
                // Settings switch that was already on (2026-07-14 incident).
                sendJSON(fd: fd, status: 500, body: pairingErrorPayload(code: "pairing_unavailable"), acceptEncoding: headers["accept-encoding"]); return
            }
            // Bind the reserved slot to the request id so it is freed exactly
            // once at terminal status/cancel, or reclaimed after the request's
            // 300s TTL if the device vanishes mid-pair. Without this, every
            // completed pairing permanently consumed a slot and the 6th
            // request from the same peer got 429 until the app restarted.
            pairingThrottle.bindOutstanding(requestId: r.requestId, peer: peer,
                                            expiresAt: Date().addingTimeInterval(300))
            sendJSON(fd: fd, status: 200, body: ["request_id": r.requestId, "code": r.code, "expires_in": 300], acceptEncoding: headers["accept-encoding"])
        case ("POST", "/v1/pair/status"):
            guard let auth = auth,
                  let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let requestId = obj["request_id"] as? String else {
                send(fd: fd, status: 400, contentType: "text/plain", body: "bad request\n".data(using: .utf8)!); return
            }
            guard let s = auth.pairingRequestStatus(requestId: requestId) else {
                // Unknown to the auth provider: nothing left to wait for, so
                // free the creator's slot too (idempotent no-op otherwise).
                pairingThrottle.releaseOutstanding(requestId: requestId)
                send(fd: fd, status: 404, contentType: "text/plain", body: "unknown request\n".data(using: .utf8)!); return
            }
            if s.status != "pending" {
                // Terminal (approved/denied/expired/cancelled): release the
                // outstanding slot exactly once across repeated polls.
                pairingThrottle.releaseOutstanding(requestId: requestId)
            }
            var resp: [String: Any] = ["status": s.status]
            if let d = s.deviceId { resp["device_id"] = d }
            if let t = s.token { resp["token"] = t }
            sendJSON(fd: fd, status: 200, body: resp, acceptEncoding: headers["accept-encoding"])
        case ("POST", "/v1/pair/cancel"):
            // Device-initiated cancel of its own outstanding request. Moves
            // the request to a terminal state so the Mac modal can dismiss
            // and the outstanding-request slot is freed. Unauthenticated,
            // same allowlist as /v1/pair/status above.
            guard let auth = auth else {
                // CONTRACT (:23): consistent machine code for all pairing-disabled paths.
                sendJSON(fd: fd, status: 503, body: pairingErrorPayload(code: "pairing_disabled"), acceptEncoding: headers["accept-encoding"]); return
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let requestId = obj["request_id"] as? String else {
                send(fd: fd, status: 400, contentType: "text/plain", body: "bad request\n".data(using: .utf8)!); return
            }
            if auth.cancelPairingRequest(requestId: requestId) {
                // Release by request id: frees the CREATOR's slot even when the
                // cancel arrives from a different peer address (Wi-Fi→cellular
                // handoff), where the old peer-based release decremented the
                // wrong peer.
                pairingThrottle.releaseOutstanding(requestId: requestId)
                sendJSON(fd: fd, status: 200, body: ["cancelled": true], acceptEncoding: headers["accept-encoding"])
            } else {
                // Already terminal/unknown: the binding may still be live if no
                // terminal-status poll ever arrived — release it (idempotent).
                pairingThrottle.releaseOutstanding(requestId: requestId)
                send(fd: fd, status: 404, contentType: "text/plain", body: "unknown request\n".data(using: .utf8)!)
            }
        case ("POST", "/v1/pair/redeem"):
            guard let auth = auth,
                  let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let code = obj["code"] as? String,
                  let name = obj["device_name"] as? String else {
                send(fd: fd, status: 400, contentType: "text/plain", body: "bad request\n".data(using: .utf8)!); return
            }
            // Brute-force brake: refuse while the peer is locked out, count
            // wrong codes toward an exponential backoff, and reset on success.
            if case .denied(let retryAfter) = pairingThrottle.check(peer: peer) {
                let secs = Int(retryAfter.rounded(.up))
                send(fd: fd, status: 429, contentType: "text/plain",
                     body: "too many attempts, retry in \(secs)s\n".data(using: .utf8)!)
                return
            }
            if let (deviceId, token) = auth.redeemPairingCode(code, deviceName: name) {
                pairingThrottle.recordSuccess(peer: peer)
                // No releaseOutstanding here: the QR/redeem flow never reserves
                // a slot (/v1/pair does), and the count-based release could free
                // a slot still bound to this peer's live pairing request.
                sendJSON(fd: fd, status: 200, body: ["device_id": deviceId, "token": token], acceptEncoding: headers["accept-encoding"])
            } else {
                pairingThrottle.recordFailure(peer: peer)
                // CONTRACT (:23): "code_expired" covers both expired and already-redeemed
                // cases -- iOS cannot meaningfully distinguish them, and the stable code
                // lets the client show a retry/re-pair CTA without parsing a string.
                sendJSON(fd: fd, status: 410, body: pairingErrorPayload(code: "code_expired"), acceptEncoding: headers["accept-encoding"])
            }
        case ("GET", "/v1/devices"):
            guard let auth = auth else { send(fd: fd, status: 503, contentType: "text/plain", body: "disabled\n".data(using: .utf8)!); return }
            sendJSON(fd: fd, status: 200, body: ["devices": auth.listDevices()], acceptEncoding: headers["accept-encoding"])
        case ("POST", "/v1/devices/revoke"):
            guard let auth = auth,
                  let obj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let id = obj["id"] as? String else {
                send(fd: fd, status: 400, contentType: "text/plain", body: "bad request\n".data(using: .utf8)!); return
            }
            auth.revokeDevice(id)
            sendJSON(fd: fd, status: 200, body: ["revoked": id], acceptEncoding: headers["accept-encoding"])
        case ("GET", "/v1/discovery"):
            let body: [String: Any] = [
                "server_id": serverId,                                  // GAP-2: stable, persisted
                "app": "remotecode",
                "version": AppVersion.short,
                "api_version": "2",
                "capabilities_version": "1",
                "auth_mode": bindLoopbackOnly ? "loopback-anonymous" : "token-required",
                "transports": ["http", "ws"],
                "host": bindLoopbackOnly ? "127.0.0.1" : "0.0.0.0",
                "port": port,
                "vpn_required": !bindLoopbackOnly,
                "relay": false,
                // IMP-MAC_SERVER_SYNC-001: anchor for client clock-drift /
                // freshness math. Pairs with the WS `heartbeat` frame (ts) so
                // the client can show an honest "live / last synced Ns ago".
                "server_time": Date().timeIntervalSince1970
            ]
            sendJSON(fd: fd, status: 200, body: body, acceptEncoding: headers["accept-encoding"])
        case ("GET", "/v1/capabilities"):
            // GAP-3: advertise what the dispatcher actually implements.
            // git mutations + full browser automation are real (see
            // Dispatcher.swift git.*/browser.*); hiding them on the
            // client breaks parity.
            let body: [String: Any] = [
                "surface_types": ["terminal", "ssh", "browser", "agentApp", "files", "markdown", "filePreview", "rightSidebarTool"],
                "ssh": [
                    "methods": ["ssh.host.list", "ssh.host.upsert", "ssh.host.delete", "ssh.connect", "ssh.disconnect", "ssh.transfer.upload", "ssh.transfer.download", "ssh.files.local.list", "ssh.files.remote.list"]
                ],
                "agent": ["providers": ["codex", "claude", "grok"], "supports_stream_events": true, "supports_resume": true, "model_routing": ["auto": true, "admission_receipts": true, "rollout_enabled": AgentOrchestrationRuntime.defaultRolloutEnabled()]],
                "browser_automation": [
                    "p0": ["navigate", "back", "forward", "reload", "url.get", "mirror_url.get"],
                    "p1": ["click", "fill", "type", "focus", "hover", "check", "uncheck", "select", "eval", "snapshot", "screenshot", "wait"],
                    "p1_unsupported": false
                ],
                "files": [
                    "methods": ["fs.workspace.list", "fs.workspace.read", "fs.workspace.preview_url", "fs.workspace.create_file", "fs.workspace.rename", "fs.workspace.delete", "files.tab.open", "files.tab.split", "files.state.get", "files.state.update", "files.edit.open", "files.edit.apply_patch", "files.edit.save", "files.edit.discard", "files.edit.close"]
                ],
                "git": ["read_only": false],
                "feature_flags": ["remote_access_enabled": !bindLoopbackOnly]
            ]
            sendJSON(fd: fd, status: 200, body: body, acceptEncoding: headers["accept-encoding"])
        default:
            send(fd: fd, status: 404, contentType: "text/plain", body: "not found\n".data(using: .utf8)!)
            return
        }
        // C-07: keep the TCP connection open for the next request unless the
        // client asked to close. Protocol-error paths above still `return`
        // (close); success falls through here.
        if clientRequestsClose { return }
        buffer = leftoverBuffer
        } // while keep-alive request loop
    }

    /// C-07: true when the client sent `Connection: close` (HTTP/1.1 default
    /// is keep-alive when the header is absent or lists keep-alive).
    nonisolated static func httpClientRequestsClose(_ headers: [String: String]) -> Bool {
        guard let raw = headers["connection"]?.lowercased() else { return false }
        return raw.split(separator: ",").contains { token in
            token.trimmingCharacters(in: .whitespaces) == "close"
        }
    }

    /// QA-003: pure async request/response seam — decode → dispatch →
    /// encode with no semaphore and no socket. Lets framing, compression,
    /// and auth-gating be unit-tested deterministically by feeding body
    /// bytes and awaiting the response bytes, instead of driving a real
    /// socket and a real main runloop. PERF-114: the /v1/rpc HTTP handler
    /// now drives this directly from a detached Task, so no global-pool
    /// worker is parked for the RPC's duration.
    public func dispatchRPC(
        bodyData: Data,
        ownerFingerprint: String? = nil
    ) async -> Data {
        let ownerFingerprint = ownerFingerprint
            ?? Self.connectionOwnerFingerprint(token: nil)
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: bodyData, options: [.fragmentsAllowed])
        } catch {
            return rpcErrorData(.parseError, id: NSNull())
        }

        if let batch = root as? [Any] {
            guard !batch.isEmpty else {
                return rpcErrorData(.invalidRequest, id: NSNull())
            }
            var seenIDs = Set<String>()
            for item in batch {
                guard let object = item as? [String: Any],
                      let (_, key) = strictRPCID(object["id"], keyIsPresent: object.keys.contains("id")) else {
                    continue
                }
                guard seenIDs.insert(key).inserted else {
                    return rpcErrorData(.invalidRequest, id: NSNull())
                }
            }
            var responses: [[String: Any]] = []
            responses.reserveCapacity(batch.count)
            for item in batch {
                responses.append(await dispatchStrictRPCItem(
                    item,
                    ownerFingerprint: ownerFingerprint
                ))
            }
            return rpcJSONData(responses)
        }

        // C-24: `sync.snapshot` is the largest payload. Encode the full JSON-RPC
        // envelope once with the wire `id` included — no Data→Any→Data cycle.
        if let object = root as? [String: Any],
           object["method"] as? String == "sync.snapshot" {
            return await dispatchSyncSnapshotRPCData(
                object,
                ownerFingerprint: ownerFingerprint
            )
        }

        return rpcJSONData(await dispatchStrictRPCItem(
            root,
            ownerFingerprint: ownerFingerprint
        ))
    }

    private func dispatchStrictRPCItem(
        _ value: Any,
        ownerFingerprint: String
    ) async -> [String: Any] {
        guard let object = value as? [String: Any] else {
            return rpcErrorObject(.invalidRequest, id: NSNull())
        }
        let fallbackID = strictRPCID(
            object["id"],
            keyIsPresent: object.keys.contains("id")
        )?.0 ?? NSNull()
        let expectedKeys: Set<String> = object.keys.contains("params")
            ? ["jsonrpc", "id", "method", "params"]
            : ["jsonrpc", "id", "method"]
        guard Set(object.keys) == expectedKeys,
              object["jsonrpc"] as? String == "2.0",
              let method = object["method"] as? String,
              !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let (wireID, _) = strictRPCID(
                  object["id"],
                  keyIsPresent: object.keys.contains("id")
              ) else {
            return rpcErrorObject(.invalidRequest, id: fallbackID)
        }

        var rawParams: [String: Any]?
        if object.keys.contains("params") {
            guard let objectParams = object["params"] as? [String: Any] else {
                return rpcErrorObject(.invalidRequest, id: wireID)
            }
            rawParams = objectParams
        }
        if method == "sync.snapshot" {
            // Handled by `dispatchRPC` single-encode path (C-24); this branch
            // only exists for batch items that still go through the dict form.
            guard let rawParams else {
                return rpcErrorObject(.invalidParams, id: wireID)
            }
            return await dispatchSyncSnapshotObject(
                rawParams: rawParams,
                wireID: wireID,
                ownerFingerprint: ownerFingerprint
            )
        }
        let params = rawParams?.mapValues(JSONValue.from)
        let requestID: JSONRPCID?
        switch wireID {
        case is NSNull: requestID = nil
        case let value as String: requestID = .string(value)
        case let value as NSNumber:
            // `Double(Int.max)` rounds up to 2^63, so a `<= Double(Int.max)` bound
            // admits a value that overflows Int. `Int(exactly:)` accepts only an
            // exactly-representable integer id; anything else uses the 0 sentinel.
            if let intID = Int(exactly: value.doubleValue) {
                requestID = .number(intID)
            } else {
                // JSONRPCID is integer-only internally. The dispatcher does not
                // inspect ids; the exact finite wire number is restored below.
                requestID = .number(0)
            }
        default: return rpcErrorObject(.invalidRequest, id: NSNull())
        }
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: requestID,
            method: method,
            params: params
        )
        let mutationContext = MutationRequestContext(
            ownerFingerprint: ownerFingerprint,
            hostId: serverId,
            bootEpoch: bootEpoch,
            activeConnection: { [activeWebSocketConnections] connectionID, ownerFingerprint in
                activeWebSocketConnections.watermark(
                    for: connectionID,
                    ownerFingerprint: ownerFingerprint
                ) != nil
            }
        )
        let response = await dispatcher.dispatch(request, mutationContext: mutationContext)
        guard let encoded = try? JSONEncoder().encode(response),
              var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            return rpcErrorObject(.internalError, id: wireID)
        }
        object["id"] = wireID
        return object
    }

    /// C-24: single-encode `sync.snapshot` JSON-RPC success path.
    private func dispatchSyncSnapshotRPCData(
        _ object: [String: Any],
        ownerFingerprint: String
    ) async -> Data {
        let fallbackID = strictRPCID(
            object["id"],
            keyIsPresent: object.keys.contains("id")
        )?.0 ?? NSNull()
        let expectedKeys: Set<String> = object.keys.contains("params")
            ? ["jsonrpc", "id", "method", "params"]
            : ["jsonrpc", "id", "method"]
        guard Set(object.keys) == expectedKeys,
              object["jsonrpc"] as? String == "2.0",
              let (wireID, _) = strictRPCID(
                  object["id"],
                  keyIsPresent: object.keys.contains("id")
              ),
              let rawParams = object["params"] as? [String: Any] else {
            return rpcJSONData(rpcErrorObject(.invalidRequest, id: fallbackID))
        }
        return await encodeSyncSnapshotResponse(
            rawParams: rawParams,
            wireID: wireID,
            ownerFingerprint: ownerFingerprint
        )
    }

    /// Batch-item dict form of snapshot (still single-encodes the frame once;
    /// outer batch encode is unavoidable for multi-response arrays).
    private func dispatchSyncSnapshotObject(
        rawParams: [String: Any],
        wireID: Any,
        ownerFingerprint: String
    ) async -> [String: Any] {
        let data = await encodeSyncSnapshotResponse(
            rawParams: rawParams,
            wireID: wireID,
            ownerFingerprint: ownerFingerprint
        )
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return rpcErrorObject(.internalError, id: wireID)
    }

    private func encodeSyncSnapshotResponse(
        rawParams: [String: Any],
        wireID: Any,
        ownerFingerprint: String
    ) async -> Data {
        // Wave 4: optional knownDomainRevisions enables partial/delta snapshots.
        let allowedKeys: Set<String> = [
            "connectionId", "expectedHostId", "expectedBootEpoch", "supportedStateVersion",
            "knownDomainRevisions",
        ]
        guard Set(rawParams.keys).isSubset(of: allowedKeys),
              rawParams.keys.contains("connectionId"),
              rawParams.keys.contains("expectedHostId"),
              rawParams.keys.contains("expectedBootEpoch"),
              rawParams.keys.contains("supportedStateVersion"),
        let connectionID = rawParams["connectionId"] as? String,
        !connectionID.isEmpty,
        let expectedHostID = rawParams["expectedHostId"] as? String,
        expectedHostID == serverId,
        let expectedBootEpoch = Self.strictUInt64(rawParams["expectedBootEpoch"]),
        expectedBootEpoch == bootEpoch,
        let supportedStateVersion = Self.strictInt64(rawParams["supportedStateVersion"]),
        supportedStateVersion == 3,
        let watermark = activeWebSocketConnections.watermark(
            for: connectionID,
            ownerFingerprint: ownerFingerprint
        ),
        watermark.beginSnapshot() else {
            return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
        }
        let knownRevisions: ConnectionDomainRevisions?
        if rawParams.keys.contains("knownDomainRevisions") {
            guard let parsed = ConnectionDomainRevisions.parse(rawParams["knownDomainRevisions"]) else {
                return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
            }
            knownRevisions = parsed
        } else {
            knownRevisions = nil
        }

        var snapshotAdopted = false
        defer {
            if !snapshotAdopted { watermark.cancelSnapshot() }
        }
        do {
            let snapshot = try await dispatcher.readConnectionSnapshot()
            guard activeWebSocketConnections.watermark(
                for: connectionID,
                ownerFingerprint: ownerFingerprint
            ) === watermark else {
                return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
            }
            let hostRevisions = snapshot.metadata.domainRevisions
            let includeDomains: Set<String>?
            if let knownRevisions {
                let changed = hostRevisions.domainsChanged(since: knownRevisions)
                // Empty change set → still send revisions-only partial (cheap reconnect).
                includeDomains = changed.isEmpty ? [] : changed
            } else {
                includeDomains = nil
            }
            let state = snapshot.state.jsonValue(
                domainRevisions: hostRevisions,
                includeDomains: includeDomains
            )
            let frame = ConnectionSnapshotFrame(
                protocolVersion: ConnectionTransportFrame.protocolVersion,
                type: "snapshot",
                connectionId: connectionID,
                hostId: serverId,
                bootEpoch: bootEpoch,
                sequence: snapshot.metadata.sequence,
                snapshotId: UUID().uuidString,
                generatedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1_000),
                stateVersion: 3,
                state: state
            )
            switch watermark.adoptSnapshot(sequence: snapshot.metadata.sequence) {
            case .adopted:
                snapshotAdopted = true
            case .gap(let expected, let received):
                return rpcJSONData(rpcErrorObject(JSONRPCError(
                    code: -32010,
                    message: "Event sequence gap detected; reconnect and request a new baseline.",
                    data: .object([
                        "expectedSequence": .number(Double(expected)),
                        "receivedSequence": .number(Double(received)),
                    ])
                ), id: wireID))
            }
            // C-24: one JSONEncoder pass for the full RPC response (id + result).
            // Avoids the prior Data → Any → Data cycle on multi-hundred-KB snapshots.
            let envelope = SnapshotRPCSuccessEnvelope(
                id: SnapshotRPCWireID(wireID),
                result: frame
            )
            let data = try JSONEncoder().encode(envelope)
            // Same absolute ceiling as a bare transport frame (plus small RPC wrap).
            guard data.count <= ConnectionTransportFrame.maximumEncodedBytes + 256 else {
                return rpcJSONData(rpcErrorObject(.internalError, id: wireID))
            }
            return data
        } catch let error as JSONRPCError {
            return rpcJSONData(rpcErrorObject(error, id: wireID))
        } catch {
            return rpcJSONData(rpcErrorObject(.internalError, id: wireID))
        }
    }

    private static func strictInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return nil
        }
        return Int64(NSDecimalNumber(decimal: number.decimalValue).stringValue)
    }

    private static func strictUInt64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return nil
        }
        return UInt64(NSDecimalNumber(decimal: number.decimalValue).stringValue)
    }

    private static func bearerToken(from headers: [String: String]) -> String? {
        headers["authorization"]
            .flatMap { $0.split(separator: " ").last.map(String.init) }
            ?? headers["x-rc2-token"]
    }

    /// True when a WS text payload is a JSON-RPC 2.0 request (single or batch).
    /// Wave 4 `rpc.websocket` — distinct from ConnectionTransportFrame envelopes.
    static func looksLikeJSONRPCRequest(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let object = root as? [String: Any] {
            return object["jsonrpc"] as? String == "2.0"
                && object["method"] is String
                && object.keys.contains("id")
        }
        if let batch = root as? [Any], let first = batch.first as? [String: Any] {
            return first["jsonrpc"] as? String == "2.0"
                && first["method"] is String
        }
        return false
    }

    static func connectionOwnerFingerprint(token: String?) -> String {
        let material = Data("rc2.connection-owner.v1:\(token ?? "trusted-local")".utf8)
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func strictRPCID(_ value: Any?, keyIsPresent: Bool) -> (Any, String)? {
        guard keyIsPresent else { return nil }
        if value is NSNull { return (NSNull(), "null") }
        if let value = value as? String { return (value, "string:\(value)") }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            return nil
        }
        let exactValue = NSDecimalNumber(decimal: number.decimalValue).stringValue
        return (number, "number:\(exactValue)")
    }

    private func rpcErrorData(_ error: JSONRPCError, id: Any) -> Data {
        rpcJSONData(rpcErrorObject(error, id: id))
    }

    private func rpcErrorObject(_ error: JSONRPCError, id: Any) -> [String: Any] {
        var errorObject: [String: Any] = [
            "code": error.code,
            "message": error.message,
        ]
        if let data = error.data {
            errorObject["data"] = Self.jsonValueToAny(data)
        }
        return [
            "jsonrpc": "2.0",
            "id": id,
            "error": errorObject,
        ]
    }

    private func rpcJSONData(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            ?? Data("{}".utf8)
    }

    private func send(fd: Int32, status: Int, contentType: String, body: Data, acceptEncoding: String? = nil, additionalHeaders: [String: String] = [:]) {
        var responseBody = body
        var extraHeaders = ""
        if contentType.contains("application/json"),
           let codec = PayloadCodec.preferredResponseCodec(acceptEncoding: acceptEncoding),
           body.count >= 128,
           let compressed = try? codec.encode(body),
           compressed.count < body.count {
            responseBody = compressed
            extraHeaders += "Content-Encoding: \(codec.wireName)\r\n"
        }
        for (k, v) in additionalHeaders {
            extraHeaders += "\(k): \(v)\r\n"
        }
        // C-07: advertise keep-alive so clients (URLSession) reuse the TCP
        // connection; idle close is enforced by SO_RCVTIMEO on the next read.
        let head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\nContent-Type: \(contentType)\r\n\(extraHeaders)Content-Length: \(responseBody.count)\r\nConnection: keep-alive\r\nKeep-Alive: timeout=\(receiveTimeoutSeconds)\r\n\r\n"
        // PERF-010: write headers then body separately (as sendFile does)
        // instead of concatenating into one Data — avoids a full-body copy
        // per response, which doubled transient memory for large payloads
        // (agent.message.list / git.diff).
        guard writeAll(fd: fd, data: Data(head.utf8)) else { return }
        if !responseBody.isEmpty {
            _ = writeAll(fd: fd, data: responseBody)
        }
    }

    private func sendFile(fd: Int32, status: Int, contentType: String, url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let handle = try? FileHandle(forReadingFrom: url) else {
            send(fd: fd, status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
            return
        }
        defer { try? handle.close() }
        let head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(size)\r\nConnection: keep-alive\r\nKeep-Alive: timeout=\(receiveTimeoutSeconds)\r\n\r\n"
        guard writeAll(fd: fd, data: Data(head.utf8)) else { return }
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { return }
            guard writeAll(fd: fd, data: chunk) else { return }
        }
    }

    private func sendJSON(fd: Int32, status: Int, body: [String: Any], acceptEncoding: String? = nil) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        send(fd: fd, status: status, contentType: "application/json", body: data, acceptEncoding: acceptEncoding)
    }

    private func reasonPhrase(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 410: return "Gone"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        case 101: return "Switching Protocols"
        default: return "OK"
        }
    }

    // MARK: WebSocket

    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private func performWSHandshake(fd: Int32, key: String) {
        let toHash = key + Self.wsGUID
        let digest = Insecure.SHA1.hash(data: Data(toHash.utf8))
        let accept = Data(digest).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        let data = Data(head.utf8)
        _ = writeAll(fd: fd, data: data)
    }

    private func sendWSEvent(
        writer: WebSocketConnectionWriter,
        data: Data,
        compressed: Bool
    ) -> Bool {
        if compressed,
           let envelope = try? PayloadCodec.encodeWebSocketEnvelope(data),
           envelope.count < data.count {
            return writer.send(opcode: 0x2, data: envelope)
        }
        return writer.send(opcode: 0x1, data: data)
    }

    private func sendWSText(writer: WebSocketConnectionWriter, data: Data) {
        _ = writer.send(opcode: 0x1, data: data)
    }

    private func sendWSFrame(fd: Int32, opcode: UInt8, data: Data) -> Bool {
        // server frames are unmasked
        var frame = Data()
        frame.append(0x80 | opcode)
        let len = data.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(len >> 8)); frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        frame.append(data)
        return writeAll(fd: fd, data: frame)
    }

    private func wsServeLoop(
        fd: Int32,
        connectionId: String,
        outbound: WebSocketOutboundQueue,
        liveness: WebSocketLivenessState,
        ownerFingerprint: String
    ) {
        // PERF-009: keep a contiguous [UInt8] buffer with a read offset
        // instead of Data + removeFirst(consumed). removeFirst is O(n) per
        // frame (shifting the whole buffer), which is quadratic under
        // pipelined input; advancing an offset is O(1). The buffer is
        // compacted only once the offset passes its midpoint.
        //
        // C-02: fd is O_NONBLOCK after the WS upgrade. Outbound frame writes
        // park on DispatchSourceWrite inside writeAll when the kernel send
        // buffer is full; this loop only owns the read side and must treat
        // EAGAIN as "wait for readable", not peer death.
        var buf = [UInt8]()
        var offset = 0
        var tmp = [UInt8](repeating: 0, count: 4096)
        while acceptedSockets.isActive(fd) {
            connectionReadWaitObserverForTesting?(fd, .webSocket)
            let n = Self.readRetryingInterrupts {
                Darwin.read(fd, &tmp, tmp.count)
            }
            if n > 0 {
                // continue below
            } else if n == 0 {
                return
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    if !Self.waitForReadable(fd: fd, timeout: Self.wsSocketReadTimeout) {
                        return
                    }
                    continue
                }
                return
            }
            // Any bytes from the peer prove the path is live (C-06 traffic liveness).
            liveness.noteInboundTraffic(now: Date().timeIntervalSinceReferenceDate)
            buf.append(contentsOf: tmp[0..<n])
            while let (frame, consumed) = parseClientFrame(buf, from: offset) {
                offset += consumed
                switch frame.opcode {
                case 0x8: // close
                    _ = outbound.terminate(errorData: nil, closingData: nil, reason: "peerClose")
                    return
                case 0x9: // ping -> pong
                    guard frame.payload.count <= 125 else {
                        _ = outbound.terminate(
                            errorData: nil,
                            closingData: connectionClosingData(
                                connectionId: connectionId,
                                reason: "protocolError",
                                code: 1002,
                                retryable: false,
                                retryAfterMs: nil
                            ),
                            reason: "protocolError"
                        )
                        return
                    }
                    _ = outbound.enqueueControl(opcode: 0xA, data: frame.payload)
                case 0xA: // pong
                    _ = liveness.acceptPong(
                        frame.payload,
                        now: Date().timeIntervalSinceReferenceDate
                    )
                    continue
                case 0x1:
                    // Wave 4: JSON-RPC over the existing WebSocket (capability
                    // `rpc.websocket`). Transport control frames remain rejected.
                    if Self.looksLikeJSONRPCRequest(frame.payload) {
                        let body = frame.payload
                        let fingerprint = ownerFingerprint
                        Task { [weak self] in
                            guard let self else { return }
                            let response = await self.dispatchRPC(
                                bodyData: body,
                                ownerFingerprint: fingerprint
                            )
                            // Control queue so hydration RPC replies are not
                            // stuck behind a full application event backlog.
                            switch outbound.enqueueControl(opcode: 0x1, data: response) {
                            case .accepted, .closed:
                                break
                            case .queueFull:
                                _ = outbound.degrade()
                                _ = outbound.enqueueControl(opcode: 0x1, data: response)
                            }
                        }
                        continue
                    }
                    let code: String
                    do {
                        _ = try ConnectionTransportFrame.decodeStrict(frame.payload)
                        code = "unsupportedMessage"
                    } catch {
                        code = "protocolError"
                    }
                    _ = outbound.terminate(
                        errorData: connectionErrorData(connectionId: connectionId, code: code),
                        closingData: connectionClosingData(
                            connectionId: connectionId,
                            reason: "protocolError",
                            code: 1002,
                            retryable: false,
                            retryAfterMs: nil
                        ),
                        reason: "protocolError"
                    )
                    return
                case 0x2:
                    _ = outbound.terminate(
                        errorData: connectionErrorData(
                            connectionId: connectionId,
                            code: "protocolError"
                        ),
                        closingData: connectionClosingData(
                            connectionId: connectionId,
                            reason: "protocolError",
                            code: 1002,
                            retryable: false,
                            retryAfterMs: nil
                        ),
                        reason: "protocolError"
                    )
                    return
                default:
                    _ = outbound.terminate(
                        errorData: nil,
                        closingData: connectionClosingData(
                            connectionId: connectionId,
                            reason: "protocolError",
                            code: 1002,
                            retryable: false,
                            retryAfterMs: nil
                        ),
                        reason: "protocolError"
                    )
                    return
                }
            }
            if offset > 0 {
                if offset >= buf.count {
                    buf.removeAll(keepingCapacity: true)
                } else if offset > buf.count / 2 {
                    buf.removeFirst(offset)
                } else {
                    continue
                }
                offset = 0
            }
        }
    }

    private struct WSFrame { let opcode: UInt8; let payload: Data }

    /// Pure frame-header parse result. No I/O, no actor. `internal` for unit tests.
    ///
    /// - `shouldReject`: true when the frame is invalid regardless of masking
    ///   (e.g. overflow length or oversized payload). The caller must close.
    /// - `masked`: reflects the MASK bit; RFC6455 s5.3 requires clients to mask.
    /// - `headerEnd`: offset from `start` to the end of length fields (before
    ///   the 4-byte mask key). Only meaningful when `shouldReject` is false.
    struct WSFrameHeader {
        let opcode: UInt8
        let masked: Bool
        let payloadLen: Int
        let headerEnd: Int
        let shouldReject: Bool
    }

    /// Parses the two-byte fixed header plus extended-length fields from `buf`
    /// starting at `start`. Returns nil when more bytes are needed.
    static func wsFrameHeader(buf: [UInt8], from start: Int) -> WSFrameHeader? {
        let available = buf.count - start
        guard available >= 2 else { return nil }
        let b0 = buf[start]
        let b1 = buf[start + 1]
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7F)
        var idx = 2
        if len == 126 {
            guard available >= 4 else { return nil }
            len = (Int(buf[start + 2]) << 8) | Int(buf[start + 3])
            idx = 4
        } else if len == 127 {
            guard available >= 10 else { return nil }
            var wideLen: UInt64 = 0
            for i in 0..<8 {
                wideLen = (wideLen << 8) | UInt64(buf[start + 2 + i])
            }
            guard wideLen <= UInt64(Int.max) else {
                return WSFrameHeader(opcode: opcode, masked: masked,
                                     payloadLen: 0, headerEnd: 10, shouldReject: true)
            }
            len = Int(wideLen)
            idx = 10
        }
        if len > maxClientFramePayloadBytes {
            return WSFrameHeader(opcode: opcode, masked: masked,
                                 payloadLen: 0, headerEnd: idx, shouldReject: true)
        }
        return WSFrameHeader(opcode: opcode, masked: masked,
                             payloadLen: len, headerEnd: idx, shouldReject: false)
    }

    private func parseClientFrame(_ buf: [UInt8], from start: Int) -> (WSFrame, Int)? {
        guard let hdr = Self.wsFrameHeader(buf: buf, from: start) else { return nil }

        // Oversized / overflow -- close regardless of masking.
        if hdr.shouldReject {
            return (WSFrame(opcode: 0x8, payload: Data()), hdr.headerEnd)
        }

        // RFC6455 s5.3: clients MUST mask all frames sent to the server.
        // An unmasked client frame is a protocol error; close with 1002.
        guard hdr.masked else {
            return (WSFrame(opcode: 0x8, payload: Data()), hdr.headerEnd)
        }

        var idx = hdr.headerEnd
        let available = buf.count - start
        var maskKey: [UInt8] = [0, 0, 0, 0]
        guard available >= idx + 4 else { return nil }
        for i in 0..<4 { maskKey[i] = buf[start + idx + i] }
        idx += 4

        guard available >= idx + hdr.payloadLen else { return nil }
        let payloadStart = start + idx
        var payload = [UInt8](repeating: 0, count: hdr.payloadLen)
        for i in 0..<hdr.payloadLen {
            payload[i] = buf[payloadStart + i] ^ maskKey[i & 3]
        }
        return (WSFrame(opcode: hdr.opcode, payload: Data(payload)), idx + hdr.payloadLen)
    }

    static func pongFrame(payload: Data) -> Data {
        let safePayload = payload.prefix(125)
        var frame = Data()
        frame.append(0x8A) // FIN + pong
        frame.append(UInt8(safePayload.count))
        frame.append(safePayload)
        return frame
    }

    private func connectionHeartbeatData(
        connectionId: String,
        nonce: String,
        lastReceivedSequence: Int64
    ) -> Data? {
        try? ConnectionTransportFrame.heartbeat(ConnectionHeartbeatFrame(
            protocolVersion: ConnectionTransportFrame.protocolVersion,
            type: "heartbeat",
            connectionId: connectionId,
            hostId: serverId,
            bootEpoch: bootEpoch,
            sentAtEpochMs: Int64(Date().timeIntervalSince1970 * 1_000),
            lastReceivedSequence: lastReceivedSequence,
            nonce: nonce
        )).encoded()
    }

    private func connectionBaselineRequiredData(
        connectionId: String,
        requestedAfterSequence: Int64,
        currentSequence: Int64
    ) -> Data? {
        try? ConnectionTransportFrame.baselineRequired(ConnectionBaselineRequiredFrame(
            protocolVersion: ConnectionTransportFrame.protocolVersion,
            type: "baselineRequired",
            connectionId: connectionId,
            hostId: serverId,
            bootEpoch: bootEpoch,
            reason: "replayTruncated",
            requestedAfterSequence: requestedAfterSequence,
            currentSequence: currentSequence,
            snapshotMethod: "sync.snapshot"
        )).encoded()
    }

    private func connectionErrorData(
        connectionId: String,
        code: String
    ) -> Data? {
        let frame = ConnectionTransportFrame.error(ConnectionErrorFrame(
            protocolVersion: ConnectionTransportFrame.protocolVersion,
            type: "error",
            connectionId: connectionId,
            hostId: serverId,
            bootEpoch: bootEpoch,
            code: code,
            message: "The transport message is not supported by this host.",
            retryable: false,
            requestId: nil
        ))
        return try? frame.encoded()
    }

    private func connectionClosingData(
        connectionId: String,
        reason: String,
        code: Int,
        retryable: Bool,
        retryAfterMs: Int64?
    ) -> Data? {
        let frame = ConnectionTransportFrame.closing(ConnectionClosingFrame(
            protocolVersion: ConnectionTransportFrame.protocolVersion,
            type: "closing",
            connectionId: connectionId,
            hostId: serverId,
            bootEpoch: bootEpoch,
            code: code,
            reason: reason,
            retryable: retryable,
            retryAfterMs: retryAfterMs
        ))
        return try? frame.encoded()
    }

    /// Instance entry point for HTTP/WS writers. Delegates to the static C-02 path.
    private func writeAll(fd: Int32, data: Data) -> Bool {
        Self.writeAll(fd: fd, data: data)
    }

    /// C-02: write a complete buffer with non-blocking I/O.
    ///
    /// - Writes as many bytes as the kernel accepts.
    /// - On `EAGAIN`/`EWOULDBLOCK`, waits for write-ready (`DispatchSourceWrite`)
    ///   and resumes from the saved offset — never treats would-block as fatal.
    /// - Resets the idle clock on every successful short write (progress-based
    ///   timeout, not total wall duration).
    /// - Returns false only on hard errors (`EPIPE`/`ECONNRESET`/…), zero-byte
    ///   write, or no progress for `progressIdleTimeout`.
    ///
    /// Frame integrity: callers (e.g. `sendWSFrame` under `WebSocketConnectionWriter`)
    /// only observe success after the *entire* frame buffer is on the wire, so a
    /// partial write never ends the connection mid-frame.
    @discardableResult
    static func writeAll(
        fd: Int32,
        data: Data,
        progressIdleTimeout: TimeInterval = writeProgressIdleTimeout,
        now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        writeFn: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) },
        waitWritable: (Int32, TimeInterval) -> Bool = { fd, timeout in
            waitForWritable(fd: fd, timeout: timeout)
        }
    ) -> Bool {
        guard !data.isEmpty else { return true }
        // Ensure would-block is observable (WS upgrade also sets this; HTTP
        // responses may hit writeAll without an earlier enableNonBlocking).
        _ = enableNonBlocking(fd)
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            var lastProgressAt = now()
            while offset < data.count {
                let n = writeFn(fd, base.advanced(by: offset), data.count - offset)
                if n > 0 {
                    offset += n
                    lastProgressAt = now()
                    continue
                }
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        let remaining = progressIdleTimeout - (now() - lastProgressAt)
                        if remaining <= 0 { return false }
                        // Wait for write-ready; timeout here is the *remaining*
                        // idle budget so total no-progress time stays bounded.
                        if !waitWritable(fd, remaining) {
                            // Wait ended without readiness (or timed out). Re-check
                            // idle budget before treating as hard failure so a
                            // short spurious wait can still retry.
                            if now() - lastProgressAt >= progressIdleTimeout {
                                return false
                            }
                        }
                        continue
                    }
                    // Peer gone or unrecoverable (EPIPE, ECONNRESET, EBADF, …).
                    return false
                }
                // n == 0 on a stream socket: treat as failure (do not spin).
                return false
            }
            return true
        }
    }

    static func jsonValueToAny(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(jsonValueToAny)
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, vv) in o { out[k] = jsonValueToAny(vv) }
            return out
        }
    }
}

public struct DirectStaticFileGrant: Sendable, Equatable {
    public let token: String
    public let rootPath: String
    public let routePath: String
}

public final class DirectStaticFileRegistry: @unchecked Sendable {
    public static let shared = DirectStaticFileRegistry()
    public static let routePrefix = "/__rc2_static/"

    private struct Grant {
        let rootPath: String
        let createdAt: Date
    }

    private let lock = NSLock()
    private var grants: [String: Grant] = [:]
    private let ttl: TimeInterval = 60 * 60
    // QA-002: clock is an injectable instance dependency, not a per-call
    // `Date()` default that every grant test must remember to override. The
    // per-call `now:` parameters still work (explicit override wins), but
    // when omitted they read this clock — so a test injects a fixed clock
    // once via `setClockForTests` and all TTL-dependent paths use it.
    private var clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public func register(fileURL: URL, now: Date? = nil) -> DirectStaticFileGrant? {
        let now = now ?? currentTime()
        guard fileURL.isFileURL else { return nil }
        let standardized = fileURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        let root = standardized.deletingLastPathComponent().path
        let relative = standardized.lastPathComponent
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let routePath = Self.routePrefix + token + "/" + Self.encodeRelativePath(relative)

        lock.lock()
        purgeExpired(now: now)
        grants[token] = Grant(rootPath: root, createdAt: now)
        lock.unlock()

        return DirectStaticFileGrant(token: token, rootPath: root, routePath: routePath)
    }

    public func resolve(routePath: String, now: Date? = nil) -> (url: URL, contentType: String)? {
        let now = now ?? currentTime()
        guard routePath.hasPrefix(Self.routePrefix) else { return nil }
        let rest = String(routePath.dropFirst(Self.routePrefix.count))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let token = String(rest[..<slash])
        let encodedRelative = String(rest[rest.index(after: slash)...])
        guard !encodedRelative.isEmpty,
              let relative = encodedRelative.removingPercentEncoding,
              !relative.split(separator: "/").contains("..") else { return nil }

        lock.lock()
        purgeExpired(now: now)
        guard let grant = grants[token] else { lock.unlock(); return nil }
        lock.unlock()

        let rootURL = URL(fileURLWithPath: grant.rootPath, isDirectory: true).standardizedFileURL
        let candidate = rootURL.appendingPathComponent(relative).standardizedFileURL
        let rootPath = rootURL.path
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return (candidate, Self.contentType(for: candidate.pathExtension))
    }

    public func resetForTests() {
        lock.lock()
        grants.removeAll()
        lock.unlock()
    }

    /// QA-002: inject a fixed/controllable clock so TTL-dependent grant
    /// tests are deterministic without threading `now:` through every call.
    public func setClockForTests(_ clock: @escaping @Sendable () -> Date) {
        lock.lock()
        self.clock = clock
        lock.unlock()
    }

    private func currentTime() -> Date {
        lock.lock(); defer { lock.unlock() }
        return clock()
    }

    private func purgeExpired(now: Date) {
        grants = grants.filter { now.timeIntervalSince($0.value.createdAt) <= ttl }
    }

    private static func encodeRelativePath(_ relative: String) -> String {
        relative.split(separator: "/", omittingEmptySubsequences: false)
            .map { part in
                String(part).addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) ?? String(part)
            }
            .joined(separator: "/")
    }

    private static let pathComponentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return set
    }()

    private static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "avif": return "image/avif"
        case "svg": return "image/svg+xml"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "pdf": return "application/pdf"
        case "md", "markdown": return "text/markdown; charset=utf-8"
        case "wasm": return "application/wasm"
        case "map": return "application/json"
        case "ico": return "image/x-icon"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - C-24 single-encode snapshot RPC envelope

/// Wire `id` for the snapshot success envelope. Preserves string / integer /
/// null fidelity without forcing a Data→Any round-trip.
private enum SnapshotRPCWireID: Encodable {
    case null
    case string(String)
    case number(NSNumber)

    init(_ value: Any) {
        if value is NSNull {
            self = .null
        } else if let s = value as? String {
            self = .string(s)
        } else if let n = value as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID() {
            self = .number(n)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .string(let s):
            try container.encode(s)
        case .number(let n):
            if CFNumberIsFloatType(n) {
                try container.encode(n.doubleValue)
            } else if let i = Int64(exactly: n.int64Value) {
                try container.encode(i)
            } else {
                try container.encode(n.doubleValue)
            }
        }
    }
}

/// Full JSON-RPC success body for `sync.snapshot` — one encode of `id` + result.
private struct SnapshotRPCSuccessEnvelope: Encodable {
    let jsonrpc: String = "2.0"
    let id: SnapshotRPCWireID
    let result: ConnectionSnapshotFrame
}
