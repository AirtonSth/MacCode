import XCTest
import CoreModel
@testable import AgentRuntime

// Descriptor-level contracts for AnthropicModelDiscovery: the reasoning gate,
// the static fallback alias list, and per-family context windows.
// No network: descriptors are built via the pure parse/alias entry points.
final class AnthropicModelDiscoveryDescriptorTests: XCTestCase {

    private func descriptor(id: String) -> AgentModelDescriptor? {
        AnthropicModelDiscovery
            .modelDescriptors(fromListResponse: ["data": [["id": id]]])
            .first
    }

    // MARK: - Reasoning gate

    func test_currentTopTierModels_advertiseReasoningEfforts() {
        // WHY: the effort/ultracode picker is hidden whenever
        // supportedReasoningEfforts is empty, and a previously chosen effort is
        // silently reset — every current reasoning-capable family must
        // advertise the full Claude effort set or the feature disappears.
        for id in [
            "claude-fable-5", "claude-mythos-5", "claude-opus-4-8",
            "claude-opus-5", "claude-sonnet-5"
        ] {
            let d = descriptor(id: id)
            XCTAssertEqual(d?.supportsReasoning, true, "\(id) must support reasoning")
            XCTAssertEqual(d?.supportedReasoningEfforts, AgentReasoningEffort.claudeSupportedCases,
                "\(id) must advertise the Claude effort set; got \(String(describing: d?.supportedReasoningEfforts))")
        }
    }

    func test_haiku_isNonReasoning() {
        // WHY: haiku does not support reasoning efforts; advertising them would
        // offer a picker whose values the CLI rejects at run time.
        let d = descriptor(id: "claude-haiku-4-5")
        XCTAssertEqual(d?.supportsReasoning, false)
        XCTAssertEqual(d?.supportedReasoningEfforts, [])
    }

    func test_unknownAndLegacyFamilies_failClosedWithoutEffortPicker() {
        // WHY: Claude's effort support is an allowlist. Guessing even low/high
        // makes the CLI reject legacy and future custom models.
        for id in [
            "claude-zenith-6", "claude-3-opus", "claude-opus-4-0",
            "claude-opus-4-1", "claude-sonnet-4-0", "claude-sonnet-4-5"
        ] {
            let d = descriptor(id: id)
            XCTAssertEqual(d?.supportsReasoning, false, "\(id) has no verified effort contract")
            XCTAssertEqual(d?.supportedReasoningEfforts, [])
        }
    }

    // MARK: - Static fallback alias list

    func test_latestAliasModels_leadWithFable() {
        // WHY: the fallback list is all a CLI-authenticated user (no API key in
        // the environment) ever sees; omitting the flagship family makes Fable
        // unselectable. The CLI accepts both the "fable" alias and the full
        // "claude-fable-5" id, so the alias is safe to offer.
        let models = AnthropicModelDiscovery.latestAliasModels()
        XCTAssertEqual(models.first?.id, "fable",
            "Fable (latest) must lead the fallback list; got \(models.map(\.id))")
        XCTAssertEqual(models.first?.label, "Fable (latest)")
        XCTAssertEqual(models.first?.supportedReasoningEfforts, AgentReasoningEffort.claudeSupportedCases,
            "the fallback Fable alias must advertise reasoning efforts")
        XCTAssertEqual(models.map(\.id), ["fable", "opus", "sonnet", "haiku"],
            "existing aliases must be preserved after Fable")
    }

    // MARK: - Context windows

    func test_contextWindow_perFamily_notHardcoded200k() {
        // WHY: the model pill renders contextWindowTokens ("200k ctx"); a
        // hardcoded 200k misinforms the user on every 1M-context tier.
        XCTAssertEqual(descriptor(id: "claude-fable-5")?.contextWindowTokens, 1_000_000)
        XCTAssertEqual(descriptor(id: "claude-opus-5")?.contextWindowTokens, 1_000_000)
        XCTAssertEqual(descriptor(id: "claude-opus-4-8")?.contextWindowTokens, 1_000_000)
        XCTAssertEqual(descriptor(id: "claude-sonnet-5")?.contextWindowTokens, 1_000_000)
        XCTAssertEqual(descriptor(id: "claude-haiku-4-5")?.contextWindowTokens, 200_000)
    }

    func test_contextWindow_aliases_matchLatestFamilyWindow() {
        // WHY: bare aliases resolve to the latest family member, so their pill
        // must show that member's window (all latest tiers except haiku are 1M).
        let byID = Dictionary(uniqueKeysWithValues: AnthropicModelDiscovery.latestAliasModels().map { ($0.id, $0) })
        XCTAssertEqual(byID["fable"]?.contextWindowTokens, 1_000_000)
        XCTAssertEqual(byID["opus"]?.contextWindowTokens, 1_000_000)
        XCTAssertEqual(byID["sonnet"]?.contextWindowTokens, 1_000_000)
        XCTAssertEqual(byID["haiku"]?.contextWindowTokens, 200_000)
    }

    func test_contextWindow_unknownModel_isNil_soPillHides() {
        // WHY: when the window is unknown the pill must hide (nil) rather than
        // display a fabricated "200k ctx".
        XCTAssertNil(descriptor(id: "claude-zenith-6")?.contextWindowTokens,
            "unknown families must not claim a 200k window")
    }
}
