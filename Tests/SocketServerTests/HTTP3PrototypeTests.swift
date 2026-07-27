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
}
