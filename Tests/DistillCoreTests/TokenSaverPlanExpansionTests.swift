import XCTest
@testable import DistillCore

final class TokenSaverPlanExpansionTests: XCTestCase {
    func test_crossAgentMemoryToolsRespectProjectScopeAndLifecycle() {
        var store = TokenSaverMemoryStore()
        let remoteCode = TokenSaverMemoryScope(projectPath: "/repo/remote-code", provider: "codex", threadID: "thread-a")
        let otherProvider = TokenSaverMemoryScope(projectPath: "/repo/remote-code", provider: "claude", threadID: "thread-a")
        let otherThread = TokenSaverMemoryScope(projectPath: "/repo/remote-code", provider: "codex", threadID: "thread-b")
        let otherProject = TokenSaverMemoryScope(projectPath: "/repo/other", provider: "codex", threadID: "thread-b")

        let saved = store.save(text: "ERROR checkout failed at Sources/Payment.swift:42", scope: remoteCode, provenance: "tool-output")

        XCTAssertEqual(store.search("checkout error", scope: remoteCode).first?.handle, saved.handle)
        XCTAssertTrue(store.search("checkout error", scope: otherProject).isEmpty,
                      "cross-agent memory must never leak handles across project scope")
        XCTAssertNil(store.retrieve(handle: saved.handle, scope: otherProvider),
                     "same-project records never cross provider scope")
        XCTAssertNil(store.retrieve(handle: saved.handle, scope: otherThread),
                     "same-project records never cross thread scope")

        XCTAssertTrue(store.update(handle: saved.handle, text: "ERROR checkout fixed", scope: remoteCode))
        XCTAssertEqual(store.retrieve(handle: saved.handle, scope: remoteCode), "ERROR checkout fixed")
        XCTAssertTrue(store.delete(handle: saved.handle, scope: remoteCode))
        XCTAssertNil(store.retrieve(handle: saved.handle, scope: remoteCode))
    }

    func test_offlineTranscriptLearningMinesProviderVerbosityAndDistillRules() {
        let report = TokenSaverTranscriptLearner.learn(from: [
            TokenSaverTranscriptSample(provider: "claude", text: "S=ok\nD=patch\nP=tests pass\n"),
            TokenSaverTranscriptSample(provider: "codex", text: String(repeating: "verbose explanation line\n", count: 80)),
            TokenSaverTranscriptSample(provider: "gemini", text: "error: skipped distill pipe for large grep output\n")
        ])

        XCTAssertEqual(report.providers, ["claude", "codex", "gemini"])
        XCTAssertGreaterThan(report.learnedVerbosityBudget.maxLines, 0)
        XCTAssertTrue(report.recommendedRules.contains { $0.contains("distill") },
                      "real corrections must be able to feed AGENTS.md and Token Saver defaults")
    }

    func test_sdkSimulationReportsSavingsWithoutProviderCall() {
        let input = String(repeating: "build log warning line\n", count: 100)
        let candidate = "build log warning line\n... 99 repeated lines elided ...\n"

        let report = DistillSimulation.simulate(input: input, candidateOutput: candidate, mode: .commandOutput)

        XCTAssertEqual(report.runMode, .simulate)
        XCTAssertFalse(report.providerCallRequired)
        XCTAssertGreaterThan(report.wouldSaveTokens, 0)
        XCTAssertEqual(report.output, input, "simulation/audit mode must not replace provider-visible text")
    }

    func test_providerProxyNoGoStillAddsRemoteCodeOwnedCacheAndToolSearchGuards() {
        let proxyDecision = TokenSaverProviderProxyPolicy.decision(for: .reverseProxy)
        XCTAssertFalse(proxyDecision.allowed)
        XCTAssertTrue(proxyDecision.reason.contains("provider HTTP bodies"))

        let env = TokenSaverProviderProxyPolicy.remoteCodeOwnedLaunchEnvironment(usesCustomBaseURL: true)
        XCTAssertEqual(env["ENABLE_TOOL_SEARCH"], "true",
                       "Claude launched through a custom base URL must keep tool-search deferral enabled")
    }

    func test_contentVisionAndContextRoutersAreFailOpenAndScoped() {
        let source = TokenSaverContentClassifier.classify(
            sample: "import Foundation\nstruct BillingView { let total: Decimal }\n",
            fileName: "BillingView.swift",
            mimeType: nil
        )
        XCTAssertEqual(source.contentType, .sourceCode)
        XCTAssertEqual(source.routingHint, .astStructure)

        let image = VisionTokenRouter.decision(
            query: "read the screenshot error",
            mimeType: "image/png",
            byteCount: 2_000_000,
            isEnabled: false
        )
        XCTAssertEqual(image.action, .deferUntilMeasuredVolume)
        XCTAssertFalse(image.shouldCompress)

        let context = TokenSaverContextDropPolicy.decide(
            text: String(repeating: "INFO noise\n", count: 200) + "ERROR keep this\nFollow-up: see Sources/App.swift:12\n",
            maxLines: 20
        )
        XCTAssertTrue(context.output.contains("ERROR keep this"))
        XCTAssertTrue(context.output.contains("Sources/App.swift:12"))
        XCTAssertGreaterThan(context.droppedLines, 0)
    }

    func test_telemetryAndEcosystemIntegrationsAreOffByDefaultAndSavingsScoped() {
        let telemetry = TokenSaverTelemetryExportPolicy.defaultConfiguration()
        XCTAssertFalse(telemetry.otelEnabled)
        XCTAssertFalse(telemetry.langfuseEnabled)
        XCTAssertNil(telemetry.otelEndpoint)

        let labels = TokenSaverTelemetryExportPolicy.labels(
            provider: "codex",
            mode: "command-output",
            routeStage: .encoderBERT,
            cacheState: "tool_output_oneshot"
        )
        XCTAssertEqual(labels["route_stage"], "encoder_bert")
        XCTAssertEqual(labels["cache_state"], "tool_output_oneshot")

        XCTAssertFalse(EcosystemIntegrationPolicy.decision(toolName: "LiteLLM", raisesRemoteCodeSessionSavings: false).allowed)
        XCTAssertTrue(EcosystemIntegrationPolicy.decision(toolName: "Codex", raisesRemoteCodeSessionSavings: true).allowed)
    }
}
