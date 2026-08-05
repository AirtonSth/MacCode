import Foundation
import Darwin
import CryptoKit
import CoreModel
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
/// - GET  /v1/capabilities/authenticated  (bearer required, including loopback)
/// - GET  /healthz
/// - GET|HEAD /__rc2_static/<grant>/<relative-path>
public protocol DirectAuthProvider: AnyObject {
    func verify(token: String) -> Bool
    /// Opaque durable owner fingerprint for a verified bearer.
    ///
    /// Used by Attachment Upload v2 so a bearer refresh for the same
    /// authorized paired/account device resumes the same upload binding.
    /// Returns `nil` when the token is invalid. Implementations must never
    /// return raw bearer material or raw client identifiers — only an
    /// opaque fingerprint suitable for durable owner isolation.
    func authorizedOwnerFingerprint(token: String) -> String?
    /// True only while the durable trusted-device row represented by this
    /// fingerprint remains non-revoked. Capability-only background PUT uses
    /// this gate before reading any request body.
    func isAuthorizedOwnerFingerprintActive(_ fingerprint: String) -> Bool
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

/// Exact `agent.checkpoint_list` capability marker shared by public HTTP
/// capabilities, authenticated HTTP capabilities, and `system.capabilities`.
/// Single source so the three surfaces cannot drift on response budgets.
/// `max_response_bytes` caps one complete JSON-RPC response item, including its
/// echoed id. Explicit response_version 1 is HTTP-only and batch-forbidden;
/// legacy `agent.checkpoint.list` retains prior batch/transport admission.
public enum AgentCheckpointListCapabilityV1 {
    public static let responseVersion = AgentCheckpointListContract.responseVersion
    public static let maxEntries = AgentCheckpointListContract.maxEntries
    public static let maxItemBytes = AgentCheckpointListContract.maxEncodedItemBytes
    public static let maxResponseBytes = AgentCheckpointListContract.maxEncodedResponseBytes
    public static let maxRequestBytes = AgentCheckpointListContract.maxEncodedRequestBytes
    public static let metadataOnly = true
    public static let transport = "http_jsonrpc_only"
    public static let sessionRecovery = AgentCheckpointListContract.sessionRecovery
    public static let catalogRevision = true

    public static var foundationObject: [String: Any] {
        [
            "response_version": responseVersion,
            "max_entries": maxEntries,
            "max_item_bytes": maxItemBytes,
            "max_response_bytes": maxResponseBytes,
            "max_request_bytes": maxRequestBytes,
            "metadata_only": metadataOnly,
            "transport": transport,
            "catalog_revision": catalogRevision,
            "session_recovery": sessionRecovery,
        ]
    }

    public static var jsonValue: JSONValue {
        .object([
            "response_version": .number(Double(responseVersion)),
            "max_entries": .number(Double(maxEntries)),
            "max_item_bytes": .number(Double(maxItemBytes)),
            "max_response_bytes": .number(Double(maxResponseBytes)),
            "max_request_bytes": .number(Double(maxRequestBytes)),
            "metadata_only": .bool(metadataOnly),
            "transport": .string(transport),
            "catalog_revision": .bool(catalogRevision),
            "session_recovery": .string(sessionRecovery),
        ])
    }
}

/// Store-independent advertisement injected into both HTTP capabilities
/// routes and the legacy authenticated `system.capabilities` RPC. The broad
/// app wiring must construct this only when its upload store is available, so
/// every authority reports the same runtime truth without this target needing
/// to depend on a particular attachment-store implementation.
public struct AgentAttachmentUploadCapabilityAdvertisement: Sendable, Equatable {
    public let protocolVersion: Int
    public let maxBytes: Int
    public let chunkBytes: Int
    public let maxChunkCount: Int
    public let maxFilenameBytes: Int?
    public let maxMIMETypeBytes: Int?
    public let contentEncodings: [String]
    public let cipherOverheadBytes: Int

    public init(
        protocolVersion: Int,
        maxBytes: Int,
        chunkBytes: Int,
        maxChunkCount: Int,
        maxFilenameBytes: Int? = nil,
        maxMIMETypeBytes: Int? = nil,
        contentEncodings: [String],
        cipherOverheadBytes: Int
    ) {
        self.protocolVersion = protocolVersion
        self.maxBytes = maxBytes
        self.chunkBytes = chunkBytes
        self.maxChunkCount = maxChunkCount
        self.maxFilenameBytes = maxFilenameBytes
        self.maxMIMETypeBytes = maxMIMETypeBytes
        self.contentEncodings = contentEncodings
        self.cipherOverheadBytes = cipherOverheadBytes
    }

    public static let plaintextV2 =
        AgentAttachmentUploadCapabilityAdvertisement(
            protocolVersion: AttachmentUploadV2Policy.protocolVersion,
            maxBytes: AttachmentUploadV2Policy.maximumFileBytes,
            chunkBytes: AttachmentUploadV2Policy.rawChunkBytes,
            maxChunkCount: AttachmentUploadV2Policy.maximumChunkCount,
            maxFilenameBytes:
                AttachmentUploadV2Policy.maximumFilenameBytes,
            maxMIMETypeBytes:
                AttachmentUploadV2Policy.maximumMIMETypeBytes,
            contentEncodings: ["identity"],
            cipherOverheadBytes: 0
        )

    public static let protectedV3 =
        AgentAttachmentUploadCapabilityAdvertisement(
            protocolVersion: AttachmentUploadV3Policy.protocolVersion,
            maxBytes: AttachmentUploadV2Policy.maximumFileBytes,
            chunkBytes: AttachmentUploadV3Policy.plaintextChunkBytes,
            maxChunkCount: AttachmentUploadV2Policy.maximumChunkCount,
            maxFilenameBytes:
                AttachmentUploadV2Policy.maximumFilenameBytes,
            maxMIMETypeBytes:
                AttachmentUploadV2Policy.maximumMIMETypeBytes,
            contentEncodings: [AttachmentUploadV3Policy.contentEncoding],
            cipherOverheadBytes:
                AttachmentUploadV3Policy.cipherOverheadBytes
        )

    var foundationObject: [String: Any] {
        var value: [String: Any] = [
            "protocol_version": protocolVersion,
            "max_bytes": maxBytes,
            "chunk_bytes": chunkBytes,
            "max_chunk_count": maxChunkCount,
            "content_encodings": contentEncodings,
            "cipher_overhead_bytes": cipherOverheadBytes,
        ]
        if let maxFilenameBytes {
            value["max_filename_bytes"] = maxFilenameBytes
        }
        if let maxMIMETypeBytes {
            value["max_mime_type_bytes"] = maxMIMETypeBytes
        }
        return value
    }

    var jsonValue: JSONValue {
        var value: [String: JSONValue] = [
            "protocol_version": .number(Double(protocolVersion)),
            "max_bytes": .number(Double(maxBytes)),
            "chunk_bytes": .number(Double(chunkBytes)),
            "max_chunk_count": .number(Double(maxChunkCount)),
            "content_encodings": .array(contentEncodings.map(JSONValue.string)),
            "cipher_overhead_bytes": .number(Double(cipherOverheadBytes)),
        ]
        if let maxFilenameBytes {
            value["max_filename_bytes"] = .number(Double(maxFilenameBytes))
        }
        if let maxMIMETypeBytes {
            value["max_mime_type_bytes"] = .number(Double(maxMIMETypeBytes))
        }
        return .object(value)
    }
}

/// Defaulted so existing conformers (e.g. test doubles) need no change
/// until they opt into the request/approve flow.
public extension DirectAuthProvider {
    /// Safe default: still validates the token and preserves owner isolation
    /// via the existing token-derived fingerprint. Providers that can expose
    /// a stable authorized identity (e.g. LocalAuthAdapter) should override.
    func authorizedOwnerFingerprint(token: String) -> String? {
        guard verify(token: token) else { return nil }
        return DirectHTTPServer.connectionOwnerFingerprint(token: token)
    }
    func isAuthorizedOwnerFingerprintActive(_ fingerprint: String) -> Bool {
        false
    }
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
///
/// Lifetime counters (`slowClientDrops`, max-observed depths, rejected/evicted
/// frame counts, outbound queue wait aggregates) are process-scoped and never
/// decrease. Live gauges (`activeClients`, `totalQueuedBytes`) follow
/// connect/disconnect samples.
public final class WSConnectionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _activeClients: Int = 0
    private var _totalQueuedBytes: Int = 0
    private var _slowClientDrops: Int = 0
    /// High-water mark of observed outbound queue depth (per sample and aggregate).
    private var _maxObservedOutboundQueuedBytes: Int = 0
    /// High-water mark of observed application frame payload sizes.
    private var _maxObservedFrameBytes: Int = 0
    /// Frames refused at enqueue under backpressure or shed by degrade().
    private var _framesRejectedOrEvicted: Int = 0
    /// Enqueue→dequeue wait aggregates by existing application priority lane.
    /// Secret-free: count/total/max milliseconds only.
    private var _outboundQueueWait = OutboundQueueWaitMetricsSnapshot.zero

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

    public var maxObservedOutboundQueuedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _maxObservedOutboundQueuedBytes
    }

    public var maxObservedFrameBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _maxObservedFrameBytes
    }

    public var framesRejectedOrEvicted: Int {
        lock.lock(); defer { lock.unlock() }
        return _framesRejectedOrEvicted
    }

    /// Process-scoped outbound queue wait aggregates (priority / normal / bulk).
    var outboundQueueWaitMetrics: OutboundQueueWaitMetricsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return _outboundQueueWait
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
        _totalQueuedBytes = max(0, _totalQueuedBytes - max(0, queuedBytes))
        lock.unlock()
    }

    /// Called when the outbound queue for a connection changes (sampled on
    /// enqueue / degrade). Replaces the previous sample for this connection.
    public func updateQueuedBytes(previous: Int, current: Int) {
        lock.lock()
        let prev = max(0, previous)
        let cur = max(0, current)
        _totalQueuedBytes = max(0, _totalQueuedBytes - prev + cur)
        // Max is monotonic: track both per-connection depth and aggregate.
        _maxObservedOutboundQueuedBytes = max(
            _maxObservedOutboundQueuedBytes,
            cur,
            _totalQueuedBytes
        )
        lock.unlock()
    }

    /// Record an observed application-frame byte size (monotonic high-water).
    public func recordFrameBytes(_ bytes: Int) {
        lock.lock()
        _maxObservedFrameBytes = max(_maxObservedFrameBytes, max(0, bytes))
        lock.unlock()
    }

    /// Count frames refused under backpressure or shed by degrade.
    /// Negative counts are ignored so callers cannot underflow health.
    public func recordFramesRejectedOrEvicted(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock()
        _framesRejectedOrEvicted += count
        lock.unlock()
    }

    /// Called when the WS outbound queue drops a slow client.
    public func recordSlowClientDrop() {
        lock.lock(); _slowClientDrops += 1; lock.unlock()
    }

    /// Record one application-frame enqueue→dequeue wait sample for a lane.
    /// Negative/non-finite waits are clamped; lane labels are fixed enums only.
    func recordOutboundQueueWait(
        priority: WebSocketOutboundQueue.ApplicationPriority,
        waitMilliseconds: Double
    ) {
        let bounded: Double
        if waitMilliseconds.isFinite {
            bounded = max(0, waitMilliseconds)
        } else {
            bounded = 0
        }
        lock.lock()
        switch priority {
        case .priority:
            _outboundQueueWait.priority.record(waitMilliseconds: bounded)
        case .normal:
            _outboundQueueWait.normal.record(waitMilliseconds: bounded)
        case .bulk:
            _outboundQueueWait.bulk.record(waitMilliseconds: bounded)
        }
        lock.unlock()
    }
}

/// Operator-facing class for whether observed WS connection latency is
/// dominated by outbound queue/backpressure, or there is no observed queue
/// pressure (or too little evidence to decide).
///
/// Observability only — pure classification of existing counters. Does not
/// change queue scheduling, wire protocol, authentication, or retries.
/// Secret-free fixed string codes only (no hosts, tokens, payloads).
///
/// Queue/backpressure classes describe **where pressure was observed in the
/// outbound path**. They do **not** prove TCP (or any L4 path) is the root
/// cause — client drain rate, radio, CPU, and app produce rate share the same
/// gauges. See `TransportLimiterEvidenceBucket` and fixed non-claims.
public enum OutboundLatencyPressureClass: String, Sendable, Equatable {
    /// Frames refused/shed or slow-client drops: the queue hit its wall.
    case backpressureDominated = "backpressure_dominated"
    /// Elevated enqueue→dequeue wait and/or queued bytes without shed signals.
    case queuePressureDominated = "queue_pressure_dominated"
    /// Enough samples and no elevated queue/backpressure signals.
    case noQueuePressure = "no_queue_pressure"
    /// Too few wait samples and no elevated depth/reject signals to decide.
    case insufficientSamples = "insufficient_samples"

    /// Coarse three-way evidence bucket for the open "is TCP/WebSocket the
    /// limiter?" question — never a path-layer root-cause verdict.
    public var limiterEvidenceBucket: TransportLimiterEvidenceBucket {
        switch self {
        case .insufficientSamples:
            return .insufficientEvidence
        case .backpressureDominated, .queuePressureDominated:
            return .queueOrBackpressure
        case .noQueuePressure:
            return .nonQueueOrUnknown
        }
    }
}

/// Coarse evidence bucket for whether the **outbound WebSocket queue** is
/// implicated in observed latency — not a proof that TCP is the limiter.
///
/// Maps the finer `OutboundLatencyPressureClass` into the three operator
/// questions: not enough data, queue/backpressure pressure present, or
/// non-queue/unknown (latency not explained by outbound queue gauges).
public enum TransportLimiterEvidenceBucket: String, Sendable, Equatable {
    /// Too little wait/depth/reject evidence to decide.
    case insufficientEvidence = "insufficient_evidence"
    /// Rejects, slow-client drops, elevated queue depth, or elevated wait.
    case queueOrBackpressure = "queue_or_backpressure"
    /// Enough quiet samples: not outbound-queue-dominated (true limiter
    /// elsewhere remains unknown — RTT, radio, client, app work, etc.).
    case nonQueueOrUnknown = "non_queue_or_unknown"
}

/// Result of `OutboundLatencyPressureClassifier.classify`.
/// Fixed `reason` codes only (documented constants on the classifier).
/// Always carries fixed non-claim codes so pressure is never misread as a
/// proven TCP root cause or path-layer isolation result.
public struct OutboundLatencyPressureSnapshot: Sendable, Equatable {
    public let classification: OutboundLatencyPressureClass
    public let reason: String
    /// Coarse three-way evidence bucket (derived from `classification`).
    public let evidence: TransportLimiterEvidenceBucket
    /// Stable fixed codes asserting what this snapshot does **not** claim.
    public let nonClaims: [String]

    public init(
        classification: OutboundLatencyPressureClass,
        reason: String,
        evidence: TransportLimiterEvidenceBucket? = nil,
        nonClaims: [String] = OutboundLatencyPressureClassifier.fixedNonClaims
    ) {
        self.classification = classification
        self.reason = reason
        self.evidence = evidence ?? classification.limiterEvidenceBucket
        self.nonClaims = nonClaims
    }
}

/// Pure, deterministic classifier over existing WS outbound health counters.
///
/// Thresholds are intentionally conservative and bounded:
/// - Wait floors sit far below the ~8s target backlog used to size the queue,
///   so only material enqueue delay trips pressure without flagging normal
///   local drain (sub-ms to a few ms).
/// - Queued-byte floor matches `WebSocketOutboundQueue.minimumQueuedBytes`
///   (64 KiB), the soft floor for dynamic sizing — below that is normal buffer.
/// - Minimum wait samples avoid classifying from a single noisy frame.
public enum OutboundLatencyPressureClassifier {
    /// Combined wait samples across lanes required for wait-based verdicts.
    public static let minimumWaitSamples: UInt64 = 3

    /// Per-frame max enqueue→dequeue wait (ms) that indicates queue pressure.
    public static let elevatedWaitMaxMilliseconds: Double = 100

    /// Average wait (ms) across all samples that indicates sustained pressure.
    public static let elevatedWaitAverageMilliseconds: Double = 50

    /// Live or high-water queued bytes that indicate material backlog.
    /// Matches `WebSocketOutboundQueue.minimumQueuedBytes`.
    public static let elevatedQueuedBytes: Int = 64 * 1_024

    // Fixed reason codes (stable for operators / support tooling).
    public static let reasonFramesRejectedOrEvicted = "frames_rejected_or_evicted"
    public static let reasonSlowClientDrops = "slow_client_drops"
    public static let reasonElevatedQueuedBytes = "elevated_queued_bytes"
    public static let reasonElevatedQueueWait = "elevated_queue_wait"
    public static let reasonNoElevatedQueueSignals = "no_elevated_queue_signals"
    public static let reasonInsufficientWaitSamples = "insufficient_wait_samples"
    /// Public snapshot had negative or non-finite wait total/max on a lane.
    public static let reasonInvalidWaitSamples = "invalid_wait_samples"

    /// Fixed non-claim codes always attached to every pressure snapshot.
    /// Queue/backpressure evidence never upgrades into a TCP root-cause proof,
    /// path-layer isolation, or QUIC/performance verdict.
    public static let fixedNonClaims: [String] = [
        "no_tcp_root_cause_claim",
        "no_path_layer_isolation_claim",
        "no_quic_performance_claim",
        "observability_only",
    ]

    /// Classify from existing process/live gauges. Inputs are clamped so
    /// negative race samples cannot invent pressure.
    public static func classify(
        totalQueuedBytes: Int,
        maxObservedOutboundQueuedBytes: Int,
        framesRejectedOrEvicted: Int,
        slowClientDrops: Int,
        outboundQueueWait: OutboundQueueWaitMetricsSnapshot
    ) -> OutboundLatencyPressureSnapshot {
        let rejects = max(0, framesRejectedOrEvicted)
        let drops = max(0, slowClientDrops)
        let liveQueued = max(0, totalQueuedBytes)
        let maxQueued = max(0, maxObservedOutboundQueuedBytes)

        // Strongest signal first: the queue refused work or shed a client.
        if rejects > 0 {
            return OutboundLatencyPressureSnapshot(
                classification: .backpressureDominated,
                reason: reasonFramesRejectedOrEvicted
            )
        }
        if drops > 0 {
            return OutboundLatencyPressureSnapshot(
                classification: .backpressureDominated,
                reason: reasonSlowClientDrops
            )
        }

        // Depth high-water / live gauge — independent of wait sample count.
        if liveQueued >= elevatedQueuedBytes || maxQueued >= elevatedQueuedBytes {
            return OutboundLatencyPressureSnapshot(
                classification: .queuePressureDominated,
                reason: reasonElevatedQueuedBytes
            )
        }

        let lanes = [
            outboundQueueWait.priority,
            outboundQueueWait.normal,
            outboundQueueWait.bulk
        ]
        var sampleCount: UInt64 = 0
        var totalMs: Double = 0
        var maxMs: Double = 0
        for lane in lanes {
            // Malformed public metrics must fail neutral: never clamp bad
            // totals/maxes into a false no_queue_pressure exoneration.
            let total = lane.totalMilliseconds
            let laneMax = lane.maxMilliseconds
            if !total.isFinite || total < 0 || !laneMax.isFinite || laneMax < 0 {
                return OutboundLatencyPressureSnapshot(
                    classification: .insufficientSamples,
                    reason: reasonInvalidWaitSamples
                )
            }
            sampleCount &+= lane.count
            totalMs += total
            maxMs = max(maxMs, laneMax)
        }

        if sampleCount < minimumWaitSamples {
            return OutboundLatencyPressureSnapshot(
                classification: .insufficientSamples,
                reason: reasonInsufficientWaitSamples
            )
        }

        let averageMs = totalMs / Double(sampleCount)
        if maxMs >= elevatedWaitMaxMilliseconds
            || averageMs >= elevatedWaitAverageMilliseconds {
            return OutboundLatencyPressureSnapshot(
                classification: .queuePressureDominated,
                reason: reasonElevatedQueueWait
            )
        }

        return OutboundLatencyPressureSnapshot(
            classification: .noQueuePressure,
            reason: reasonNoElevatedQueueSignals
        )
    }
}

/// Pure helper: assembles the `connections` sub-object for /v1/health from
/// plain counter inputs. No I/O, no actor, fully unit-testable.
/// Values are clamped nonnegative so health never emits negative gauges.
///
/// `outbound_queue_wait_ms` is additive diagnostics only (count/total/max per
/// existing application lane). It never includes payloads, tokens, hosts, or
/// request bodies.
///
/// `outbound_latency_pressure` is additive operator diagnostics derived only
/// from the same counters (class + reason + coarse evidence bucket + fixed
/// non-claim codes). No secrets/hosts. Never claims TCP is the proven limiter.
public func connectionMetricsJSON(
    activeClients: Int,
    totalQueuedBytes: Int,
    slowClientDrops: Int,
    maxObservedOutboundQueuedBytes: Int = 0,
    maxObservedFrameBytes: Int = 0,
    framesRejectedOrEvicted: Int = 0,
    outboundQueueWait: OutboundQueueWaitMetricsSnapshot = .zero
) -> [String: Any] {
    /// JSONSerialization rejects NaN/Inf; clamp negative/non-finite wait
    /// aggregates to finite 0 so a malformed public snapshot cannot break
    /// /v1/health. Classifier still sees raw inputs for invalid_wait_samples.
    func finiteNonNegativeMilliseconds(_ value: Double) -> Double {
        (value.isFinite && value >= 0) ? value : 0
    }
    func laneJSON(_ metrics: OutboundQueueWaitLaneMetrics) -> [String: Any] {
        [
            "count": metrics.count,
            "total": finiteNonNegativeMilliseconds(metrics.totalMilliseconds),
            "max": finiteNonNegativeMilliseconds(metrics.maxMilliseconds)
        ]
    }
    let pressure = OutboundLatencyPressureClassifier.classify(
        totalQueuedBytes: totalQueuedBytes,
        maxObservedOutboundQueuedBytes: maxObservedOutboundQueuedBytes,
        framesRejectedOrEvicted: framesRejectedOrEvicted,
        slowClientDrops: slowClientDrops,
        outboundQueueWait: outboundQueueWait
    )
    return [
        "active_clients": max(0, activeClients),
        "total_queued_bytes": max(0, totalQueuedBytes),
        "slow_client_drops": max(0, slowClientDrops),
        "max_observed_outbound_queued_bytes": max(0, maxObservedOutboundQueuedBytes),
        "max_observed_frame_bytes": max(0, maxObservedFrameBytes),
        "frames_rejected_or_evicted": max(0, framesRejectedOrEvicted),
        "outbound_queue_wait_ms": [
            "priority": laneJSON(outboundQueueWait.priority),
            "normal": laneJSON(outboundQueueWait.normal),
            "bulk": laneJSON(outboundQueueWait.bulk)
        ],
        "outbound_latency_pressure": [
            "class": pressure.classification.rawValue,
            "reason": pressure.reason,
            "evidence": pressure.evidence.rawValue,
            "non_claims": pressure.nonClaims
        ]
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

/// Observable publication lifecycle for the TCP listener (and Bonjour supervisors
/// that mirror the same states). Bounded retries use `ListenerRetryPolicy`.
public enum ListenerPublicationState: String, Sendable, Equatable {
    case idle
    case publishing
    case published
    case failed
}

/// Bounded listen/publish retry schedule. Exhaustion is explicit (`nil` delay)
/// so supervisors never storm with infinite tight loops.
public struct ListenerRetryPolicy: Sendable, Equatable {
    public let delaysSeconds: [TimeInterval]

    /// Default: 1s, 2s, 4s — matches the historical supervisor ladder without
    /// continuing forever after the third failure.
    public static let `default` = ListenerRetryPolicy(delaysSeconds: [1, 2, 4])

    public init(delaysSeconds: [TimeInterval]) {
        self.delaysSeconds = delaysSeconds.filter { $0 >= 0 }
    }

    public var maxAttempts: Int { delaysSeconds.count }

    /// 0-based failure index → delay before the next attempt, or nil when exhausted.
    public func delayAfterFailure(attemptIndex: Int) -> TimeInterval? {
        guard attemptIndex >= 0, attemptIndex < delaysSeconds.count else { return nil }
        return delaysSeconds[attemptIndex]
    }

    public func isExhausted(afterFailureCount failures: Int) -> Bool {
        failures >= delaysSeconds.count
    }
}

/// Extended listener publication payload (diagnostics / UI). Does not replace
/// the stable three-key `serverListenerEventPayload` contract.
public func listenerPublicationStatusPayload(
    state: ListenerPublicationState,
    bound: Bool,
    address: String,
    port: UInt16,
    attempt: Int,
    maxAttempts: Int,
    nextRetryMs: Int? = nil,
    errorCode: Int? = nil
) -> [String: Any] {
    var payload: [String: Any] = [
        "state": state.rawValue,
        "bound": bound,
        "address": address,
        "port": Int(port),
        "attempt": attempt,
        "max_attempts": maxAttempts
    ]
    if let nextRetryMs { payload["next_retry_ms"] = nextRetryMs }
    if let errorCode { payload["error_code"] = errorCode }
    return payload
}

/// Bracket IPv6 literals (and percent-encode zone IDs) for URL host components.
/// IPv4 and hostnames pass through unchanged. Does not invent relays.
///
/// Already-bracketed hosts still get zone-id encoding (`[fe80::1%en0]` →
/// `[fe80::1%25en0]`) without double-encoding an existing `%25`.
public func urlHostLiteral(_ host: String) -> String {
    if host.hasPrefix("[") {
        guard host.hasSuffix("]") else { return host }
        let inner = String(host.dropFirst().dropLast())
        return "[\(encodeIPv6ZoneIDForURL(inner))]"
    }
    // Scope id: fe80::1%en0 → fe80::1%25en0 inside brackets.
    if host.contains(":") {
        return "[\(encodeIPv6ZoneIDForURL(host))]"
    }
    return host
}

/// Percent-encode bare IPv6 zone-id `%` for URL hosts; leave existing `%25` alone.
private func encodeIPv6ZoneIDForURL(_ host: String) -> String {
    guard host.contains("%") else { return host }
    var out = String()
    out.reserveCapacity(host.count + 4)
    var i = host.startIndex
    while i < host.endIndex {
        if host[i] == "%" {
            let after = host.index(after: i)
            // Already percent-encoded zone separator: keep "%25" intact.
            if after < host.endIndex,
               host[after] == "2",
               host.index(after: after) < host.endIndex,
               host[host.index(after: after)] == "5" {
                out.append(contentsOf: "%25")
                i = host.index(i, offsetBy: 3)
            } else {
                out.append(contentsOf: "%25")
                i = after
            }
        } else {
            out.append(host[i])
            i = host.index(after: i)
        }
    }
    return out
}

public func endpointURLString(scheme: String, host: String, port: UInt16, path: String = "/") -> String {
    let normalizedPath = path.hasPrefix("/") ? path : "/" + path
    return "\(scheme)://\(urlHostLiteral(host)):\(port)\(normalizedPath)"
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
    nonisolated static let staticFileHTTPMethods: Set<String> = [
        "GET",
        "HEAD",
    ]

    enum AttachmentUploadV2HTTPRoute: Equatable {
        case upload(uploadId: String)
        case chunk(uploadId: String, index: Int)

        var uploadId: String {
            switch self {
            case .upload(let uploadId), .chunk(let uploadId, _):
                return uploadId
            }
        }
    }

    enum AttachmentUploadV3HTTPRoute: Equatable {
        case upload(uploadId: String)
        case prepare(uploadId: String)
        case chunk(uploadId: String, index: Int)

        var uploadId: String {
            switch self {
            case .upload(let uploadId),
                 .prepare(let uploadId),
                 .chunk(let uploadId, _):
                return uploadId
            }
        }
    }

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
    static let maxClientFramePayloadBytes = WebSocketClientFrameAssembler.maxFragmentedMessageBytes
    public static let maxWebSocketOutboundQueuedBytes = 1024 * 1024

    /// Baseline welcome capabilities required by old and new peers. Optional
    /// negotiated controls (e.g. `stream.interest.v1`) are appended only when
    /// the host actually implements them — see `welcomeCapabilities(streamInterestSupported:)`.
    public static let baselineWelcomeCapabilities: [String] = [
        "events.replay", "snapshot.v3",
        "snapshot.incremental", "resume.v1",
        SnapshotChunkCapability.wireName,
    ]

    /// Wire name for mid-session interest control (iOS sends `rc2.interest` only
    /// after seeing this capability on welcome).
    public static let streamInterestCapability = "stream.interest.v1"

    /// Mac implements `EventStreamFilter.parseInterestControl` + live filter update.
    public static var supportsStreamInterestControl: Bool { true }

    /// Welcome capability list: baseline always present; `stream.interest.v1`
    /// only when the host can apply interest control (preserves old-peer shape
    /// when the flag is false).
    public static func welcomeCapabilities(
        streamInterestSupported: Bool = DirectHTTPServer.supportsStreamInterestControl
    ) -> [String] {
        var caps = baselineWelcomeCapabilities
        if streamInterestSupported {
            caps.append(streamInterestCapability)
        }
        return caps
    }
    /// Wi-Fi / unmetered default: snappy dead-peer detection without thrashing radio idle.
    public static let wsHeartbeatProfileWiFi = WebSocketHeartbeatProfile(interval: 10, timeout: 30)
    /// Cellular / Low Data (`X-RC2-WS-Filter: cellular-safe`): tolerate 3G RRC promotion
    /// and allow the radio to sleep between bursts (C-06).
    public static let wsHeartbeatProfileCellular = WebSocketHeartbeatProfile(interval: 25, timeout: 90)
    /// Short adaptive application-event coalescing window. Clients may propose
    /// a larger bounded value for measured degraded/severe links; absent/legacy
    /// proposals keep these defaults (15 ms Wi-Fi, 100 ms cellular-safe).
    public static let wsCoalescingWindowWiFiMs = 15
    public static let wsCoalescingWindowCellularMs = 100
    public static let wsCoalescingWindowMinMs = 5
    public static let wsCoalescingWindowMaxMs = 250
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
    /// C-07: baseline idle between keep-alive HTTP requests (~5s closes abandoned
    /// sockets quickly). U-002 experiment lengthens this for 3G RRC gaps.
    public static let httpKeepAliveIdleTimeoutSeconds = 5
    /// U-002 / plan-connection: longer keep-alive when transport keepalive exp is on.
    /// Covers typical cellular RRC idle without holding dead clients forever.
    public static let httpKeepAliveIdleTimeoutExperimentSeconds = 25

    /// Pure seam: pick HTTP keep-alive idle budget from experiment flag.
    public static func resolvedHttpKeepAliveIdleTimeoutSeconds(experimentEnabled: Bool) -> Int {
        experimentEnabled
            ? httpKeepAliveIdleTimeoutExperimentSeconds
            : httpKeepAliveIdleTimeoutSeconds
    }

    /// Accept an optional client coalescing proposal while preserving the
    /// filter-specific legacy default and a strict latency/aggregation bound.
    nonisolated public static func negotiateCoalescingWindowMs(
        filter: EventStreamFilter,
        proposedMs: Int64?
    ) -> Int {
        let fallback = filter.isCellularSafe
            ? wsCoalescingWindowCellularMs
            : wsCoalescingWindowWiFiMs
        guard let proposedMs, proposedMs > 0 else { return fallback }
        return Int(min(
            Int64(wsCoalescingWindowMaxMs),
            max(Int64(wsCoalescingWindowMinMs), proposedMs)
        ))
    }

    /// Select the host heartbeat offer from the client's WS filter proposal.
    /// `cellular-safe` → cellular budget; otherwise Wi-Fi. Pure for unit tests.
    nonisolated static func heartbeatProfile(
        forWSFilter filter: EventStreamFilter
    ) -> WebSocketHeartbeatProfile {
        switch filter {
        case .cellularSafe:
            return wsHeartbeatProfileCellular
        case .full, .kindPrefixes:
            // Local kind-prefix filters are host-only and use the Wi-Fi heartbeat budget.
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
        let offer: Int64 = filter.isCellularSafe
            ? wsSnapshotTimeoutCellularMs
            : wsSnapshotTimeoutWiFiMs
        guard let proposedMs, proposedMs > 0 else { return offer }
        return min(wsSnapshotTimeoutMaxMs, max(wsSnapshotTimeoutMinMs, proposedMs))
    }

    /// Pure resume-contract seam. A cursor is usable only when the optional
    /// envelope is absent (legacy client) or matches this host's identity and
    /// current boot epoch; stale envelopes deliberately start at zero.
    public static func acceptedResumeSequence(
        requestedSinceSequence: Int64,
        requestedResumeHost: String?,
        requestedResumeBootEpoch: Int64?,
        serverId: String,
        bootEpoch: Int64,
        currentSequence: Int64
    ) -> Int64 {
        let hasEnvelope = requestedResumeHost != nil || requestedResumeBootEpoch != nil
        let matches = requestedResumeHost == serverId && requestedResumeBootEpoch == bootEpoch
        guard !hasEnvelope || matches else { return 0 }
        return min(max(0, requestedSinceSequence), max(0, currentSequence))
    }

    /// Clamp an optional client proposal into the host profile offer.
    /// Client proposes (headers or policy); host accepts within profile, or counters
    /// by the profile ceiling. Missing proposal → host profile defaults.
    ///
    /// Full-content fidelity (filter `.full`) must not force Wi‑Fi liveness when
    /// the client proposes cellular-scale budgets (4G+Tailscale street path).
    nonisolated static func negotiateHeartbeatProfile(
        filter: EventStreamFilter,
        proposedIntervalMs: Int64?,
        proposedTimeoutMs: Int64?
    ) -> WebSocketHeartbeatProfile {
        let filterOffer = heartbeatProfile(forWSFilter: filter)
        // If the client asks for ≥ cellular timeout (60s+), raise the ceiling to
        // the cellular profile even when content filter stays full fidelity.
        let offer: WebSocketHeartbeatProfile
        if let proposedTimeoutMs, proposedTimeoutMs >= 60_000 {
            offer = WebSocketHeartbeatProfile(
                interval: max(filterOffer.interval, wsHeartbeatProfileCellular.interval),
                timeout: max(filterOffer.timeout, wsHeartbeatProfileCellular.timeout)
            )
        } else {
            offer = filterOffer
        }
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
    /// (open) for ordinary `/v1/*` routes, pre-token paths are exempt, and a
    /// missing auth provider disables the gate.
    ///
    /// Exception: `GET /v1/capabilities/authenticated` always requires a bearer
    /// when an auth provider is configured, including loopback-only binds —
    /// paired iOS cold connect uses this path to prove identity in one round
    /// trip. Extracted so the auth decision is unit-testable without a live
    /// socket (a loopback test client is always treated as trusted for other
    /// routes, so a real socket cannot exercise the non-loopback gate).
    nonisolated static func httpAuthGateRequiresToken(loopbackOnly: Bool, path: String, hasAuthProvider: Bool) -> Bool {
        guard hasAuthProvider, path.hasPrefix("/v1") else { return false }
        // Always-gated: identity proof for cold connect; not loopback-trusted.
        if path == "/v1/capabilities/authenticated" { return true }
        return !loopbackOnly && !authExemptV1Paths.contains(path)
    }

    /// Shared capabilities object for public `GET /v1/capabilities` and the
    /// authenticated envelope's `capabilities` field. Single builder so the
    /// two routes cannot drift.
    nonisolated static func capabilitiesPayload(
        loopbackOnly: Bool,
        attachmentUpload:
            AgentAttachmentUploadCapabilityAdvertisement? = nil
    ) -> [String: Any] {
        // GAP-3: advertise what the dispatcher actually implements.
        // git mutations + full browser automation are real (see
        // Dispatcher.swift git.*/browser.*); hiding them on the
        // client breaks parity.
        var agent: [String: Any] = [
            "providers": ["codex", "claude", "grok"],
            "supports_stream_events": true,
            "supports_resume": true,
            "checkpoint_list": AgentCheckpointListCapabilityV1.foundationObject,
            "model_routing": [
                "auto": true,
                "admission_receipts": true,
                "rollout_enabled":
                    AgentOrchestrationRuntime.defaultRolloutEnabled(),
            ],
            // Always present while PlanNotesProjectionV1 is compiled in this
            // target (v1 get + digest-CAS save). Single helper with system.capabilities.
            "plan_notes": PlanNotesProjectionV1.CapabilityAdvertisement.foundationObject,
        ]
        if let attachmentUpload {
            agent["attachment_upload"] = attachmentUpload.foundationObject
        }
        return [
            "surface_types": ["terminal", "ssh", "browser", "agentApp", "files", "markdown", "filePreview", "rightSidebarTool"],
            "ssh": [
                "methods": ["ssh.host.list", "ssh.host.upsert", "ssh.host.delete", "ssh.connect", "ssh.disconnect", "ssh.transfer.upload", "ssh.transfer.download", "ssh.files.local.list", "ssh.files.remote.list", "ssh.files.remote.mkdir", "ssh.files.remote.rename", "ssh.files.remote.delete"]
            ],
            "agent": agent,
            // Public pre-auth hint only. iOS enables message v1 solely from the
            // exact authenticated system.capabilities marker.
            "message_transport_advisory": [
                "protocol": "agent.message.v1",
                "version": 1,
                "list": "bounded-envelope",
                "get": "rpc-byte-offset",
                "event": "bounded-preview",
                "metadata": "offset-zero-only",
                "digest": "sha256-hex",
                "revision": "body_revision",
                "advisory_only": true,
                "authoritative_rpc": "system.capabilities",
            ],
            "browser_automation": [
                "p0": ["navigate", "back", "forward", "reload", "stop", "url.get", "mirror_url.get"],
                "p1": ["click", "fill", "type", "focus", "hover", "check", "uncheck", "select", "eval", "snapshot", "screenshot", "wait"],
                "p1_unsupported": false
            ],
            "files": [
                "methods": ["fs.mkdir", "fs.workspace.list", "fs.workspace.read", "fs.workspace.preview_url", "fs.workspace.create_file", "fs.workspace.rename", "fs.workspace.delete", "files.tab.open", "files.tab.split", "files.state.get", "files.state.update", "files.edit.open", "files.edit.apply_patch", "files.edit.save", "files.edit.discard", "files.edit.close"]
            ],
            "git": [
                "read_only": false,
                "methods": ["git.status", "git.branches", "git.checkout", "git.create_branch", "git.commit", "git.log", "git.diff", "git.fetch", "git.pull", "git.push", "git.pull_request_url", "git.delivery_plan", "git.deliver"],
            ],
            "feature_flags": ["remote_access_enabled": !loopbackOnly]
        ]
    }

    nonisolated static func isAttachmentUploadRPCEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "agent.attachment.upload"
    }

    /// Strict parser for the authenticated raw-upload v2 route family.
    /// UUID-only path components make traversal/ambiguous normalization fail
    /// before any staging filesystem path is built.
    nonisolated static func attachmentUploadV2Route(
        path: String
    ) -> AttachmentUploadV2HTTPRoute? {
        guard path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("//") else {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 5 || components.count == 7,
              components[0] == "v1",
              components[1] == "agent",
              components[2] == "attachment-uploads",
              components[3] == "v2" else {
            return nil
        }
        let rawUploadId = String(components[4]).lowercased()
        guard UUID(uuidString: rawUploadId) != nil else { return nil }
        if components.count == 5 {
            return .upload(uploadId: rawUploadId)
        }
        guard components[5] == "chunks",
              let index = Int(components[6]),
              index >= 0 else {
            return nil
        }
        return .chunk(uploadId: rawUploadId, index: index)
    }

    nonisolated static func attachmentUploadV3Route(
        path: String
    ) -> AttachmentUploadV3HTTPRoute? {
        guard path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("//") else {
            return nil
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard (5...7).contains(components.count),
              components[0] == "v1",
              components[1] == "agent",
              components[2] == "attachment-uploads",
              components[3] == "v3" else {
            return nil
        }
        let rawUploadId = String(components[4]).lowercased()
        guard UUID(uuidString: rawUploadId) != nil else { return nil }
        if components.count == 5 {
            return .upload(uploadId: rawUploadId)
        }
        if components.count == 6, components[5] == "prepare" {
            return .prepare(uploadId: rawUploadId)
        }
        guard components.count == 7,
              components[5] == "chunks",
              let index = Int(components[6]),
              index >= 0,
              index < AttachmentUploadV2Policy.maximumChunkCount else {
            return nil
        }
        return .chunk(uploadId: rawUploadId, index: index)
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
    public let attachmentUploadV2Store: AttachmentUploadV2Store?
    public let attachmentUploadV3Store: AttachmentUploadV3Store?
    public weak var auth: DirectAuthProvider?
    /// Stable, persisted **logical** host identity. iOS pins this (RCA-022); it must
    /// survive process restarts or every relaunch looks like a different
    /// Mac and forces a re-pair (GAP-2).
    ///
    /// This is not a certificate/public-key identity. The listener is plaintext
    /// HTTP; cryptographic host proof requires a coordinated protocol change
    /// (iOS `HostIdentityTrustBoundary.cryptographicVerificationSupported` is
    /// fail-closed until then).
    public let serverId: String
    public let bootEpoch: UInt64

    /// Per-peer brute-force brake for the LAN pairing endpoints. The 6-digit
    /// code is brute-forceable over LAN without this throttle.
    let pairingThrottle = PairingThrottle()

    /// Live connection-level metrics surfaced via /v1/health.
    let wsTracker = WSConnectionTracker()
    /// Secret-free HTTP/RPC phase aggregates (admit/read/encode/write).
    public let requestPhaseMetrics = HTTPRequestPhaseMetrics()
    private let activeWebSocketConnections = ActiveWebSocketConnectionRegistry()
    /// TTL/memory-bounded cache for opt-in resumable `sync.snapshot` chunks.
    let snapshotChunkTransfers = SnapshotChunkTransferCache()
    private let receiveTimeoutSeconds: Int
    private let webSocketOutboundMaxQueuedBytes: Int

    private var listenFD: Int32 = -1
    /// Optional dual-stack IPv6 listener. Failure to bind IPv6 never tears down IPv4.
    private var listenFD6: Int32 = -1
    private var accept: Thread?
    private var accept6: Thread?
    private let acceptedSockets = AcceptedSocketRegistry()
    private let listenerStateLock = NSLock()
    private var _listenerPublicationState: ListenerPublicationState = .idle
    private var _listenerPublishAttempt: Int = 0
    private let listenerRetryPolicy = ListenerRetryPolicy.default
    /// Test seam: nanoseconds budget for `sync.snapshot` state capture (default 5s).
    var snapshotReadTimeoutNanosecondsForTesting: UInt64?


    static let maximumAcceptedConnections = AcceptedSocketRegistry.defaultMaximumDescriptors
    var acceptedSocketCountForTests: Int { acceptedSockets.count }
    var afterWelcomeWriteForTests: ((String) -> Void)?
    /// Test seam: fires once per WS upgrade with the coalescing window (ms)
    /// that is passed as `WebSocketEventBatcher.delay` after header negotiation.
    /// Production never sets this; used only to prove `X-RC2-WS-Coalesce-Window-Ms`
    /// is honored on the real HTTP→WebSocket path (not just the pure helper).
    var webSocketCoalescingWindowObserverForTests: (@Sendable (Int) -> Void)?
    var acceptedFDObserverForTesting: (@Sendable (Int32) -> Void)?
    var connectionReadWaitObserverForTesting: (@Sendable (Int32, ConnectionReadWaitStageForTesting) -> Void)?

    /// Explicit publication state for diagnostics (idle/publishing/published/failed).
    public var listenerPublicationState: ListenerPublicationState {
        listenerStateLock.lock(); defer { listenerStateLock.unlock() }
        return _listenerPublicationState
    }

    /// True when the IPv6 listener is bound (dual-stack path active).
    public var isIPv6ListenerBound: Bool { listenFD6 >= 0 }

    public init(
        port: UInt16 = 18217,
        loopbackOnly: Bool = true,
        dispatcher: JSONRPCDispatcher,
        auth: DirectAuthProvider? = nil,
        serverId: String = ProcessInfo.processInfo.globallyUniqueString,
        bootEpoch: UInt64,
        clientReceiveTimeoutSeconds: Int = DirectHTTPServer.httpKeepAliveIdleTimeoutSeconds,
        webSocketOutboundMaxQueuedBytes: Int = DirectHTTPServer.maxWebSocketOutboundQueuedBytes,
        attachmentUploadV2Store: AttachmentUploadV2Store? = nil,
        attachmentUploadV3Store: AttachmentUploadV3Store? = nil
    ) {
        self.port = port
        self.bindLoopbackOnly = loopbackOnly
        self.dispatcher = dispatcher
        self.commandReceiptMetrics = dispatcher.commandReceiptMetrics
        self.attachmentUploadV2Store = attachmentUploadV2Store
        self.attachmentUploadV3Store = attachmentUploadV3Store
        self.auth = auth
        self.serverId = serverId
        self.bootEpoch = bootEpoch
        self.receiveTimeoutSeconds = max(1, clientReceiveTimeoutSeconds)
        self.webSocketOutboundMaxQueuedBytes = max(1, webSocketOutboundMaxQueuedBytes)
    }

    public func start() throws {
        setListenerState(.publishing, attempt: 1)
        publishListenerStatus(
            state: .publishing,
            bound: false,
            attempt: 1,
            nextRetryMs: nil,
            errorCode: nil
        )

        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        if listenFD < 0 {
            markListenerFailed(errorCode: Int(errno))
            throw POSIXError(.EIO)
        }
        // Close-on-exec: forkpty terminal shells (and any other spawned child)
        // must not inherit the listener, or an orphaned child keeps port 18217
        // bound after the app stops and every rebind fails EADDRINUSE while
        // iOS connects hang in a backlog nobody accepts.
        guard Self.enableCloseOnExec(listenFD) else {
            let savedErrno = errno
            close(listenFD)
            listenFD = -1
            markListenerFailed(errorCode: Int(savedErrno))
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
            markListenerFailed(errorCode: Int(savedErrno))
            throw NSError(domain: "RC2.HTTP", code: Int(savedErrno), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        if Darwin.listen(listenFD, 32) < 0 {
            let savedErrno = errno
            close(listenFD); listenFD = -1
            markListenerFailed(errorCode: Int(savedErrno))
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }

        // Publish health/discovery as soon as IPv4 is accepting. Dual-stack
        // IPv6 is best-effort and must not delay loopback/LAN readiness.
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
        setListenerState(.published, attempt: 1)
        publishListenerStatus(
            state: .published,
            bound: true,
            attempt: 1,
            nextRetryMs: nil,
            errorCode: nil
        )

        // Dual-stack: optional IPv6 listener after IPv4 is already published.
        // Failure is non-fatal so IPv4 clients keep working.
        listenFD6 = Self.bindIPv6Listener(port: port, loopbackOnly: bindLoopbackOnly)
        if listenFD6 >= 0 {
            let v6 = listenFD6
            let t6 = Thread { [weak self] in
                self?.acceptLoop(
                    listenerDescriptor: v6,
                    acceptanceGeneration: acceptanceGeneration
                )
            }
            t6.name = "RC2.HTTPAccept6"
            t6.start()
            accept6 = t6
        }
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
        if listenFD6 >= 0 {
            shutdown(listenFD6, SHUT_RDWR)
            close(listenFD6)
            listenFD6 = -1
        }
        accept6 = nil
        setListenerState(.idle, attempt: 0)
    }

    /// Pure helper used by supervisors: next delay after `failureCount` failures,
    /// or nil when the bounded policy is exhausted (no infinite storm).
    public func nextListenerRetryDelayMs(afterFailureCount failureCount: Int) -> Int? {
        guard let delay = listenerRetryPolicy.delayAfterFailure(attemptIndex: failureCount) else {
            return nil
        }
        return Int((delay * 1000).rounded())
    }

    private func setListenerState(_ state: ListenerPublicationState, attempt: Int) {
        listenerStateLock.lock()
        _listenerPublicationState = state
        _listenerPublishAttempt = attempt
        listenerStateLock.unlock()
    }

    private func markListenerFailed(errorCode: Int) {
        let attempt: Int = {
            listenerStateLock.lock(); defer { listenerStateLock.unlock() }
            return max(1, _listenerPublishAttempt)
        }()
        let next = nextListenerRetryDelayMs(afterFailureCount: attempt - 1)
        setListenerState(.failed, attempt: attempt)
        publishListenerStatus(
            state: .failed,
            bound: false,
            attempt: attempt,
            nextRetryMs: next,
            errorCode: errorCode
        )
    }

    private func publishListenerStatus(
        state: ListenerPublicationState,
        bound: Bool,
        attempt: Int,
        nextRetryMs: Int?,
        errorCode: Int?
    ) {
        let address = bindLoopbackOnly ? "127.0.0.1" : "0.0.0.0"
        let raw = listenerPublicationStatusPayload(
            state: state,
            bound: bound,
            address: address,
            port: port,
            attempt: attempt,
            maxAttempts: listenerRetryPolicy.maxAttempts + 1,
            nextRetryMs: nextRetryMs,
            errorCode: errorCode
        )
        // Correlation id only — never tokens, raw peer content, or credentials.
        let correlationId = ConnectionTelemetryRedactor.makeCorrelationId()
        var payload = raw.mapValues { v -> JSONValue in
            if let b = v as? Bool { return .bool(b) }
            if let i = v as? Int { return .number(Double(i)) }
            if let s = v as? String { return .string(s) }
            return .string("\(v)")
        }
        payload["correlation_id"] = .string(correlationId)
        EventBus.shared.publish(kind: "server.listener.publication", payload: .object(payload))
    }

    /// Bind an IPv6 listener with `IPV6_V6ONLY` so IPv4-mapped accepts stay on
    /// the AF_INET socket. Returns -1 when IPv6 is unavailable (non-fatal).
    static func bindIPv6Listener(port: UInt16, loopbackOnly: Bool) -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        guard enableCloseOnExec(fd) else {
            close(fd)
            return -1
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Keep v6-only so dual listeners do not fight over IPv4-mapped traffic.
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr6 = sockaddr_in6()
        addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = in_port_t(port).bigEndian
        addr6.sin6_addr = loopbackOnly ? in6addr_loopback : in6addr_any
        let len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let rc = withUnsafePointer(to: &addr6) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        if rc < 0 {
            close(fd)
            return -1
        }
        if Darwin.listen(fd, 32) < 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private func acceptLoop(listenerDescriptor: Int32, acceptanceGeneration: UInt64) {
        let registry = acceptedSockets
        while registry.isAccepting(generation: acceptanceGeneration) {
            var storage = sockaddr_storage()
            var clen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let fd = withUnsafeMutablePointer(to: &storage) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenerDescriptor, $0, &clen)
                }
            }
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
                    "errno": .number(Double(savedErrno)),
                    "correlation_id": .string(ConnectionTelemetryRedactor.makeCorrelationId())
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
                        "maximum_connections": .number(Double(limit)),
                        "correlation_id": .string(ConnectionTelemetryRedactor.makeCorrelationId())
                    ]))
                }
                continue
            }
            let peer = Self.peerIP(storage)
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
    ///
    /// IPv6 link-local addresses keep their zone/scope suffix when the kernel
    /// provides `sin6_scope_id` (e.g. `fe80::1%en0`) so dual-stack / AWDL
    /// endpoints are not stripped to an unroutable bare address.
    static func peerIP(_ addr: sockaddr) -> String {
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { dst in
            withUnsafeBytes(of: addr) { src in
                let n = min(src.count, dst.count)
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: n))
            }
        }
        return peerIP(storage)
    }

    static func peerIP(_ storage: sockaddr_storage) -> String {
        var storage = storage
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let family = Int32(storage.ss_family)
        let len: socklen_t
        if storage.ss_len > 0 {
            len = socklen_t(storage.ss_len)
        } else if family == AF_INET6 {
            len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            len = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        let rc = withUnsafePointer(to: &storage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard rc == 0 else { return "unknown" }
        return String(cString: host)
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
        let parsedAttachmentUploadV2Route = Self.attachmentUploadV2Route(path: path)
        let attachmentUploadV2Route: AttachmentUploadV2HTTPRoute? = {
            switch (method, parsedAttachmentUploadV2Route) {
            case ("PUT", .chunk), ("GET", .upload), ("DELETE", .upload):
                return parsedAttachmentUploadV2Route
            default:
                return nil
            }
        }()
        let parsedAttachmentUploadV3Route = Self.attachmentUploadV3Route(
            path: path
        )
        let attachmentUploadV3Route: AttachmentUploadV3HTTPRoute? = {
            switch (method, parsedAttachmentUploadV3Route) {
            case ("POST", .prepare),
                 ("PUT", .chunk),
                 ("GET", .upload),
                 ("DELETE", .upload):
                return parsedAttachmentUploadV3Route
            default:
                return nil
            }
        }()
        var attachmentUploadOwnerFingerprint: String?
        var attachmentUploadV3OwnerFingerprint: String?
        var authorizedProtectedChunk: AttachmentUploadV3AuthorizedChunk?

        if let attachmentUploadV3Route {
            let uploadId = attachmentUploadV3Route.uploadId
            guard let v3Store = attachmentUploadV3Store else {
                sendAttachmentUploadV3Error(
                    fd: fd,
                    status: 404,
                    code: "attachment_upload_v3_unavailable",
                    message: "Protected attachment upload is unavailable.",
                    retryable: false,
                    uploadId: uploadId
                )
                return
            }
            switch attachmentUploadV3Route {
            case .chunk(_, let index):
                attachmentUploadV3OwnerFingerprint =
                    Self.attachmentUploadV3OwnerFingerprint(
                        token: presentedBearerToken,
                        auth: auth
                    )
                guard let attachmentUploadV3OwnerFingerprint else {
                    sendAttachmentUploadV3Error(
                        fd: fd,
                        status: 401,
                        code: "unauthorized",
                        message: "A valid bearer token is required.",
                        retryable: false,
                        uploadId: uploadId,
                        additionalHeaders: [
                            "WWW-Authenticate": wwwAuthenticateHeaderValue(
                                scheme: "Bearer",
                                realm: "RC2"
                            )
                        ]
                    )
                    return
                }
                // These fields carry raw host/key material in v2. Their
                // presence on a background request is a protocol violation;
                // bearer authorization remains mandatory for every chunk.
                let forbidden = [
                    "x-rc2-expected-host-id",
                    "x-rc2-workspace-id",
                    "x-rc2-filename-utf8-base64url",
                    "x-rc2-total-bytes",
                    "x-rc2-file-sha256",
                    "x-rc2-chunk-sha256",
                    "x-rc2-encryption-key",
                ]
                guard forbidden.allSatisfy({ headers[$0] == nil }),
                      headers["content-encoding"] == nil
                        || headers["content-encoding"]?
                            .lowercased() == "identity",
                      headers["content-type"]?
                        .split(separator: ";", maxSplits: 1)
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "application/octet-stream",
                      let capability =
                        headers["x-rc2-chunk-capability"],
                      let sealedSHA256 = headers["x-rc2-sealed-sha256"],
                      let sealedBytes =
                        Self.attachmentUploadV2PositiveInt(
                            headers["x-rc2-sealed-bytes"]
                        ),
                      let declaredContentLength =
                        Self.attachmentUploadV2PositiveInt(
                            headers["content-length"]
                        ),
                      sealedBytes == declaredContentLength,
                      sealedBytes
                        <= AttachmentUploadV3Policy
                            .maximumSealedChunkBytes,
                      let idempotencyKey = headers["idempotency-key"] else {
                    sendAttachmentUploadV3Error(
                        fd: fd,
                        status: 400,
                        code: "invalid_protected_chunk_headers",
                        message: "Protected chunk headers are invalid.",
                        retryable: false,
                        uploadId: uploadId
                    )
                    return
                }
                do {
                    authorizedProtectedChunk = try v3Store.authorizeChunk(
                        uploadId: uploadId,
                        chunkIndex: index,
                        capabilityBase64URL: capability,
                        sealedSHA256: sealedSHA256,
                        sealedBytes: sealedBytes,
                        idempotencyKey: idempotencyKey,
                        ownerIsActive: { owner in
                            owner == attachmentUploadV3OwnerFingerprint
                        }
                    )
                } catch {
                    let mapped = Self.attachmentUploadV3HTTPError(error)
                    sendAttachmentUploadV3Error(
                        fd: fd,
                        status: mapped.status,
                        code: mapped.code,
                        message: mapped.message,
                        retryable: mapped.retryable,
                        uploadId: uploadId
                    )
                    return
                }

            case .prepare, .upload:
                attachmentUploadV3OwnerFingerprint =
                    Self.attachmentUploadV3OwnerFingerprint(
                        token: presentedBearerToken,
                        auth: auth
                    )
                guard attachmentUploadV3OwnerFingerprint != nil else {
                    sendAttachmentUploadV3Error(
                        fd: fd,
                        status: 401,
                        code: "unauthorized",
                        message: "A valid bearer token is required.",
                        retryable: false,
                        uploadId: uploadId,
                        additionalHeaders: [
                            "WWW-Authenticate": wwwAuthenticateHeaderValue(
                                scheme: "Bearer",
                                realm: "RC2"
                            )
                        ]
                    )
                    return
                }
                // Bearer owner + matching Idempotency-Key only. Optional
                // X-RC2-Expected-Host-ID is never an HTTP authorization gate.
                guard let idempotencyKey = headers["idempotency-key"],
                      UUID(uuidString: idempotencyKey)
                        == UUID(uuidString: uploadId) else {
                    sendAttachmentUploadV3Error(
                        fd: fd,
                        status: 409,
                        code: "idempotency_key_mismatch",
                        message: "Idempotency-Key must match the upload id.",
                        retryable: false,
                        uploadId: uploadId
                    )
                    return
                }
            }
        }

        // Raw upload v2 is authenticated and host-pinned before reading the
        // request body. This prevents an unauthenticated LAN peer or stale host
        // endpoint from making the server buffer even one 512 KiB chunk.
        if let attachmentUploadV2Route,
           attachmentUploadV3Route == nil {
            let uploadId = attachmentUploadV2Route.uploadId
            guard attachmentUploadV2Store != nil else {
                sendAttachmentUploadV2Error(
                    fd: fd,
                    status: 404,
                    code: "attachment_upload_v2_unavailable",
                    message: "Attachment upload v2 is unavailable.",
                    retryable: false,
                    uploadId: uploadId,
                    acceptEncoding: headers["accept-encoding"]
                )
                return
            }
            let requiresToken = Self.httpAuthGateRequiresToken(
                loopbackOnly: bindLoopbackOnly,
                path: path,
                hasAuthProvider: auth != nil
            )
            attachmentUploadOwnerFingerprint =
                Self.attachmentUploadV2OwnerFingerprint(
                    token: presentedBearerToken,
                    auth: auth,
                    requiresToken: requiresToken
                )
            guard attachmentUploadOwnerFingerprint != nil else {
                sendAttachmentUploadV2Error(
                    fd: fd,
                    status: 401,
                    code: "unauthorized",
                    message: "A valid bearer token is required.",
                    retryable: false,
                    uploadId: uploadId,
                    acceptEncoding: headers["accept-encoding"],
                    additionalHeaders: [
                        "WWW-Authenticate": wwwAuthenticateHeaderValue(
                            scheme: "Bearer",
                            realm: "RC2"
                        )
                    ]
                )
                return
            }
            // Optional X-RC2-Expected-Host-ID is ignored: HTTP upload admission
            // is bearer owner + workspace/idempotency/size/digest only.
            guard let idempotencyKey = headers["idempotency-key"],
                  UUID(uuidString: idempotencyKey) == UUID(uuidString: uploadId) else {
                sendAttachmentUploadV2Error(
                    fd: fd,
                    status: 409,
                    code: "idempotency_key_mismatch",
                    message: "Idempotency-Key must match the upload id.",
                    retryable: false,
                    uploadId: uploadId,
                    acceptEncoding: headers["accept-encoding"]
                )
                return
            }
            guard let workspaceId = headers["x-rc2-workspace-id"],
                  UUID(uuidString: workspaceId) != nil else {
                sendAttachmentUploadV2Error(
                    fd: fd,
                    status: 400,
                    code: "invalid_workspace_id",
                    message: "X-RC2-Workspace-ID must be a UUID.",
                    retryable: false,
                    uploadId: uploadId,
                    acceptEncoding: headers["accept-encoding"]
                )
                return
            }
            let contentEncoding = headers["content-encoding"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard contentEncoding == nil || contentEncoding == "identity" else {
                sendAttachmentUploadV2Error(
                    fd: fd,
                    status: 400,
                    code: "unsupported_content_encoding",
                    message: "Attachment upload v2 accepts identity encoding only.",
                    retryable: false,
                    uploadId: uploadId,
                    acceptEncoding: headers["accept-encoding"]
                )
                return
            }
            if method == "PUT" {
                let contentType = headers["content-type"]?
                    .split(separator: ";", maxSplits: 1)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard contentType == "application/octet-stream" else {
                    sendAttachmentUploadV2Error(
                        fd: fd,
                        status: 400,
                        code: "unsupported_content_type",
                        message: "Attachment chunks must use application/octet-stream.",
                        retryable: false,
                        uploadId: uploadId,
                        acceptEncoding: headers["accept-encoding"]
                    )
                    return
                }
            }
        }

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
        var requestBearerVerified = false
        let largeBodyAuthorized: Bool
        if requestedAttachmentUpload,
           Self.httpAuthGateRequiresToken(
            loopbackOnly: bindLoopbackOnly,
            path: path,
            hasAuthProvider: auth != nil
        ), let auth {
            if let presentedBearerToken {
                largeBodyAuthorized = auth.verify(token: presentedBearerToken)
                requestBearerVerified = largeBodyAuthorized
            } else {
                largeBodyAuthorized = false
            }
        } else {
            largeBodyAuthorized = true
        }
        let requestBodyLimit: Int
        if let route = attachmentUploadV3Route {
            switch route {
            case .chunk:
                requestBodyLimit =
                    AttachmentUploadV3Policy.maximumSealedChunkBytes
            case .prepare:
                requestBodyLimit = AttachmentUploadV3Policy.maximumPrepareBytes
            case .upload:
                requestBodyLimit = 0
            }
        } else if attachmentUploadV2Route != nil {
            requestBodyLimit = AttachmentUploadV2Policy.rawChunkBytes
        } else if requestedAttachmentUpload && largeBodyAuthorized {
            requestBodyLimit = Self.maxAttachmentUploadRequestBodyBytes
        } else {
            requestBodyLimit = Self.maxRequestBodyBytes
        }
        guard contentLength <= requestBodyLimit else {
            if let route = attachmentUploadV3Route {
                sendAttachmentUploadV3Error(
                    fd: fd,
                    status: 413,
                    code: "protected_request_too_large",
                    message: "Protected upload request exceeds its fixed limit.",
                    retryable: false,
                    uploadId: route.uploadId
                )
            } else if let route = attachmentUploadV2Route {
                sendAttachmentUploadV2Error(
                    fd: fd,
                    status: 413,
                    code: "chunk_too_large",
                    message: "The raw chunk exceeds the fixed 512 KiB limit.",
                    retryable: false,
                    uploadId: route.uploadId,
                    acceptEncoding: headers["accept-encoding"]
                )
            } else {
                send(
                    fd: fd,
                    status: 413,
                    contentType: "text/plain",
                    body: Data("request body too large\n".utf8)
                )
            }
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
            let wsFilter = EventStreamFilter.parse(
                filterHeader: headers["x-rc2-ws-filter"],
                interestThreadHeader: headers["x-rc2-ws-interest-threads"]
            )
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
            let proposedCoalescingWindowMs = headers["x-rc2-ws-coalesce-window-ms"]
                .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            let coalescingWindowMs = Self.negotiateCoalescingWindowMs(
                filter: wsFilter,
                proposedMs: proposedCoalescingWindowMs
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
            let requestedResumeHost = headers["x-rc2-resume-host-id"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedResumeBootEpoch = headers["x-rc2-resume-boot-epoch"]
                .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            let wsSinceSeq = Self.acceptedResumeSequence(
                requestedSinceSequence: requestedSinceSequence,
                requestedResumeHost: requestedResumeHost,
                requestedResumeBootEpoch: requestedResumeBootEpoch,
                serverId: serverId,
                bootEpoch: Int64(bootEpoch),
                currentSequence: eventSnapshot.sequence
            )
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
                // Snapshot deltas and replay are advertised independently of
                // the event-only WebSocket transport.
                // stream.interest.v1 only when the host applies rc2.interest
                // (see welcomeCapabilities); old peers ignore unknown caps.
                capabilities: Self.welcomeCapabilities()
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
                },
                onApplicationQueueWaitRecorded: { [wsTracker] priority, waitMilliseconds in
                    // Secret-free process aggregates for /v1/health.connections.
                    wsTracker.recordOutboundQueueWait(
                        priority: priority,
                        waitMilliseconds: waitMilliseconds
                    )
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
            // METRICS: last per-connection queue sample for /v1/health gauges.
            // Process-scoped max/reject counters live on wsTracker; this only
            // keeps the live totalQueuedBytes contribution accurate.
            let queuedBytesSample = LockedQueuedBytesSample()
            let sampleOutboundQueuedBytes: @Sendable () -> Void = { [wsTracker] in
                let current = outbound.queuedByteCount
                let previous = queuedBytesSample.swap(current)
                wsTracker.updateQueuedBytes(previous: previous, current: current)
            }
            /// C-04 degrade ladder: never close on queueFull.
            let enqueueApplicationOrDegrade: @Sendable (Data) -> Void = { [wsTracker] data in
                // Transport-limit observability for 3G: frame size + queue depth
                // + rejected/evicted counts. Does not change enqueue policy.
                wsTracker.recordFrameBytes(data.count)
                switch outbound.enqueueApplication(data) {
                case .accepted:
                    recordAcceptedEvent(data)
                    sampleOutboundQueuedBytes()
                case .queueFull:
                    let outcome = outbound.degrade()
                    if outcome.freedFrames > 0 {
                        wsTracker.recordFramesRejectedOrEvicted(outcome.freedFrames)
                        sampleOutboundQueuedBytes()
                    }
                    if outcome.needsBaselineRequired {
                        emitPressureBaseline()
                    }
                    // Prefer shedding bulk/diagnostic arrivals over closing.
                    if WebSocketOutboundQueue.isSheddableApplicationFrame(data) {
                        if let sequence = WebSocketOutboundQueue.eventSequence(in: data) {
                            sequenceWatermark.recordFilteredEvent(sequence: sequence)
                        }
                        wsTracker.recordFramesRejectedOrEvicted(1)
                        emitPressureBaseline()
                        return
                    }
                    switch outbound.enqueueApplication(data) {
                    case .accepted:
                        recordAcceptedEvent(data)
                        sampleOutboundQueuedBytes()
                    case .queueFull:
                        // Still saturated after degrade: drop with filtered
                        // watermark accounting; socket stays open.
                        if let sequence = WebSocketOutboundQueue.eventSequence(in: data) {
                            sequenceWatermark.recordFilteredEvent(sequence: sequence)
                        }
                        wsTracker.recordFramesRejectedOrEvicted(1)
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
            // Same value negotiated from `X-RC2-WS-Coalesce-Window-Ms` (or
            // filter default / clamp) is what the batcher is configured with.
            webSocketCoalescingWindowObserverForTests?(coalescingWindowMs)
            let batcher = WebSocketEventBatcher(
                enabled: wsFilter.isCellularSafe,
                filter: wsFilter,
                delay: TimeInterval(coalescingWindowMs) / 1000.0,
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
                            // Still full after degrade: skip this tick; do not
                            // close a healthy socket solely for control backlog.
                            NSLog("[RC2.WS] outbound pressure class=queue_or_backpressure control=heartbeat_skip")
                            emitPressureBaseline()
                        }
                    case .closed:
                        break
                    }
                case .timedOut:
                    // Host-side heartbeat timeout (distinct from queue pressure).
                    NSLog("[RC2.WS] disconnect class=host_heartbeat_timeout")
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
                ownerFingerprint: webSocketOwnerFingerprint,
                subscriberIDBox: subIDBox,
                initialFilter: wsFilter
            )
            heartbeatTimer.cancel()
            batcher.stop()
            outbound.close()
            outbound.finish()
            // Remove this connection's last sampled contribution (not post-close
            // residual) so total_queued_bytes stays non-negative and accurate.
            wsTracker.clientDisconnected(queuedBytes: queuedBytesSample.value)
            return
        }

        if Self.staticFileHTTPMethods.contains(method),
           path.hasPrefix(DirectStaticFileRegistry.routePrefix) {
            guard let file = DirectStaticFileRegistry.shared.resolve(routePath: path) else {
                send(fd: fd, status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
                return
            }
            sendFile(
                fd: fd,
                contentType: file.contentType,
                url: file.url,
                rangeHeader: headers["range"],
                sendBody: method == "GET"
            )
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
        if attachmentUploadV2Route == nil,
           attachmentUploadV3Route == nil,
           Self.httpAuthGateRequiresToken(loopbackOnly: bindLoopbackOnly, path: path, hasAuthProvider: auth != nil),
           let auth = auth {
            if requestBearerVerified {
                // ok
            } else if let token = presentedBearerToken, auth.verify(token: token) {
                requestBearerVerified = true
            } else {
                var challengeHeaders = [
                    "WWW-Authenticate":
                        wwwAuthenticateHeaderValue(
                            scheme: "Bearer",
                            realm: "RC2"
                        ),
                ]
                if path == "/v1/capabilities/authenticated" {
                    challengeHeaders["Cache-Control"] = "no-store"
                }
                send(fd: fd, status: 401, contentType: "text/plain",
                     body: "unauthorized\n".data(using: .utf8)!,
                     additionalHeaders: challengeHeaders); return
            }
        }
        // Attachment Upload v2 binds durable jobs to a stable authorized
        // identity (when the auth provider can supply one) so a bearer
        // refresh for the same paired device resumes the same upload.
        // Other HTTP/WS owner paths keep the token-derived fingerprint.
        let requestOwnerFingerprint = Self.connectionOwnerFingerprint(
            token: presentedBearerToken
        )
        // POST body for pair endpoints; honor Content-Length read above.
        var bodyData = buffer.subdata(in: bodyStartAbsolute..<min(bodyStartAbsolute + contentLength, buffer.endIndex))
        if attachmentUploadV2Route == nil,
           attachmentUploadV3Route == nil,
           let contentEncoding = headers["content-encoding"],
           !contentEncoding.isEmpty {
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
        if let attachmentUploadV3Route {
            handleAttachmentUploadV3(
                fd: fd,
                method: method,
                route: attachmentUploadV3Route,
                headers: headers,
                bodyData: bodyData,
                ownerFingerprint: attachmentUploadV3OwnerFingerprint,
                authorizedChunk: authorizedProtectedChunk
            )
            if clientRequestsClose { return }
            buffer = leftoverBuffer
            continue
        }
        if let attachmentUploadV2Route {
            guard let attachmentUploadOwnerFingerprint else {
                sendAttachmentUploadV2Error(
                    fd: fd,
                    status: 401,
                    code: "unauthorized",
                    message: "A valid bearer token is required.",
                    retryable: false,
                    uploadId: attachmentUploadV2Route.uploadId,
                    acceptEncoding: headers["accept-encoding"]
                )
                return
            }
            handleAttachmentUploadV2(
                fd: fd,
                method: method,
                route: attachmentUploadV2Route,
                headers: headers,
                bodyData: bodyData,
                ownerFingerprint: attachmentUploadOwnerFingerprint
            )
            if clientRequestsClose { return }
            buffer = leftoverBuffer
            continue
        }

        switch (method, path) {
        case ("GET", "/healthz"):
            // Liveness only: independent of WebSocket sessions and snapshot work.
            send(fd: fd, status: 200, contentType: "text/plain", body: "ok\n".data(using: .utf8)!)
        case ("GET", "/v1/health"):
            // IMP-MAC_SERVER_SYNC-009: authenticated sync diagnostics so
            // power users / support can answer "why is sync slow". Gated by
            // the /v1 auth check above (not in the exempt list). Sourced from
            // EventBus health counters (no re-encode of retained events) plus
            // connection/phase aggregates. Independent of any live WebSocket.
            let events = EventBus.shared.healthCounters()
            let receiptMetrics = commandReceiptMetrics.snapshot()
            let phaseMetrics = requestPhaseMetrics.snapshot()
            let body: [String: Any] = [
                "status": "ok",
                "server_id": serverId,
                "server_time": Date().timeIntervalSince1970,
                "listener_state": listenerPublicationState.rawValue,
                "events": [
                    "last_seq": events.lastSeq,
                    "retained_count": events.retainedCount,
                    "retained_bytes": events.retainedBytes,
                    "oldest_retained_seq": events.oldestRetainedSeq
                ],
                "connections": connectionMetricsJSON(
                    activeClients: wsTracker.activeClients,
                    totalQueuedBytes: wsTracker.totalQueuedBytes,
                    slowClientDrops: wsTracker.slowClientDrops,
                    maxObservedOutboundQueuedBytes: wsTracker.maxObservedOutboundQueuedBytes,
                    maxObservedFrameBytes: wsTracker.maxObservedFrameBytes,
                    framesRejectedOrEvicted: wsTracker.framesRejectedOrEvicted,
                    outboundQueueWait: wsTracker.outboundQueueWaitMetrics
                ),
                "request_phases": Self.requestPhaseMetricsJSON(phaseMetrics),
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
            //
            // Disconnect mid-RPC: a watchdog cancels the work Task when the
            // accepted socket is closed so slow snapshots cannot keep CPU
            // after the peer is gone. HTTP remains independent of WS queues.
            handedOff = true
            let ae = headers["accept-encoding"]
            let registry = acceptedSockets
            let rpcLeftover = leftoverBuffer
            let rpcClientClose = clientRequestsClose
            // Scheduler admission only: bulk snapshot/replay runs at utility
            // priority so stop/input/control Tasks can preempt on the host.
            // Does not change wire fields, response routing, or method behavior.
            let rpcTaskPriority = RPCDispatchSchedulerClass.taskPriority(for: bodyData)
            let admitStarted = DispatchTime.now().uptimeNanoseconds
            Task(priority: rpcTaskPriority) { [weak self] in
                guard let self else {
                    registry.close(fd)
                    return
                }
                self.requestPhaseMetrics.record(
                    .admit,
                    latencyMilliseconds: HTTPRequestPhaseMetrics.elapsedMilliseconds(since: admitStarted)
                )
                let work = Task(priority: rpcTaskPriority) {
                    await self.dispatchRPC(
                        bodyData: bodyData,
                        ownerFingerprint: requestOwnerFingerprint
                    )
                }
                let watchdog = Task {
                    while !Task.isCancelled {
                        if !registry.isActive(fd) || !Self.isRPCPeerConnected(fd: fd) {
                            registry.close(fd)
                            work.cancel()
                            return
                        }
                        do {
                            try await Task.sleep(nanoseconds: 5_000_000)
                        } catch {
                            return
                        }
                    }
                }
                let respData = await work.value
                watchdog.cancel()
                _ = await watchdog.result
                guard registry.isActive(fd) else {
                    self.requestPhaseMetrics.recordCancelled()
                    registry.close(fd)
                    return
                }
                let writeStarted = DispatchTime.now().uptimeNanoseconds
                let wrote = self.send(
                    fd: fd,
                    status: 200,
                    contentType: "application/json",
                    body: respData,
                    acceptEncoding: ae
                )
                self.requestPhaseMetrics.record(
                    .responseWrite,
                    latencyMilliseconds: HTTPRequestPhaseMetrics.elapsedMilliseconds(since: writeStarted)
                )
                if !wrote {
                    self.requestPhaseMetrics.recordWriteAborted()
                    registry.close(fd)
                    return
                }
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
                // Dual-stack advertisement; clients may prefer v6 without a relay.
                "host_v6": bindLoopbackOnly ? "::1" : "::",
                "ipv6_listener": listenFD6 >= 0,
                "port": port,
                "boot_epoch": Int64(bootEpoch),
                "vpn_required": !bindLoopbackOnly,
                "relay": false,
                // Optional stream control negotiated on welcome, not here.
                "stream_interest_v1": Self.supportsStreamInterestControl,
                // Paired iOS cold connect: one-shot authenticated capabilities
                // + host/process identity (GET /v1/capabilities/authenticated).
                "authenticated_capabilities_v1": true,
                // IMP-MAC_SERVER_SYNC-001: anchor for client clock-drift /
                // freshness math. Pairs with the WS `heartbeat` frame (ts) so
                // the client can show an honest "live / last synced Ns ago".
                "server_time": Date().timeIntervalSince1970
            ]
            sendJSON(fd: fd, status: 200, body: body, acceptEncoding: headers["accept-encoding"])
        case ("GET", "/v1/capabilities"):
            // Public / pre-token surface (GAP-9). Unwrapped capabilities only —
            // never the authenticated identity envelope.
            sendJSON(
                fd: fd,
                status: 200,
                body: Self.capabilitiesPayload(
                    loopbackOnly: bindLoopbackOnly,
                    attachmentUpload:
                        dispatcher.agentAttachmentUploadCapability
                ),
                acceptEncoding: headers["accept-encoding"]
            )
        case ("GET", "/v1/capabilities/authenticated"):
            // Always require a verified bearer (including loopback-only). The
            // shared HTTP gate records that proof once. Requiring the recorded
            // proof here also fails closed if the provider is absent or the
            // gate ever regresses, without verifying the same token twice.
            guard requestBearerVerified else {
                send(fd: fd, status: 401, contentType: "text/plain",
                     body: "unauthorized\n".data(using: .utf8)!,
                     additionalHeaders: [
                        "WWW-Authenticate":
                            wwwAuthenticateHeaderValue(
                                scheme: "Bearer",
                                realm: "RC2"
                            ),
                        "Cache-Control": "no-store",
                     ])
                return
            }
            let body: [String: Any] = [
                "authenticated": true,
                "server_id": serverId,
                "boot_epoch": Int64(bootEpoch),
                "capabilities": Self.capabilitiesPayload(
                    loopbackOnly: bindLoopbackOnly,
                    attachmentUpload:
                        dispatcher.agentAttachmentUploadCapability
                )
            ]
            sendJSON(
                fd: fd,
                status: 200,
                body: body,
                acceptEncoding: headers["accept-encoding"],
                additionalHeaders: ["Cache-Control": "no-store"]
            )
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

    nonisolated static func requestPhaseMetricsJSON(
        _ metrics: HTTPRequestPhaseMetricsSnapshot
    ) -> [String: Any] {
        func lane(_ value: HTTPRequestPhaseLaneSnapshot) -> [String: Any] {
            [
                "count": value.count,
                "total": value.totalMilliseconds.isFinite ? max(0, value.totalMilliseconds) : 0,
                "max": value.maxMilliseconds.isFinite ? max(0, value.maxMilliseconds) : 0,
            ]
        }
        return [
            "admit_ms": lane(metrics.admit),
            "snapshot_read_ms": lane(metrics.snapshotRead),
            "snapshot_encode_ms": lane(metrics.snapshotEncode),
            "response_write_ms": lane(metrics.responseWrite),
            "cancelled_total": metrics.cancelledTotal,
            "timed_out_total": metrics.timedOutTotal,
            "fence_retry_total": metrics.fenceRetryTotal,
            "fence_exhausted_total": metrics.fenceExhaustedTotal,
            "write_aborted_total": metrics.writeAbortedTotal,
        ]
    }

    /// Non-consuming peer probe for the handed-off RPC socket. Registry state
    /// alone cannot observe a remote FIN while no request reader owns the fd.
    nonisolated static func isRPCPeerConnected(fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = withUnsafeMutableBytes(of: &byte) { buffer in
            Darwin.recv(fd, buffer.baseAddress, 1, MSG_PEEK | MSG_DONTWAIT)
        }
        if result > 0 { return true }
        if result == 0 { return false }
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
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
        await dispatchRPC(
            bodyData: bodyData,
            ownerFingerprint: ownerFingerprint,
            wireTransport: .http
        )
    }

    private func dispatchRPC(
        bodyData: Data,
        ownerFingerprint: String?,
        wireTransport: AgentCheckpointListContract.WireTransport
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
            // Checkpoint-specific admission only: reject explicit v1 items before
            // any sibling executes. No global item/byte caps (legacy batch shape).
            var seenIDs = Set<String>()
            for item in batch {
                guard let object = item as? [String: Any] else {
                    return rpcErrorData(.invalidRequest, id: NSNull())
                }
                if let method = object["method"] as? String {
                    let itemParams = object["params"] as? [String: Any]
                    do {
                        try AgentCheckpointListContract.preflightTransport(
                            method: method,
                            transport: wireTransport,
                            inBatch: true,
                            isExplicitV1: AgentCheckpointListContract.isExplicitV1(
                                params: itemParams
                            )
                        )
                    } catch let error as JSONRPCError {
                        return rpcErrorData(error, id: NSNull())
                    } catch {
                        return rpcErrorData(.invalidRequest, id: NSNull())
                    }
                }
                if let (_, key) = strictRPCID(object["id"], keyIsPresent: object.keys.contains("id")) {
                    guard seenIDs.insert(key).inserted else {
                        return rpcErrorData(.invalidRequest, id: NSNull())
                    }
                }
            }
            var responses: [[String: Any]] = []
            responses.reserveCapacity(batch.count)
            for item in batch {
                responses.append(await dispatchStrictRPCItem(
                    item,
                    ownerFingerprint: ownerFingerprint,
                    wireTransport: wireTransport
                ))
            }
            return rpcJSONData(responses)
        }

        // C-24: `sync.snapshot` is the largest payload. Encode the full JSON-RPC
        // envelope once with the wire `id` included — no Data→Any→Data cycle.
        // Chunk begin/chunk share bearer-owner admission with the full path
        // (no WS registry / host-boot / watermark prerequisites).
        if let object = root as? [String: Any],
           let method = object["method"] as? String {
            let phaseMetrics = wireTransport == .http ? requestPhaseMetrics : nil
            switch method {
            case "sync.snapshot":
                return await dispatchSyncSnapshotRPCData(
                    object,
                    ownerFingerprint: ownerFingerprint,
                    phaseMetrics: phaseMetrics
                )
            case "sync.snapshot.begin":
                return await dispatchSyncSnapshotBeginRPCData(
                    object,
                    ownerFingerprint: ownerFingerprint,
                    phaseMetrics: phaseMetrics
                )
            case "sync.snapshot.chunk":
                return await dispatchSyncSnapshotChunkRPCData(
                    object,
                    ownerFingerprint: ownerFingerprint
                )
            case "sync.snapshot.commit":
                return await dispatchSyncSnapshotCommitRPCData(
                    object,
                    ownerFingerprint: ownerFingerprint
                )
            default:
                break
            }
        }

        return rpcJSONData(await dispatchStrictRPCItem(
            root,
            ownerFingerprint: ownerFingerprint,
            wireTransport: wireTransport
        ))
    }

    private func dispatchStrictRPCItem(
        _ value: Any,
        ownerFingerprint: String,
        wireTransport: AgentCheckpointListContract.WireTransport = .http
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
        if method == AgentCheckpointListContract.method {
            // Explicit v1 transport gate before any repository work.
            // Legacy (no response_version) keeps prior Unix/WS/batch admission.
            let isV1 = AgentCheckpointListContract.isExplicitV1(params: rawParams)
            do {
                try AgentCheckpointListContract.preflightTransport(
                    method: method,
                    transport: wireTransport,
                    inBatch: false,
                    isExplicitV1: isV1
                )
            } catch let error as JSONRPCError {
                return rpcErrorObject(error, id: NSNull())
            } catch {
                return rpcErrorObject(.invalidRequest, id: NSNull())
            }
            if isV1,
               let stringID = wireID as? String,
               AgentTurnCheckpointWireIdentity.encodedJSONStringByteCount(stringID)
                    > JSONRPCDispatcher.checkpointListV1MaxEncodedResponseIDBytes {
                // The HTTP seam restores the exact wire id after dispatcher encoding.
                // Reject here so restoration cannot reintroduce a hostile id.
                return rpcErrorObject(.invalidRequest, id: NSNull())
            }
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
        if method == "sync.snapshot.begin" {
            guard let rawParams else {
                return rpcErrorObject(.invalidParams, id: wireID)
            }
            let data = await encodeSyncSnapshotBeginResponse(
                rawParams: rawParams,
                wireID: wireID,
                ownerFingerprint: ownerFingerprint
            )
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            return rpcErrorObject(.internalError, id: wireID)
        }
        if method == "sync.snapshot.chunk" {
            guard let rawParams else {
                return rpcErrorObject(.invalidParams, id: wireID)
            }
            let data = encodeSyncSnapshotChunkResponse(
                rawParams: rawParams,
                wireID: wireID,
                ownerFingerprint: ownerFingerprint
            )
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            return rpcErrorObject(.internalError, id: wireID)
        }
        if method == "sync.snapshot.commit" {
            guard let rawParams else {
                return rpcErrorObject(.invalidParams, id: wireID)
            }
            let data = encodeSyncSnapshotCommitResponse(
                rawParams: rawParams,
                wireID: wireID,
                ownerFingerprint: ownerFingerprint
            )
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            return rpcErrorObject(.internalError, id: wireID)
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
        // HTTP is independently authoritative: bearer owner only. Live/absent/
        // foreign WS registry identity is never a mutation precondition.
        let mutationContext = MutationRequestContext(
            ownerFingerprint: ownerFingerprint,
            hostId: serverId,
            bootEpoch: bootEpoch
        )
        let response: JSONRPCResponse
        switch wireTransport {
        case .http:
            response = await dispatcher.dispatchHTTP(
                request,
                mutationContext: mutationContext
            )
        case .unix:
            response = await dispatcher.dispatchUnixSocket(request)
        case .localTest:
            response = await dispatcher.dispatch(request, mutationContext: mutationContext)
        }
        guard let encoded = try? JSONEncoder().encode(response),
              var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            return rpcErrorObject(.internalError, id: wireID)
        }
        // Restore the exact wire id for finite responses. When the dispatcher
        // deliberately nulled the id (hostile id / envelope overflow), keep null.
        if response.id == nil {
            object["id"] = NSNull()
        } else {
            object["id"] = wireID
        }
        return object
    }

    /// C-24: single-encode `sync.snapshot` JSON-RPC success path.
    private func dispatchSyncSnapshotRPCData(
        _ object: [String: Any],
        ownerFingerprint: String,
        phaseMetrics: HTTPRequestPhaseMetrics?
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
            ownerFingerprint: ownerFingerprint,
            phaseMetrics: phaseMetrics
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
        ownerFingerprint: String,
        phaseMetrics: HTTPRequestPhaseMetrics? = nil
    ) async -> Data {
        // HTTP snapshot admission: bearer owner (caller) + schema only.
        // connectionId / expectedHostId / expectedBootEpoch may appear as
        // ignored legacy noise of any JSON type — never parsed, validated,
        // or used as WS-registry / host-boot / watermark preconditions.
        _ = ownerFingerprint
        let allowedKeys: Set<String> = [
            "connectionId", "expectedHostId", "expectedBootEpoch", "supportedStateVersion",
            "knownDomainRevisions",
        ]
        guard Set(rawParams.keys).isSubset(of: allowedKeys),
              rawParams.keys.contains("supportedStateVersion"),
              let supportedStateVersion = Self.strictInt64(rawParams["supportedStateVersion"]),
              supportedStateVersion == 3 else {
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

        do {
            let snapshot = try await dispatcher.readConnectionSnapshot(
                timeoutNanoseconds: snapshotReadTimeoutNanosecondsForTesting
                    ?? JSONRPCDispatcher.connectionSnapshotTimeoutNanoseconds,
                phaseMetrics: phaseMetrics
            )
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
            // Server response metadata only (host/boot + non-empty connectionId
            // required by transport frame decoding). HTTP does not bind to a
            // live WS connection and never echoes client identity fields.
            let frame = ConnectionSnapshotFrame(
                protocolVersion: ConnectionTransportFrame.protocolVersion,
                type: "snapshot",
                connectionId: UUID().uuidString,
                hostId: serverId,
                bootEpoch: bootEpoch,
                sequence: snapshot.metadata.sequence,
                snapshotId: UUID().uuidString,
                generatedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1_000),
                stateVersion: 3,
                state: state
            )
            // C-24: one JSONEncoder pass for the full RPC response (id + result).
            // Avoids the prior Data → Any → Data cycle on multi-hundred-KB snapshots.
            let envelope = SnapshotRPCSuccessEnvelope(
                id: SnapshotRPCWireID(wireID),
                result: frame
            )
            let encodeStarted = DispatchTime.now().uptimeNanoseconds
            let data = try JSONEncoder().encode(envelope)
            phaseMetrics?.record(
                .snapshotEncode,
                latencyMilliseconds: HTTPRequestPhaseMetrics.elapsedMilliseconds(since: encodeStarted)
            )
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

    // MARK: - Resumable snapshot chunks (`snapshot.chunks.v1`)

    private func dispatchSyncSnapshotBeginRPCData(
        _ object: [String: Any],
        ownerFingerprint: String,
        phaseMetrics: HTTPRequestPhaseMetrics?
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
        return await encodeSyncSnapshotBeginResponse(
            rawParams: rawParams,
            wireID: wireID,
            ownerFingerprint: ownerFingerprint,
            phaseMetrics: phaseMetrics
        )
    }

    private func dispatchSyncSnapshotChunkRPCData(
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
        return encodeSyncSnapshotChunkResponse(
            rawParams: rawParams,
            wireID: wireID,
            ownerFingerprint: ownerFingerprint
        )
    }

    /// Opt-in chunked baseline: bearer owner + schema only (no WS registry,
    /// host/boot client tuple, snapshot-owner, or watermark preconditions).
    /// Returns a secret-free manifest and caches bounded frame bytes for
    /// granular resume via `sync.snapshot.chunk`.
    private func encodeSyncSnapshotBeginResponse(
        rawParams: [String: Any],
        wireID: Any,
        ownerFingerprint: String,
        phaseMetrics: HTTPRequestPhaseMetrics? = nil
    ) async -> Data {
        // Legacy connectionId/expectedHostId/expectedBootEpoch may appear as
        // ignored noise of any JSON type — never parsed for auth or storage.
        let allowedKeys: Set<String> = [
            "connectionId", "expectedHostId", "expectedBootEpoch", "supportedStateVersion",
            "knownDomainRevisions", "preferredChunkBytes",
        ]
        guard Set(rawParams.keys).isSubset(of: allowedKeys),
              rawParams.keys.contains("supportedStateVersion"),
              let supportedStateVersion = Self.strictInt64(rawParams["supportedStateVersion"]),
              supportedStateVersion == 3 else {
            return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
        }

        let preferredChunkBytes: Int?
        if rawParams.keys.contains("preferredChunkBytes") {
            guard let value = Self.strictInt64(rawParams["preferredChunkBytes"]),
                  value > 0,
                  value <= Int64(SnapshotChunkSizePolicy.maximumBytes * 4) else {
                return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
            }
            preferredChunkBytes = Int(value)
        } else {
            preferredChunkBytes = nil
        }

        // Drop TTL-expired transfers so cache pressure stays deterministic.
        _ = snapshotChunkTransfers.evictExpired()

        let knownRevisions: ConnectionDomainRevisions?
        if rawParams.keys.contains("knownDomainRevisions") {
            guard let parsed = ConnectionDomainRevisions.parse(rawParams["knownDomainRevisions"]) else {
                return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
            }
            knownRevisions = parsed
        } else {
            knownRevisions = nil
        }

        do {
            let snapshot = try await dispatcher.readConnectionSnapshot(
                timeoutNanoseconds: snapshotReadTimeoutNanosecondsForTesting
                    ?? JSONRPCDispatcher.connectionSnapshotTimeoutNanoseconds,
                phaseMetrics: phaseMetrics
            )
            let hostRevisions = snapshot.metadata.domainRevisions
            let includeDomains: Set<String>?
            if let knownRevisions {
                let changed = hostRevisions.domainsChanged(since: knownRevisions)
                includeDomains = changed.isEmpty ? [] : changed
            } else {
                includeDomains = nil
            }
            let state = snapshot.state.jsonValue(
                domainRevisions: hostRevisions,
                includeDomains: includeDomains
            )
            // Server response metadata only; HTTP is not WS-connection-bound.
            // Non-empty connectionId satisfies transport-frame decoding only.
            let responseConnectionId = UUID().uuidString
            let frame = ConnectionSnapshotFrame(
                protocolVersion: ConnectionTransportFrame.protocolVersion,
                type: "snapshot",
                connectionId: responseConnectionId,
                hostId: serverId,
                bootEpoch: bootEpoch,
                sequence: snapshot.metadata.sequence,
                snapshotId: UUID().uuidString,
                generatedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1_000),
                stateVersion: 3,
                state: state
            )
            // Encode the authoritative frame once — chunks resume these bytes.
            let encodeStarted = DispatchTime.now().uptimeNanoseconds
            let frameBytes = try JSONEncoder().encode(frame)
            phaseMetrics?.record(
                .snapshotEncode,
                latencyMilliseconds: HTTPRequestPhaseMetrics.elapsedMilliseconds(since: encodeStarted)
            )
            guard frameBytes.count <= ConnectionTransportFrame.maximumEncodedBytes else {
                return rpcJSONData(rpcErrorObject(.internalError, id: wireID))
            }
            let inserted = try snapshotChunkTransfers.insert(
                frameBytes: frameBytes,
                ownerFingerprint: ownerFingerprint,
                connectionId: responseConnectionId,
                hostId: serverId,
                bootEpoch: bootEpoch,
                snapshotId: frame.snapshotId,
                sequence: frame.sequence,
                generatedAtEpochMs: frame.generatedAtEpochMs,
                stateVersion: frame.stateVersion,
                preferredChunkBytes: preferredChunkBytes
            )
            _ = inserted.releasedReservations
            return rpcJSONData([
                "jsonrpc": "2.0",
                "id": wireID,
                "result": inserted.record.manifest.jsonObject,
            ])
        } catch let error as SnapshotChunkTransferFailure {
            switch error {
            case .payloadTooLarge, .cachePressure:
                return rpcJSONData(rpcErrorObject(.internalError, id: wireID))
            default:
                return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
            }
        } catch let error as JSONRPCError {
            return rpcJSONData(rpcErrorObject(error, id: wireID))
        } catch {
            return rpcJSONData(rpcErrorObject(.internalError, id: wireID))
        }
    }

    private func dispatchSyncSnapshotCommitRPCData(
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
        return encodeSyncSnapshotCommitResponse(
            rawParams: rawParams,
            wireID: wireID,
            ownerFingerprint: ownerFingerprint
        )
    }

    /// Finalize a chunked transfer: bearer owner + transfer/request identifiers
    /// (transferId, snapshotId, digest). No WS watermark adopt prerequisite.
    private func encodeSyncSnapshotCommitResponse(
        rawParams: [String: Any],
        wireID: Any,
        ownerFingerprint: String
    ) -> Data {
        let allowedKeys: Set<String> = [
            "transferId", "snapshotId", "digest",
            "connectionId", "expectedHostId", "expectedBootEpoch",
        ]
        guard Set(rawParams.keys).isSubset(of: allowedKeys),
              rawParams.keys.contains("transferId"),
              rawParams.keys.contains("snapshotId"),
              rawParams.keys.contains("digest"),
              let transferId = rawParams["transferId"] as? String,
              !transferId.isEmpty,
              let snapshotId = rawParams["snapshotId"] as? String,
              !snapshotId.isEmpty,
              let digest = rawParams["digest"] as? String,
              digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else {
            return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
        }

        do {
            let record = try snapshotChunkTransfers.takeForCommit(
                transferId: transferId,
                snapshotId: snapshotId,
                digest: digest,
                ownerFingerprint: ownerFingerprint
            )
            return rpcJSONData([
                "jsonrpc": "2.0",
                "id": wireID,
                "result": [
                    "transferId": record.transferId,
                    "snapshotId": record.snapshotId,
                    "sequence": NSNumber(value: record.sequence),
                    "committed": true,
                ] as [String: Any],
            ])
        } catch let failure as SnapshotChunkTransferFailure {
            switch failure {
            case .transferExpired:
                return rpcJSONData(rpcErrorObject(JSONRPCError(
                    code: -32041,
                    message: "Snapshot chunk transfer expired or unknown; request a new baseline.",
                    data: .object(["reason": .string("transfer_expired")])
                ), id: wireID))
            case .transferUnknown:
                // Already committed (single-flight) or never existed.
                // Double-commit is fail-closed and non-advancing.
                return rpcJSONData(rpcErrorObject(JSONRPCError(
                    code: -32041,
                    message: "Snapshot chunk transfer expired or unknown; request a new baseline.",
                    data: .object(["reason": .string("transfer_unknown")])
                ), id: wireID))
            case .identityMismatch, .commitMismatch, .invalidParams, .chunkOutOfRange:
                return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
            case .payloadTooLarge, .cachePressure:
                return rpcJSONData(rpcErrorObject(.internalError, id: wireID))
            }
        } catch {
            return rpcJSONData(rpcErrorObject(.internalError, id: wireID))
        }
    }

    /// Serve one cached chunk. Auth is bearer owner + transferId; legacy
    /// connection/host/boot fields are optional and ignored. Never returns secrets.
    private func encodeSyncSnapshotChunkResponse(
        rawParams: [String: Any],
        wireID: Any,
        ownerFingerprint: String
    ) -> Data {
        let allowedKeys: Set<String> = [
            "transferId", "chunkIndex",
            "connectionId", "expectedHostId", "expectedBootEpoch",
        ]
        guard Set(rawParams.keys).isSubset(of: allowedKeys),
              rawParams.keys.contains("transferId"),
              rawParams.keys.contains("chunkIndex"),
              let transferId = rawParams["transferId"] as? String,
              !transferId.isEmpty,
              let chunkIndex = Self.strictInt64(rawParams["chunkIndex"]),
              chunkIndex >= 0,
              chunkIndex <= Int64(SnapshotChunkSizePolicy.maximumChunkCount) else {
            return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
        }

        do {
            let chunk = try snapshotChunkTransfers.fetchChunk(
                transferId: transferId,
                chunkIndex: Int(chunkIndex),
                ownerFingerprint: ownerFingerprint
            )
            return rpcJSONData([
                "jsonrpc": "2.0",
                "id": wireID,
                "result": chunk.jsonObject,
            ])
        } catch let failure as SnapshotChunkTransferFailure {
            switch failure {
            case .transferExpired:
                return rpcJSONData(rpcErrorObject(JSONRPCError(
                    code: -32041,
                    message: "Snapshot chunk transfer expired or unknown; request a new baseline.",
                    data: .object(["reason": .string("transfer_expired")])
                ), id: wireID))
            case .transferUnknown:
                return rpcJSONData(rpcErrorObject(JSONRPCError(
                    code: -32041,
                    message: "Snapshot chunk transfer expired or unknown; request a new baseline.",
                    data: .object(["reason": .string("transfer_unknown")])
                ), id: wireID))
            case .identityMismatch, .chunkOutOfRange, .invalidParams, .commitMismatch:
                return rpcJSONData(rpcErrorObject(.invalidParams, id: wireID))
            case .payloadTooLarge, .cachePressure:
                return rpcJSONData(rpcErrorObject(.internalError, id: wireID))
            }
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

    static func connectionOwnerFingerprint(token: String?) -> String {
        let material = Data("rc2.connection-owner.v1:\(token ?? "trusted-local")".utf8)
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Owner binding for Attachment Upload v2.
    ///
    /// When auth is required, `authorizedOwnerFingerprint` is both the
    /// validation and owner-resolution gate: a provider failure returns nil
    /// rather than silently creating a second token-scoped owner. Trusted
    /// loopback/no-auth requests retain the existing local fallback.
    static func attachmentUploadV2OwnerFingerprint(
        token: String?,
        auth: DirectAuthProvider?,
        requiresToken: Bool
    ) -> String? {
        if requiresToken {
            guard let auth, let token else { return nil }
            return auth.authorizedOwnerFingerprint(token: token)
        }
        return connectionOwnerFingerprint(token: token)
    }

    /// Protected-v3 control calls always derive their owner from a verified
    /// bearer when an auth provider exists, including loopback tests. The
    /// prepare body's owner field is only a consistency claim, never authority.
    static func attachmentUploadV3OwnerFingerprint(
        token: String?,
        auth: DirectAuthProvider?
    ) -> String? {
        if let auth {
            guard let token else { return nil }
            return auth.authorizedOwnerFingerprint(token: token)
        }
        return connectionOwnerFingerprint(token: token)
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

    private func handleAttachmentUploadV2(
        fd: Int32,
        method: String,
        route: AttachmentUploadV2HTTPRoute,
        headers: [String: String],
        bodyData: Data,
        ownerFingerprint: String
    ) {
        guard let store = attachmentUploadV2Store else {
            sendAttachmentUploadV2Error(
                fd: fd,
                status: 404,
                code: "attachment_upload_v2_unavailable",
                message: "Attachment upload v2 is unavailable.",
                retryable: false,
                uploadId: route.uploadId,
                acceptEncoding: headers["accept-encoding"]
            )
            return
        }

        do {
            guard let idempotencyKey = headers["idempotency-key"],
                  UUID(uuidString: idempotencyKey) == UUID(uuidString: route.uploadId) else {
                throw AttachmentUploadV2HTTPError(
                    status: 409,
                    code: "idempotency_key_mismatch",
                    message: "Idempotency-Key must match the upload id."
                )
            }
            guard let workspaceId = headers["x-rc2-workspace-id"],
                  UUID(uuidString: workspaceId) != nil else {
                throw AttachmentUploadV2HTTPError(
                    status: 400,
                    code: "invalid_workspace_id",
                    message: "X-RC2-Workspace-ID must be a UUID."
                )
            }
            let status: AttachmentUploadV2Status
            let responseStatus: Int
            switch (method, route) {
            case ("GET", .upload(let uploadId)):
                guard bodyData.isEmpty else {
                    throw AttachmentUploadV2HTTPError(
                        status: 400,
                        code: "unexpected_request_body",
                        message: "Upload status requests must not include a body."
                    )
                }
                status = try store.status(
                    ownerFingerprint: ownerFingerprint,
                    uploadId: uploadId,
                    workspaceId: workspaceId
                )
                responseStatus = 200

            case ("DELETE", .upload(let uploadId)):
                guard bodyData.isEmpty else {
                    throw AttachmentUploadV2HTTPError(
                        status: 400,
                        code: "unexpected_request_body",
                        message: "Upload cancellation requests must not include a body."
                    )
                }
                status = try store.cancel(
                    ownerFingerprint: ownerFingerprint,
                    uploadId: uploadId,
                    workspaceId: workspaceId
                )
                responseStatus = 200

            case ("PUT", .chunk(let uploadId, let index)):
                guard let encodedFilename = headers["x-rc2-filename-utf8-base64url"],
                      let filename = Self.attachmentUploadV2Filename(
                        base64URLValue: encodedFilename
                      ) else {
                    throw AttachmentUploadV2HTTPError(
                        status: 400,
                        code: "invalid_filename",
                        message: "The filename header is not valid UTF-8 base64url."
                    )
                }
                guard let totalBytes = Self.attachmentUploadV2PositiveInt(
                    headers["x-rc2-total-bytes"]
                ) else {
                    throw AttachmentUploadV2HTTPError(
                        status: 400,
                        code: "invalid_total_bytes",
                        message: "X-RC2-Total-Bytes must be a positive integer."
                    )
                }
                guard totalBytes <= AttachmentUploadV2Policy.maximumFileBytes else {
                    throw AttachmentUploadV2HTTPError(
                        status: 413,
                        code: "attachment_too_large",
                        message: "The attachment exceeds the 25 MiB limit."
                    )
                }
                guard let chunkBytes = Self.attachmentUploadV2PositiveInt(
                    headers["x-rc2-chunk-bytes"]
                ), chunkBytes == AttachmentUploadV2Policy.rawChunkBytes else {
                    throw AttachmentUploadV2HTTPError(
                        status: 400,
                        code: "invalid_chunk_size",
                        message: "X-RC2-Chunk-Bytes does not match the fixed protocol size."
                    )
                }
                let expectedChunkCount = AttachmentUploadV2Policy.chunkCount(
                    sizeBytes: totalBytes
                )
                guard let chunkCount = Self.attachmentUploadV2PositiveInt(
                    headers["x-rc2-chunk-count"]
                ), chunkCount == expectedChunkCount,
                   chunkCount <= AttachmentUploadV2Policy.maximumChunkCount else {
                    throw AttachmentUploadV2HTTPError(
                        status: 400,
                        code: "invalid_chunk_count",
                        message: "X-RC2-Chunk-Count does not match the declared file size."
                    )
                }
                guard let rawChunkBytes = Self.attachmentUploadV2PositiveInt(
                    headers["x-rc2-raw-chunk-bytes"]
                ), rawChunkBytes == bodyData.count else {
                    throw AttachmentUploadV2HTTPError(
                        status: 400,
                        code: "invalid_raw_chunk_size",
                        message: "X-RC2-Raw-Chunk-Bytes does not match the request body."
                    )
                }
                guard let fileSHA256 = headers["x-rc2-file-sha256"],
                      let chunkSHA256 = headers["x-rc2-chunk-sha256"] else {
                    throw AttachmentUploadV2HTTPError(
                        status: 400,
                        code: "missing_digest",
                        message: "Whole-file and chunk SHA-256 headers are required."
                    )
                }

                _ = try store.begin(
                    ownerFingerprint: ownerFingerprint,
                    uploadId: uploadId,
                    workspaceId: workspaceId,
                    filename: filename,
                    mimeType: headers["x-rc2-mime-type"],
                    sizeBytes: totalBytes,
                    sha256: fileSHA256
                )
                status = try store.putChunk(
                    ownerFingerprint: ownerFingerprint,
                    uploadId: uploadId,
                    chunkIndex: index,
                    data: bodyData,
                    sha256: chunkSHA256
                )
                if status.newlyCommitted {
                    responseStatus = 201
                } else if status.newlyAcceptedChunk {
                    responseStatus = 202
                } else {
                    responseStatus = 200
                }

            default:
                throw AttachmentUploadV2HTTPError(
                    status: 404,
                    code: "route_not_found",
                    message: "Attachment upload v2 route not found."
                )
            }

            if status.newlyCommitted, let result = status.result {
                EventBus.shared.publish(kind: "agent.attachment.uploaded", payload: .object([
                    "workspace_id": .string(status.workspaceId),
                    "id": .string(result.id),
                    "display_name": .string(result.displayName),
                    "sha256": .string(result.sha256),
                    "size_bytes": .number(Double(result.sizeBytes)),
                ]))
            }
            sendAttachmentUploadV2Status(
                fd: fd,
                httpStatus: responseStatus,
                status: status,
                acceptEncoding: headers["accept-encoding"]
            )
        } catch let error as AttachmentUploadV2HTTPError {
            sendAttachmentUploadV2Error(
                fd: fd,
                status: error.status,
                code: error.code,
                message: error.message,
                retryable: error.retryable,
                uploadId: route.uploadId,
                acceptEncoding: headers["accept-encoding"]
            )
        } catch let error as AttachmentUploadV2Error {
            let mapped = Self.attachmentUploadV2HTTPError(error)
            sendAttachmentUploadV2Error(
                fd: fd,
                status: mapped.status,
                code: mapped.code,
                message: mapped.message,
                retryable: mapped.retryable,
                uploadId: route.uploadId,
                acceptEncoding: headers["accept-encoding"]
            )
        } catch {
            sendAttachmentUploadV2Error(
                fd: fd,
                status: 500,
                code: "attachment_upload_storage_failure",
                message: "Attachment upload v2 failed.",
                retryable: true,
                uploadId: route.uploadId,
                acceptEncoding: headers["accept-encoding"]
            )
        }
    }

    private func handleAttachmentUploadV3(
        fd: Int32,
        method: String,
        route: AttachmentUploadV3HTTPRoute,
        headers: [String: String],
        bodyData: Data,
        ownerFingerprint: String?,
        authorizedChunk: AttachmentUploadV3AuthorizedChunk?
    ) {
        guard let store = attachmentUploadV3Store else {
            sendAttachmentUploadV3Error(
                fd: fd,
                status: 404,
                code: "attachment_upload_v3_unavailable",
                message: "Protected attachment upload is unavailable.",
                retryable: false,
                uploadId: route.uploadId
            )
            return
        }
        do {
            switch (method, route) {
            case ("POST", .prepare(let uploadId)):
                guard let ownerFingerprint else {
                    throw AttachmentUploadV3HTTPError(
                        status: 401,
                        code: "unauthorized",
                        message: "A valid bearer token is required."
                    )
                }
                let contentType = headers["content-type"]?
                    .split(separator: ";", maxSplits: 1)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard contentType == "application/json" else {
                    throw AttachmentUploadV3HTTPError(
                        status: 400,
                        code: "unsupported_content_type",
                        message: "Prepare requires application/json."
                    )
                }
                let prepare = try AttachmentUploadV3Store
                    .decodePrepareRequest(bodyData)
                // prepare.serverId is a client-declared crypto binding label
                // (AAD / HKDF salt), not a Mac host-identity gate.
                _ = try store.prepare(
                    uploadId: uploadId,
                    authorizedOwnerFingerprint: ownerFingerprint,
                    request: prepare
                )
                sendAttachmentUploadV3Prepare(
                    fd: fd,
                    uploadId: uploadId
                )

            case ("GET", .upload(let uploadId)),
                 ("DELETE", .upload(let uploadId)):
                guard bodyData.isEmpty,
                      let ownerFingerprint,
                      let workspaceId = headers["x-rc2-workspace-id"],
                      UUID(uuidString: workspaceId) != nil else {
                    throw AttachmentUploadV3HTTPError(
                        status: 400,
                        code: "invalid_control_request",
                        message: "Protected upload control request is invalid."
                    )
                }
                let status: AttachmentUploadV2Status
                if method == "GET" {
                    status = try store.status(
                        ownerFingerprint: ownerFingerprint,
                        uploadId: uploadId,
                        workspaceId: workspaceId
                    )
                } else {
                    status = try store.cancel(
                        ownerFingerprint: ownerFingerprint,
                        uploadId: uploadId,
                        workspaceId: workspaceId
                    )
                }
                sendAttachmentUploadV3Status(
                    fd: fd,
                    httpStatus: 200,
                    status: status
                )

            case ("PUT", .chunk):
                guard let authorizedChunk else {
                    throw AttachmentUploadV3HTTPError(
                        status: 403,
                        code: "chunk_capability_rejected",
                        message: "Protected chunk capability was rejected."
                    )
                }
                let status = try store.putProtectedChunk(
                    authorization: authorizedChunk,
                    sealedData: bodyData,
                    ownerIsActive: { [weak auth] owner in
                        auth?.isAuthorizedOwnerFingerprintActive(owner)
                            ?? false
                    }
                )
                if status.newlyCommitted, let result = status.result {
                    EventBus.shared.publish(
                        kind: "agent.attachment.uploaded",
                        payload: .object([
                            "workspace_id": .string(status.workspaceId),
                            "id": .string(result.id),
                            "display_name": .string(result.displayName),
                            "sha256": .string(result.sha256),
                            "size_bytes": .number(Double(result.sizeBytes)),
                        ])
                    )
                }
                // The iOS background callback is deliberately untrusted and
                // always confirms via authenticated GET. Avoid spending weak
                // cellular downlink on 50 redundant status envelopes.
                send(
                    fd: fd,
                    status: 204,
                    contentType: "application/json",
                    body: Data(),
                    additionalHeaders: [
                        "Cache-Control": "no-store",
                        "Content-Length": "0",
                    ]
                )

            default:
                throw AttachmentUploadV3HTTPError(
                    status: 404,
                    code: "route_not_found",
                    message: "Protected attachment upload route not found."
                )
            }
        } catch let error as AttachmentUploadV3HTTPError {
            sendAttachmentUploadV3Error(
                fd: fd,
                status: error.status,
                code: error.code,
                message: error.message,
                retryable: error.retryable,
                uploadId: route.uploadId
            )
        } catch let error as AttachmentUploadV3Error {
            let mapped = Self.attachmentUploadV3HTTPError(error)
            sendAttachmentUploadV3Error(
                fd: fd,
                status: mapped.status,
                code: mapped.code,
                message: mapped.message,
                retryable: mapped.retryable,
                uploadId: route.uploadId
            )
        } catch let error as AttachmentUploadV2Error {
            let mapped = Self.attachmentUploadV2HTTPError(error)
            sendAttachmentUploadV3Error(
                fd: fd,
                status: mapped.status,
                code: mapped.code,
                message: mapped.message,
                retryable: mapped.retryable,
                uploadId: route.uploadId
            )
        } catch {
            sendAttachmentUploadV3Error(
                fd: fd,
                status: 500,
                code: "attachment_upload_storage_failure",
                message: "Protected attachment upload failed.",
                retryable: true,
                uploadId: route.uploadId
            )
        }
    }

    private struct AttachmentUploadV3HTTPError: Error {
        let status: Int
        let code: String
        let message: String
        let retryable: Bool

        init(
            status: Int,
            code: String,
            message: String,
            retryable: Bool = false
        ) {
            self.status = status
            self.code = code
            self.message = message
            self.retryable = retryable
        }
    }

    nonisolated private static func attachmentUploadV3HTTPError(
        _ error: Error
    ) -> AttachmentUploadV3HTTPError {
        guard let error = error as? AttachmentUploadV3Error else {
            return .init(
                status: 500,
                code: "attachment_upload_storage_failure",
                message: "Protected attachment upload storage failed.",
                retryable: true
            )
        }
        switch error {
        case .invalidParams(let detail):
            return .init(
                status: 400,
                code: "invalid_protected_request",
                message: detail
            )
        case .uploadUnknown:
            return .init(
                status: 404,
                code: "upload_not_found",
                message: "Upload not found."
            )
        case .ownerInactive:
            return .init(
                status: 403,
                code: "upload_owner_revoked",
                message: "The paired device is no longer authorized."
            )
        case .capabilityRejected:
            return .init(
                status: 403,
                code: "chunk_capability_rejected",
                message: "Protected chunk capability was rejected."
            )
        case .metadataConflict:
            return .init(
                status: 409,
                code: "upload_metadata_conflict",
                message: "Protected upload metadata conflicts."
            )
        case .sealedChunkRejected(let detail):
            return .init(
                status: 422,
                code: "invalid_protected_chunk",
                message: detail
            )
        case .storageFailure:
            return .init(
                status: 500,
                code: "attachment_upload_storage_failure",
                message: "Protected attachment upload storage failed.",
                retryable: true
            )
        }
    }

    private func sendAttachmentUploadV3Prepare(
        fd: Int32,
        uploadId: String
    ) {
        let body: [String: Any] = [
            "protocol_version": AttachmentUploadV3Policy.protocolVersion,
            "content_encoding": AttachmentUploadV3Policy.contentEncoding,
            "server_id": serverId,
            "upload_id": uploadId,
            "prepared": true,
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )) ?? Data()
        send(
            fd: fd,
            status: 200,
            contentType: "application/json",
            body: data,
            additionalHeaders: ["Cache-Control": "no-store"]
        )
    }

    private func sendAttachmentUploadV3Status(
        fd: Int32,
        httpStatus: Int,
        status: AttachmentUploadV2Status
    ) {
        let result: Any
        if let value = status.result {
            result = [
                "id": value.id,
                "display_name": value.displayName,
                "kind": value.kind.rawValue,
                "mime_type": value.mimeType.map { $0 as Any } ?? NSNull(),
                "sha256": value.sha256,
                "size_bytes": value.sizeBytes,
                "composer_insertion_text": value.composerInsertionText,
            ] as [String: Any]
        } else {
            result = NSNull()
        }
        let body: [String: Any] = [
            "protocol_version": AttachmentUploadV3Policy.protocolVersion,
            "server_id": serverId,
            "upload_id": status.uploadId,
            "workspace_id": status.workspaceId,
            "state": status.phase.rawValue,
            "received_chunks": status.receivedChunkIndices,
            "received_bytes": status.receivedBytes,
            "total_bytes": status.sizeBytes,
            "result": result,
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )) ?? Data()
        send(
            fd: fd,
            status: httpStatus,
            contentType: "application/json",
            body: data,
            additionalHeaders: ["Cache-Control": "no-store"]
        )
    }

    private func sendAttachmentUploadV3Error(
        fd: Int32,
        status: Int,
        code: String,
        message: String,
        retryable: Bool,
        uploadId: String?,
        additionalHeaders: [String: String] = [:]
    ) {
        var body: [String: Any] = [
            "protocol_version": AttachmentUploadV3Policy.protocolVersion,
            "server_id": serverId,
            "error": [
                "code": code,
                "message": message,
                "retryable": retryable,
            ] as [String: Any],
        ]
        if let uploadId {
            body["upload_id"] = uploadId
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )) ?? Data()
        send(
            fd: fd,
            status: status,
            contentType: "application/json",
            body: data,
            additionalHeaders: additionalHeaders.merging(
                ["Cache-Control": "no-store"],
                uniquingKeysWith: { current, _ in current }
            )
        )
    }

    private struct AttachmentUploadV2HTTPError: Error {
        let status: Int
        let code: String
        let message: String
        let retryable: Bool

        init(
            status: Int,
            code: String,
            message: String,
            retryable: Bool = false
        ) {
            self.status = status
            self.code = code
            self.message = message
            self.retryable = retryable
        }
    }

    nonisolated private static func attachmentUploadV2HTTPError(
        _ error: AttachmentUploadV2Error
    ) -> AttachmentUploadV2HTTPError {
        switch error {
        case .invalidParams(let detail):
            return .init(status: 400, code: "invalid_request", message: detail)
        case .uploadUnknown, .ownerMismatch:
            return .init(status: 404, code: "upload_not_found", message: "Upload not found.")
        case .uploadCancelled:
            return .init(status: 410, code: "upload_cancelled", message: "Upload was cancelled.")
        case .metadataConflict:
            return .init(
                status: 409,
                code: "upload_metadata_conflict",
                message: "Upload metadata conflicts with the durable upload."
            )
        case .chunkDigestConflict:
            return .init(
                status: 409,
                code: "chunk_conflict",
                message: "The chunk conflicts with a previously accepted chunk."
            )
        case .chunkValidationFailed(let detail):
            return .init(status: 422, code: "invalid_chunk", message: detail)
        case .fileDigestMismatch:
            return .init(
                status: 422,
                code: "file_digest_mismatch",
                message: "The assembled file SHA-256 does not match."
            )
        case .activeJobLimitExceeded, .reservedBytesExceeded:
            return .init(
                status: 409,
                code: "upload_capacity_exceeded",
                message: "The durable upload capacity is temporarily full.",
                retryable: true
            )
        case .storageFailure:
            return .init(
                status: 500,
                code: "attachment_upload_storage_failure",
                message: "Attachment upload storage failed.",
                retryable: true
            )
        }
    }

    nonisolated static func attachmentUploadV2Filename(
        base64URLValue: String
    ) -> String? {
        guard !base64URLValue.isEmpty,
              base64URLValue.utf8.allSatisfy({
                  (65...90).contains($0)
                      || (97...122).contains($0)
                      || (48...57).contains($0)
                      || $0 == 45
                      || $0 == 95
              }) else {
            return nil
        }
        var base64 = base64URLValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              let filename = String(data: data, encoding: .utf8) else {
            return nil
        }
        return filename
    }

    nonisolated private static func attachmentUploadV2PositiveInt(
        _ raw: String?
    ) -> Int? {
        guard let raw,
              !raw.isEmpty,
              raw.allSatisfy(\.isNumber),
              let value = Int(raw),
              value > 0 else {
            return nil
        }
        return value
    }

    private func sendAttachmentUploadV2Status(
        fd: Int32,
        httpStatus: Int,
        status: AttachmentUploadV2Status,
        acceptEncoding: String?
    ) {
        let result: Any
        if let value = status.result {
            result = [
                "id": value.id,
                "display_name": value.displayName,
                "kind": value.kind.rawValue,
                "mime_type": value.mimeType.map { $0 as Any } ?? NSNull(),
                "sha256": value.sha256,
                "size_bytes": value.sizeBytes,
                "composer_insertion_text": value.composerInsertionText,
            ] as [String: Any]
        } else {
            result = NSNull()
        }
        let body: [String: Any] = [
            "protocol_version": status.protocolVersion,
            "server_id": serverId,
            "upload_id": status.uploadId,
            "workspace_id": status.workspaceId,
            "state": status.phase.rawValue,
            "received_chunks": status.receivedChunkIndices,
            "received_bytes": status.receivedBytes,
            "total_bytes": status.sizeBytes,
            "result": result,
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )) ?? Data()
        send(
            fd: fd,
            status: httpStatus,
            contentType: "application/json",
            body: data,
            acceptEncoding: acceptEncoding,
            additionalHeaders: ["Cache-Control": "no-store"]
        )
    }

    private func sendAttachmentUploadV2Error(
        fd: Int32,
        status: Int,
        code: String,
        message: String,
        retryable: Bool,
        uploadId: String?,
        acceptEncoding: String?,
        additionalHeaders: [String: String] = [:]
    ) {
        var body: [String: Any] = [
            "protocol_version": AttachmentUploadV2Policy.protocolVersion,
            "server_id": serverId,
            "error": [
                "code": code,
                "message": message,
                "retryable": retryable,
            ] as [String: Any],
        ]
        if let uploadId {
            body["upload_id"] = uploadId
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )) ?? Data()
        var responseHeaders = additionalHeaders
        responseHeaders["Cache-Control"] = "no-store"
        send(
            fd: fd,
            status: status,
            contentType: "application/json",
            body: data,
            acceptEncoding: acceptEncoding,
            additionalHeaders: responseHeaders
        )
    }

    @discardableResult
    private func send(fd: Int32, status: Int, contentType: String, body: Data, acceptEncoding: String? = nil, additionalHeaders: [String: String] = [:]) -> Bool {
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
        guard writeAll(fd: fd, data: Data(head.utf8)) else { return false }
        if !responseBody.isEmpty {
            return writeAll(fd: fd, data: responseBody)
        }
        return true
    }

    enum StaticFileByteRange: Equatable {
        case full
        case partial(start: UInt64, end: UInt64)
        case unsatisfiable
    }

    nonisolated static func staticFileByteRange(
        header: String?,
        fileSize: UInt64
    ) -> StaticFileByteRange {
        guard let header else { return .full }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("bytes="),
              !trimmed.contains(","),
              fileSize > 0
        else { return .unsatisfiable }

        let value = trimmed.dropFirst("bytes=".count)
        let components = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return .unsatisfiable }

        if components[0].isEmpty {
            guard let suffixLength = UInt64(components[1]), suffixLength > 0 else {
                return .unsatisfiable
            }
            let length = min(suffixLength, fileSize)
            return .partial(start: fileSize - length, end: fileSize - 1)
        }

        guard let start = UInt64(components[0]), start < fileSize else {
            return .unsatisfiable
        }
        let end: UInt64
        if components[1].isEmpty {
            end = fileSize - 1
        } else {
            guard let requestedEnd = UInt64(components[1]), requestedEnd >= start else {
                return .unsatisfiable
            }
            end = min(requestedEnd, fileSize - 1)
        }
        return .partial(start: start, end: end)
    }

    private func sendFile(
        fd: Int32,
        contentType: String,
        url: URL,
        rangeHeader: String?,
        sendBody: Bool
    ) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            send(fd: fd, status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
            return
        }
        let status: Int
        let offset: UInt64
        let responseSize: UInt64
        var rangeHeaders = "Accept-Ranges: bytes\r\n"
        switch Self.staticFileByteRange(header: rangeHeader, fileSize: size) {
        case .full:
            status = 200
            offset = 0
            responseSize = size
        case .partial(let start, let end):
            status = 206
            offset = start
            responseSize = end - start + 1
            rangeHeaders += "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        case .unsatisfiable:
            send(
                fd: fd,
                status: 416,
                contentType: "text/plain",
                body: Data(),
                additionalHeaders: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes */\(size)"
                ]
            )
            return
        }
        let handle: FileHandle?
        if sendBody {
            guard let opened = try? FileHandle(forReadingFrom: url) else {
                send(fd: fd, status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
                return
            }
            if offset > 0 {
                do {
                    try opened.seek(toOffset: offset)
                } catch {
                    try? opened.close()
                    send(fd: fd, status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
                    return
                }
            }
            handle = opened
        } else {
            // HEAD intentionally does not open, seek, or read the granted file.
            handle = nil
        }
        defer { try? handle?.close() }
        let head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\nContent-Type: \(contentType)\r\n\(rangeHeaders)Content-Length: \(responseSize)\r\nConnection: keep-alive\r\nKeep-Alive: timeout=\(receiveTimeoutSeconds)\r\n\r\n"
        guard writeAll(fd: fd, data: Data(head.utf8)) else { return }
        guard let handle else { return }
        var remaining = responseSize
        while remaining > 0 {
            let readCount = Int(min(remaining, UInt64(64 * 1024)))
            guard let chunk = try? handle.read(upToCount: readCount), !chunk.isEmpty else { return }
            guard writeAll(fd: fd, data: chunk) else { return }
            remaining -= UInt64(chunk.count)
        }
    }

    private func sendJSON(
        fd: Int32,
        status: Int,
        body: [String: Any],
        acceptEncoding: String? = nil,
        additionalHeaders: [String: String] = [:]
    ) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        send(
            fd: fd,
            status: status,
            contentType: "application/json",
            body: data,
            acceptEncoding: acceptEncoding,
            additionalHeaders: additionalHeaders
        )
    }

    private func reasonPhrase(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
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
        ownerFingerprint: String,
        subscriberIDBox: LockedSubscriberID? = nil,
        initialFilter: EventStreamFilter = .full
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
        var liveFilter = initialFilter
        // RFC6455 reassembly lives in WebSocketClientFrameAssembler (FIN/
        // continuation, interleaved control, 1 MiB aggregate, UTF-8).
        var assembler = WebSocketClientFrameAssembler()
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
            parseFrames: while offset < buf.count {
                let (event, consumed) = assembler.consume(buf: buf, from: offset)
                switch event {
                case .needMore:
                    break parseFrames
                case .fragmentProgress:
                    offset += consumed
                    continue
                case .peerClose:
                    offset += consumed
                    _ = outbound.terminate(errorData: nil, closingData: nil, reason: "peerClose")
                    return
                case .mustClose(let closeCode):
                    offset += consumed
                    _ = outbound.terminate(
                        errorData: nil,
                        closingData: connectionClosingData(
                            connectionId: connectionId,
                            reason: "protocolError",
                            code: Int(closeCode),
                            retryable: false,
                            retryAfterMs: nil
                        ),
                        reason: "protocolError"
                    )
                    return
                case .ping(let payload):
                    offset += consumed
                    // Assembler already rejects control payloads > 125 / fragmented
                    // control with mustClose(1002); keep defensive cap for safety.
                    guard payload.count <= 125 else {
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
                    _ = outbound.enqueueControl(opcode: 0xA, data: payload)
                case .pong(let payload):
                    offset += consumed
                    _ = liveness.acceptPong(
                        payload,
                        now: Date().timeIntervalSinceReferenceDate
                    )
                    continue
                case .text(let payload):
                    offset += consumed
                    // Mid-session interest: update cellular-safe admission without
                    // tearing down the socket. Unknown to older clients; ignored
                    // when filter is full (fail open).
                    if let interestIds = EventStreamFilter.parseInterestControl(payload) {
                        liveFilter = liveFilter.applyingInterestThreadIds(interestIds)
                        if let subId = subscriberIDBox?.value {
                            EventBus.shared.updateSubscriberFilter(subId, filter: liveFilter)
                        }
                        continue
                    }
                    let code: String
                    do {
                        _ = try ConnectionTransportFrame.decodeStrict(payload)
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
                case .binary:
                    offset += consumed
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
    /// Kept for unit tests; the live path uses `WebSocketClientFrameAssembler`.
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

// MARK: - RPC dispatch Task scheduler admission

/// Host-side scheduler admission class for JSON-RPC `dispatchRPC` Tasks.
///
/// Pure, secret-free classification of the **encoded request body only**.
/// Used solely to choose a Swift `TaskPriority` when launching HTTP `/v1/rpc`
/// and WebSocket JSON-RPC handlers — does **not** change wire fields, response
/// routing, outbound queue lanes, authentication, or method behavior.
///
/// Conservative default is interactive: any malformed body, mutation,
/// stop/input/control, or mixed batch must not run at bulk/utility priority.
public enum RPCDispatchSchedulerClass: String, Sendable, Equatable {
    /// Read-only bulk snapshot / replay work. Maps to `TaskPriority.utility`.
    case bulk
    /// Stop/input/control, mutations, mixed batches, unknown methods, malformed.
    /// Maps to `TaskPriority.userInitiated`.
    case interactive

    /// Exact read-only bulk methods eligible for lower scheduler priority.
    /// Intentionally narrow: only known large snapshot/replay surfaces.
    public static let bulkMethods: Set<String> = [
        "sync.snapshot",
        "sync.snapshot.begin",
        "sync.snapshot.chunk",
        "sync.snapshot.commit",
        "events.recent",
    ]

    /// Pure classifier for an encoded JSON-RPC request body (single or batch).
    ///
    /// - Bulk: single call whose `method` is in `bulkMethods`, or a non-empty
    ///   batch where **every** item is bulk (snapshot-only batches).
    /// - Interactive: malformed JSON, empty batch, non-object items, missing
    ///   method, any non-bulk method (mutations, stop/input/control, etc.),
    ///   or a mixed batch containing any interactive item.
    public static func classify(bodyData: Data) -> RPCDispatchSchedulerClass {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: bodyData, options: [.fragmentsAllowed])
        } catch {
            return .interactive
        }

        if let batch = root as? [Any] {
            // Empty batch is invalid request shape → treat conservatively.
            guard !batch.isEmpty else { return .interactive }
            for item in batch {
                guard isBulkRequestObject(item) else { return .interactive }
            }
            return .bulk
        }

        if isBulkRequestObject(root) {
            return .bulk
        }
        return .interactive
    }

    /// Swift Task priority for a classified body. Bulk → utility (lower);
    /// interactive → userInitiated (higher). No semaphores or thread parking.
    public static func taskPriority(for bodyData: Data) -> TaskPriority {
        switch classify(bodyData: bodyData) {
        case .bulk: return .utility
        case .interactive: return .userInitiated
        }
    }

    /// Task priority for an already-classified admission class.
    public var taskPriority: TaskPriority {
        switch self {
        case .bulk: return .utility
        case .interactive: return .userInitiated
        }
    }

    /// True when `value` is a JSON-RPC request object whose `method` is bulk.
    private static func isBulkRequestObject(_ value: Any) -> Bool {
        guard let object = value as? [String: Any],
              let method = object["method"] as? String else {
            return false
        }
        return bulkMethods.contains(method)
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
