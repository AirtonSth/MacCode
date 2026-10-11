import XCTest
import SwiftUI
@testable import DesignSystemKit

// MARK: - dsHoverFill (pure fill decision + source guard)
//
// WHY: on a pointer platform the row under the cursor has to answer, and the
// thread rail, the Bots roster and the compact menu rows had no hover state at
// all. They now share one modifier. These tests pin the two rules a caller
// relies on: hover never repaints a selected row, and the fill is instant.

final class DSHoverFillTests: XCTestCase {

    func test_hoveredUnselectedRowGetsTheHoverToken_becauseTheRowUnderThePointerMustAnswer() {
        XCTAssertEqual(DSHoverFill.fill(isHovering: true, enabled: true), DS.Palette.hover)
        XCTAssertNotEqual(
            DS.Palette.hover,
            Color.clear,
            "a clear hover token would make the hovered row look like every other row"
        )
    }

    func test_hoveredSelectedRowStaysClear_becauseSelectionOwnsItsFill() {
        // WHY: callers pass enabled: !selected. The selected row already
        // paints DS.Palette.selection (or the Bot's own colour); a hover layer
        // on top would shift that colour every time the pointer crosses it.
        XCTAssertEqual(DSHoverFill.fill(isHovering: true, enabled: false), Color.clear)
    }

    func test_rowAwayFromThePointerHasNoFill_becauseOnlyOneRowIsUnderThePointer() {
        XCTAssertEqual(DSHoverFill.fill(isHovering: false, enabled: true), Color.clear)
        XCTAssertEqual(DSHoverFill.fill(isHovering: false, enabled: false), Color.clear)
    }

    func test_modifierPaintsTheDecisionWithNoAnimation_becauseHoverIsInstantOnTheMac() throws {
        // WHY: the decision above is only worth pinning if the modifier
        // paints it, and a fade on hover makes a row that is crossed hundreds
        // of times a day feel late. DSIconButton already answers in one frame.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DesignSystemKit/Components.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "// MARK: - Hover fill"), "hover fill section not found")
        let end = try XCTUnwrap(
            source.range(of: "// MARK: - Surface containers", range: start.upperBound..<source.endIndex),
            "hover fill section must end at the surface containers"
        )
        let section = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(
            section.contains("func dsHoverFill(enabled: Bool = true, cornerRadius: CGFloat = DS.Radius.control)"),
            "rows call dsHoverFill(enabled:cornerRadius:)"
        )
        XCTAssertTrue(
            section.contains(".fill(DSHoverFill.fill(isHovering: hovering, enabled: enabled))"),
            "the modifier must paint what the decision returns"
        )
        XCTAssertTrue(section.contains(".onHover { hovering = $0 }"))
        XCTAssertFalse(section.contains(".animation("), "hover fill must not animate")
        XCTAssertFalse(section.contains("withAnimation"), "hover fill must not animate")
        XCTAssertFalse(section.contains(".transition("), "hover fill must not animate")
    }
}
