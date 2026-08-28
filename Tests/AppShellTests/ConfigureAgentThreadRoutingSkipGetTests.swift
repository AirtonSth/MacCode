import XCTest
@testable import AppShell
import CoreModel
import Persistence
@testable import SocketServer

/// WHY: Auto toggle / iOS routing RPC compiled the 26-column row plus routing
/// JSON twice per call.
@MainActor
final class ConfigureAgentThreadRoutingSkipGetTests: XCTestCase {
    func test_configureRouting_doesNotDurableGetAndPreservesChrome() async throws {
        let (ctx, router) = try makeRouter()
        var thread = AgentThread(
            title: "keep-title",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised
        )
        thread.color = "purple"
        thread.pinned = true
        thread.hasUnread = true
        thread.status = .running
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = stamped
        let selection = AgentModelSelection(provider: .codex, modelId: "fake-model")
        let digest = String(repeating: "r", count: 32 * 1024)
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: selection,
            policyDigest: digest,
            revision: 1,
            updatedAt: stamped
        )
        try ctx.threadRepo.upsert(thread)
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let routingProbesBefore = ctx.threadRepo.routingConfigurationProbeCountForTesting

        let updated = try await router.configureAgentThreadRouting(
            thread: thread.id,
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: nil,
            serviceTier: nil,
            modelSelection: selection,
            providerInstanceId: nil,
            runAsUser: nil,
            routing: AgentRoutingRequest(
                mode: .manual,
                expectedRevision: 1,
                manualSelection: selection
            )
        )

        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(ctx.threadRepo.routingConfigurationProbeCountForTesting, routingProbesBefore + 1)
        XCTAssertEqual(updated.routingConfiguration?.mode, .manual)
        XCTAssertEqual(updated.routingConfiguration?.policyDigest, digest)
        XCTAssertEqual(updated.title, "keep-title")
        let stored = try XCTUnwrap(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.title, "keep-title")
        XCTAssertEqual(stored.color, "purple")
        XCTAssertTrue(stored.pinned)
        XCTAssertTrue(stored.hasUnread)
        XCTAssertEqual(stored.status, .running)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
    }

    private func makeRouter() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "rc2-cfg-routing-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }
}
