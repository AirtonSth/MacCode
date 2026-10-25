import XCTest
import CoreModel
@testable import Persistence

final class BotWorkspaceTransferTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
    }

    func test_transferRetainsIdentityRevisionHistoryAndAddsDestinationAuthorityOnce() throws {
        let bot = try store.create(name: "Engineer", title: "Build", description: "Existing")
        let conversation = BotConversation(botID: bot.id, title: "Previous work")
        try store.upsertConversation(conversation)
        let workspace = WorkspaceID()
        let moved = try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: workspace,
            expectedWorkspaceID: nil, expectedCurrentRevisionID: bot.currentRevisionID)
        XCTAssertEqual(moved.bot.id, bot.id)
        XCTAssertEqual(moved.bot.currentRevisionID, bot.currentRevisionID)
        XCTAssertEqual(moved.bot.workspaceID, workspace)
        XCTAssertEqual(moved.bot.directoryEpoch, bot.directoryEpoch)
        let support = URL(fileURLWithPath: "/tmp/workspace-transfer-home-test")
        XCTAssertEqual(BotHome.url(appSupportDirectory: support, bot: moved.bot), BotHome.url(appSupportDirectory: support, bot: bot))
        XCTAssertEqual(try store.conversation(id: conversation.id)?.title, conversation.title)
        let grant = try XCTUnwrap(store.getContextBinding(hostID: "host", botID: bot.id, context: .workspace(workspace)))
        XCTAssertEqual(grant.actions, [.read, .send], "Ownership must not silently grant tool, delegation or export access")
        let again = try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: workspace,
            expectedWorkspaceID: workspace, expectedCurrentRevisionID: moved.bot.currentRevisionID)
        XCTAssertTrue(again.changedBindings.isEmpty)
        XCTAssertEqual(try store.getContextBinding(hostID: "host", botID: bot.id, context: .workspace(workspace)), grant)
    }

    func test_staleTransferAndAdditionalAccessRefuseWithoutPartialUpdates() throws {
        let bot = try store.create(name: "QA", title: "", description: "")
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .general,
            actions: [.read, .send], expectedRevision: nil)
        let workspace = WorkspaceID()
        XCTAssertThrowsError(try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: workspace,
            expectedWorkspaceID: nil, expectedCurrentRevisionID: bot.currentRevisionID))
        XCTAssertNil(try store.get(id: bot.id)?.workspaceID)
        let moved = try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: workspace,
            expectedWorkspaceID: nil, expectedCurrentRevisionID: bot.currentRevisionID, revokeOtherContexts: true)
        XCTAssertEqual(moved.changedBindings.count, 2)
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: bot.id, context: .general,
            action: .send, policyRevision: grant.policyRevision))
        XCTAssertThrowsError(try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: WorkspaceID(),
            expectedWorkspaceID: nil, expectedCurrentRevisionID: bot.currentRevisionID, revokeOtherContexts: true))
        XCTAssertEqual(try store.get(id: bot.id)?.workspaceID, workspace)
    }

    func test_vmMovePreservesUUIDAndRefusesIncompatibleDefaultThenSucceedsAfterBotMove() throws {
        let bot = try store.create(name: "Tech Lead", title: "", description: "")
        let machine = try store.saveVirtualMachine(name: "airtours")
        let savedMachine = try XCTUnwrap(store.virtualMachine(id: machine.id))
        try store.setExecutionDestination(.virtualMachine(machine.id), botID: bot.id)
        let currentBot = try XCTUnwrap(store.get(id: bot.id))
        let workspace = WorkspaceID()
        XCTAssertThrowsError(try store.transferVirtualMachineWorkspace(id: machine.id, workspaceID: workspace, expectedWorkspaceID: nil))
        XCTAssertNil(try store.virtualMachine(id: machine.id)?.workspaceID)
        _ = try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: workspace,
            expectedWorkspaceID: nil, expectedCurrentRevisionID: currentBot.currentRevisionID)
        let moved = try store.transferVirtualMachineWorkspace(id: machine.id, workspaceID: workspace, expectedWorkspaceID: nil, hostID: "host")
        XCTAssertEqual(moved.id, machine.id)
        XCTAssertEqual(moved.createdAt, savedMachine.createdAt)
        XCTAssertEqual(try store.executionDestination(botID: bot.id), .virtualMachine(machine.id))
        XCTAssertThrowsError(try store.transferVirtualMachineWorkspace(id: machine.id, workspaceID: nil, expectedWorkspaceID: nil))
    }

    func test_vmMoveRefusesHistoricalForeignWorkspaceThreadWithoutRewritingIt() throws {
        let destination = WorkspaceID()
        let original = WorkspaceID()
        let bot = try store.create(name: "Engineer", title: "", description: "", workspaceID: destination)
        let machine = try store.saveVirtualMachine(name: "airtours")
        let thread = AgentThread(workspaceId: original, title: "Original project", provider: .distill, model: "auto")
        try AgentThreadRepository(db: db).upsert(thread)
        try store.upsertConversation(BotConversation(botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id))
        try store.pinExecutionDestination(threadID: thread.id, botID: bot.id, destination: .virtualMachine(machine.id))
        XCTAssertThrowsError(try store.transferVirtualMachineWorkspace(id: machine.id, workspaceID: destination, expectedWorkspaceID: nil))
        XCTAssertEqual(try AgentThreadRepository(db: db).get(id: thread.id)?.workspaceId, original)
        XCTAssertEqual(try store.threadExecutionDestination(thread.id), .virtualMachine(machine.id))
    }

    func test_vmMoveRefusesScheduleOverrideAndDestinationNameCollision() throws {
        let bot = try store.create(name: "QA", title: "", description: "")
        let machine = try store.saveVirtualMachine(name: "airtours")
        var spec = BotScheduleSpec(model: "auto")
        spec.executionDestination = .virtualMachine(machine.id)
        try store.saveRoutine(BotRoutineDefinition(botID: bot.id, name: "Nightly checks", prompt: "Check", scheduleNote: spec.displayNote(), scheduleSpecJSON: spec.encodedJSON()))
        let workspace = WorkspaceID()
        XCTAssertThrowsError(try store.transferVirtualMachineWorkspace(id: machine.id, workspaceID: workspace, expectedWorkspaceID: nil))
        _ = try store.saveVirtualMachine(name: "AIRTOURS", workspaceID: workspace)
        XCTAssertThrowsError(try store.transferVirtualMachineWorkspace(id: machine.id, workspaceID: workspace, expectedWorkspaceID: nil))
    }

    func test_transferRefusesRunningWaitingAndUserControlledResourcesWithoutChangingOwnership() throws {
        let bot = try store.create(name: "Engineer", title: "", description: "")
        let registry = BotVMRunRegistry()
        let control = BotComputerControl()
        let workspace = WorkspaceID()
        let run = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "In progress", workspace: "")
        XCTAssertNil(registry.tryBegin(botID: bot.id, entry: run))
        func move() throws {
            _ = try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: workspace,
                expectedWorkspaceID: nil, expectedCurrentRevisionID: bot.currentRevisionID, registry: registry, computerControl: control)
        }
        XCTAssertThrowsError(try move())
        registry.endRun(runID: run.runID)
        registry.addWaiting(botID: bot.id, threadID: run.threadID)
        XCTAssertThrowsError(try move())
        _ = registry.popWaitingIfFree(botID: bot.id)
        control.take(bot.id)
        XCTAssertThrowsError(try move())
        control.release(bot.id)
        XCTAssertNil(try store.get(id: bot.id)?.workspaceID)
        XCTAssertNil(try store.getContextBinding(hostID: "host", botID: bot.id, context: .workspace(workspace)))
        XCTAssertNoThrow(try move())
    }

    func test_hostTransferAPIUsesCurrentHostCASRevocationCallbackAndIdempotentReceipt() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: SettingsStore(db: db), appSupportDirectory: support)
        let workspace = WorkspaceID()
        authority.onVMWorkspaceExists = { $0 == workspace }
        authority.workspaceAssignmentHostID = { "host" }
        var changed: [BotContextBinding] = []
        authority.onContextBindingChanged = { changed.append($0); return true }
        let bot = try store.create(name: "QA", title: "", description: "")
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read, .send], expectedRevision: nil)
        var params: [String: Any] = [
            "client_request_id": UUID().uuidString, "bot_id": bot.id.value.uuidString,
            "host_id": "wrong-host", "workspace_id": workspace.value.uuidString,
            "expected_workspace_id": NSNull(), "expected_current_revision_id": try XCTUnwrap(bot.currentRevisionID).value.uuidString,
            "revoke_other_contexts": true,
        ]
        XCTAssertThrowsError(try authority.dispatch(method: "bot.workspace.transfer", params: params))
        params["host_id"] = "host"
        params["client_request_id"] = UUID().uuidString
        let result = try authority.dispatch(method: "bot.workspace.transfer", params: params)
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertEqual(changed.count, 2)
        _ = try authority.dispatch(method: "bot.workspace.transfer", params: params)
        XCTAssertEqual(changed.count, 2, "replaying a completed receipt must not revoke or grant twice")
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: bot.id, context: .general, action: .send, policyRevision: grant.policyRevision))
        XCTAssertEqual(try BotStore(db: db).get(id: bot.id)?.workspaceID, workspace)
    }

    func test_existingIncompleteTargetGrantIsNotElevatedAndRollsBackOtherRevocations() throws {
        let bot = try store.create(name: "QA", title: "", description: "")
        let workspace = WorkspaceID()
        let original = try store.grantContext(hostID: "host", botID: bot.id, context: .general,
            actions: [.read, .send], expectedRevision: nil)
        let restricted = try store.grantContext(hostID: "host", botID: bot.id, context: .workspace(workspace),
            actions: [.read], expectedRevision: nil)
        XCTAssertThrowsError(try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: workspace,
            expectedWorkspaceID: nil, expectedCurrentRevisionID: bot.currentRevisionID, revokeOtherContexts: true))
        XCTAssertNil(try store.get(id: bot.id)?.workspaceID)
        XCTAssertEqual(try store.getContextBinding(hostID: "host", botID: bot.id, context: .workspace(workspace)), restricted)
        XCTAssertEqual(try store.getContextBinding(hostID: "host", botID: bot.id, context: .general), original)
    }

    func test_usableExistingTargetGrantAndPolicyRevisionStayExactlyTheSame() throws {
        let bot = try store.create(name: "Engineer", title: "", description: "")
        let workspace = WorkspaceID()
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .workspace(workspace),
            actions: [.read, .send, .files], expectedRevision: nil)
        let moved = try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: workspace,
            expectedWorkspaceID: nil, expectedCurrentRevisionID: bot.currentRevisionID)
        XCTAssertTrue(moved.changedBindings.isEmpty)
        XCTAssertEqual(try store.getContextBinding(hostID: "host", botID: bot.id, context: .workspace(workspace)), grant)
    }

    func test_botMoveRefusesUnpinnedHistoricalWorkspaceThreadOnMacAndOwnVM() throws {
        for destination in [BotExecutionDestination.mac, .ownVM] {
            let original = WorkspaceID(), target = WorkspaceID()
            let bot = try store.create(name: "Engineer \(destination.storageValue)", title: "", description: "", workspaceID: original)
            try store.setExecutionDestination(destination, botID: bot.id)
            let current = try XCTUnwrap(store.get(id: bot.id))
            let thread = AgentThread(workspaceId: original, title: "Original project", provider: .distill, model: "auto")
            try AgentThreadRepository(db: db).upsert(thread)
            try store.upsertConversation(BotConversation(botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id))
            XCTAssertThrowsError(try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: target,
                expectedWorkspaceID: original, expectedCurrentRevisionID: current.currentRevisionID))
            XCTAssertEqual(try store.get(id: bot.id)?.workspaceID, original)
            XCTAssertEqual(try AgentThreadRepository(db: db).get(id: thread.id)?.workspaceId, original)
            XCTAssertNil(try store.getContextBinding(hostID: "host", botID: bot.id, context: .workspace(target)))
        }
    }

    func test_foreignHostGrantsBlockBotAndVMMovesEvenWithRevocationSelected() throws {
        let workspace = WorkspaceID()
        let bot = try store.create(name: "Remote worker", title: "", description: "", workspaceID: workspace)
        let machine = try store.saveVirtualMachine(name: "Shared")
        try store.setExecutionDestination(.virtualMachine(machine.id), botID: bot.id)
        let current = try XCTUnwrap(store.get(id: bot.id))
        let foreign = try store.grantContext(hostID: "other-host", botID: bot.id, context: .general,
            actions: [.read, .send], expectedRevision: nil)
        XCTAssertThrowsError(try store.transferBotWorkspace(botID: bot.id, hostID: "host", workspaceID: nil,
            expectedWorkspaceID: workspace, expectedCurrentRevisionID: current.currentRevisionID, revokeOtherContexts: true))
        XCTAssertThrowsError(try store.transferVirtualMachineWorkspace(id: machine.id, workspaceID: workspace,
            expectedWorkspaceID: nil, hostID: "host"))
        XCTAssertEqual(try store.getContextBinding(hostID: "other-host", botID: bot.id, context: .general), foreign)
        XCTAssertEqual(try store.get(id: bot.id)?.workspaceID, workspace)
        XCTAssertNil(try store.virtualMachine(id: machine.id)?.workspaceID)
    }
}
