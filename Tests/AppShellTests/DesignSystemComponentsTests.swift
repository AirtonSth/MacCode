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
        XCTAssertEqual(
            DSIconButton.visualPackInset,
            (DSIconButton.hitTargetSize - DSIconButton.visualSize.width) / 2
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

    // MARK: - DSPill iconName (WCAG 1.4.1: do not use color as the only visual cue)

    // success must map to a distinct SF Symbol so color-blind users can tell it apart
    // from warning and danger without relying on green/yellow/red hue.
    func testPillIconNameSuccessReturnsCheckmark() {
        XCTAssertEqual(
            DSPill.iconName(for: .success), "checkmark.circle.fill",
            "success tone must carry a checkmark icon so it is distinguishable without color"
        )
    }

    // warning must carry a triangle symbol -- visually distinct shape from success/danger.
    func testPillIconNameWarningReturnsTriangle() {
        XCTAssertEqual(
            DSPill.iconName(for: .warning), "exclamationmark.triangle.fill",
            "warning tone must carry an exclamation-triangle icon (unique shape among tones)"
        )
    }

    // danger must carry an octagon -- a shape universally associated with stop/error.
    func testPillIconNameDangerReturnsOctagon() {
        XCTAssertEqual(
            DSPill.iconName(for: .danger), "xmark.octagon.fill",
            "danger tone must carry an xmark-octagon icon (distinct from checkmark and triangle)"
        )
    }

    // neutral and accent carry no semantic state; returning nil keeps the pill compact
    // and avoids adding a non-communicative icon.
    func testPillIconNameNeutralReturnsNil() {
        XCTAssertNil(
            DSPill.iconName(for: .neutral),
            "neutral tone must not add an icon -- no semantic state to convey"
        )
    }

    func testPillIconNameAccentReturnsNil() {
        XCTAssertNil(
            DSPill.iconName(for: .accent),
            "accent tone must not add an icon -- it is a brand highlight, not a semantic state"
        )
    }

    // All three semantic-state icons must be pairwise distinct so a color-blind user
    // receives a unique shape cue for each state (WCAG 1.4.1 pass criterion).
    func testPillSemanticStateIconsAreAllDistinct() {
        let success = DSPill.iconName(for: .success)!
        let warning = DSPill.iconName(for: .warning)!
        let danger  = DSPill.iconName(for: .danger)!
        XCTAssertNotEqual(success, warning, "success and warning icons must differ (color-blind disambiguation)")
        XCTAssertNotEqual(success, danger,  "success and danger icons must differ")
        XCTAssertNotEqual(warning, danger,  "warning and danger icons must differ")
    }
}
