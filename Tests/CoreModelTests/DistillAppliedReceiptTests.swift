import CryptoKit
import Foundation
import XCTest
@testable import CoreModel

final class DistillAppliedReceiptTests: XCTestCase {
    private let marker = "[[rcd:v1.AAAAAAAAAAAAAAAAAAAAAA]]"

    func test_makeMarkerUsesExactVersioned128BitBase64URLFormat() throws {
        let marker = DistillAppliedReceipt.makeMarker()
        let regex = try NSRegularExpression(
            pattern: #"\A\[\[rcd:v1\.([A-Za-z0-9_-]{22})\]\]\z"#
        )
        let range = NSRange(marker.startIndex..<marker.endIndex, in: marker)
        let match = try XCTUnwrap(regex.firstMatch(in: marker, range: range))
        let tokenRange = try XCTUnwrap(Range(match.range(at: 1), in: marker))
        let token = String(marker[tokenRange])
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

        XCTAssertEqual(Data(base64Encoded: base64)?.count, 16)
    }

    func test_stripHidesValidTrailingReceiptAndTidiesWhitespace() {
        let text = "first  \n\n\nsecond\t \n\(marker)"

        XCTAssertTrue(DistillAppliedReceipt.containsMarker(text))
        XCTAssertEqual(DistillAppliedReceipt.strip(text), "first\n\nsecond")
        XCTAssertFalse(DistillAppliedReceipt.strip(text).contains("[[rcd:"))
    }

    func test_completeTrailingLineMayEndWithOutputNewline() {
        let text = "answer\r\n\(marker)\r\n"

        XCTAssertTrue(DistillAppliedReceipt.containsMarker(text))
        XCTAssertEqual(DistillAppliedReceipt.strip(text), "answer")
    }

    func test_validMarkerInBodyCannotAccidentallyClaimDistillWasApplied() {
        // WHY: model-authored prose may quote the syntax. Only the host-appended
        // complete trailing line is trustworthy as an application receipt.
        let text = "Example:\n\(marker)\nDo not emit this yourself."

        XCTAssertFalse(DistillAppliedReceipt.containsMarker(text))
        XCTAssertEqual(DistillAppliedReceipt.strip(text), text)
    }

    func test_malformedOrArbitrarySyntaxCannotTriggerOrAlterUserText() {
        // WHY: loose prefix matching could hide ordinary text and falsely report
        // that paid Token Saver work ran when no valid host receipt was present.
        let invalidTexts = [
            "[[rcd:anything]]",
            "[[rcd:v2.AAAAAAAAAAAAAAAAAAAAAA]]",
            "[[rcd:v1.AAAAAAAAAAAAAAAAAAAAA]]",
            "[[rcd:v1.AAAAAAAAAAAAAAAAAAAAAAA]]",
            "[[rcd:v1.AAAAAAAAAAAAAAAAAAAAA+]]",
            "[[rcd:v1.AAAAAAAAAAAAAAAAAAAAA=]]",
            "prefix \(marker)",
            " \(marker)",
            "\(marker) suffix",
        ]

        for text in invalidTexts {
            XCTAssertFalse(DistillAppliedReceipt.containsMarker(text), text)
            XCTAssertEqual(DistillAppliedReceipt.strip(text), text, text)
        }
    }

    func test_v2DeterministicVectorBindsExactPrefixRootNonceAndKey() throws {
        // WHY: Swift and the Claude Node bridge must sign identical bytes or a
        // valid provider receipt will be rejected by the host as untrusted.
        let prefix = Data("COMPRESSED\n".utf8)
        let key = Data(0..<32)
        let nonce = Data(repeating: 0xaa, count: 16)
        let rootRunID = "123e4567-e89b-12d3-a456-426614174000"
        let digest = Data(SHA256.hash(data: prefix))
        let expected = "[[rcd:v2.qqqqqqqqqqqqqqqqqqqqqg.TGBL0F4FLPCrX7LMh5OGUsnui3T65Z3_HuZrCa08rzw]]"

        let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: rootRunID,
            payloadByteCount: prefix.count,
            payloadSHA256: digest,
            key: key,
            nonce: nonce
        ))

        XCTAssertEqual(marker, expected)
        let framed = prefix + Data((marker + "\n").utf8)
        let parsed = try XCTUnwrap(DistillAppliedReceipt.parseTrailingV2Marker(in: framed))
        XCTAssertEqual(parsed.nonce, nonce)
        XCTAssertEqual(parsed.markerByteRange, prefix.count..<(prefix.count + marker.utf8.count))
        XCTAssertEqual(parsed.markerByteCount, marker.utf8.count)
        XCTAssertEqual(parsed.terminalSuffixByteCount, 1)
        XCTAssertEqual(DistillAppliedReceipt.maximumV2MarkerByteCount, marker.utf8.count)
        XCTAssertTrue(DistillAppliedReceipt.verify(
            parsed,
            rootRunID: rootRunID,
            payloadByteCount: prefix.count,
            payloadSHA256: digest,
            key: key
        ))
    }

    func test_v2ParserIsByteSafeWhenTailStartsInsideUTF8AndRejectsNonTerminalMarker() throws {
        // WHY: the coordinator retains only a bounded byte tail. Its first byte
        // may be a UTF-8 continuation byte, so receipt parsing cannot decode the
        // entire tail as a String before finding the ASCII terminal marker.
        let prefix = Data([0x80, 0x81, 0x0a])
        let key = Data(repeating: 0x11, count: 32)
        let nonce = Data(repeating: 0x22, count: 16)
        let digest = Data(SHA256.hash(data: prefix))
        let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: "root",
            payloadByteCount: prefix.count,
            payloadSHA256: digest,
            key: key,
            nonce: nonce
        ))
        let tail = prefix + Data((marker + "\r\n").utf8)

        let parsed = try XCTUnwrap(DistillAppliedReceipt.parseTrailingV2Marker(in: tail))
        XCTAssertEqual(parsed.markerByteRange.lowerBound, prefix.count)
        XCTAssertEqual(parsed.terminalSuffixByteCount, 2)
        XCTAssertNil(DistillAppliedReceipt.parseTrailingV2Marker(in: tail + Data("after".utf8)))
    }

    func test_v2VerificationRejectsEveryBoundFieldAndMalformedLengths() throws {
        // WHY: a random syntax token is forgeable. Trust requires the MAC to bind
        // the exact bytes, run identity, nonce, and the current On-lifecycle key.
        let prefix = Data("result\n".utf8)
        let digest = Data(SHA256.hash(data: prefix))
        let key = Data(repeating: 0x33, count: 32)
        let nonce = Data(repeating: 0x44, count: 16)
        let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: "root-a",
            payloadByteCount: prefix.count,
            payloadSHA256: digest,
            key: key,
            nonce: nonce
        ))
        let parsed = try XCTUnwrap(DistillAppliedReceipt.parseTrailingV2Marker(
            in: prefix + Data(marker.utf8)
        ))

        XCTAssertFalse(DistillAppliedReceipt.verify(parsed, rootRunID: "root-b", payloadByteCount: prefix.count, payloadSHA256: digest, key: key))
        XCTAssertFalse(DistillAppliedReceipt.verify(parsed, rootRunID: "root-a", payloadByteCount: prefix.count + 1, payloadSHA256: digest, key: key))
        XCTAssertFalse(DistillAppliedReceipt.verify(parsed, rootRunID: "root-a", payloadByteCount: prefix.count, payloadSHA256: Data(repeating: 0, count: 32), key: key))
        XCTAssertFalse(DistillAppliedReceipt.verify(parsed, rootRunID: "root-a", payloadByteCount: prefix.count, payloadSHA256: digest, key: Data(repeating: 0x34, count: 32)))
        XCTAssertNil(DistillAppliedReceipt.makeV2Marker(rootRunID: "root-a", payloadByteCount: prefix.count, payloadSHA256: Data(), key: key, nonce: nonce))
        XCTAssertNil(DistillAppliedReceipt.makeV2Marker(rootRunID: "root-a", payloadByteCount: prefix.count, payloadSHA256: digest, key: key, nonce: Data()))
    }
}
