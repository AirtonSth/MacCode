import Foundation
import XCTest
@testable import CoreModel

/// WHY: older threads can end tool output with a `[[rcd:…]]` marker that the
/// removed Token Saver appended. It must never render raw, and ordinary text
/// that only looks like a marker must reach the user unchanged.
final class DistillAppliedReceiptTests: XCTestCase {
    private let marker = "[[rcd:v1.AAAAAAAAAAAAAAAAAAAAAA]]"
    private let v2Marker = "[[rcd:v2.AAAAAAAAAAAAAAAAAAAAAA.\(String(repeating: "B", count: 43))]]"

    func test_stripHidesValidTrailingReceiptAndTidiesWhitespace() {
        let text = "first  \n\n\nsecond\t \n\(marker)"

        XCTAssertEqual(DistillAppliedReceipt.strip(text), "first\n\nsecond")
        XCTAssertFalse(DistillAppliedReceipt.strip(text).contains("[[rcd:"))
    }

    func test_stripHidesTrailingV2Receipt() {
        XCTAssertEqual(DistillAppliedReceipt.strip("answer\n\(v2Marker)"), "answer")
    }

    func test_completeTrailingLineMayEndWithOutputNewline() {
        let text = "answer\r\n\(marker)\r\n"

        XCTAssertEqual(DistillAppliedReceipt.strip(text), "answer")
    }

    func test_validMarkerInBodyIsLeftUnchanged() {
        // WHY: model-authored prose may quote the syntax. Only a complete
        // trailing line was ever host-appended.
        let text = "Example:\n\(marker)\nDo not emit this yourself."

        XCTAssertEqual(DistillAppliedReceipt.strip(text), text)
    }

    func test_malformedOrArbitrarySyntaxDoesNotAlterUserText() {
        // WHY: loose prefix matching could hide ordinary text.
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
            XCTAssertEqual(DistillAppliedReceipt.strip(text), text, text)
        }
    }
}
