import XCTest
@testable import DistillCore

final class DistillBlockDeduperTests: XCTestCase {
    func test_collapsesExactDuplicateLargeBlockToReadablePointer() {
        let block = String(repeating: "The widget renderer reads config from disk and validates each field. ", count: 8) // >400 chars
        XCTAssertGreaterThan(block.count, 400)
        let prompt = "Intro paragraph.\n\n\(block)\n\nMiddle note.\n\n\(block)\n\nClosing."

        let result = DistillBlockDeduper.dedupe(prompt)
        XCTAssertEqual(result.dedupedBlocks, 1)
        XCTAssertTrue(result.output.contains("⟪identical to block #"), "duplicate replaced with a model-readable pointer")
        XCTAssertLessThan(result.output.count, prompt.count)
        // Non-lossy: the content still appears once (the first occurrence stays inline).
        XCTAssertTrue(result.output.contains(block))
        // The first occurrence is NOT replaced; exactly one copy of the block remains.
        let occurrences = result.output.components(separatedBy: block).count - 1
        XCTAssertEqual(occurrences, 1, "first occurrence inline, only later duplicates collapsed")
    }

    func test_smallBlocksAndUniqueContentUnchanged() {
        let prompt = "short a\n\nshort b\n\nshort c" // all blocks < 400 chars
        XCTAssertEqual(DistillBlockDeduper.dedupe(prompt).output, prompt)
        XCTAssertEqual(DistillBlockDeduper.dedupe(prompt).dedupedBlocks, 0)
    }

    func test_neverInflates() {
        let prompt = "single block with no blank-line separators and no duplicates at all here"
        XCTAssertEqual(DistillBlockDeduper.dedupe(prompt).output, prompt)
    }
}
