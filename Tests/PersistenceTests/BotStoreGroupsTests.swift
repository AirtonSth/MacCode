import XCTest
import CoreModel
@testable import Persistence

/// Shared fixture: an in-memory database migrated to head.
class BotStoreGroupsFixture: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    var db: SQLiteDB!
    var store: BotStore!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
    }

    override func tearDown() {
        store = nil
        db = nil
    }

    func makeBot(_ name: String) throws -> BotDefinition {
        try store.create(name: name, title: "Teammate", description: "", provider: .claude)
    }

    func makeGroup(
        _ bots: [BotDefinition],
        policy: BotGroupPolicy = .roundtable,
        lead: BotDefinition? = nil,
        teamID: BotTeamID? = nil
    ) throws -> BotGroupConversation {
        try store.createGroup(
            title: "Launch room",
            teamID: teamID,
            roomThreadID: AgentThreadID(),
            policy: policy,
            leadBotID: lead?.id,
            participantBotIDs: bots.map(\.id),
            now: t0
        )
    }

    func assertInvalidInput(_ body: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case BotStoreError.invalidInput = error else {
                return XCTFail("expected invalidInput, got \(error)", file: file, line: line)
            }
        }
    }
}

final class BotStoreTeamsTests: BotStoreGroupsFixture {
    func test_teamsAreManyToMany_becauseABotIsListedUnderEveryTeamItBelongsTo() throws {
        // WHY (decision 3.0): a bot must appear under every team it belongs to;
        // a single team_id column on bots could not express that.
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let cy = try makeBot("Cy")
        let design = try store.createTeam(name: " Design ", memberBotIDs: [ana.id, ben.id], now: t0)
        let growth = try store.createTeam(name: "Growth", memberBotIDs: [ben.id, cy.id, ben.id], now: t0)

        XCTAssertEqual(design.name, "Design", "names are trimmed")
        XCTAssertEqual(try store.listTeams().map(\.id), [design.id, growth.id], "creation order is sidebar order")
        let members = try store.listTeamMembers()
        XCTAssertEqual(members.filter { $0.botID == ben.id }.map(\.teamID), [design.id, growth.id])
        XCTAssertEqual(try store.listTeamMembers(teamID: growth.id).map(\.botID), [ben.id, cy.id],
                       "duplicates are dropped and order is kept")

        // Survives relaunch: a fresh store on the same database sees the same teams.
        let relaunched = BotStore(db: db)
        XCTAssertEqual(try relaunched.listTeams(), try store.listTeams())
        XCTAssertEqual(try relaunched.listTeamMembers(), members)
    }

    func test_setTeamMembers_rejectsStaleRevision_becauseTwoEditorsMustNotClobberMembership() throws {
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let team = try store.createTeam(name: "Ops", memberBotIDs: [ana.id], now: t0)
        let later = t0.addingTimeInterval(60)

        let edited = try store.setTeamMembers(id: team.id, expectedRevision: team.revision,
                                              botIDs: [ben.id, ana.id], now: later)
        XCTAssertEqual(edited.revision, team.revision + 1)
        XCTAssertThrowsError(try store.setTeamMembers(id: team.id, expectedRevision: team.revision,
                                                      botIDs: [], now: later)) { error in
            XCTAssertEqual(error as? BotStoreError, .revisionConflict)
        }
        let members = try store.listTeamMembers(teamID: team.id)
        XCTAssertEqual(members.map(\.botID), [ben.id, ana.id], "the stale write must not land")
        XCTAssertEqual(members.first { $0.botID == ana.id }?.addedAt, t0,
                       "a kept member keeps its original join time")
        XCTAssertEqual(try store.team(id: team.id)?.revision, edited.revision)
    }

    func test_updateTeam_renamesWithRevisionAndRejectsEmptyName() throws {
        let team = try store.createTeam(name: "Ops", now: t0)
        let renamed = try store.updateTeam(id: team.id, expectedRevision: 1, name: "Platform",
                                           description: "Infra", avatarSymbol: "server.rack", now: t0)
        XCTAssertEqual(try store.team(id: team.id), renamed)
        XCTAssertEqual(renamed.revision, 2)
        assertInvalidInput(try self.store.updateTeam(id: team.id, expectedRevision: 2, name: "  ",
                                                     description: "", avatarSymbol: "x", now: self.t0))
        XCTAssertThrowsError(try store.createTeam(name: "Ghost", memberBotIDs: [BotID()], now: t0)) { error in
            XCTAssertEqual(error as? BotStoreError, .notFound, "unknown bots cannot join a team")
        }
        XCTAssertEqual(try store.listTeams().count, 1, "a rejected create writes nothing")
    }

    func test_deleteTeam_keepsBotsAndGroups_becauseATeamIsOnlyAGrouping() throws {
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let team = try store.createTeam(name: "Ops", memberBotIDs: [ana.id, ben.id], now: t0)
        let group = try makeGroup([ana, ben], teamID: team.id)

        try store.deleteTeam(id: team.id, now: t0.addingTimeInterval(5))

        XCTAssertTrue(try store.listTeams().isEmpty)
        XCTAssertTrue(try store.listTeamMembers().isEmpty)
        XCTAssertNotNil(try store.get(id: ana.id))
        let kept = try XCTUnwrap(store.group(id: group.id))
        XCTAssertNil(kept.teamID, "the group outlives its source team")
        XCTAssertEqual(kept.revision, group.revision + 1,
                       "revision-keyed caches (iOS) must learn the team link is gone")
        XCTAssertEqual(kept.updatedAt, t0.addingTimeInterval(5))
        XCTAssertEqual(try store.listGroupParticipants(groupID: group.id).map(\.botID), [ana.id, ben.id])
    }

    func test_reorderTeams_persistsOrderAndRejectsPartialLists() throws {
        let a = try store.createTeam(name: "A", now: t0)
        let b = try store.createTeam(name: "B", now: t0)
        let c = try store.createTeam(name: "C", now: t0)
        try store.reorderTeams([c.id, a.id, b.id], now: t0)
        XCTAssertEqual(try store.listTeams().map(\.id), [c.id, a.id, b.id])
        assertInvalidInput(try self.store.reorderTeams([a.id, b.id], now: self.t0))
        assertInvalidInput(try self.store.reorderTeams([a.id, a.id, b.id], now: self.t0))
        XCTAssertEqual(try store.listTeams().map(\.id), [c.id, a.id, b.id], "rejected reorders change nothing")
    }
}

final class BotStoreGroupsTests: BotStoreGroupsFixture {
    func test_memberConversationsStayOutOfDeskLists_becauseGroupPlumbingMustNotLeakIntoEachBotsDesk() throws {
        // WHY (F5): each participant gets a hidden member conversation. If the
        // desk list returned it, every group would add a phantom chat to each
        // bot's desk on macOS and on iOS (bot.conversation.list).
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let desk = BotConversation(botID: ana.id, title: "Desk chat")
        try store.upsertConversation(desk)

        let group = try makeGroup([ana, ben])

        XCTAssertEqual(try store.listConversations(botID: ana.id).map(\.id), [desk.id])
        XCTAssertTrue(try store.listConversations(botID: ben.id).isEmpty)
        let members = try store.listGroupMemberConversations(groupID: group.id)
        XCTAssertEqual(Set(members.map(\.botID)), [ana.id, ben.id])
        XCTAssertTrue(members.allSatisfy { $0.hidden && $0.groupID == group.id && $0.linkedAgentThreadID == nil })
        let participants = try store.listGroupParticipants(groupID: group.id)
        XCTAssertEqual(Set(participants.map(\.memberConversationID)), Set(members.map(\.id)))
        XCTAssertEqual(try store.listConversations(botID: ana.id, includeGroupMembers: true).count, 2,
                       "live-run discovery still sees the bot's group conversation")

        // Linking the member thread later (orchestrator, T3) goes through the
        // ordinary upsert; it must keep the row grouped.
        var member = try XCTUnwrap(members.first { $0.botID == ana.id })
        let memberThread = AgentThreadID()
        member.linkedAgentThreadID = memberThread
        member.groupID = nil
        try store.upsertConversation(member)
        XCTAssertEqual(try store.conversation(id: member.id)?.groupID, group.id,
                       "group membership of a conversation is immutable after insert")
        XCTAssertEqual(try store.listConversations(botID: ana.id).map(\.id), [desk.id])

        // Remote list (iOS bot.conversation.list) applies the same filter.
        let settings = SettingsStore(db: db)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: settings,
                                                  appSupportDirectory: support)
        let listed = try authority.dispatch(method: "bot.conversation.list",
                                            params: ["bot_id": ana.id.value.uuidString.lowercased()])
        let rows = try XCTUnwrap(listed["conversations"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, [desk.id.value.uuidString.lowercased()])
    }

    func test_roomAndMemberThreadsAreBotOwned_becauseTheyMustNotSurfaceAsAgentAppThreads() throws {
        // WHY: Pet and Active Threads hide bot-owned threads via this set. The
        // quiet room thread never runs a provider and would otherwise show up
        // as an orphan Agent App thread.
        let ana = try makeBot("Ana")
        let group = try makeGroup([ana])
        var member = try XCTUnwrap(store.listGroupMemberConversations(groupID: group.id).first)
        let memberThread = AgentThreadID()
        member.linkedAgentThreadID = memberThread
        try store.upsertConversation(member)

        let linked = try store.listLinkedAgentThreadIDs()
        XCTAssertTrue(linked.contains(group.roomThreadID))
        XCTAssertTrue(linked.contains(memberThread))
        XCTAssertEqual(try store.group(roomThreadID: group.roomThreadID)?.id, group.id)
    }

    func test_createGroup_enforcesParticipantCapPolicyAndHopBudget() throws {
        // WHY (decision 3.0): max 8 participants, hop budget 0...8, and a lead
        // policy needs a lead that is actually in the room.
        let bots = try (0..<9).map { try makeBot("Bot\($0)") }
        assertInvalidInput(try self.makeGroup(bots))
        XCTAssertNoThrow(try makeGroup(Array(bots.prefix(BotGroupConversation.maxParticipants))))
        assertInvalidInput(try self.makeGroup([]))
        assertInvalidInput(try self.makeGroup([bots[0]], policy: .lead))
        assertInvalidInput(try self.makeGroup([bots[0]], policy: .lead, lead: bots[1]))
        assertInvalidInput(try self.store.createGroup(title: "x", roomThreadID: AgentThreadID(),
                                                      maxAutoHops: 9, participantBotIDs: [bots[0].id]))
        assertInvalidInput(try self.store.createGroup(title: " ", roomThreadID: AgentThreadID(),
                                                      participantBotIDs: [bots[0].id]))
        XCTAssertEqual(try store.listGroups().count, 1, "rejected creates write nothing")
        XCTAssertEqual(try store.listGroupMemberConversations(groupID: store.listGroups()[0].id).count, 8)

        let created = try makeGroup([bots[0], bots[1]], policy: .lead, lead: bots[1])
        XCTAssertEqual(created.maxAutoHops, BotGroupConversation.defaultMaxAutoHops)
        XCTAssertEqual(try store.group(id: created.id), created, "round-trips every field")
    }

    func test_updateGroup_isCompareAndSetAndCannotMoveTheRoom() throws {
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let group = try makeGroup([ana, ben])
        let later = t0.addingTimeInterval(5)

        let updated = try store.updateGroup(id: group.id, expectedRevision: group.revision, now: later) {
            $0.title = "Renamed"
            $0.policy = .lead
            $0.leadBotID = ben.id
            $0.maxAutoHops = 8
            $0.roomThreadID = AgentThreadID()
        }
        XCTAssertEqual(updated.roomThreadID, group.roomThreadID, "the room thread is fixed for life")
        XCTAssertEqual(updated.revision, group.revision + 1)
        XCTAssertEqual(try store.group(id: group.id), updated)
        XCTAssertThrowsError(try store.updateGroup(id: group.id, expectedRevision: group.revision) { $0.title = "Stale" }) {
            XCTAssertEqual($0 as? BotStoreError, .revisionConflict)
        }
        assertInvalidInput(try self.store.updateGroup(id: group.id, expectedRevision: nil) { $0.maxAutoHops = 9 })
        assertInvalidInput(try self.store.updateGroup(id: group.id, expectedRevision: nil) { $0.leadBotID = nil })
        let marked = try store.updateGroup(id: group.id, expectedRevision: nil) { $0.unread = true }
        XCTAssertTrue(marked.unread, "host bookkeeping writes without a user revision")
        XCTAssertEqual(try store.group(id: group.id)?.title, "Renamed")
    }

    func test_setGroupParticipants_leavesAndRejoinsWithoutLosingTheMemberThread() throws {
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let cy = try makeBot("Cy")
        let group = try makeGroup([ana, ben])
        let benConversation = try XCTUnwrap(store.listGroupParticipants(groupID: group.id)
            .first { $0.botID == ben.id }?.memberConversationID)
        let round = BotGroupRoundID()
        let anaTurn = BotGroupTurn(groupID: group.id, roundID: round, botID: ana.id, ordinal: 1)
        let benTurn = BotGroupTurn(groupID: group.id, roundID: round, botID: ben.id, ordinal: 2)
        try store.insertGroupTurns([anaTurn, benTurn])

        let shrunk = try store.setGroupParticipants(id: group.id, expectedRevision: group.revision,
                                                    botIDs: [ana.id, cy.id], now: t0)
        XCTAssertEqual(try store.listGroupParticipants(groupID: group.id).map(\.botID), [ana.id, cy.id])
        XCTAssertNotNil(try store.listGroupParticipants(groupID: group.id, includeLeft: true)
            .first { $0.botID == ben.id }?.leftAt)
        XCTAssertEqual(try store.groupTurn(id: benTurn.id)?.state, .cancelled,
                       "a removed bot's unstarted turn must not run")
        XCTAssertEqual(try store.groupTurn(id: anaTurn.id)?.state, .planned)
        assertInvalidInput(try self.store.insertGroupTurns([
            BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ben.id, ordinal: 3),
        ]))

        let regrown = try store.setGroupParticipants(id: group.id, expectedRevision: shrunk.revision,
                                                     botIDs: [ben.id, ana.id, cy.id], now: t0)
        let ben2 = try XCTUnwrap(store.listGroupParticipants(groupID: group.id).first)
        XCTAssertEqual(ben2.botID, ben.id)
        XCTAssertNil(ben2.leftAt)
        XCTAssertEqual(ben2.memberConversationID, benConversation, "a returning bot keeps its private thread")
        XCTAssertEqual(try store.listGroupMemberConversations(groupID: group.id).count, 3)

        let led = try store.updateGroup(id: group.id, expectedRevision: regrown.revision) {
            $0.policy = .lead
            $0.leadBotID = cy.id
        }
        assertInvalidInput(try self.store.setGroupParticipants(id: group.id, expectedRevision: led.revision,
                                                               botIDs: [ana.id], now: self.t0))
    }

    func test_deleteBot_leavesGroupsAndTeamsAndCancelsItsUnstartedTurns() throws {
        // WHY (F6): bot delete hard-deletes its conversations. Without this
        // cascade a 3-bot group would keep a dangling participant, a deleted
        // lead and queued turns for a bot that no longer exists.
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let cy = try makeBot("Cy")
        let team = try store.createTeam(name: "Core", memberBotIDs: [ana.id, ben.id], now: t0)
        let other = try store.createTeam(name: "Other", memberBotIDs: [cy.id], now: t0)
        let group = try makeGroup([ana, ben, cy], policy: .lead, lead: ana)
        let round = BotGroupRoundID()
        let planned = BotGroupTurn(groupID: group.id, roundID: round, botID: ana.id, ordinal: 1)
        let waiting = BotGroupTurn(groupID: group.id, roundID: round, botID: ana.id, ordinal: 2, hop: 1,
                                   state: .waitingForBot)
        let done = BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ana.id, ordinal: 0,
                                state: .completed)
        let benPlanned = BotGroupTurn(groupID: group.id, roundID: round, botID: ben.id, ordinal: 3)
        try store.insertGroupTurns([planned, waiting, done, benPlanned])

        try store.delete(id: ana.id, now: t0.addingTimeInterval(10))

        XCTAssertEqual(try store.listTeamMembers(teamID: team.id).map(\.botID), [ben.id])
        XCTAssertEqual(try store.team(id: team.id)?.revision, team.revision + 1, "iOS must see the change")
        XCTAssertEqual(try store.team(id: other.id)?.revision, other.revision, "unrelated teams are untouched")
        XCTAssertEqual(try store.listGroupParticipants(groupID: group.id).map(\.botID), [ben.id, cy.id])
        let left = try XCTUnwrap(store.listGroupParticipants(groupID: group.id, includeLeft: true)
            .first { $0.botID == ana.id })
        XCTAssertEqual(left.leftAt, t0.addingTimeInterval(10))
        let after = try XCTUnwrap(store.group(id: group.id))
        XCTAssertNil(after.leadBotID)
        XCTAssertEqual(after.policy, .roundtable, "a lead group that lost its lead keeps working")
        XCTAssertEqual(after.revision, group.revision + 1)
        XCTAssertEqual(try store.groupTurn(id: planned.id)?.state, .cancelled)
        XCTAssertEqual(try store.groupTurn(id: waiting.id)?.state, .cancelled)
        XCTAssertEqual(try store.groupTurn(id: done.id)?.state, .completed, "history is kept")
        XCTAssertEqual(try store.groupTurn(id: benPlanned.id)?.state, .planned)
        XCTAssertNoThrow(try store.insertGroupTurns([
            BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ben.id, ordinal: 4),
        ]), "the group keeps working with the remaining bots")
        XCTAssertTrue(try store.listLinkedAgentThreadIDs().contains(group.roomThreadID))
    }

    func test_transitionGroupTurn_isSingleWinner_becauseAStaleSettleMustChangeNothing() throws {
        let ana = try makeBot("Ana")
        let group = try makeGroup([ana])
        let turn = BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ana.id, ordinal: 1,
                                submitKey: "submit-1")
        try store.insertGroupTurns([turn])
        let run = AgentRunID()

        let running = try XCTUnwrap(store.transitionGroupTurn(id: turn.id, from: BotGroupTurn.State.pending,
                                                              to: .running, memberRunID: run, now: t0))
        XCTAssertEqual(running.memberRunID, run)
        XCTAssertNil(try store.transitionGroupTurn(id: turn.id, from: [.planned], to: .running, now: t0),
                     "a duplicate start loses")
        XCTAssertNotNil(try store.transitionGroupTurn(id: turn.id, from: [.running], to: .failed,
                                                      error: "Provider exited", now: t0))
        XCTAssertNil(try store.transitionGroupTurn(id: turn.id, from: [.running], to: .completed, now: t0),
                     "a late didFinish must not overwrite the settled state")
        let stored = try XCTUnwrap(store.groupTurn(id: turn.id))
        XCTAssertEqual(stored.state, .failed)
        XCTAssertEqual(stored.error, "Provider exited")
        XCTAssertEqual(stored.memberRunID, run)
        XCTAssertEqual(stored.submitKey, "submit-1")
        XCTAssertTrue(stored.state.isTerminal)
    }

    func test_insertGroupTurns_isAtomicAndUniquePerRoundBotHop() throws {
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let group = try makeGroup([ana, ben])
        let round = BotGroupRoundID()
        try store.insertGroupTurns([BotGroupTurn(groupID: group.id, roundID: round, botID: ana.id, ordinal: 1)])

        XCTAssertThrowsError(try store.insertGroupTurns([
            BotGroupTurn(groupID: group.id, roundID: round, botID: ben.id, ordinal: 2),
            BotGroupTurn(groupID: group.id, roundID: round, botID: ana.id, ordinal: 3),
        ]), "the same bot cannot answer twice at one hop of one round")
        XCTAssertEqual(try store.listGroupTurns(groupID: group.id).map(\.botID), [ana.id],
                       "a failed batch inserts nothing")
        XCTAssertNoThrow(try store.insertGroupTurns([
            BotGroupTurn(groupID: group.id, roundID: round, botID: ana.id, ordinal: 2, hop: 1),
        ]), "a mention hand-off is a new hop")
    }

    func test_cancelPendingGroupTurns_supersedesOnlyUnstartedTurns() throws {
        // WHY (3.2): a new user message supersedes planned turns; the running
        // turn finishes first. Other groups are untouched.
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let group = try makeGroup([ana, ben])
        let otherGroup = try makeGroup([ana])
        let round = BotGroupRoundID()
        let running = BotGroupTurn(groupID: group.id, roundID: round, botID: ana.id, ordinal: 1, state: .running)
        let planned = BotGroupTurn(groupID: group.id, roundID: round, botID: ben.id, ordinal: 2)
        let waiting = BotGroupTurn(groupID: group.id, roundID: round, botID: ben.id, ordinal: 3, hop: 1,
                                   state: .waitingForBot)
        let elsewhere = BotGroupTurn(groupID: otherGroup.id, roundID: BotGroupRoundID(), botID: ana.id, ordinal: 1)
        try store.insertGroupTurns([running, planned, waiting, elsewhere])

        let cancelled = try store.cancelPendingGroupTurns(groupID: group.id, now: t0)

        XCTAssertEqual(Set(cancelled.map(\.id)), [planned.id, waiting.id])
        XCTAssertEqual(try store.listGroupTurns(groupID: group.id, states: [.running]).map(\.id), [running.id])
        XCTAssertEqual(try store.listGroupTurns(groupID: group.id, states: [.cancelled]).count, 2)
        XCTAssertEqual(try store.listGroupTurns(groupID: nil, states: BotGroupTurn.State.pending).map(\.id),
                       [elsewhere.id], "relaunch reconcile can find pending turns across groups")
        XCTAssertEqual(try store.listGroupTurns(groupID: group.id, states: []), [])
    }

    func test_deleteGroup_removesRowsAndReturnsThreadsToRemove() throws {
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let desk = BotConversation(botID: ana.id, title: "Desk")
        try store.upsertConversation(desk)
        let group = try makeGroup([ana, ben])
        var member = try XCTUnwrap(store.listGroupMemberConversations(groupID: group.id).first { $0.botID == ana.id })
        let memberThread = AgentThreadID()
        member.linkedAgentThreadID = memberThread
        try store.upsertConversation(member)
        try store.insertGroupTurns([BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ana.id, ordinal: 1)])

        let threads = try store.deleteGroup(id: group.id)

        XCTAssertEqual(threads, [group.roomThreadID, memberThread])
        XCTAssertNil(try store.group(id: group.id))
        XCTAssertTrue(try store.listGroupParticipants(groupID: group.id, includeLeft: true).isEmpty)
        XCTAssertTrue(try store.listGroupTurns(groupID: group.id).isEmpty)
        XCTAssertTrue(try store.listGroupMemberConversations(groupID: group.id).isEmpty)
        XCTAssertNil(store.cachedBotID(linkedTo: memberThread), "the hot-path cache forgets the member thread")
        XCTAssertEqual(try store.listConversations(botID: ana.id).map(\.id), [desk.id], "desk chats are untouched")
        XCTAssertFalse(try store.listLinkedAgentThreadIDs().contains(group.roomThreadID))
        XCTAssertThrowsError(try store.deleteGroup(id: group.id)) {
            XCTAssertEqual($0 as? BotStoreError, .notFound)
        }
    }

    func test_groupStateSurvivesRelaunch_becauseRoomsAndTurnsMustPersist() throws {
        let ana = try makeBot("Ana")
        let group = try makeGroup([ana])
        let turn = BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), triggerMessageID: AgentMessageID(),
                                botID: ana.id, ordinal: 1, state: .waitingForBot, createdAt: t0, updatedAt: t0)
        try store.insertGroupTurns([turn])
        let seen = AgentMessageID()
        try store.setGroupParticipantWatermark(groupID: group.id, botID: ana.id, messageID: seen, createdAt: t0)

        let relaunched = BotStore(db: db)
        XCTAssertEqual(try relaunched.listGroups(), [group])
        XCTAssertEqual(try relaunched.groupTurn(id: turn.id), turn)
        let participant = try XCTUnwrap(relaunched.listGroupParticipants(groupID: group.id).first)
        XCTAssertEqual(participant.seenRoomMessageID, seen)
        XCTAssertEqual(participant.seenRoomCreatedAt, t0)

        _ = try relaunched.updateGroup(id: group.id, expectedRevision: nil) { $0.hidden = true }
        XCTAssertTrue(try relaunched.listGroups().isEmpty)
        XCTAssertEqual(try relaunched.listGroups(includeHidden: true).map(\.id), [group.id])
    }
}

/// Review fixes for T1: member conversations stay isolated from desk paths,
/// and stores stay usable after the bots that formed them are gone.
final class BotStoreGroupIsolationTests: BotStoreGroupsFixture {
    func test_clearDesk_keepsGroupMemberConversations_becauseParticipantsStillPointAtThem() throws {
        // WHY: "Clear all desk threads" and remote bot.conversation.clear_all
        // call deleteConversations. Deleting member rows would orphan the
        // participant, drop the member thread from the bot-owned set (Pet would
        // show it as a plain Agent App thread) and break the next room turn.
        let ana = try makeBot("Ana")
        let group = try makeGroup([ana])
        var member = try XCTUnwrap(store.listGroupMemberConversations(groupID: group.id).first)
        let memberThread = AgentThreadID()
        member.linkedAgentThreadID = memberThread
        try store.upsertConversation(member)
        let deskThread = AgentThreadID()
        try store.upsertConversation(BotConversation(botID: ana.id, title: "Desk", linkedAgentThreadID: deskThread))
        XCTAssertEqual(store.cachedBotID(linkedTo: memberThread), ana.id)

        try store.deleteConversations(botID: ana.id)

        XCTAssertTrue(try store.listConversations(botID: ana.id).isEmpty, "the desk is cleared")
        XCTAssertEqual(try store.listGroupMemberConversations(groupID: group.id).map(\.id), [member.id])
        let linked = try store.listLinkedAgentThreadIDs()
        XCTAssertTrue(linked.contains(memberThread))
        XCTAssertFalse(linked.contains(deskThread))
        XCTAssertEqual(store.cachedBotID(linkedTo: memberThread), ana.id, "member thread stays bot-owned in the cache")
        XCTAssertNil(store.cachedBotID(linkedTo: deskThread))
        let participant = try XCTUnwrap(store.listGroupParticipants(groupID: group.id).first)
        XCTAssertEqual(participant.memberConversationID, member.id)
        XCTAssertNotNil(try store.conversation(id: participant.memberConversationID))
    }

    func test_memberActivityStaysOutOfPetAttentionAndRosterRecency() throws {
        // WHY: member conversations are hidden plumbing. Once room turns set
        // attention on them, Pet's inbox and the attention list would show
        // phantom chats, and room activity would reorder the desk roster.
        let ana = try makeBot("Ana")
        let group = try makeGroup([ana])
        let desk = BotConversation(botID: ana.id, title: "Desk", attentionState: .needsAttention,
                                   createdAt: t0, updatedAt: t0)
        try store.upsertConversation(desk)
        var member = try XCTUnwrap(store.listGroupMemberConversations(groupID: group.id).first)
        member.attentionState = .needsAttention
        member.updatedAt = t0.addingTimeInterval(60)
        try store.upsertConversation(member)
        let deskItem = BotAttentionItem(botID: ana.id, conversationID: desk.id, kind: .question, title: "Desk?")
        let memberItem = BotAttentionItem(botID: ana.id, conversationID: member.id, kind: .question, title: "Room?")
        try store.upsertAttention(deskItem)
        try store.upsertAttention(memberItem)

        XCTAssertEqual(try store.listConversations(attentionStates: [.needsAttention]).map(\.id), [desk.id])
        XCTAssertEqual(try store.listAttention().map(\.id), [deskItem.id])
        XCTAssertEqual(try store.latestConversationUpdatedAt(botIDs: [ana.id])[ana.id], t0,
                       "room activity must not move the bot up the desk roster")
    }

    func test_updateGroup_afterItsLastBotIsDeleted_stillTakesBookkeeping() throws {
        // WHY: the bot-delete cascade marks every participant left. If
        // updateGroup re-checked "at least one bot", the room could never be
        // hidden, renamed or marked read, and host attention writes would throw.
        let ana = try makeBot("Ana")
        let group = try makeGroup([ana])
        try store.delete(id: ana.id, now: t0)
        XCTAssertTrue(try store.listGroupParticipants(groupID: group.id).isEmpty)

        let marked = try store.updateGroup(id: group.id, expectedRevision: nil) { $0.unread = true }
        XCTAssertTrue(marked.unread)
        let renamed = try store.updateGroup(id: group.id, expectedRevision: marked.revision) { $0.title = "Archive" }
        XCTAssertEqual(renamed.title, "Archive")
        let hidden = try store.updateGroup(id: group.id, expectedRevision: nil) { $0.hidden = true }
        XCTAssertTrue(hidden.hidden)
        assertInvalidInput(try store.updateGroup(id: group.id, expectedRevision: nil) { $0.maxAutoHops = 9 })
        // Changing participants still needs at least one bot.
        assertInvalidInput(try store.setGroupParticipants(id: group.id, expectedRevision: hidden.revision, botIDs: []))
    }

    func test_transitionGroupTurn_staleRunCannotSettleARetriedTurn() throws {
        // WHY: run R1 is stopped (turn cancelled), the turn is retried with
        // R2, then R1's late didFinish arrives. Its outcome must not land on
        // R2's turn, so the run check has to be inside the store transaction.
        let ana = try makeBot("Ana")
        let group = try makeGroup([ana])
        let turn = BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ana.id, ordinal: 1)
        try store.insertGroupTurns([turn])
        let r1 = AgentRunID()
        let r2 = AgentRunID()
        _ = try XCTUnwrap(store.transitionGroupTurn(id: turn.id, from: [.planned], to: .running, memberRunID: r1))
        _ = try XCTUnwrap(store.transitionGroupTurn(id: turn.id, from: [.running], to: .failed,
                                                expectedMemberRunID: r1, error: "Stopped"))
        let retried = try XCTUnwrap(store.transitionGroupTurn(id: turn.id, from: [.failed], to: .running,
                                                              memberRunID: r2, clearError: true))
        XCTAssertNil(retried.error, "a retry starts clean")
        XCTAssertEqual(retried.memberRunID, r2)

        XCTAssertNil(try store.transitionGroupTurn(id: turn.id, from: [.running], to: .completed,
                                                   expectedMemberRunID: r1),
                     "R1's late finish matches the state but not the run")
        let stillRunning = try XCTUnwrap(store.groupTurn(id: turn.id))
        XCTAssertEqual(stillRunning.state, .running)
        XCTAssertEqual(stillRunning.memberRunID, r2)

        let settled = try XCTUnwrap(store.transitionGroupTurn(id: turn.id, from: [.running], to: .completed,
                                                              expectedMemberRunID: r2))
        XCTAssertEqual(settled.state, .completed)
        let cleared = try XCTUnwrap(store.transitionGroupTurn(id: turn.id, from: [.completed], to: .planned,
                                                              clearMemberRunID: true))
        XCTAssertNil(cleared.memberRunID)
        XCTAssertNil(try store.groupTurn(id: turn.id)?.memberRunID, "the clear is persisted")
    }

    func test_insertGroupTurns_rejectsADuplicateRoundForTheSameSubmitKey() throws {
        // WHY: bot.group.send is idempotent by submit_key. Two concurrent
        // retries must not each insert a full round; the loser's batch fails
        // as a whole and the first round is untouched.
        let ana = try makeBot("Ana")
        let ben = try makeBot("Ben")
        let group = try makeGroup([ana, ben])
        let first = BotGroupRoundID()
        try store.insertGroupTurns([
            BotGroupTurn(groupID: group.id, roundID: first, botID: ana.id, ordinal: 1, submitKey: "send-1"),
            BotGroupTurn(groupID: group.id, roundID: first, botID: ben.id, ordinal: 2, submitKey: "send-1"),
        ])
        let duplicate = BotGroupRoundID()
        XCTAssertThrowsError(try store.insertGroupTurns([
            BotGroupTurn(groupID: group.id, roundID: duplicate, botID: ana.id, ordinal: 3, submitKey: "send-1"),
            BotGroupTurn(groupID: group.id, roundID: duplicate, botID: ben.id, ordinal: 4, submitKey: "send-1"),
        ]))
        XCTAssertEqual(Set(try store.listGroupTurns(groupID: group.id).map(\.roundID)), [first])
        XCTAssertNoThrow(try store.insertGroupTurns([
            BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ana.id, ordinal: 3, submitKey: "send-2"),
            BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ana.id, ordinal: 4),
            BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ana.id, ordinal: 5),
        ]), "a new send, and turns without a key, are never deduplicated")
    }

    func test_remoteConversationRPCsRejectMemberConversations_becauseOnlyGroupRPCsMayReachThem() throws {
        // WHY: a paired client that learns a member conversation id must not
        // send into it (bypassing sequential turns and D12), select it, or
        // stage attachments there (groups reject attachments).
        let ana = try makeBot("Ana")
        let group = try makeGroup([ana])
        let member = try XCTUnwrap(store.listGroupMemberConversations(groupID: group.id).first)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: SettingsStore(db: db),
                                                  appSupportDirectory: support)
        let botID = ana.id.value.uuidString.lowercased()
        let memberID = member.id.value.uuidString.lowercased()
        let calls: [(String, [String: Any])] = [
            ("bot.send", ["text": "hello"]),
            ("bot.conversation.select", [:]),
            ("bot.attachment.stage", [
                "attachment_id": "rcatt1_\(String(repeating: "a", count: 32))",
                "filename": "x.txt",
                "kind": "file",
                "digest": String(repeating: "b", count: 64),
                "size": 4,
            ]),
            ("bot.attachment.list", [:]),
        ]
        for (index, call) in calls.enumerated() {
            var params = call.1
            params["client_request_id"] = "member-\(index)"
            params["bot_id"] = botID
            params["conversation_id"] = memberID
            XCTAssertThrowsError(try authority.dispatch(method: call.0, params: params), call.0) { error in
                XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget, call.0)
            }
        }
    }
}

/// `migrateSteps` skips by version. A sibling branch's step recorded at v88
/// first must not leave this branch without its group schema.
final class BotTeamsGroupsSchemaHealTests: XCTestCase {
    func test_foreignStepAtV88_stillLeavesTheGroupSchemaInPlace() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version < Schema.botTeamsGroupsSchemaVersion })
        try db.execute("""
            INSERT INTO schema_meta(version, applied_at)
            VALUES(\(Schema.botTeamsGroupsSchemaVersion), '2026-10-06T00:00:00Z');
            """)

        try Schema.migrate(db)
        try Schema.migrate(db)

        let store = BotStore(db: db)
        let ana = try store.create(name: "Ana", title: "Teammate", description: "", provider: .claude)
        let group = try store.createGroup(title: "Room", roomThreadID: AgentThreadID(), participantBotIDs: [ana.id])
        XCTAssertTrue(try store.listConversations(botID: ana.id).isEmpty, "group_id exists, so desk lists work")
        XCTAssertEqual(try store.listGroupMemberConversations(groupID: group.id).count, 1)
        let index = try db.prepare("SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_bot_group_turns_submit';")
        defer { index.reset() }
        XCTAssertTrue(try index.step())
        XCTAssertEqual(index.columnInt64(0), 1)
    }
}
