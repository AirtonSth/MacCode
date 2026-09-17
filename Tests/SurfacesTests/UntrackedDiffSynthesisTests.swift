import XCTest
import AgentRuntime

/// Unit tests for `GitDiff.synthesizeUntrackedDiff(content:path:)`.
///
/// WHY: selecting an untracked file in the diff panel previously showed
/// nothing because `git diff HEAD` has no entry for untracked paths.
/// The synthesizer must produce a valid all-addition unified-diff patch
/// so the diff viewer renders the full new file in green, giving users
/// a meaningful preview before their first commit.
final class UntrackedDiffSynthesisTests: XCTestCase {

    // MARK: correctness — N-line file → N addition lines

    func test_threeLineFile_producesThreeAdditionLines() {
        let content = "alpha\nbeta\ngamma\n"
        let result = GitDiff.synthesizeUntrackedDiff(content: content, path: "src/foo.swift")

        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        let addLines = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
        XCTAssertEqual(addLines.count, 3,
                       "every line in the file must appear as a '+' addition — none dropped, none duplicated")
    }

    func test_additionLinesMatchFileContent() {
        let content = "line1\nline2\n"
        let result = GitDiff.synthesizeUntrackedDiff(content: content, path: "a.txt")

        XCTAssertTrue(result.contains("+line1\n"),
                      "'+line1' must appear so the viewer shows the real file content")
        XCTAssertTrue(result.contains("+line2\n"),
                      "'+line2' must appear so the viewer shows the real file content")
    }

    // MARK: header — sane unified-diff structure for colorizer compatibility

    func test_headerContainsDiffGitLine() {
        let result = GitDiff.synthesizeUntrackedDiff(content: "x\n", path: "p/q.txt")
        XCTAssertTrue(result.hasPrefix("diff --git a/p/q.txt b/p/q.txt\n"),
                      "diff --git header must be first so DiffLineKind.classify colours it as .header")
    }

    func test_headerContainsDevNullMinusLine() {
        let result = GitDiff.synthesizeUntrackedDiff(content: "x\n", path: "p/q.txt")
        XCTAssertTrue(result.contains("--- /dev/null\n"),
                      "'--- /dev/null' marks the old-file side of an all-addition patch")
    }

    func test_headerContainsPlusPlusPlus() {
        let result = GitDiff.synthesizeUntrackedDiff(content: "x\n", path: "p/q.txt")
        XCTAssertTrue(result.contains("+++ b/p/q.txt\n"),
                      "'+++ b/<path>' identifies the new file for viewers and tooling")
    }

    func test_hunkHeaderReflectsLineCount() {
        let content = "a\nb\nc\n"
        let result = GitDiff.synthesizeUntrackedDiff(content: content, path: "f.txt")
        XCTAssertTrue(result.contains("@@ -0,0 +1,3 @@\n"),
                      "hunk header line count must match actual file lines so viewers parse it correctly")
    }

    func test_hunkHeaderForSingleLine() {
        let result = GitDiff.synthesizeUntrackedDiff(content: "only\n", path: "f.txt")
        XCTAssertTrue(result.contains("@@ -0,0 +1,1 @@\n"),
                      "single-line file must report +1,1 in the hunk header")
    }

    // MARK: binary guard

    func test_binaryContent_returnsEmpty() {
        let binaryContent = "not\0binary"
        let result = GitDiff.synthesizeUntrackedDiff(content: binaryContent, path: "img.png")
        XCTAssertEqual(result, "",
                       "binary content (NUL byte) must return empty so the panel falls through to the binary label")
    }

    // MARK: large-file guard

    func test_contentExceedingMaxLines_returnsEmpty() {
        // Build content with maxLines+1 lines using a low custom cap so the
        // test stays fast.
        let overLimit = (0...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
        let result = GitDiff.synthesizeUntrackedDiff(content: overLimit, path: "big.txt", maxLines: 10)
        XCTAssertEqual(result, "",
                       "files exceeding maxLines must return empty to avoid TextKit layout spikes")
    }

    func test_contentAtExactMaxLines_isAllowed() {
        let atLimit = (1...5).map { "line\($0)" }.joined(separator: "\n") + "\n"
        let result = GitDiff.synthesizeUntrackedDiff(content: atLimit, path: "ok.txt", maxLines: 5)
        XCTAssertFalse(result.isEmpty,
                       "a file at exactly maxLines must be rendered — the guard is strictly greater-than")
    }

    // MARK: empty file edge case

    func test_emptyFile_producesHeaderOnly() {
        let result = GitDiff.synthesizeUntrackedDiff(content: "", path: "empty.txt")
        // An empty file has 0 content lines; the hunk still appears with count 0.
        XCTAssertTrue(result.contains("diff --git"),
                      "even an empty untracked file must get a header so the panel isn't blank")
        let addLines = result.components(separatedBy: "\n").filter {
            $0.hasPrefix("+") && !$0.hasPrefix("+++")
        }
        XCTAssertEqual(addLines.count, 0,
                       "an empty file must have zero addition lines — no phantom content")
    }

    /// WHY (DIFF-UNCAPPED): selecting a 10 MiB untracked file used to
    /// `Data(contentsOf:)` the whole blob before synthesis. The reload path
    /// must FileHandle-prefix at the 512 KiB preview cap.
    func test_reloadDiff_untrackedRead_usesBoundedFileHandlePrefix() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Surfaces/DiffPanelSurface.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let marker = try XCTUnwrap(source.range(of: "public func reloadDiff()"))
        let rest = source[marker.lowerBound...]
        let end = rest.range(of: "\n    public func switchBranch")?.lowerBound ?? rest.endIndex
        let chunk = String(source[marker.lowerBound..<end])
        XCTAssertFalse(
            chunk.contains("Data(contentsOf: URL") || chunk.contains("Data(contentsOf: url"),
            "untracked reload must not load the whole file into Data"
        )
        XCTAssertTrue(
            chunk.contains("GitDiff.readFilePrefix"),
            "untracked reload must FileHandle-prefix via GitDiff.readFilePrefix"
        )
        XCTAssertTrue(
            chunk.contains("GitDiff.untrackedDiffPreviewByteCap"),
            "untracked reload must cap at FilePreviewSurface.maxTextPreviewBytes (512 KiB)"
        )
        XCTAssertTrue(
            chunk.contains("String(decoding: data, as: UTF8.self)"),
            "prefix decode must keep a valid UTF-8 head instead of nil on a mid-scalar cut"
        )
        XCTAssertEqual(GitDiff.untrackedDiffPreviewByteCap, 512 * 1024)
    }
}
