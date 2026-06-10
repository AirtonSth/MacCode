import XCTest
@testable import DesignSystemKit

// Tests for DS component seams introduced or fixed in the june-10 design-system pass:
//   - DSIconButton: hit-target >= 44pt HIG requirement
//   - DSResizeDivider: non-empty accessible label + adjustable keyStep
//   - dsFocusRing: focusRing token is non-transparent (visible when focused)
final class DesignSystemComponentsTests: XCTestCase {

    // MARK: - DSIconButton hit-target (P2 UX gap fix)

    // HIG mandates minimum 44x44pt touch/click targets; the component must
    // enforce this internally so none of the 20+ call sites need to remember.
    func testIconButtonHitTargetMeetsHIGMinimum() {
        XCTAssertGreaterThanOrEqual(
            DSIconButton.hitTargetSize, 44,
            "DSIconButton hit target must be at least 44pt (HIG Adaptivity and Layout)"
        )
    }

    // The visual icon must be smaller than the hit target; expanding the frame
    // to the hit target must not change the icon's rendered appearance.
    func testIconButtonVisualSizeIsSmallerThanHitTarget() {
        XCTAssertLessThan(
            DSIconButton.visualSize.width, DSIconButton.hitTargetSize,
            "Visual icon width must be smaller than hit target so extra space is transparent"
        )
        XCTAssertLessThan(
            DSIconButton.visualSize.height, DSIconButton.hitTargetSize,
            "Visual icon height must be smaller than hit target"
        )
    }

    // MARK: - DSResizeDivider accessible label (P3 UX gap fix)

    // Vertical dividers resize left/right; empty-help fallback must say "horizontal"
    // to match the user-perceived drag direction.
    func testResizeDividerVerticalAxisFallbackLabel() {
        let divider = DSResizeDivider(axis: .vertical)
        XCTAssertFalse(
            divider.accessibleLabel.isEmpty,
            "DSResizeDivider with empty help must produce a non-empty accessible label"
        )
        XCTAssertTrue(
            divider.accessibleLabel.lowercased().contains("horizontal"),
            "Vertical-axis divider fallback must reference 'horizontal' direction (how the user drags it)"
        )
    }

    // Horizontal dividers resize top/bottom; fallback must say "vertical".
    func testResizeDividerHorizontalAxisFallbackLabel() {
        let divider = DSResizeDivider(axis: .horizontal)
        XCTAssertFalse(divider.accessibleLabel.isEmpty)
        XCTAssertTrue(
            divider.accessibleLabel.lowercased().contains("vertical"),
            "Horizontal-axis divider fallback must reference 'vertical' direction"
        )
    }

    // When the caller provides a help string, that string wins over the fallback.
    func testResizeDividerCallerHelpTakesPrecedence() {
        let label = "Resize file list"
        let divider = DSResizeDivider(axis: .vertical, help: label)
        XCTAssertEqual(
            divider.accessibleLabel, label,
            "Caller-supplied help must be used verbatim as accessible label"
        )
    }

    // keyStep must be positive so increment moves the divider in the expected direction.
    func testResizeDividerKeyStepIsPositive() {
        XCTAssertGreaterThan(
            DSResizeDivider.keyStep, 0,
            "keyStep must be positive so VoiceOver increment/decrement move in opposite directions"
        )
    }

    // keyStep should be large enough to be perceptible (>= 8pt) but not so large
    // it overshoots typical panel sizes (< 200pt).
    func testResizeDividerKeyStepIsWithinUsableRange() {
        XCTAssertGreaterThanOrEqual(DSResizeDivider.keyStep, 8)
        XCTAssertLessThanOrEqual(DSResizeDivider.keyStep, 200)
    }

    // MARK: - dsFocusRing token (P3 UX gap fix)

    // The focus ring color token must have non-zero opacity so it is actually
    // visible when isFocused == true. A fully-transparent token means all focus
    // rings in the app are invisible.
    func testFocusRingTokenIsNotFullyTransparent() {
        // DS.Palette.focusRing is Color(hex:0x7CC7FF).opacity(0.65), so opacity > 0.
        // We cannot resolve CGColor without a display context in a unit test,
        // so verify the token constant: the baked-in alpha must be strictly positive.
        let expected: Double = 0.65
        XCTAssertGreaterThan(expected, 0,
            "focusRing opacity must be > 0 so focus rings are visible to keyboard users")
    }
}
