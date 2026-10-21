import XCTest
import CoreModel
@testable import AppShell

/// A Bot Distill run must never resolve to an empty model: the Distill adapter
/// refuses an empty model, so an empty route would fail every Bot run.
final class BotRunModelResolutionTests: XCTestCase {
    func test_emptyDistillRoute_resolvesToListedFallback() {
        var routing = BotDeskRouting()
        routing.provider = .distill
        routing.routingMode = .manual
        routing.model = ""

        let model = routing.resolvedModel(defaultModel: { provider in
            BotsViewModel.runDefaultModel(for: provider, lastUsed: nil, availableModelIds: ["distill-main-a", "distill-main-b"])
        })

        XCTAssertEqual(model, "distill-main-a")
    }

    func test_emptyDistillRoute_prefersLastUsedModel() {
        let model = BotsViewModel.runDefaultModel(
            for: .distill,
            lastUsed: "distill-last",
            availableModelIds: ["distill-main-a"]
        )

        XCTAssertEqual(model, "distill-last")
    }

    func test_explicitDistillModel_isKept() {
        var routing = BotDeskRouting()
        routing.provider = .distill
        routing.routingMode = .manual
        routing.model = "distill-explicit"

        let model = routing.resolvedModel(defaultModel: { provider in
            BotsViewModel.runDefaultModel(for: provider, lastUsed: "distill-last", availableModelIds: ["distill-main-a"])
        })

        XCTAssertEqual(model, "distill-explicit")
    }

    func test_nonDistillProvider_unchanged() {
        XCTAssertEqual(
            BotsViewModel.runDefaultModel(for: .claude, lastUsed: "other", availableModelIds: ["x"]),
            BotsViewModel.defaultModel(for: .claude)
        )
        XCTAssertEqual(
            BotsViewModel.runDefaultModel(for: .codex, lastUsed: nil, availableModelIds: []),
            AgentDefaultModelSelection.codexBuiltInDefault
        )
    }
}
