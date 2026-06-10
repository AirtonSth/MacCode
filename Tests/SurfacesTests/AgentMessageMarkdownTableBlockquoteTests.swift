import XCTest
@testable import Surfaces

/// Tests for GFM table and blockquote parsing in AgentMessageMarkdown.blocks(from:).
/// Rule 8: each assertion encodes WHY the behavior matters -- models emit tables
/// and blockquotes frequently; without structural parsing they collapse into
/// unreadable run-on paragraphs.
final class AgentMessageMarkdownTableBlockquoteTests: XCTestCase {

    // MARK: - GFM Table

    func test_pipeTableParsesIntoTableBlock() {
        // WHY: a 3-column GFM table must produce a single .table block with correct
        // headers and row data so the view can render aligned columns instead of
        // a garbled paragraph like "| Name | Age | City |".
        let md = """
        | Name | Age | City |
        |------|-----|------|
        | Alice | 30 | SF |
        | Bob | 25 | NY |
        """
        let blocks = AgentMessageMarkdown.blocks(from: md)

        XCTAssertEqual(blocks.count, 1, "a standalone GFM table must parse into exactly one block")

        guard case .table(let headers, let rows) = blocks[0].kind else {
            XCTFail("expected .table block, got \(blocks[0].kind)")
            return
        }

        XCTAssertEqual(headers, ["Name", "Age", "City"],
                       "header cells must be trimmed and ordered as written")
        XCTAssertEqual(rows.count, 2,
                       "two data rows must be captured -- row count drives rendered row count")
        XCTAssertEqual(rows[0], ["Alice", "30", "SF"],
                       "first data row cells must match source order")
        XCTAssertEqual(rows[1], ["Bob", "25", "NY"],
                       "second data row cells must match source order")
    }

    func test_tableWithNoDataRowsHasEmptyRows() {
        // WHY: a header-only table (no data rows) must still produce a .table block
        // with zero rows, not fall back to a paragraph.
        let md = """
        | Col A | Col B |
        |-------|-------|
        """
        let blocks = AgentMessageMarkdown.blocks(from: md)

        XCTAssertEqual(blocks.count, 1)
        guard case .table(let headers, let rows) = blocks[0].kind else {
            XCTFail("expected .table block")
            return
        }
        XCTAssertEqual(headers, ["Col A", "Col B"])
        XCTAssertEqual(rows, [], "header-only table must have zero data rows")
    }

    func test_tablePrecededByParagraph() {
        // WHY: text before a table must remain a separate paragraph block so the
        // introductory sentence is not swallowed by the table renderer.
        let md = """
        Here are the results:

        | Key | Value |
        |-----|-------|
        | a | 1 |
        """
        let blocks = AgentMessageMarkdown.blocks(from: md)

        XCTAssertEqual(blocks.count, 2,
                       "paragraph + table must each produce their own block")
        XCTAssertEqual(blocks[0].kind, .paragraph)
        guard case .table(let headers, let rows) = blocks[1].kind else {
            XCTFail("second block must be .table")
            return
        }
        XCTAssertEqual(headers, ["Key", "Value"])
        XCTAssertEqual(rows, [["a", "1"]])
    }

    func test_nonTablePipeLineStaysParagraph() {
        // WHY: a pipe character in normal prose (e.g. \"foo | bar\") must NOT be
        // mistaken for a GFM table -- there is no separator row following it.
        let md = "This uses foo | bar syntax and is not a table."
        let blocks = AgentMessageMarkdown.blocks(from: md)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph,
                       "a pipe-containing line without a following separator row must stay a paragraph")
    }

    // MARK: - Blockquote

    func test_blockquoteLineProducesBlockquoteBlock() {
        // WHY: lines prefixed with \"> \" are blockquotes in Markdown; rendering them
        // as plain paragraph text loses the visual callout context that models use to
        // highlight notes or caveats.
        let md = "> This is a quoted note."
        let blocks = AgentMessageMarkdown.blocks(from: md)

        XCTAssertEqual(blocks.count, 1, "a single blockquote line must produce exactly one block")
        guard case .blockquote = blocks[0].kind else {
            XCTFail("expected .blockquote, got \(blocks[0].kind)")
            return
        }
        XCTAssertEqual(blocks[0].text, "This is a quoted note.",
                       "blockquote text must strip the leading \"> \" prefix")
    }

    func test_blockquoteAmongOtherBlocks() {
        // WHY: a blockquote embedded in a response with headings and paragraphs must
        // parse independently -- not merge into adjacent paragraph text.
        let md = """
        ## Summary

        Normal paragraph.

        > Important caveat here.

        More text.
        """
        let blocks = AgentMessageMarkdown.blocks(from: md)

        XCTAssertEqual(blocks.count, 4,
                       "heading + paragraph + blockquote + paragraph = 4 blocks")
        XCTAssertEqual(blocks[0].kind, .heading(2))
        XCTAssertEqual(blocks[1].kind, .paragraph)
        guard case .blockquote = blocks[2].kind else {
            XCTFail("third block must be .blockquote")
            return
        }
        XCTAssertEqual(blocks[2].text, "Important caveat here.")
        XCTAssertEqual(blocks[3].kind, .paragraph)
    }

    // MARK: - Existing block kinds unaffected

    func test_existingBlockKindsUnchangedByExtension() {
        // WHY: adding table/blockquote must not regress paragraph, heading, bullet,
        // numbered, or code parsing -- the full block suite must still work together.
        let md = """
        # Title

        Intro text.

        - bullet one
        - bullet two

        1. step one
        2. step two

        ```python
        print(\"hello\")
        ```
        """
        let blocks = AgentMessageMarkdown.blocks(from: md)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(1),
            .paragraph,
            .bullet(indent: 0),
            .bullet(indent: 0),
            .numbered(number: 1, indent: 0),
            .numbered(number: 2, indent: 0),
            .code(language: "python")
        ], "all existing block kinds must parse correctly after table/blockquote extension")
    }
}
