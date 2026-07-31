import XCTest
@testable import Surfaces
@testable import AgentRuntime

/// Pure-seam coverage for the Token Saver per-thread savings footer under final replies.
final class TokenSaverThreadFooterTests: XCTestCase {
    func test_footerText_disabled_returnsNil() {
        // WHY: Token Saver is paid — never teaser a savings claim while off.
        XCTAssertNil(AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 100_000,
            measuredTokens: 100_000,
            enabled: false
        ))
    }

    func test_footerText_zeroSaved_returnsNil() {
        // WHY: empty chip under every answer is noise; only show when total > 0.
        XCTAssertNil(AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 0,
            measuredTokens: 0,
            enabled: true
        ))
    }

    func test_footerText_zeroMeasured_evenWithDisplayEstimate_returnsNil() {
        // WHY: estimates may only raise a proven ledger figure — never invent a
        // savings chip from assistant text alone (measured == 0).
        XCTAssertNil(AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 12_000,
            measuredTokens: 0,
            enabled: true
        ))
    }

    func test_footerText_measuredOnly_usesLedgerNotProviderUsageCopy() {
        // WHY: chip must not be read as total provider/context usage (e.g. 6.6M).
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 100_000,
            measuredTokens: 100_000,
            enabled: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 100K tool-output tokens saved (local ledger; not total provider usage)"
        )
    }

    func test_footerText_estimatedAboveMeasured_stillUsesLedgerScopeCopy() {
        // WHY: figure may include dialect/graphify legs; still tool-output ledger scope.
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 150_000,
            measuredTokens: 100_000,
            enabled: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 150K tool-output tokens saved (local ledger; not total provider usage)"
        )
    }

    func test_footerText_autoRouting_usesPlusAutoNote() {
        // WHY: product-locked Auto note with same-quality cheaper models.
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 3_100,
            measuredTokens: 2_000,
            enabled: true,
            autoRoutingActive: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 3.1K tool-output tokens saved (local ledger; not total provider usage) + Auto used cheaper models at the same quality"
        )
    }

    func test_footerText_autoRouting_measuredOnly_sameForm() {
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 3_100,
            measuredTokens: 3_100,
            enabled: true,
            autoRoutingActive: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 3.1K tool-output tokens saved (local ledger; not total provider usage) + Auto used cheaper models at the same quality"
        )
    }

    func test_footerText_accumulation_updatesAmount() {
        // WHY: the single chip shows the running thread total as savings grow.
        let first = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 12_500,
            measuredTokens: 12_500,
            enabled: true
        )
        let later = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 410_000,
            measuredTokens: 410_000,
            enabled: true
        )
        XCTAssertEqual(
            first,
            "Token Saver: 12.5K tool-output tokens saved (local ledger; not total provider usage)"
        )
        XCTAssertEqual(
            later,
            "Token Saver: 410K tool-output tokens saved (local ledger; not total provider usage)"
        )
        XCTAssertNotEqual(first, later)
    }

    func test_footerText_explicitlySeparatesFromProviderUsage() {
        // WHY: item 4 — never present ledger chip as total provider actualTokens.
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 3_800,
            measuredTokens: 3_399,
            enabled: true
        )!
        XCTAssertTrue(text.contains("tool-output"))
        XCTAssertTrue(text.contains("not total provider usage"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("you saved"))
    }

    func test_displayTokens_atLeastMeasuredWhenEnabled() {
        // WHY: enabling estimates must never lower the thread figure (inversion).
        let measured = 50_000
        let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measured,
            assistantChars: 0,
            tokenSaverEnabled: true,
            graphifyActive: false
        )
        XCTAssertGreaterThanOrEqual(display, measured)
    }

    func test_displayTokens_disabled_returnsMeasuredOnly() {
        // WHY: paid-feature off → no dialect/graphify inflation.
        let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: 80_000,
            assistantChars: 400_000,
            tokenSaverEnabled: false,
            graphifyActive: true,
            graphifySignalCount: 20
        )
        XCTAssertEqual(display, 80_000)
    }

    func test_displayTokens_assistantCharsCanRaiseDialect() {
        // WHY: same bare-user estimator as sidebar; assistant-char floor can add dialect.
        let measured = 10_000
        let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measured,
            assistantChars: 200_000, // ~50K tokens floor × (V-1) dialect
            tokenSaverEnabled: true,
            graphifyActive: false
        )
        XCTAssertGreaterThan(display, measured,
                             "large assistant output should raise credible total above pure ledger")
    }

    func test_formatTokenCount_millions() {
        XCTAssertEqual(AgentAppView.formatTokenCountForFooter(1_500_000), "1.5M")
        XCTAssertEqual(AgentAppView.formatTokenCountForFooter(12_000_000), "12M")
    }

    func test_formatTokenCount_smallExact() {
        XCTAssertEqual(AgentAppView.formatTokenCountForFooter(42), "42")
        XCTAssertEqual(AgentAppView.formatTokenCountForFooter(999), "999")
    }
}
