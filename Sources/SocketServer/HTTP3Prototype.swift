import Foundation
import Network

// MARK: - HTTP/3 (QUIC) evaluation seam
//
// Evaluation seam only. This module does **not** claim HTTP/3 interoperability,
// production readiness, or performance characteristics.
//
// Isolation rules (Phase 5 open item — intentionally incomplete):
// - Opt-in and **disabled by default**. Production HTTP remains the reliable
//   transport; WebSocket remains the realtime path. Nothing here is wired into
//   DirectHTTPServer, UnixSocketServer, or automatic transport fallback.
// - Validates configuration and can construct `NWProtocolQUIC.Options` when
//   Network.framework QUIC is available (macOS 14+). It never opens a connection,
//   never bypasses certificate validation, and never handles bearer tokens.
// - Callers that experiment with this seam own any future connection lifecycle;
//   shipping paths must not depend on this type.

/// Explicit opt-in configuration for the QUIC/HTTP-3 prototype seam.
///
/// Defaults keep the feature off. `requireTLS` must stay `true` — QUIC is TLS-bound
/// and this seam refuses cleartext configurations rather than inventing a bypass.
public struct HTTP3PrototypeConfiguration: Sendable, Equatable {
    /// When `false` (default), assessment reports `.disabled` and no options are built.
    public var enabled: Bool
    /// Peer host (hostname or IP). Validated for non-empty, trimmed content only.
    public var host: String
    /// UDP port for QUIC. Must be non-zero when enabled.
    public var port: UInt16
    /// Must be `true` for a successful assessment. Explicit so callers cannot
    /// accidentally request cleartext QUIC.
    public var requireTLS: Bool

    /// Canonical off state used by production settings and tests.
    public static let disabled = HTTP3PrototypeConfiguration(
        enabled: false,
        host: "127.0.0.1",
        port: 443,
        requireTLS: true
    )

    public init(
        enabled: Bool = false,
        host: String = "127.0.0.1",
        port: UInt16 = 443,
        requireTLS: Bool = true
    ) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.requireTLS = requireTLS
    }
}

/// Deterministic outcome of validating an `HTTP3PrototypeConfiguration`.
///
/// Does not imply a live peer, ALPN negotiation success, or HTTP/3 framing support.
public enum HTTP3PrototypeAssessment: Sendable, Equatable {
    /// Opt-in flag is false (the default).
    case disabled
    /// Host/port failed local validation.
    case invalidEndpoint(reason: String)
    /// Configuration requested QUIC without TLS; refused.
    case tlsRequired
    /// Network.framework QUIC options are not available on this OS.
    case unsupported
    /// Configuration is valid and options may be constructed without connecting.
    case configured(host: String, port: UInt16)
}

/// Failure surface when building protocol options (mirrors assessment, no connection).
public enum HTTP3PrototypeFailure: Error, Sendable, Equatable {
    case disabled
    case invalidEndpoint(reason: String)
    case tlsRequired
    case unsupported
}

/// Stable reason codes explaining why the seam keeps the production HTTP/WebSocket path.
///
/// Inspectable by tests and diagnostics. These are **not** wire schema values and
/// do not change listeners or transport selection in `DirectHTTPServer`.
public enum HTTP3PrototypeFallbackReason: String, Sendable, Equatable, CaseIterable {
    /// Opt-in is false — default-off deployment posture.
    case defaultOff = "default_off"
    /// Host/port failed local validation.
    case invalidEndpoint = "invalid_endpoint"
    /// QUIC is TLS-bound; cleartext configuration was refused.
    case tlsRequired = "tls_required"
    /// Network.framework QUIC options unavailable on this OS (compatibility gate).
    case unsupportedOS = "unsupported_os"

    /// Human-readable explanation for logs and assertion messages.
    public var reasonDescription: String {
        switch self {
        case .defaultOff:
            return "HTTP/3 prototype is disabled by default; keep HTTP+WebSocket"
        case .invalidEndpoint:
            return "invalid host/port; keep HTTP+WebSocket fallback"
        case .tlsRequired:
            return "QUIC requires TLS; keep HTTP+WebSocket fallback"
        case .unsupportedOS:
            return "QUIC options unavailable on this OS; keep HTTP+WebSocket fallback"
        }
    }
}

/// Deployment disposition for the default-off HTTP/3 prototype seam.
///
/// Pure selection result: maps configuration assessment to the path callers
/// should honor. Never opens sockets, never wires QUIC into production listeners,
/// never selects QUIC in `DirectHTTPServer`, and never handles bearer tokens.
public enum HTTP3PrototypeDisposition: Sendable, Equatable {
    /// Retain production HTTP (reliable) + WebSocket (realtime) as the functional path.
    case httpWebSocketFallback(reason: HTTP3PrototypeFallbackReason)
    /// Configuration is prototype-ready for offline evaluation only.
    /// Does **not** authorize production transport selection or live connections.
    case prototypeReady(host: String, port: UInt16)

    /// `true` when the production HTTP+WebSocket path remains the selected fallback.
    public var usesHTTPWebSocketFallback: Bool {
        switch self {
        case .httpWebSocketFallback:
            return true
        case .prototypeReady:
            return false
        }
    }

    /// Stable inspectable reason string for diagnostics and tests.
    public var reasonCode: String {
        switch self {
        case .httpWebSocketFallback(let reason):
            return reason.rawValue
        case .prototypeReady:
            return "prototype_ready"
        }
    }
}

/// Public SocketServer entry point for the Phase 5 QUIC/HTTP-3 prototype seam.
public enum HTTP3Prototype {
    /// ALPN token used when constructing prototype options (`h3` per RFC 9114).
    /// Selection here is configuration only — not an interoperability claim.
    public static let prototypeALPN = "h3"

    /// `true` when `NWProtocolQUIC.Options` can be created on this process (macOS 14+).
    public static var isQUICOptionsAvailable: Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        return false
    }

    /// Validate host/port, opt-in flag, and explicit TLS requirement.
    /// Pure and deterministic for a given configuration and OS availability.
    public static func assess(_ configuration: HTTP3PrototypeConfiguration) -> HTTP3PrototypeAssessment {
        guard configuration.enabled else {
            return .disabled
        }
        guard configuration.requireTLS else {
            return .tlsRequired
        }
        if let reason = endpointValidationFailure(host: configuration.host, port: configuration.port) {
            return .invalidEndpoint(reason: reason)
        }
        guard isQUICOptionsAvailable else {
            return .unsupported
        }
        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return .configured(host: host, port: configuration.port)
    }

    /// Map a configuration assessment to the deployment disposition.
    ///
    /// Pure and side-effect free: no sockets, no `NWProtocolQUIC.Options` construction,
    /// no listener changes. Disabled / invalid / TLS-refused / unsupported-OS all
    /// select the reliable HTTP+WebSocket fallback. `.configured` maps only to
    /// `.prototypeReady` (evaluation seam — not production transport selection).
    public static func disposition(
        from assessment: HTTP3PrototypeAssessment
    ) -> HTTP3PrototypeDisposition {
        switch assessment {
        case .disabled:
            return .httpWebSocketFallback(reason: .defaultOff)
        case .invalidEndpoint:
            return .httpWebSocketFallback(reason: .invalidEndpoint)
        case .tlsRequired:
            return .httpWebSocketFallback(reason: .tlsRequired)
        case .unsupported:
            return .httpWebSocketFallback(reason: .unsupportedOS)
        case .configured(let host, let port):
            return .prototypeReady(host: host, port: port)
        }
    }

    /// Assess configuration then map to deployment disposition (pure).
    public static func disposition(
        for configuration: HTTP3PrototypeConfiguration
    ) -> HTTP3PrototypeDisposition {
        disposition(from: assess(configuration))
    }

    /// Create and lightly configure `NWProtocolQUIC.Options` when assessment is
    /// `.configured`. Never opens a socket or starts a handshake.
    public static func makeProtocolOptions(
        for configuration: HTTP3PrototypeConfiguration
    ) -> Result<NWProtocolQUIC.Options, HTTP3PrototypeFailure> {
        switch assess(configuration) {
        case .disabled:
            return .failure(.disabled)
        case .invalidEndpoint(let reason):
            return .failure(.invalidEndpoint(reason: reason))
        case .tlsRequired:
            return .failure(.tlsRequired)
        case .unsupported:
            return .failure(.unsupported)
        case .configured:
            return .success(makeQUICOptions())
        }
    }

    // MARK: - Private

    private static func endpointValidationFailure(host: String, port: UInt16) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "host must be non-empty"
        }
        if trimmed.contains(where: { $0.isNewline || $0 == "\0" }) {
            return "host contains invalid characters"
        }
        if port == 0 {
            return "port must be non-zero"
        }
        return nil
    }

    private static func makeQUICOptions() -> NWProtocolQUIC.Options {
        if #available(macOS 14.0, *) {
            // ALPN "h3" only — evaluation seam; no connection, no cert policy changes.
            return NWProtocolQUIC.Options(alpn: [prototypeALPN])
        }
        // Unreachable when assess() returned `.configured`; keep the compiler happy.
        preconditionFailure("NWProtocolQUIC.Options requested without macOS 14+ availability")
    }
}
