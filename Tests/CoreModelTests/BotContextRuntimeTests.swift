import CoreModel
import XCTest

final class BotContextRuntimeTests: XCTestCase {
    func test_runtimeStoragePartitionsHostBotAndContextButNotPolicyRevision() throws {
        // WHY: Runtime homes must isolate authority bindings without turning policy edits into new storage.
        let bot = BotID()
        let workspace = BotContext.workspace(WorkspaceID())
        let binding = makeBinding(host: "host-a", bot: bot, context: workspace, revision: 1)
        let original = try BotContextRuntimeIdentity(binding: binding)
        let revised = try BotContextRuntimeIdentity(binding: makeBinding(host: "host-a", bot: bot, context: workspace, revision: 2))

        XCTAssertEqual(original.storageBotID, revised.storageBotID)
        XCTAssertNotEqual(original.storageBotID, bot)
        XCTAssertNotEqual(original.storageBotID, try BotContextRuntimeIdentity(binding: makeBinding(host: "host-b", bot: bot, context: workspace)).storageBotID)
        XCTAssertNotEqual(original.storageBotID, try BotContextRuntimeIdentity(binding: makeBinding(host: "host-a", bot: BotID(), context: workspace)).storageBotID)
        XCTAssertNotEqual(original.storageBotID, try BotContextRuntimeIdentity(binding: makeBinding(host: "host-a", bot: bot, context: .general)).storageBotID)
        XCTAssertEqual(original.schemaVersion, BotContextRuntimeIdentity.schemaVersion)
    }

    func test_durableIdentityUsesContextAndIgnoresPolicyRevision() throws {
        let bot = BotID()
        let context = BotContext.workspace(WorkspaceID())
        let first = try BotContextRuntimeIdentity(hostID: "host", botID: bot, context: context, policyRevision: 1)
        let later = try BotContextRuntimeIdentity(hostID: "host", botID: bot, context: context, policyRevision: 8)
        XCTAssertEqual(first.storageBotID, later.storageBotID)
        XCTAssertThrowsError(try BotContextRuntimeIdentity(hostID: " ", botID: bot, context: context, policyRevision: 1))
        XCTAssertThrowsError(try BotContextRuntimeIdentity(hostID: "host", botID: bot, context: context, policyRevision: 0))
    }

    func test_runtimeIdentityRejectsInvalidBindings() {
        let bot = BotID()
        let context = BotContext.general
        let invalid = [
            BotContextBinding(hostID: " ", botID: bot, context: context, state: .active, policyRevision: 1, actions: [.send]),
            BotContextBinding(hostID: "host", botID: bot, context: context, state: .revoked, policyRevision: 1, actions: [.send]),
            BotContextBinding(hostID: "host", botID: bot, context: context, state: .active, policyRevision: 1, actions: []),
            BotContextBinding(hostID: "host", botID: bot, context: context, state: .active, policyRevision: 0, actions: [.send]),
        ]
        for binding in invalid {
            XCTAssertThrowsError(try BotContextRuntimeIdentity(binding: binding))
        }
    }

    func test_gatewayLeaseEqualityIncludesRunAndContext() throws {
        let bot = BotID()
        let workspace = BotContext.workspace(WorkspaceID())
        let identity = try BotContextRuntimeIdentity(hostID: "host", botID: bot, context: workspace, policyRevision: 1)
        let sameLease = BotContextGatewayLease(identity: identity, runID: AgentRunID(), hostAddress: "127.0.0.1", port: 1234)
        let sameLeaseCopy = BotContextGatewayLease(identity: identity, runID: sameLease.runID, hostAddress: "127.0.0.1", port: 1234)
        let otherRun = BotContextGatewayLease(identity: identity, runID: AgentRunID(), hostAddress: "127.0.0.1", port: 1234)
        let otherIdentity = try BotContextRuntimeIdentity(hostID: "host", botID: bot, context: .general, policyRevision: 1)
        let otherContext = BotContextGatewayLease(identity: otherIdentity, runID: sameLease.runID, hostAddress: "127.0.0.1", port: 1234)

        XCTAssertEqual(sameLease, sameLeaseCopy)
        XCTAssertNotEqual(sameLease, otherRun)
        XCTAssertNotEqual(sameLease, otherContext)
    }

    private func makeBinding(
        host: String,
        bot: BotID,
        context: BotContext,
        revision: Int64 = 1
    ) -> BotContextBinding {
        BotContextBinding(hostID: host, botID: bot, context: context, state: .active, policyRevision: revision, actions: [.send])
    }
}
