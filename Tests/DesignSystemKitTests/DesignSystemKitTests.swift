import XCTest
import CoreGraphics
@testable import DesignSystemKit

// MARK: - DS.Space rhythm

/// Pins the 4/8 spacing rhythm token values.
/// WHY: views compose spacing constants at call sites — a silent rename or
/// value change breaks layout without a compile error.  These guard the
/// token contract so refactors fail loudly.
final class DSSpaceTests: XCTestCase {

    func test_xxs_is2() {
        XCTAssertEqual(DS.Space.xxs, 2, "xxs must be 2pt — base of the 4/8 rhythm")
    }

    func test_xs_is4() {
        XCTAssertEqual(DS.Space.xs, 4)
    }

    func test_sm_is6() {
        XCTAssertEqual(DS.Space.sm, 6)
    }

    func test_md_is8() {
        XCTAssertEqual(DS.Space.md, 8, "md must be 8pt — primary unit of the 4/8 rhythm")
    }

    func test_lg_is12() {
        XCTAssertEqual(DS.Space.lg, 12)
    }

    func test_xl_is16() {
        XCTAssertEqual(DS.Space.xl, 16)
    }

    func test_xxl_is20() {
        XCTAssertEqual(DS.Space.xxl, 20)
    }

    func test_xxxl_is24() {
        XCTAssertEqual(DS.Space.xxxl, 24)
    }

    func test_huge_is32() {
        XCTAssertEqual(DS.Space.huge, 32)
    }
}

// MARK: - DS.Radius

/// Pins radius token values.
/// WHY: corner-radius tokens appear in clipping masks and overlays; a drift
/// causes visible mismatches between the background and the stroke.
final class DSRadiusTests: XCTestCase {

    func test_control_is5() {
        XCTAssertEqual(DS.Radius.control, 5)
    }

    func test_card_is7() {
        XCTAssertEqual(DS.Radius.card, 7)
    }

    func test_panel_is9() {
        XCTAssertEqual(DS.Radius.panel, 9)
    }

    func test_modal_is12() {
        XCTAssertEqual(DS.Radius.modal, 12)
    }

    func test_pill_isVeryLarge() {
        // Must be large enough that it always produces a capsule on any
        // realistically-sized element (<= a screen width).
        XCTAssertGreaterThanOrEqual(DS.Radius.pill, 999,
                                    "pill must always exceed real dimensions — any smaller breaks capsule corners")
    }
}

// MARK: - DS.Control

final class DSControlTests: XCTestCase {

    func test_sidebarSearchHeight_is30() {
        // WHY: Workspaces filter and Search bots share this token so the
        // Agentic | Bots sidebar modes cannot paint different-sized boxes.
        XCTAssertEqual(DS.Control.sidebarSearchHeight, 30)
    }
}

// MARK: - DS.Border

final class DSBorderTests: XCTestCase {

    func test_hairline_is1() {
        XCTAssertEqual(DS.Border.hairline, 1, "hairline must be exactly 1pt — the design rule prohibits thicker borders on content")
    }
}

// MARK: - DS.ResizeDivider

final class DSResizeDividerTests: XCTestCase {

    func test_thickness_is5() {
        XCTAssertEqual(DS.ResizeDivider.thickness, 5)
    }

    func test_gripThickness_is2() {
        XCTAssertEqual(DS.ResizeDivider.gripThickness, 2)
    }

    func test_gripLength_is28() {
        XCTAssertEqual(DS.ResizeDivider.gripLength, 28)
    }
}

// MARK: - DS.Alpha

final class DSAlphaTests: XCTestCase {

    func test_disabled_is0_38() {
        XCTAssertEqual(DS.Alpha.disabled, 0.38, accuracy: 0.001,
                       "disabled opacity must match WCAG minimum contrast ratio intent (0.38)")
    }

    func test_hoverDelta_isPositive_andSmall() {
        XCTAssertGreaterThan(DS.Alpha.hoverDelta, 0,
                             "hover delta must be additive — a zero delta means hover is invisible")
        XCTAssertLessThan(DS.Alpha.hoverDelta, 0.5,
                          "hover delta must not overwhelm the base layer — it is additive, not a replacement")
    }
}

// MARK: - DSButtonOpacity (pure logic seam)

/// WHY: DSButtonOpacity.effectiveOpacity is the single source of truth for
/// DS button interaction states.  A disabled-beats-hover inversion would
/// show enabled-style opacity on a disabled button.
final class DSButtonOpacityTests: XCTestCase {

    func test_disabled_returnsAlphaDisabled() {
        let result = DSButtonOpacity.effectiveOpacity(isEnabled: false, isHovering: false)
        XCTAssertEqual(result, DS.Alpha.disabled, accuracy: 0.001,
                       "disabled state must return DS.Alpha.disabled regardless of hover")
    }

    func test_disabled_beats_hover() {
        // WHY: hover must not override disabled — WCAG contrast rule.
        let result = DSButtonOpacity.effectiveOpacity(isEnabled: false, isHovering: true)
        XCTAssertEqual(result, DS.Alpha.disabled, accuracy: 0.001,
                       "hovering a disabled button must not raise its opacity above the disabled floor")
    }

    func test_normal_returns1() {
        let result = DSButtonOpacity.effectiveOpacity(isEnabled: true, isHovering: false)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func test_hovering_clampsTo1() {
        // hoverDelta > 0, so 1.0 + hoverDelta > 1.0 — must be clamped.
        let result = DSButtonOpacity.effectiveOpacity(isEnabled: true, isHovering: true)
        XCTAssertLessThanOrEqual(result, 1.0,
                                 "hover opacity must not exceed 1.0 — values above 1.0 have no visual effect and indicate a logic error")
        XCTAssertGreaterThan(result, DS.Alpha.disabled,
                             "hovering an enabled button must produce opacity above the disabled floor")
    }
}

// MARK: - DSPill.iconName (pure logic seam)

/// WHY: iconName drives WCAG 1.4.1 (Use of Color) compliance — semantic
/// states must convey meaning via icon+shape, not color alone.  A nil where
/// a symbol is expected (or vice versa) silently breaks the accessibility contract.
final class DSPillIconNameTests: XCTestCase {

    func test_neutral_returnsNil() {
        XCTAssertNil(DSPill.iconName(for: .neutral),
                     "neutral tone carries no distinct semantic state — no icon needed")
    }

    func test_accent_returnsNil() {
        XCTAssertNil(DSPill.iconName(for: .accent),
                     "accent tone is decorative — no semantic icon")
    }

    func test_success_returnsCheckmark() {
        let name = DSPill.iconName(for: .success)
        XCTAssertNotNil(name, "success must supply an icon for WCAG 1.4.1 compliance")
        XCTAssertTrue(name?.contains("checkmark") == true,
                      "success icon must be a checkmark variant")
    }

    func test_warning_returnsExclamation() {
        let name = DSPill.iconName(for: .warning)
        XCTAssertNotNil(name, "warning must supply an icon for WCAG 1.4.1 compliance")
        XCTAssertTrue(name?.contains("exclamationmark") == true,
                      "warning icon must be an exclamationmark variant")
    }

    func test_danger_returnsXmark() {
        let name = DSPill.iconName(for: .danger)
        XCTAssertNotNil(name, "danger must supply an icon for WCAG 1.4.1 compliance")
        XCTAssertTrue(name?.contains("xmark") == true,
                      "danger icon must be an xmark variant")
    }
}

// MARK: - DSSectionHeaderG.displayTitle (pure logic seam)

/// WHY: displayTitle is a testable seam explicitly added so tests can verify
/// the uppercasing transform without a View host.  If the seam drifts from
/// the real render (Text(title.uppercased())), section titles would silently
/// mismatch between tests and production.
final class DSSectionHeaderDisplayTitleTests: XCTestCase {

    func test_lowercaseInput_uppercased() {
        XCTAssertEqual(DSSectionHeaderG<Never>.displayTitle(for: "workspaces"), "WORKSPACES")
    }

    func test_mixedCaseInput_uppercased() {
        XCTAssertEqual(DSSectionHeaderG<Never>.displayTitle(for: "Recent Files"), "RECENT FILES")
    }

    func test_alreadyUppercase_unchanged() {
        XCTAssertEqual(DSSectionHeaderG<Never>.displayTitle(for: "SETTINGS"), "SETTINGS")
    }

    func test_emptyString_returnsEmpty() {
        XCTAssertEqual(DSSectionHeaderG<Never>.displayTitle(for: ""), "")
    }
}

// MARK: - AdaptiveSidebarPolicy

/// WHY: the sidebar auto-hide policy is pure arithmetic — the only source of
/// truth for when the sidebar collapses or reappears.  An off-by-one in the
/// hysteresis comparison silently degrades layout on edge-case window widths.
final class AdaptiveSidebarPolicyTests: XCTestCase {

    // Forced intents bypass auto logic entirely.

    func test_forcedHidden_alwaysHides() {
        let d = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 1200, contentMinimumExtent: 300, sidebarExtent: 220,
            currentVisible: true, intent: .forcedHidden, event: .structural,
            now: 0, lastAutomaticChange: nil
        )
        XCTAssertFalse(d.isVisible, "forcedHidden must hide regardless of available space")
    }

    func test_forcedVisible_hideWhenTooNarrow() {
        // hardMinimum = contentMinimum * 0.72; sidebar + hard minimum > available => collapse.
        let d = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 300, contentMinimumExtent: 300, sidebarExtent: 220,
            currentVisible: false, intent: .forcedVisible, event: .structural,
            now: 0, lastAutomaticChange: nil
        )
        // 300 - 220 = 80 < 300 * 0.72 = 216 => must hide.
        XCTAssertFalse(d.isVisible,
                       "forcedVisible must still collapse if the available extent cannot preserve a usable content region")
    }

    func test_forcedVisible_showsWhenWide() {
        let d = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 1200, contentMinimumExtent: 300, sidebarExtent: 220,
            currentVisible: false, intent: .forcedVisible, event: .structural,
            now: 0, lastAutomaticChange: nil
        )
        XCTAssertTrue(d.isVisible)
    }

    // Auto intent — collapse when content would be squeezed below minimum.

    func test_auto_collapsesWhenContentBelowMinimum() {
        let d = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 400, contentMinimumExtent: 300, sidebarExtent: 220,
            currentVisible: true, intent: .auto, event: .structural,
            now: 10, lastAutomaticChange: nil
        )
        // 400 - 220 = 180 < 300 => sidebar steals content space => must hide.
        XCTAssertFalse(d.isVisible)
        XCTAssertTrue(d.didChangeAutomatically)
    }

    func test_auto_revealsAfterHysteresis() {
        let hysteresis: CGFloat = 120
        // availableExtent - sidebarExtent = 500; contentMinimum = 300; 500 >= 300+120 => show.
        let d = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 740, contentMinimumExtent: 300, sidebarExtent: 220,
            currentVisible: false, intent: .auto, event: .structural,
            now: 10, lastAutomaticChange: nil,
            hysteresis: hysteresis
        )
        XCTAssertTrue(d.isVisible,
                      "sidebar must reappear once available extent exceeds contentMinimum + hysteresis")
    }

    func test_auto_doesNotRevealBelowHysteresis() {
        // availableExtent - sidebarExtent = 380; contentMinimum = 300; 380 < 300+120 => keep hidden.
        let d = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 600, contentMinimumExtent: 300, sidebarExtent: 220,
            currentVisible: false, intent: .auto, event: .structural,
            now: 10, lastAutomaticChange: nil,
            hysteresis: 120
        )
        XCTAssertFalse(d.isVisible,
                       "sidebar must stay hidden until the hysteresis threshold is cleared — prevents flutter")
    }

    func test_auto_cooldownSuppressesResizeEvent() {
        // A resize within the cooldown window must NOT auto-change visibility.
        let d = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 400, contentMinimumExtent: 300, sidebarExtent: 220,
            currentVisible: true, intent: .auto, event: .resize,
            now: 1.0, lastAutomaticChange: 0.5,   // elapsed = 0.5s < 2s cooldown
            cooldown: 2
        )
        XCTAssertTrue(d.isVisible,
                      "a resize event within the cooldown window must not trigger auto-hide — prevents thrash on live resize")
        XCTAssertFalse(d.didChangeAutomatically)
    }

    func test_auto_structuralEventBypassesCooldown() {
        // A structural event (tab open/close) always re-evaluates even if recent.
        let d = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 400, contentMinimumExtent: 300, sidebarExtent: 220,
            currentVisible: true, intent: .auto, event: .structural,
            now: 0.1, lastAutomaticChange: 0.0,
            cooldown: 2
        )
        // 400 - 220 = 180 < 300 => should collapse despite tiny elapsed.
        XCTAssertFalse(d.isVisible,
                       "structural events must bypass the resize cooldown — tab open/close must be responded to immediately")
    }

    func test_auto_noChangeWhenAlreadyFits() {
        // Sidebar visible, plenty of room: no change.
        let d = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 1200, contentMinimumExtent: 300, sidebarExtent: 220,
            currentVisible: true, intent: .auto, event: .resize,
            now: 10, lastAutomaticChange: nil
        )
        XCTAssertTrue(d.isVisible)
        XCTAssertFalse(d.didChangeAutomatically)
    }
}
