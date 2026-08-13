import XCTest
@testable import DistillCore
@testable import CoreModel

final class LiteralPreservationTests: XCTestCase {
    func test_pinsLoadBearingLiterals() {
        let text = """
        Build failed at Sources/Foo/Bar.swift:142
        request id 3f8a1c2d-4b5e-6f70-8192-a3b4c5d6e7f8
        commit a1b2c3d4e5f6 exit code 1337
        """
        let pins = LiteralPreservation.pinnedLiterals(in: text)
        XCTAssertTrue(pins.contains("Sources/Foo/Bar.swift:142"), "file:line pinned")
        XCTAssertTrue(pins.contains("3f8a1c2d-4b5e-6f70-8192-a3b4c5d6e7f8"), "UUID pinned")
        XCTAssertTrue(pins.contains("a1b2c3d4e5f6"), "hex hash pinned")
        XCTAssertTrue(pins.contains("1337"), "long number pinned")
    }

    func test_guardRejectsLossyOutputThatDropsALiteral() {
        let original = "FATAL at App/Main.swift:88 — null deref in render()"
        let lossyDroppingLine = "There was a fatal error during rendering." // drops App/Main.swift:88
        let result = LiteralPreservation.guarded(original: original, compressed: lossyDroppingLine)
        XCTAssertEqual(result.output, original, "dropping a pinned literal => reject, keep original (N5)")
        XCTAssertTrue(result.droppedLiteral?.contains("App/Main.swift:88") == true)
    }

    func test_guardAcceptsLossyOutputThatKeepsLiterals() {
        let original = "Long verbose explanation. The crash is at App/Main.swift:88 with code 4040 and lots of extra prose padding."
        let compressed = "Crash at App/Main.swift:88, code 4040."
        let result = LiteralPreservation.guarded(original: original, compressed: compressed)
        XCTAssertEqual(result.output, compressed, "all literals preserved => adopt the compressed form")
        XCTAssertNil(result.droppedLiteral)
    }

    func test_pureProseHasNoPinsAndCompressesFreely() {
        let original = "This is an ordinary sentence with nothing load bearing to preserve at all."
        let compressed = "Ordinary sentence."
        let result = LiteralPreservation.guarded(original: original, compressed: compressed)
        XCTAssertEqual(result.output, compressed)
        XCTAssertNil(result.droppedLiteral)
    }

    func test_diffChangeLinesArePinned() {
        let diff = """
        @@ -1,2 +1,2 @@
         context line
        -let timeout = 30
        +let timeout = 60
        """
        XCTAssertTrue(LiteralPreservation.pinnedLiterals(in: diff).contains("-let timeout = 30"))
        XCTAssertTrue(LiteralPreservation.pinnedLiterals(in: diff).contains("+let timeout = 60"))
        // A summary that loses the actual edit must be rejected.
        let result = LiteralPreservation.guarded(original: diff, compressed: "Changed the timeout value.")
        XCTAssertEqual(result.output, diff)
    }

    func test_tagsAndRetrieveMarkersArePinned() {
        let original = "Do not drop <policy mode=\"strict\">safe</policy> or [[rc:deadbeef]]."
        let pins = LiteralPreservation.pinnedLiterals(in: original)

        XCTAssertTrue(pins.contains("<policy mode=\"strict\">"))
        XCTAssertTrue(pins.contains("</policy>"))
        XCTAssertTrue(pins.contains("[[rc:deadbeef]]"))

        let result = LiteralPreservation.guarded(original: original, compressed: "Do not drop safe.")
        XCTAssertEqual(result.output, original)
    }

    func test_extendedPinsForProsePruningLane() {
        let original = "Commit abc1234 fixed `retryLimit` in version 1.2.3 on port 8080.\nERROR: keep this whole line."
        let pins = LiteralPreservation.pinnedLiterals(in: original)

        XCTAssertTrue(pins.contains("abc1234"))
        XCTAssertTrue(pins.contains("`retryLimit`"))
        XCTAssertTrue(pins.contains("1.2.3"))
        XCTAssertTrue(pins.contains("port 8080"))
        XCTAssertTrue(pins.contains("ERROR: keep this whole line."))
    }
}
