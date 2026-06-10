import XCTest
import CoreModel
@testable import AppShell

// Tests for P3 polish: tooltip string, half-tab drop placement.
// Both helpers are pure nonisolated static -- no MainActor needed.
final class PaneTabsP3PolishTests: XCTestCase {

    // MARK: - tabTooltipString

    // WHY: tooltip must surface the full title so truncated tabs remain
    // discoverable via hover; type label must identify the surface kind.

    func test_tooltipString_containsTitle() {
        let result = PaneTabsView.tabTooltipString(title: "My Terminal", type: .terminal)
        XCTAssertTrue(result.contains("My Terminal"),
                      "tooltip must contain the tab title so hovered truncated tabs are identifiable")
    }

    func test_tooltipString_containsTypeLabel_terminal() {
        let result = PaneTabsView.tabTooltipString(title: "t", type: .terminal)
        XCTAssertTrue(result.contains("Terminal"),
                      "terminal surface tooltip must include the type label 'Terminal'")
    }

    func test_tooltipString_containsTypeLabel_ssh() {
        let result = PaneTabsView.tabTooltipString(title: "t", type: .ssh)
        XCTAssertTrue(result.contains("SSH"),
                      "ssh surface tooltip must include the type label 'SSH'")
    }

    func test_tooltipString_containsTypeLabel_browser() {
        let result = PaneTabsView.tabTooltipString(title: "t", type: .browser)
        XCTAssertTrue(result.contains("Browser"),
                      "browser surface tooltip must include the type label 'Browser'")
    }

    func test_tooltipString_containsTypeLabel_agentApp() {
        let result = PaneTabsView.tabTooltipString(title: "t", type: .agentApp)
        XCTAssertTrue(result.contains("Agent App"),
                      "agentApp surface tooltip must include the type label 'Agent App'")
    }

    func test_tooltipString_containsTypeLabel_files() {
        let result = PaneTabsView.tabTooltipString(title: "t", type: .files)
        XCTAssertTrue(result.contains("Files"),
                      "files surface tooltip must include the type label 'Files'")
    }

    func test_tooltipString_containsTypeLabel_markdown() {
        let result = PaneTabsView.tabTooltipString(title: "t", type: .markdown)
        XCTAssertTrue(result.contains("Markdown"),
                      "markdown surface tooltip must include the type label 'Markdown'")
    }

    func test_tooltipString_containsTypeLabel_filePreview() {
        let result = PaneTabsView.tabTooltipString(title: "t", type: .filePreview)
        XCTAssertTrue(result.contains("File Preview"),
                      "filePreview surface tooltip must include the type label 'File Preview'")
    }

    func test_tooltipString_containsTypeLabel_rightSidebarTool() {
        let result = PaneTabsView.tabTooltipString(title: "t", type: .rightSidebarTool)
        XCTAssertTrue(result.contains("Git"),
                      "rightSidebarTool surface tooltip must include the type label 'Git'")
    }

    func test_tooltipString_titleAndTypeBothPresent() {
        // WHY: a tooltip that shows only one part is useless; verify both appear together
        let result = PaneTabsView.tabTooltipString(title: "Prod SSH", type: .ssh)
        XCTAssertTrue(result.contains("Prod SSH") && result.contains("SSH"),
                      "tooltip must contain both title and type label simultaneously")
    }

    // MARK: - halfTabDropIndex

    // WHY: drops in the left half of a tab frame should insert BEFORE that
    // tab (keeps spatial expectation: "drop left side = insert left").
    // Drops in the right half insert AFTER (index + 1).

    func test_halfDrop_leftHalf_returnsIndex() {
        // frame at x=100, width=80 -> midX=140; pointer at 120 (left half)
        let frame = NSRect(x: 100, y: 0, width: 80, height: 34)
        let result = PaneTabsView.halfTabDropIndex(pointerX: 120, tabFrame: frame, index: 2)
        XCTAssertEqual(result, 2,
                       "pointer in left half must return tab index (insert before), not index+1")
    }

    func test_halfDrop_rightHalf_returnsIndexPlusOne() {
        // frame at x=100, width=80 -> midX=140; pointer at 160 (right half)
        let frame = NSRect(x: 100, y: 0, width: 80, height: 34)
        let result = PaneTabsView.halfTabDropIndex(pointerX: 160, tabFrame: frame, index: 2)
        XCTAssertEqual(result, 3,
                       "pointer in right half must return index+1 (insert after), not index")
    }

    func test_halfDrop_exactlyAtMidX_returnsIndexPlusOne() {
        // midX boundary: pointer == midX is treated as right half (not strictly <)
        let frame = NSRect(x: 0, y: 0, width: 100, height: 34)
        let result = PaneTabsView.halfTabDropIndex(pointerX: 50, tabFrame: frame, index: 0)
        XCTAssertEqual(result, 1,
                       "pointer at exact midX must resolve to right half (index+1) per strict-less-than rule")
    }

    func test_halfDrop_firstTab_leftHalf_returnsZero() {
        // WHY: drop on left half of the first tab must yield 0 (prepend), not a negative index
        let frame = NSRect(x: 0, y: 0, width: 120, height: 34)
        let result = PaneTabsView.halfTabDropIndex(pointerX: 40, tabFrame: frame, index: 0)
        XCTAssertEqual(result, 0,
                       "left-half drop on first tab must yield insertion index 0 (prepend)")
    }

    func test_halfDrop_lastTab_rightHalf_returnsCount() {
        // WHY: drop on right half of the last tab (index N-1) must yield N (append),
        // matching the existing append-drop semantics of dropInsertionIndex.
        let frame = NSRect(x: 400, y: 0, width: 100, height: 34)
        let lastIndex = 4 // 5-tab strip, indices 0..4
        let result = PaneTabsView.halfTabDropIndex(pointerX: 460, tabFrame: frame, index: lastIndex)
        XCTAssertEqual(result, 5,
                       "right-half drop on last tab must yield count (append position)")
    }
}
