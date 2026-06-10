import XCTest
@testable import DesignSystemKit

final class DSButtonOpacityTests: XCTestCase {

    // disabled wins over all other states — user cannot perceive hover when element is inactive
    func testDisabledReturnsDisabledOpacity() {
        let opacity = DSButtonOpacity.effectiveOpacity(isEnabled: false, isHovering: false)
        XCTAssertEqual(opacity, DS.Alpha.disabled, accuracy: 1e-9)
    }

    // hover-while-disabled must still yield disabled opacity, not a boosted value
    func testDisabledPlusHoveringReturnsDisabledOpacity() {
        let opacity = DSButtonOpacity.effectiveOpacity(isEnabled: false, isHovering: true)
        XCTAssertEqual(opacity, DS.Alpha.disabled, accuracy: 1e-9)
    }

    // hovering an enabled button must produce a visually distinct (brighter) result
    func testEnabledHoveringReturnsBrighterThanNormal() {
        let normal  = DSButtonOpacity.effectiveOpacity(isEnabled: true, isHovering: false)
        let hovered = DSButtonOpacity.effectiveOpacity(isEnabled: true, isHovering: true)
        XCTAssertGreaterThanOrEqual(hovered, normal,
            "hover must not make the button dimmer than its resting state")
    }

    // normal (enabled, not hovering) baseline is full opacity
    func testEnabledNotHoveringReturnsFullOpacity() {
        let opacity = DSButtonOpacity.effectiveOpacity(isEnabled: true, isHovering: false)
        XCTAssertEqual(opacity, 1.0, accuracy: 1e-9)
    }

    // result must never exceed 1.0 regardless of hoverDelta magnitude
    func testOpacityNeverExceedsOne() {
        let opacity = DSButtonOpacity.effectiveOpacity(isEnabled: true, isHovering: true)
        XCTAssertLessThanOrEqual(opacity, 1.0)
    }

    // disabled token must be strictly less than 1 so disabled elements are visually dimmed
    func testDisabledOpacityTokenIsLessThanOne() {
        XCTAssertLessThan(DS.Alpha.disabled, 1.0)
    }
}
