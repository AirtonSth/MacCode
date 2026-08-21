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
}
