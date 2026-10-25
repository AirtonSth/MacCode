import XCTest
import CoreModel
@testable import Persistence

final class BotGroupWorkspaceContextTests: BotStoreGroupsFixture {
    private func room(_ workspace: WorkspaceID? = nil) throws -> AgentThread {
        let thread = AgentThread(workspaceId: workspace, title: "Airtours", provider: .codex, model: "fixture")
        try AgentThreadRepository(db: db).upsert(thread)
        return thread
    }

    func test_ownedWorkspaceGroupCreatesOnlyMissingMinimalAuthorityAndPinsSharedVMDestination() throws {
        let workspace = WorkspaceID()
        let bot = try store.create(name: "Engineer", title: "", description: "", workspaceID: workspace)
        let machine = try store.saveVirtualMachine(name: "Airtours", workspaceID: workspace)
        try store.setExecutionDestination(.virtualMachine(machine.id), botID: bot.id)
        let room = try room(workspace)
        let group = try store.createGroup(title: "Airtours", roomThreadID: room.id, participantBotIDs: [bot.id], hostID: "host")
        let grant = try XCTUnwrap(store.getContextBinding(hostID: "host", botID: bot.id, context: .workspace(workspace)))
        XCTAssertEqual(grant.actions, [.read, .send])
        let member = AgentThread(workspaceId: workspace, title: "Engineer", provider: .codex, model: "fixture")
        let conversation = try store.bindWorkspaceGroupMemberThread(groupID: group.id, botID: bot.id,
            newThread: member, hostID: "host", policyRevision: grant.policyRevision, destination: .virtualMachine(machine.id))
        let pin = try XCTUnwrap(store.conversationContextPin(conversationID: conversation.id))
        XCTAssertEqual(pin.context, .workspace(workspace))
        XCTAssertEqual(pin.policyRevision, grant.policyRevision)
        XCTAssertEqual(try AgentThreadRepository(db: db).get(id: member.id)?.actor, .bot(bot.id))
        XCTAssertEqual(try store.guestResourceID(botID: bot.id, threadID: member.id), machine.storageID)
        XCTAssertNotNil(try store.globalMemoryUnavailableReason(botID: bot.id, threadID: member.id))
        XCTAssertThrowsError(try store.bindWorkspaceGroupMemberThread(groupID: group.id, botID: bot.id,
            newThread: AgentThread(workspaceId: workspace, title: "Replace", provider: .codex, model: "fixture"),
            hostID: "host", policyRevision: grant.policyRevision, destination: .virtualMachine(machine.id)))
        XCTAssertEqual(try store.conversation(id: conversation.id)?.linkedAgentThreadID, member.id)
    }

    func test_emptyLegacyGroupAdoptionKeepsAllIdentitiesAndUsesSourceRevision() throws {
        let workspace = WorkspaceID()
        let bot = try store.create(name: "Tech Lead", title: "", description: "", workspaceID: workspace)
        let room = try room()
        let team = try store.createTeam(name: "Airtours", memberBotIDs: [bot.id])
        let group = try store.createGroup(title: "Airtours", teamID: team.id, roomThreadID: room.id, participantBotIDs: [bot.id])
        let members = try store.listGroupParticipants(groupID: group.id)
        XCTAssertThrowsError(try store.validateGroupWorkspaceAccess(groupID: group.id, botIDs: [bot.id], hostID: "host"),
            "General access validation must not silently ignore a required workspace")
        let adopted = try store.adoptEmptyGroupWorkspace(groupID: group.id, expectedRevision: group.revision,
            workspaceID: workspace, hostID: "host")
        XCTAssertEqual(adopted.id, group.id)
        XCTAssertEqual(adopted.teamID, team.id)
        XCTAssertEqual(adopted.roomThreadID, room.id)
        XCTAssertEqual(adopted.revision, group.revision + 1)
        XCTAssertEqual(try store.listGroupParticipants(groupID: group.id), members)
        XCTAssertEqual(try store.groupWorkspaceID(groupID: group.id), workspace)
        XCTAssertThrowsError(try store.adoptEmptyGroupWorkspace(groupID: group.id, expectedRevision: group.revision,
            workspaceID: workspace, hostID: "host"))
    }

    func test_adoptionRefusesAnyHistoryOrLinkedMemberWithoutGrantingAccess() throws {
        for kind in ["message", "turn", "member"] {
            let workspace = WorkspaceID()
            let bot = try store.create(name: "QA \(kind)", title: "", description: "", workspaceID: workspace)
            let room = try room()
            let group = try store.createGroup(title: "Legacy", roomThreadID: room.id, participantBotIDs: [bot.id])
            if kind == "message" {
                try AgentMessageRepository(db: db).append(AgentMessage(threadId: room.id, role: .user, content: "Keep original context"))
            } else if kind == "turn" {
                try store.insertGroupTurns([BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: bot.id, ordinal: 1)])
            } else {
                let participant = try XCTUnwrap(store.listGroupParticipants(groupID: group.id).first)
                var conversation = try XCTUnwrap(store.conversation(id: participant.memberConversationID))
                let member = try self.room()
                conversation.linkedAgentThreadID = member.id
                try store.upsertConversation(conversation)
            }
            XCTAssertThrowsError(try store.adoptEmptyGroupWorkspace(groupID: group.id, expectedRevision: group.revision,
                workspaceID: workspace, hostID: "host"))
            XCTAssertNil(try store.groupWorkspaceID(groupID: group.id))
            XCTAssertEqual(try store.group(id: group.id)?.revision, group.revision)
            XCTAssertNil(try store.getContextBinding(hostID: "host", botID: bot.id, context: .workspace(workspace)))
        }
    }

    func test_groupCreationNeverRevivesOrElevatesExplicitOwnedGrant() throws {
        for revoked in [false, true] {
            let workspace = WorkspaceID()
            let first = try store.create(name: "Lead", title: "", description: "", workspaceID: workspace)
            let second = try store.create(name: "QA", title: "", description: "", workspaceID: workspace)
            var restricted = try store.grantContext(hostID: "host", botID: second.id, context: .workspace(workspace),
                actions: revoked ? [.read, .send] : [.read], expectedRevision: nil)
            if revoked { restricted = try store.revokeContext(hostID: "host", botID: second.id,
                context: .workspace(workspace), expectedRevision: restricted.policyRevision) }
            let room = try room(workspace)
            XCTAssertThrowsError(try store.createGroup(title: "Restricted", roomThreadID: room.id,
                participantBotIDs: [first.id, second.id], hostID: "host"))
            XCTAssertNil(try store.getContextBinding(hostID: "host", botID: first.id, context: .workspace(workspace)), "earlier minimal grants must roll back")
            XCTAssertEqual(try store.getContextBinding(hostID: "host", botID: second.id, context: .workspace(workspace)), restricted)
        }
    }

    func test_generalParticipantNeedsExplicitWorkspaceGrantAndDifferentOwnersCannotBeImplicitlyCombined() throws {
        let workspace = WorkspaceID()
        let owner = try store.create(name: "Lead", title: "", description: "", workspaceID: workspace)
        let general = try makeBot("General")
        let foreign = try store.create(name: "Foreign", title: "", description: "", workspaceID: WorkspaceID())
        XCTAssertThrowsError(try store.proposedGroupWorkspace(botIDs: [owner.id, foreign.id]))
        let room = try room(workspace)
        XCTAssertThrowsError(try store.createGroup(title: "Workspace", roomThreadID: room.id,
            participantBotIDs: [owner.id, general.id], hostID: "host"))
        XCTAssertNil(try store.getContextBinding(hostID: "host", botID: owner.id, context: .workspace(workspace)))
        let grant = try store.grantContext(hostID: "host", botID: general.id, context: .workspace(workspace), actions: [.read, .send], expectedRevision: nil)
        XCTAssertNoThrow(try store.createGroup(title: "Workspace", roomThreadID: room.id,
            participantBotIDs: [owner.id, general.id], hostID: "host"))
        XCTAssertEqual(try store.getContextBinding(hostID: "host", botID: general.id, context: .workspace(workspace)), grant)
    }

    func test_revokedPinCannotBeReplacedOrUsedForAnotherGroupMemberThread() throws {
        let workspace = WorkspaceID()
        let bot = try store.create(name: "Engineer", title: "", description: "", workspaceID: workspace)
        let room = try room(workspace)
        let group = try store.createGroup(title: "Airtours", roomThreadID: room.id, participantBotIDs: [bot.id], hostID: "host")
        let grant = try XCTUnwrap(store.getContextBinding(hostID: "host", botID: bot.id, context: .workspace(workspace)))
        _ = try store.revokeContext(hostID: "host", botID: bot.id, context: .workspace(workspace), expectedRevision: grant.policyRevision)
        let thread = AgentThread(workspaceId: workspace, title: "New member", provider: .codex, model: "fixture")
        XCTAssertThrowsError(try store.bindWorkspaceGroupMemberThread(groupID: group.id, botID: bot.id,
            newThread: thread, hostID: "host", policyRevision: grant.policyRevision, destination: .mac))
        XCTAssertNil(try AgentThreadRepository(db: db).get(id: thread.id))
        XCTAssertNil(try store.listGroupMemberConversations(groupID: group.id).first?.linkedAgentThreadID)
    }

    func test_memberEditAddsOnlyMissingOwnedAuthorityAndRollsBackUnauthorizedGeneralParticipant() throws {
        let workspace = WorkspaceID()
        let first = try store.create(name: "Lead", title: "", description: "", workspaceID: workspace)
        let second = try store.create(name: "Engineer", title: "", description: "", workspaceID: workspace)
        let general = try makeBot("General")
        let room = try room(workspace)
        let group = try store.createGroup(title: "Airtours", roomThreadID: room.id, participantBotIDs: [first.id], hostID: "host")
        XCTAssertThrowsError(try store.setGroupParticipants(id: group.id, expectedRevision: group.revision,
            botIDs: [first.id, second.id, general.id], hostID: "host"))
        XCTAssertNil(try store.getContextBinding(hostID: "host", botID: second.id, context: .workspace(workspace)))
        XCTAssertEqual(try store.listGroupParticipants(groupID: group.id).map(\.botID), [first.id])
        _ = try store.setGroupParticipants(id: group.id, expectedRevision: group.revision,
            botIDs: [first.id, second.id], hostID: "host")
        XCTAssertEqual(try store.getContextBinding(hostID: "host", botID: second.id, context: .workspace(workspace))?.actions, [.read, .send])
    }
}
