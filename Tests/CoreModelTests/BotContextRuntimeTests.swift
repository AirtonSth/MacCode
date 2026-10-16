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

    private func makeBinding(
        host: String,
        bot: BotID,
        context: BotContext,
        revision: Int64 = 1
    ) -> BotContextBinding {
        BotContextBinding(hostID: host, botID: bot, context: context, state: .active, policyRevision: revision, actions: [.send])
    }
}
