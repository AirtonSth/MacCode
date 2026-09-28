import XCTest
@testable import Surfaces
import CoreModel

/// Distill picker redesign: split Main/Reasoning pills, inline filter,
/// collapsed lists with selection pinning, wider popover, single inline
/// warning per section. These tests lock the pure seams the redesign added;
/// view composition reuses them so SwiftUI stays untestable-thin.
final class AgentDistillModelPickerRedesignTests: XCTestCase {

    private func distillModel(_ id: String, label: String? = nil, contextWindowTokens: Int? = nil) -> AgentModelDescriptor {
        AgentModelDescriptor(
            id: id,
            label: label ?? id,
            provider: .distill,
            supportsReasoning: true,
            contextWindowTokens: contextWindowTokens
        )
    }

    // MARK: - Filter

    func test_filtered_matchesLabelAndIdCaseInsensitively() {
        let models = [
            distillModel("grok-4.7", label: "Grok 4.7"),
            distillModel("gpt-6-astra-chat", label: "GPT-6-Astra (ChatGPT)"),
            distillModel("muse-spark-1.3-contributor", label: "Muse Spark 1.3 Contributor"),
        ]

        XCTAssertEqual(
            AgentDistillModelCatalog.filtered(models, query: "astra").map(\.id),
            ["gpt-6-astra-chat"],
            "label match must survive case differences"
        )
        XCTAssertEqual(
            AgentDistillModelCatalog.filtered(models, query: "MUSE-SPARK").map(\.id),
            ["muse-spark-1.3-contributor"],
            "id match must survive case differences"
        )
        XCTAssertEqual(
            AgentDistillModelCatalog.filtered(models, query: "  grok  ").map(\.id),
            ["grok-4.7"],
            "surrounding whitespace must not break the filter"
        )
        XCTAssertEqual(
            AgentDistillModelCatalog.filtered(models, query: "zzz-no-such-model").count,
            0,
            "a query with no matches filters everything out (the section paints the empty state)"
        )
    }

    func test_filtered_emptyQueryReturnsAll() {
        let models = [distillModel("a"), distillModel("b")]
        XCTAssertEqual(AgentDistillModelCatalog.filtered(models, query: "").map(\.id), ["a", "b"])
        XCTAssertEqual(AgentDistillModelCatalog.filtered(models, query: "   ").map(\.id), ["a", "b"])
    }

    // MARK: - Collapse with selection pinning

    func test_visibleModels_collapsesBeyondLimitAndPinsSelected() {
        let models = (1...8).map { distillModel("model-\($0)") }

        let collapsed = AgentDistillModelCatalog.visibleModels(models, selectedID: "model-7", expanded: false)
        XCTAssertEqual(collapsed.map(\.id), ["model-1", "model-2", "model-3", "model-4", "model-7"],
                       "collapsed list shows the prefix plus the pinned selection")

        let collapsedVisibleSelection = AgentDistillModelCatalog.visibleModels(models, selectedID: "model-2", expanded: false)
        XCTAssertEqual(collapsedVisibleSelection.map(\.id), ["model-1", "model-2", "model-3", "model-4"],
                       "an already-visible selection must not duplicate a row")

        let expanded = AgentDistillModelCatalog.visibleModels(models, selectedID: "model-7", expanded: true)
        XCTAssertEqual(expanded.map(\.id), models.map(\.id), "Show-all must list every model")

        let short = Array(models.prefix(3))
        XCTAssertEqual(
            AgentDistillModelCatalog.visibleModels(short, selectedID: nil, expanded: false).map(\.id),
            ["model-1", "model-2", "model-3"],
            "short lists never collapse, so no Show-all row appears"
        )
    }

    // MARK: - Width estimator

    func test_menuWidth_respectsMinMaxAndKeepsLegacyMath() {
        XCTAssertEqual(AgentModelMenuWidth.estimatedWidth(titles: []), 112, "empty titles fall back to the minimum")
        XCTAssertEqual(AgentModelMenuWidth.estimatedWidth(titles: ["abc"]), 112, "short titles clamp to the minimum")
        // Legacy math: count * 7 + 34, clamped to [min, max].
        XCTAssertEqual(AgentModelMenuWidth.estimatedWidth(titles: ["123456789012"]), 12 * 7 + 34)
        XCTAssertEqual(
            AgentModelMenuWidth.estimatedWidth(titles: [String(repeating: "x", count: 100)]),
            260,
            "the default cap is unchanged for non-Distill popovers"
        )
        XCTAssertEqual(
            AgentModelMenuWidth.estimatedWidth(
                titles: [String(repeating: "x", count: 100)],
                min: AgentModelMenuWidth.distillMin,
                max: AgentModelMenuWidth.distillMax
            ),
            360,
            "Distill popovers may grow to the wider cap so live labels fit"
        )
        XCTAssertGreaterThan(AgentModelMenuWidth.distillMin, AgentModelMenuWidth.defaultMin)
        XCTAssertGreaterThan(AgentModelMenuWidth.distillMax, AgentModelMenuWidth.defaultMax)
    }

    func test_menuWidth_fitsKnownLongDistillLabels() {
        let labels = [
            "Grok 4.7",
            "GPT-6-Astra (ChatGPT)",
            "Muse Spark 1.3 Contributor",
            "Qwen3.8-27B MTPLX 128k",
        ]
        let width = AgentModelMenuWidth.estimatedWidth(
            titles: labels,
            min: AgentModelMenuWidth.distillMin,
            max: AgentModelMenuWidth.distillMax
        )
        let longest = labels.map(\.count).max() ?? 0
        XCTAssertGreaterThanOrEqual(width, CGFloat(longest * 7 + 34), "the full label set must size the popover, not just the first rows")
        XCTAssertLessThanOrEqual(width, AgentModelMenuWidth.distillMax)
    }

    // MARK: - Effort + context labels

    func test_effortSelection_pickerDisplayName() {
        XCTAssertEqual(AgentEffortSelection.automatic.pickerDisplayName, "Auto")
        XCTAssertEqual(AgentEffortSelection.fixed(.medium).pickerDisplayName, "Medium")
        XCTAssertEqual(AgentEffortSelection.fixed(.xhigh).pickerDisplayName, "Extra High")
    }

    func test_contextWindowLabel_formatsTiers() {
        XCTAssertNil(distillModel("a").contextWindowLabel)
        XCTAssertNil(distillModel("b", contextWindowTokens: 0).contextWindowLabel)
        XCTAssertEqual(distillModel("c", contextWindowTokens: 128_000).contextWindowLabel, "128k ctx")
        XCTAssertEqual(distillModel("d", contextWindowTokens: 1_000_000).contextWindowLabel, "1M ctx")
        XCTAssertEqual(distillModel("e", contextWindowTokens: 200_000).contextWindowLabel, "200k ctx")
        XCTAssertEqual(distillModel("f", contextWindowTokens: 1500).contextWindowLabel, "1500 ctx")
    }

    // MARK: - Split-pill presentation

    func test_pillPresentation_prefixAndWarning() {
        let main = AgentModelPillPresentation(title: "Grok 4.7", effort: "Medium", prefix: "Main", warning: false)
        XCTAssertEqual(main.accessibilityLabel, "Main model Grok 4.7, effort Medium")

        let missing = AgentModelPillPresentation(title: "gpt-6-astra", effort: "Auto", prefix: "Main", warning: true)
        XCTAssertEqual(missing.accessibilityLabel, "Main model gpt-6-astra, effort Auto, unavailable")

        let reasoning = AgentModelPillPresentation(title: "Off", prefix: "Reasoning", warning: false)
        XCTAssertEqual(reasoning.accessibilityLabel, "Reasoning model Off")
    }

    func test_pillPresentation_legacyShapeIsUnchanged() {
        // Non-Distill pills pass no prefix/warning: the old label contract holds.
        let legacy = AgentModelPillPresentation(title: "gpt-5.5", effort: "Medium", serviceTier: "Fast")
        XCTAssertEqual(legacy.accessibilityLabel, "Model gpt-5.5, effort Medium, tier Fast")
        XCTAssertEqual(AgentModelPillPresentation(title: "Auto").accessibilityLabel, "Auto model routing")
    }
}
