import XCTest
@testable import SocketServer

// PayloadCodecLZFSETests
// Verifies lzfse-first codec selection and round-trip correctness.
// WHY: P3 goal = cut CPU on large compressed responses by preferring lzfse
//      (Apple Compression framework, no CRC table walk) over gzip.
//      Tests encode the BUSINESS RULE: lzfse wins past the threshold,
//      gzip is fallback, identity is used below threshold / when nothing accepted.
final class PayloadCodecLZFSETests: XCTestCase {

    // MARK: round-trip

    func test_lzfse_roundTrip_empty() throws {
        // WHY: empty data must not crash or corrupt; codec must be symmetric
        let data = Data()
        let compressed = try PayloadCodec.lzfse.encode(data)
        let restored = try PayloadCodec.lzfse.decode(compressed, expectedSize: data.count)
        XCTAssertEqual(restored, data)
    }

    func test_lzfse_roundTrip_small() throws {
        // WHY: small payloads below any threshold must still round-trip correctly
        let data = Data("hello remote-code".utf8)
        let compressed = try PayloadCodec.lzfse.encode(data)
        let restored = try PayloadCodec.lzfse.decode(compressed, expectedSize: data.count)
        XCTAssertEqual(restored, data)
    }

    func test_lzfse_roundTrip_large_restoresBytesExactly() throws {
        // WHY: large JSON-like payloads are the primary use-case; byte identity is the hard contract
        let raw = String(repeating: "{\"key\":\"value\",\"n\":12345}", count: 2000)
        let data = Data(raw.utf8)
        XCTAssertGreaterThan(data.count, 32_768, "fixture must be large to exercise lzfse block boundaries")
        let compressed = try PayloadCodec.lzfse.encode(data)
        let restored = try PayloadCodec.lzfse.decode(compressed, expectedSize: data.count)
        XCTAssertEqual(restored, data)
    }

    func test_lzfse_roundTrip_binary_randomBytes() throws {
        // WHY: binary payloads (file content, images) must survive the codec without corruption
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 4096)
        for i in bytes.indices { bytes[i] = UInt8(rng.next() & 0xff) }
        let data = Data(bytes)
        let compressed = try PayloadCodec.lzfse.encode(data)
        let restored = try PayloadCodec.lzfse.decode(compressed, expectedSize: nil)
        XCTAssertEqual(restored, data)
    }

    // MARK: selectResponseCodec - threshold logic

    func test_selectResponseCodec_belowThreshold_returnsNil() {
        // WHY: tiny payloads gain nothing from compression; overhead would increase latency
        let acceptBoth = "\(PayloadCodec.gzip.wireName), \(PayloadCodec.lzfse.wireName)"
        let result = PayloadCodec.selectResponseCodec(
            payloadSize: 127,
            acceptEncoding: acceptBoth,
            threshold: 128
        )
        XCTAssertNil(result, "below threshold must return nil (no compression)")
    }

    func test_selectResponseCodec_atThreshold_returnsLZFSE() {
        // WHY: at exactly threshold lzfse must be selected as the preferred (lower-CPU) codec
        let acceptBoth = "\(PayloadCodec.gzip.wireName), \(PayloadCodec.lzfse.wireName)"
        let result = PayloadCodec.selectResponseCodec(
            payloadSize: 128,
            acceptEncoding: acceptBoth,
            threshold: 128
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.wireName, PayloadCodec.lzfse.wireName)
    }

    func test_selectResponseCodec_aboveThreshold_lzfseAccepted_returnsLZFSE() {
        // WHY: primary P3 rule — lzfse wins over gzip when client accepts it and payload is large
        let acceptBoth = "\(PayloadCodec.gzip.wireName), \(PayloadCodec.lzfse.wireName)"
        let result = PayloadCodec.selectResponseCodec(
            payloadSize: 50_000,
            acceptEncoding: acceptBoth,
            threshold: 128
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.wireName, PayloadCodec.lzfse.wireName)
    }

    func test_selectResponseCodec_aboveThreshold_onlyGzipAccepted_returnsGzip() {
        // WHY: when client advertises gzip only, we must not silently use lzfse
        let result = PayloadCodec.selectResponseCodec(
            payloadSize: 50_000,
            acceptEncoding: PayloadCodec.gzip.wireName,
            threshold: 128
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.wireName, PayloadCodec.gzip.wireName)
    }

    func test_selectResponseCodec_aboveThreshold_onlyLZFSEAccepted_returnsLZFSE() {
        // WHY: when client advertises only lzfse (e.g., native iOS client) lzfse is selected
        let result = PayloadCodec.selectResponseCodec(
            payloadSize: 50_000,
            acceptEncoding: PayloadCodec.lzfse.wireName,
            threshold: 128
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.wireName, PayloadCodec.lzfse.wireName)
    }

    func test_selectResponseCodec_aboveThreshold_nilAccept_returnsNil() {
        // WHY: no Accept-Encoding header means client declared no compression support
        let result = PayloadCodec.selectResponseCodec(
            payloadSize: 50_000,
            acceptEncoding: nil,
            threshold: 128
        )
        XCTAssertNil(result)
    }

    func test_selectResponseCodec_aboveThreshold_emptyAccept_returnsNil() {
        // WHY: empty Accept-Encoding string is equivalent to no header; must not throw or crash
        let result = PayloadCodec.selectResponseCodec(
            payloadSize: 50_000,
            acceptEncoding: "",
            threshold: 128
        )
        XCTAssertNil(result)
    }

    func test_selectResponseCodec_defaultThreshold_usedWhenOmitted() {
        // WHY: callers not specifying threshold must get the canonical default (128 bytes)
        //      — the default must match what HTTPServer send() uses
        let acceptBoth = "\(PayloadCodec.gzip.wireName), \(PayloadCodec.lzfse.wireName)"
        let belowDefault = PayloadCodec.selectResponseCodec(
            payloadSize: 127,
            acceptEncoding: acceptBoth
        )
        let atDefault = PayloadCodec.selectResponseCodec(
            payloadSize: 128,
            acceptEncoding: acceptBoth
        )
        XCTAssertNil(belowDefault)
        XCTAssertNotNil(atDefault)
        XCTAssertEqual(atDefault!.wireName, PayloadCodec.lzfse.wireName)
    }

    // MARK: preferredResponseCodec unchanged

    func test_preferredResponseCodec_unchanged_gzipFirst() {
        // WHY: existing callers rely on gzip-first order; must not break after adding new API
        let acceptBoth = "\(PayloadCodec.gzip.wireName), \(PayloadCodec.lzfse.wireName)"
        let result = PayloadCodec.preferredResponseCodec(acceptEncoding: acceptBoth)
        XCTAssertEqual(result?.wireName, PayloadCodec.gzip.wireName)
    }
}
