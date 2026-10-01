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

    // MARK: - Provider grouping and display labels

    func test_providerGroups_orderModelsAndShortLabels() {
        let models = [
            distillModel("custom/vendor", label: "Vendor (OpenRouter)"),
            distillModel("claude/sonnet", label: "Sonnet (Claude)"),
            distillModel("chatgpt/gpt", label: "GPT (ChatGPT)"),
            distillModel("grok-4", label: "Grok 4"),
        ]
        XCTAssertEqual(AgentDistillModelCatalog.providerGroups(models).map(\.0), ["Grok", "ChatGPT", "Claude", "Custom"])
        XCTAssertEqual(AgentDistillModelCatalog.shortLabel("GPT (ChatGPT)"), "GPT")
        XCTAssertEqual(AgentDistillModelCatalog.shortLabel("Sonnet"), "Sonnet")
        XCTAssertEqual(AgentDistillModelCatalog.effortOptionLabels([.low, .high]), ["Auto", "Low", "High"])
    }

    func test_configWorkerSummary_readsConfigForSharedWorkerFallback() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        [models]
        worker = "claude/sonnet (Claude)"
        worker_effort = "high"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let summary = AgentDistillModelCatalog.configWorkerSummary(homePath: home.path)
        XCTAssertEqual(summary, "From Distill config: claude/sonnet · high")
        let section = AgentDistillReasoningModelSection(
            mainModel: "main",
            reasoningModel: nil,
            reasoningModels: [],
            supportsReasoningModelEffort: false,
            configWorkerSummary: summary,
            isDisabled: false,
            onSelectReasoningModel: { _ in }
        )
        XCTAssertTrue(section.showsConfigFallback)
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

        let reasoning = AgentModelPillPresentation(title: "Off", prefix: "Worker", warning: false)
        XCTAssertEqual(reasoning.accessibilityLabel, "Worker model Off")
    }

    func test_pillPresentation_legacyShapeIsUnchanged() {
        // Non-Distill pills pass no prefix/warning: the old label contract holds.
        let legacy = AgentModelPillPresentation(title: "gpt-5.5", effort: "Medium", serviceTier: "Fast")
        XCTAssertEqual(legacy.accessibilityLabel, "Model gpt-5.5, effort Medium, tier Fast")
        XCTAssertEqual(AgentModelPillPresentation(title: "Auto").accessibilityLabel, "Auto model routing")
    }
}
