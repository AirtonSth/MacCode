import XCTest
@testable import DistillCore

final class CCRSearchIndexTests: XCTestCase {
    func test_searchRanksByQueryOverlapAndReturnsDeterministicExcerpt() {
        var index = CCRSearchIndex()
        index.add(handle: "a", text: "INFO startup complete")
        index.add(handle: "b", text: "ERROR checkout failed at Sources/Payment.swift:42\nretry later")

        let results = index.search("checkout error", topK: 1)

        XCTAssertEqual(results.first?.handle, "b")
        XCTAssertTrue(results.first?.excerpt.contains("ERROR checkout failed") == true)
        XCTAssertTrue(results.first?.excerpt.contains("bytes") == true)
        XCTAssertTrue(results.first?.excerpt.contains("lines") == true)
    }

    func test_nominateNearDuplicateDoesNotSilentlyDisposeDifferentText() {
        let index = CCRSearchIndex(records: [
            CCRSearchRecord(handle: "old", text: "alpha beta gamma delta")
        ])

        XCTAssertNil(index.nominateNearDuplicate("alpha beta changed delta", minimumJaccard: 0.95))
        XCTAssertEqual(index.nominateNearDuplicate("alpha beta gamma delta", minimumJaccard: 0.95)?.handle, "old")
    }
}
