import XCTest
@testable import SocketServer

/// Unit tests for the Phase 5 QUIC/HTTP-3 evaluation seam.
///
/// WHY: the seam must stay opt-in/off-by-default and must not open connections or
/// invent TLS bypass. These tests pin that contract without live network I/O so
/// production HTTP/WebSocket paths remain the only reliable/realtime transports.
final class HTTP3PrototypeTests: XCTestCase {

    func test_configuration_disabledByDefault() {
        // WHY: accidental default-on would couple experiments to production listeners.
        let config = HTTP3PrototypeConfiguration()
        XCTAssertFalse(config.enabled, "HTTP/3 prototype must default to disabled")
        XCTAssertEqual(HTTP3PrototypeConfiguration.disabled.enabled, false)
        XCTAssertEqual(HTTP3Prototype.assess(config), .disabled)
        XCTAssertEqual(HTTP3Prototype.assess(.disabled), .disabled)

        switch HTTP3Prototype.makeProtocolOptions(for: config) {
        case .success:
            XCTFail("disabled configuration must not produce QUIC options")
        case .failure(let error):
            XCTAssertEqual(error, .disabled)
        }
    }

    func test_invalidEndpoint_rejectedWithoutBuildingOptions() {
        // WHY: garbage host/port must fail at the seam, not at connect time later.
        let cases: [(HTTP3PrototypeConfiguration, String)] = [
            (
                HTTP3PrototypeConfiguration(enabled: true, host: "", port: 443, requireTLS: true),
                "host"
            ),
            (
                HTTP3PrototypeConfiguration(enabled: true, host: "   ", port: 443, requireTLS: true),
                "host"
            ),
            (
                HTTP3PrototypeConfiguration(enabled: true, host: "example.test", port: 0, requireTLS: true),
                "port"
            ),
            (
                HTTP3PrototypeConfiguration(enabled: true, host: "bad\nhost", port: 443, requireTLS: true),
                "host"
            ),
        ]

        for (config, expectedNeedle) in cases {
            let assessment = HTTP3Prototype.assess(config)
            guard case .invalidEndpoint(let reason) = assessment else {
                return XCTFail("expected invalidEndpoint for \(config), got \(assessment)")
            }
            XCTAssertTrue(
                reason.localizedCaseInsensitiveContains(expectedNeedle),
                "reason '\(reason)' should mention \(expectedNeedle)"
            )

            switch HTTP3Prototype.makeProtocolOptions(for: config) {
            case .success:
                XCTFail("invalid endpoint must not produce options")
            case .failure(let error):
                guard case .invalidEndpoint = error else {
                    return XCTFail("expected invalidEndpoint failure, got \(error)")
                }
            }
        }
    }

    func test_tlsRequired_whenRequireTLSIsFalse() {
        // WHY: QUIC is TLS-bound; refusing cleartext keeps cert-bypass out of scope.
        let config = HTTP3PrototypeConfiguration(
            enabled: true,
            host: "127.0.0.1",
            port: 443,
            requireTLS: false
        )
        XCTAssertEqual(HTTP3Prototype.assess(config), .tlsRequired)

        switch HTTP3Prototype.makeProtocolOptions(for: config) {
        case .success:
            XCTFail("requireTLS=false must not produce options")
        case .failure(let error):
            XCTAssertEqual(error, .tlsRequired)
        }
    }

    func test_assessment_supportedOrUnsupported_isDeterministic() {
        // WHY: given the same config and process OS, assess/makeProtocolOptions must
        // agree and must not perform network I/O (pure configuration only).
        let config = HTTP3PrototypeConfiguration(
            enabled: true,
            host: "  example.test  ",
            port: 8443,
            requireTLS: true
        )

        let first = HTTP3Prototype.assess(config)
        let second = HTTP3Prototype.assess(config)
        XCTAssertEqual(first, second, "assessment must be deterministic for fixed input")

        if HTTP3Prototype.isQUICOptionsAvailable {
            XCTAssertEqual(
                first,
                .configured(host: "example.test", port: 8443),
                "macOS 14+ with valid opt-in config must report configured (host trimmed)"
            )
            switch HTTP3Prototype.makeProtocolOptions(for: config) {
            case .success(let options):
                XCTAssertNotNil(options, "options object is constructed; no connection is started")
            case .failure(let error):
                XCTFail("expected success when isQUICOptionsAvailable, got \(error)")
            }
        } else {
            XCTAssertEqual(first, .unsupported)
            switch HTTP3Prototype.makeProtocolOptions(for: config) {
            case .success:
                XCTFail("unsupported OS must not produce options")
            case .failure(let error):
                XCTAssertEqual(error, .unsupported)
            }
        }

        // Disabled still wins over a otherwise-valid endpoint.
        var disabled = config
        disabled.enabled = false
        XCTAssertEqual(HTTP3Prototype.assess(disabled), .disabled)
    }

    // MARK: - Deployment disposition / fallback selection

    func test_disposition_defaultOff_selectsHTTPWebSocketFallback() {
        // WHY: default-off deployment must keep production HTTP+WebSocket and never
        // construct QUIC options that could be mistaken for a transport switch.
        let configs = [
            HTTP3PrototypeConfiguration(),
            HTTP3PrototypeConfiguration.disabled,
        ]
        for config in configs {
            let disposition = HTTP3Prototype.disposition(for: config)
            XCTAssertEqual(
                disposition,
                .httpWebSocketFallback(reason: .defaultOff),
                "disabled config must map to default_off fallback"
            )
            XCTAssertTrue(disposition.usesHTTPWebSocketFallback)
            XCTAssertEqual(disposition.reasonCode, "default_off")
            XCTAssertEqual(
                HTTP3PrototypeFallbackReason.defaultOff.reasonDescription,
                "HTTP/3 prototype is disabled by default; keep HTTP+WebSocket"
            )
            assertNoQUICOptions(for: config, file: #filePath, line: #line)
        }

        // Pure assessment → disposition mapping (no re-assess side effects).
        XCTAssertEqual(
            HTTP3Prototype.disposition(from: .disabled),
            .httpWebSocketFallback(reason: .defaultOff)
        )
    }

    func test_disposition_invalidEndpoint_selectsHTTPWebSocketFallback() {
        // WHY: bad endpoints stay on the reliable path; options must not be built.
        let config = HTTP3PrototypeConfiguration(
            enabled: true,
            host: "",
            port: 443,
            requireTLS: true
        )
        let assessment = HTTP3Prototype.assess(config)
        guard case .invalidEndpoint = assessment else {
            return XCTFail("expected invalidEndpoint assessment, got \(assessment)")
        }

        let disposition = HTTP3Prototype.disposition(for: config)
        XCTAssertEqual(disposition, .httpWebSocketFallback(reason: .invalidEndpoint))
        XCTAssertTrue(disposition.usesHTTPWebSocketFallback)
        XCTAssertEqual(disposition.reasonCode, "invalid_endpoint")
        XCTAssertEqual(
            HTTP3Prototype.disposition(from: assessment),
            .httpWebSocketFallback(reason: .invalidEndpoint)
        )
        assertNoQUICOptions(for: config, file: #filePath, line: #line)
    }

    func test_disposition_tlsRequired_selectsHTTPWebSocketFallback() {
        // WHY: TLS requirement is a hard security gate; cleartext stays on HTTP+WS.
        let config = HTTP3PrototypeConfiguration(
            enabled: true,
            host: "127.0.0.1",
            port: 443,
            requireTLS: false
        )
        XCTAssertEqual(HTTP3Prototype.assess(config), .tlsRequired)

        let disposition = HTTP3Prototype.disposition(for: config)
        XCTAssertEqual(disposition, .httpWebSocketFallback(reason: .tlsRequired))
        XCTAssertTrue(disposition.usesHTTPWebSocketFallback)
        XCTAssertEqual(disposition.reasonCode, "tls_required")
        XCTAssertTrue(
            HTTP3PrototypeFallbackReason.tlsRequired.reasonDescription
                .localizedCaseInsensitiveContains("TLS")
        )
        XCTAssertEqual(
            HTTP3Prototype.disposition(from: .tlsRequired),
            .httpWebSocketFallback(reason: .tlsRequired)
        )
        assertNoQUICOptions(for: config, file: #filePath, line: #line)
    }

    func test_disposition_unsupportedOS_selectsHTTPWebSocketFallback() {
        // WHY: OS compatibility gate must not invent QUIC options; fallback is mandatory.
        // Pure mapping is always testable even when this process is macOS 14+.
        XCTAssertEqual(
            HTTP3Prototype.disposition(from: .unsupported),
            .httpWebSocketFallback(reason: .unsupportedOS)
        )
        let unsupportedDisposition = HTTP3Prototype.disposition(from: .unsupported)
        XCTAssertTrue(unsupportedDisposition.usesHTTPWebSocketFallback)
        XCTAssertEqual(unsupportedDisposition.reasonCode, "unsupported_os")
        XCTAssertTrue(
            HTTP3PrototypeFallbackReason.unsupportedOS.reasonDescription
                .localizedCaseInsensitiveContains("OS")
        )

        // When the live process lacks QUIC options, a valid opt-in config must
        // assess as unsupported and refuse options construction.
        if !HTTP3Prototype.isQUICOptionsAvailable {
            let config = HTTP3PrototypeConfiguration(
                enabled: true,
                host: "example.test",
                port: 443,
                requireTLS: true
            )
            XCTAssertEqual(HTTP3Prototype.assess(config), .unsupported)
            XCTAssertEqual(
                HTTP3Prototype.disposition(for: config),
                .httpWebSocketFallback(reason: .unsupportedOS)
            )
            assertNoQUICOptions(for: config, file: #filePath, line: #line)
        }
    }

    func test_disposition_configured_reportsPrototypeReadyOnly() {
        // WHY: valid opt-in on a capable OS is prototype-ready for evaluation only —
        // not production QUIC selection, listener changes, or live connections.
        XCTAssertEqual(
            HTTP3Prototype.disposition(from: .configured(host: "example.test", port: 8443)),
            .prototypeReady(host: "example.test", port: 8443)
        )
        let ready = HTTP3Prototype.disposition(from: .configured(host: "h", port: 1))
        XCTAssertFalse(ready.usesHTTPWebSocketFallback)
        XCTAssertEqual(ready.reasonCode, "prototype_ready")

        let config = HTTP3PrototypeConfiguration(
            enabled: true,
            host: "  example.test  ",
            port: 8443,
            requireTLS: true
        )
        if HTTP3Prototype.isQUICOptionsAvailable {
            let disposition = HTTP3Prototype.disposition(for: config)
            XCTAssertEqual(
                disposition,
                .prototypeReady(host: "example.test", port: 8443),
                "configured assessment maps to prototypeReady (not a production switch)"
            )
            // Options construction remains evaluation-only; no connection is started.
            switch HTTP3Prototype.makeProtocolOptions(for: config) {
            case .success(let options):
                XCTAssertNotNil(options)
            case .failure(let error):
                XCTFail("prototype-ready path may build options without connecting: \(error)")
            }
        }
    }

    func test_disposition_coversEveryAssessmentCase() {
        // WHY: every assessment must have an explicit disposition so deployment
        // choice stays inspectable (compatibility, TLS, default-off, fallback).
        let pairs: [(HTTP3PrototypeAssessment, HTTP3PrototypeDisposition)] = [
            (.disabled, .httpWebSocketFallback(reason: .defaultOff)),
            (.invalidEndpoint(reason: "host must be non-empty"), .httpWebSocketFallback(reason: .invalidEndpoint)),
            (.tlsRequired, .httpWebSocketFallback(reason: .tlsRequired)),
            (.unsupported, .httpWebSocketFallback(reason: .unsupportedOS)),
            (.configured(host: "a.b", port: 443), .prototypeReady(host: "a.b", port: 443)),
        ]
        for (assessment, expected) in pairs {
            XCTAssertEqual(
                HTTP3Prototype.disposition(from: assessment),
                expected,
                "assessment \(assessment) must map to \(expected)"
            )
        }

        // All fallback reason codes are stable and non-empty.
        for reason in HTTP3PrototypeFallbackReason.allCases {
            XCTAssertFalse(reason.rawValue.isEmpty)
            XCTAssertFalse(reason.reasonDescription.isEmpty)
            XCTAssertTrue(
                HTTP3PrototypeDisposition.httpWebSocketFallback(reason: reason)
                    .usesHTTPWebSocketFallback
            )
        }
    }

    func test_fallbackDispositions_neverProduceQUICOptions() {
        // WHY: prove no QUIC option/connection is created for any fallback case.
        let fallbackConfigs: [HTTP3PrototypeConfiguration] = [
            HTTP3PrototypeConfiguration(), // default-off
            HTTP3PrototypeConfiguration(enabled: true, host: "", port: 443, requireTLS: true),
            HTTP3PrototypeConfiguration(enabled: true, host: "example.test", port: 0, requireTLS: true),
            HTTP3PrototypeConfiguration(enabled: true, host: "127.0.0.1", port: 443, requireTLS: false),
        ]
        for config in fallbackConfigs {
            let disposition = HTTP3Prototype.disposition(for: config)
            XCTAssertTrue(
                disposition.usesHTTPWebSocketFallback,
                "expected fallback disposition for \(config), got \(disposition)"
            )
            assertNoQUICOptions(for: config, file: #filePath, line: #line)
        }

        // Unsupported OS assessment is always a fallback disposition regardless of
        // process capability; options construction is gated by assess(), not by
        // disposition alone — verify the pure mapping still selects fallback.
        XCTAssertTrue(
            HTTP3Prototype.disposition(from: .unsupported).usesHTTPWebSocketFallback
        )
    }

    // MARK: - Helpers

    private func assertNoQUICOptions(
        for configuration: HTTP3PrototypeConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch HTTP3Prototype.makeProtocolOptions(for: configuration) {
        case .success:
            XCTFail(
                "fallback disposition must not construct NWProtocolQUIC.Options",
                file: file,
                line: line
            )
        case .failure:
            break // expected — no options object, no connection
        }
    }
}
