import XCTest
@testable import DistillCore

final class DistillBlockDeduperTests: XCTestCase {
    func test_collapsesExactDuplicateLargeBlockToReadablePointer() {
        let block = String(repeating: "The widget renderer reads config from disk and validates each field. ", count: 8) // >400 chars
        XCTAssertGreaterThan(block.count, 400)
        let prompt = "Intro paragraph.\n\n\(block)\n\nMiddle note.\n\n\(block)\n\nClosing."

        let result = DistillBlockDeduper.dedupe(prompt)
        XCTAssertEqual(result.dedupedBlocks, 1)
        XCTAssertEqual(result.nearDedupedBlocks, 0)
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
        XCTAssertEqual(DistillBlockDeduper.dedupe(prompt).nearDedupedBlocks, 0)
    }

    func test_neverInflates() {
        let prompt = "single block with no blank-line separators and no duplicates at all here"
        XCTAssertEqual(DistillBlockDeduper.dedupe(prompt).output, prompt)
    }

    func test_nearDuplicateCollapseAllowsOnlyVolatileDiffsAndKeepsThemVerbatim() {
        let stableTail = String(repeating: " repeated stable diagnostic text", count: 24)
        let first = """
        2026-06-13T10:20:30Z pid=1234 crashed at 0x0000000abcdef123
        ERROR auth failed in LoginView.swift:88\(stableTail)
        """
        let second = """
        2026-06-13T10:20:31Z pid=5678 crashed at 0x0000000abcdef999
        ERROR auth failed in LoginView.swift:88\(stableTail)
        """
        XCTAssertGreaterThan(first.count, 400)
        let prompt = "Intro.\n\n\(first)\n\n\(second)\n\nDone."

        let result = DistillBlockDeduper.dedupe(prompt, originalHandleMarker: "[[rc:abc123]]")

        XCTAssertEqual(result.dedupedBlocks, 0)
        XCTAssertEqual(result.nearDedupedBlocks, 1)
        XCTAssertTrue(result.output.contains("same as block #1 above except"))
        XCTAssertTrue(result.output.contains("pid=1234"))
        XCTAssertTrue(result.output.contains("pid=5678"))
        XCTAssertTrue(result.output.contains("[[rc:abc123]]"))
        XCTAssertLessThan(result.output.count, prompt.count)
    }

    func test_nearDuplicateRejectsLineDriftAndSemanticNumbers() {
        let stableTail = String(repeating: " repeated stable diagnostic text", count: 24)
        let first = "ERROR auth failed in LoginView.swift:88 count=1\(stableTail)"
        let second = "ERROR auth failed in LoginView.swift:89 count=2\(stableTail)"
        XCTAssertGreaterThan(first.count, 400)

        let result = DistillBlockDeduper.dedupe("Intro.\n\n\(first)\n\n\(second)")

        XCTAssertEqual(result.output, "Intro.\n\n\(first)\n\n\(second)")
        XCTAssertEqual(result.nearDedupedBlocks, 0,
                       "line numbers and counts are not volatile; near-dup collapse must reject them")
    }

    func test_nominatorCannotForceUnsafeNearDuplicateCollapse() {
        let stableTail = String(repeating: " repeated stable diagnostic text", count: 24)
        let first = "PASS login spec line 88\(stableTail)"
        let second = "FAIL login spec line 88\(stableTail)"
        let prompt = "Intro.\n\n\(first)\n\n\(second)"

        let result = DistillBlockDeduper.dedupe(prompt, nearDuplicateNominator: { _, _ in true })

        XCTAssertEqual(result.output, prompt,
                       "BERT/embedding nomination is advisory; deterministic diff decides and blocks PASS->FAIL")
        XCTAssertEqual(result.nearDedupedBlocks, 0)
    }
}
