import XCTest
@testable import DistillCore

final class DistillImportanceScorerTests: XCTestCase {
    func test_shortInputUnchanged() {
        let text = "line1\nline2\nline3"
        let r = DistillImportanceScorer.compact(text, maxKeep: 40)
        XCTAssertEqual(r.compacted, text)
        XCTAssertEqual(r.droppedLines, 0)
    }

    func test_keepsErrorAndFileLine_dropsBulk() {
        var lines = (1...100).map { "INFO step \($0) doing routine work" }
        lines[50] = "ERROR crash at Sources/Foo/Bar.swift:142 — null deref"
        let text = lines.joined(separator: "\n")

        let r = DistillImportanceScorer.compact(text, maxKeep: 20, keepLast: 5)
        XCTAssertTrue(r.compacted.contains("ERROR crash at Sources/Foo/Bar.swift:142 — null deref"),
                      "the load-bearing error+file:line line must survive verbatim")
        XCTAssertTrue(r.compacted.contains("elided"), "bulk INFO lines are elided into a marker")
        XCTAssertGreaterThan(r.droppedLines, 0)
        XCTAssertLessThan(r.compacted.count, text.count, "compaction shrinks the output")
    }

    func test_keepsTailLines() {
        let lines = (1...60).map { "noise line \($0)" }
        let text = lines.joined(separator: "\n")
        let r = DistillImportanceScorer.compact(text, maxKeep: 20, keepLast: 6)
        XCTAssertTrue(r.compacted.contains("noise line 60"), "the last line (most recent) is kept")
        XCTAssertTrue(r.compacted.contains("noise line 55"), "the tail window is kept")
    }
}
