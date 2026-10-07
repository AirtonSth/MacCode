import XCTest
@testable import CoreModel

final class BotGroupTurnPlannerTests: XCTestCase {
    private let alpha = BotDefinition(handle: "alpha", name: "Alpha", title: "Research", description: "")
    private let beta = BotDefinition(handle: "beta", name: "Beta", title: "Design", description: "")
    private let gamma = BotDefinition(handle: "gamma", name: "Gamma", title: "", description: "")
    private let outsider = BotDefinition(handle: "outsider", name: "Outsider", title: "", description: "")
    private var participants: [BotDefinition] { [alpha, beta, gamma] }

    private func turns(_ plan: BotGroupTurnPlanner.UserRoundPlan) -> [BotGroupTurnPlanner.PlannedTurn] {
        guard case .turns(let turns) = plan else {
            XCTFail("expected turns, got \(plan)")
            return []
        }
        return turns
    }

    // MARK: - User round

    func test_userMentions_answerInTextOrder_deduplicated_outsidersIgnored() {
        // WHY: the user picks who speaks and in what order; a repeated
        // mention must not make a bot answer twice, and a bot outside the
        // group must never be started from the room.
        let plan = BotGroupTurnPlanner.planUserRound(
            text: "@gamma first, then @alpha. @outsider too, and again @gamma",
            participants: participants,
            policy: .roundtable,
            leadBotID: nil
        )
        XCTAssertEqual(turns(plan).map(\.botID), [gamma.id, alpha.id])
        XCTAssertEqual(turns(plan).map(\.hop), [0, 0])
    }

    func test_roundtable_withoutMention_everyParticipantAnswersInGroupOrder() {
        let plan = BotGroupTurnPlanner.planUserRound(
            text: "What should we ship first?",
            participants: participants,
            policy: .roundtable,
            leadBotID: nil
        )
        XCTAssertEqual(turns(plan).map(\.botID), [alpha.id, beta.id, gamma.id])
    }

    func test_onlyOutsiderMentioned_fallsBackToPolicy() {
        // WHY: mentioning a bot that is not in the room is not a choice of
        // speaker inside the room, so the policy still decides.
        let plan = BotGroupTurnPlanner.planUserRound(
            text: "ask @outsider later",
            participants: participants,
            policy: .roundtable,
            leadBotID: nil
        )
        XCTAssertEqual(turns(plan).map(\.botID), [alpha.id, beta.id, gamma.id])
    }

    func test_lead_withoutMention_onlyLeadAnswers_mentionStillWins() {
        let lead = BotGroupTurnPlanner.planUserRound(
            text: "status?",
            participants: participants,
            policy: .lead,
            leadBotID: beta.id
        )
        XCTAssertEqual(turns(lead).map(\.botID), [beta.id])

        let mentioned = BotGroupTurnPlanner.planUserRound(
            text: "@gamma status?",
            participants: participants,
            policy: .lead,
            leadBotID: beta.id
        )
        XCTAssertEqual(turns(mentioned).map(\.botID), [gamma.id])
    }

    func test_lead_whoLeftTheGroup_fallsBackToRoundtable() {
        // WHY: BotStore drops a deleted lead back to roundtable; a planner
        // reading a stale lead must not silently answer with nobody.
        let plan = BotGroupTurnPlanner.planUserRound(
            text: "status?",
            participants: [alpha, gamma],
            policy: .lead,
            leadBotID: beta.id
        )
        XCTAssertEqual(turns(plan).map(\.botID), [alpha.id, gamma.id])
    }

    func test_mentionsOnly_rejectsUnmentionedSend_withClearMessage() {
        let plan = BotGroupTurnPlanner.planUserRound(
            text: "hello everyone",
            participants: participants,
            policy: .mentionsOnly,
            leadBotID: nil
        )
        XCTAssertEqual(plan, .rejected(.mentionRequired))
        XCTAssertTrue(BotGroupTurnPlanner.Rejection.mentionRequired.message.contains("@mention"))

        let mentioned = BotGroupTurnPlanner.planUserRound(
            text: "hello @beta",
            participants: participants,
            policy: .mentionsOnly,
            leadBotID: nil
        )
        XCTAssertEqual(turns(mentioned).map(\.botID), [beta.id])
    }

    func test_emptyGroup_isRejected() {
        XCTAssertEqual(
            BotGroupTurnPlanner.planUserRound(text: "@alpha hi", participants: [], policy: .roundtable, leadBotID: nil),
            .rejected(.noParticipants)
        )
    }

    // MARK: - Hand-offs

    private func turn(
        _ bot: BotDefinition,
        round: BotGroupRoundID,
        hop: Int = 0,
        state: BotGroupTurn.State,
        ordinal: Int = 0
    ) -> BotGroupTurn {
        BotGroupTurn(groupID: BotGroupID(), roundID: round, botID: bot.id, ordinal: ordinal, hop: hop, state: state)
    }

    func test_handOff_mentionedParticipantsGetNextHops_selfAndOutsidersIgnored() {
        let round = BotGroupRoundID()
        let author = turn(alpha, round: round, state: .running)
        let plan = BotGroupTurnPlanner.planHandOff(
            replyText: "@alpha (me) thinks @gamma and @outsider should weigh in, then @beta",
            author: author,
            groupTurns: [author],
            latestRoundID: round,
            participants: participants,
            maxAutoHops: 4
        )
        XCTAssertEqual(plan.turns.map(\.botID), [gamma.id, beta.id])
        XCTAssertEqual(plan.turns.map(\.hop), [1, 2])
        XCTAssertTrue(plan.pausedBotIDs.isEmpty)
    }

    func test_handOff_skipsBotsAlreadyQueuedInRound() {
        // WHY: a roundtable bot that has not spoken yet will see the mention
        // in its room delta; a second turn would make it answer twice.
        let round = BotGroupRoundID()
        let author = turn(alpha, round: round, state: .running, ordinal: 0)
        let pendingBeta = turn(beta, round: round, state: .planned, ordinal: 1)
        let doneGamma = turn(gamma, round: round, state: .completed, ordinal: 2)
        let plan = BotGroupTurnPlanner.planHandOff(
            replyText: "@beta and @gamma, thoughts?",
            author: author,
            groupTurns: [author, pendingBeta, doneGamma],
            latestRoundID: round,
            participants: participants,
            maxAutoHops: 4
        )
        XCTAssertEqual(plan.turns, [.init(botID: gamma.id, hop: 1)])
    }

    func test_handOff_hopBudgetCountsWholeRound_thenPausesHonestly() {
        // WHY: the budget bounds total automatic turns per round, so two bots
        // that keep mentioning each other stop after maxAutoHops and the room
        // says who was not asked instead of looping forever.
        let round = BotGroupRoundID()
        var history = [turn(alpha, round: round, hop: 0, state: .completed, ordinal: 0)]
        var speaker = alpha
        var handOffs = 0
        var paused: [BotID] = []
        for step in 1...10 {
            let author = turn(speaker, round: round, hop: history.last!.hop, state: .running, ordinal: step)
            let next = speaker.id == alpha.id ? beta : alpha
            let plan = BotGroupTurnPlanner.planHandOff(
                replyText: "over to you @\(next.handle)",
                author: author,
                groupTurns: history + [author],
                latestRoundID: round,
                participants: participants,
                maxAutoHops: 4
            )
            history.append(turn(speaker, round: round, hop: author.hop, state: .completed, ordinal: step))
            if let handOff = plan.turns.first {
                handOffs += 1
                history.append(turn(next, round: round, hop: handOff.hop, state: .completed, ordinal: step))
                speaker = next
            } else {
                paused = plan.pausedBotIDs
                break
            }
        }
        XCTAssertEqual(handOffs, 4)
        XCTAssertEqual(paused.count, 1)
        XCTAssertEqual(Set(history.map(\.hop)).max(), 4)
    }

    func test_handOff_partialBudget_plansWhatFits_andPausesTheRest() {
        let round = BotGroupRoundID()
        let author = turn(alpha, round: round, hop: 3, state: .running)
        let plan = BotGroupTurnPlanner.planHandOff(
            replyText: "@beta then @gamma",
            author: author,
            groupTurns: [author],
            latestRoundID: round,
            participants: participants,
            maxAutoHops: 4
        )
        XCTAssertEqual(plan.turns, [.init(botID: beta.id, hop: 4)])
        XCTAssertEqual(plan.pausedBotIDs, [gamma.id])
        let note = BotGroupTurnPlanner.pausedNote(pausedBots: [gamma], maxAutoHops: 4)
        XCTAssertTrue(note.contains("@gamma"))
        XCTAssertTrue(note.contains("4 automatic hand-offs"))
    }

    func test_handOff_budgetIsClampedToHardCap() {
        // WHY: the hard cap 8 is a safety bound even if a stored value is
        // out of range; hop 9 would also violate the store's hop check.
        let round = BotGroupRoundID()
        let author = turn(alpha, round: round, hop: 8, state: .running)
        let plan = BotGroupTurnPlanner.planHandOff(
            replyText: "@beta",
            author: author,
            groupTurns: [author],
            latestRoundID: round,
            participants: participants,
            maxAutoHops: 50
        )
        XCTAssertTrue(plan.turns.isEmpty)
        XCTAssertEqual(plan.pausedBotIDs, [beta.id])
    }

    func test_handOff_zeroBudget_pausesWithHandOffsOffCopy() {
        let round = BotGroupRoundID()
        let author = turn(alpha, round: round, state: .running)
        let plan = BotGroupTurnPlanner.planHandOff(
            replyText: "@beta",
            author: author,
            groupTurns: [author],
            latestRoundID: round,
            participants: participants,
            maxAutoHops: 0
        )
        XCTAssertTrue(plan.turns.isEmpty)
        XCTAssertEqual(plan.pausedBotIDs, [beta.id])
        XCTAssertTrue(BotGroupTurnPlanner.pausedNote(pausedBots: [beta], maxAutoHops: 0).contains("off"))
    }

    // MARK: - Supersede

    func test_newUserMessage_cancelsUnstartedTurns_runningTurnFinishes() {
        // WHY: latest wins. The user moved on, so queued answers to the old
        // message are dropped, but a run already in flight is not killed.
        let round = BotGroupRoundID()
        let running = turn(alpha, round: round, state: .running, ordinal: 0)
        let planned = turn(beta, round: round, state: .planned, ordinal: 1)
        let waiting = turn(gamma, round: round, state: .waitingForBot, ordinal: 2)
        let done = turn(gamma, round: BotGroupRoundID(), state: .completed)
        let result = BotGroupTurnPlanner.supersede([done, running, planned, waiting], newRoundID: BotGroupRoundID())
        XCTAssertEqual(result.cancelledTurnIDs, [planned.id, waiting.id])
        XCTAssertEqual(result.runningTurnID, running.id)
    }

    func test_supersede_neverCancelsTheNewRoundsOwnTurns() {
        // WHY: the orchestrator may insert the new round's turns before it
        // supersedes; the new message must not cancel its own answers.
        let oldRound = BotGroupRoundID()
        let newRound = BotGroupRoundID()
        let oldPlanned = turn(beta, round: oldRound, state: .planned, ordinal: 1)
        let newPlanned = turn(alpha, round: newRound, state: .planned, ordinal: 2)
        let newWaiting = turn(gamma, round: newRound, state: .waitingForBot, ordinal: 3)
        let result = BotGroupTurnPlanner.supersede([oldPlanned, newPlanned, newWaiting], newRoundID: newRound)
        XCTAssertEqual(result.cancelledTurnIDs, [oldPlanned.id])
        XCTAssertNil(result.runningTurnID)
    }

    func test_handOff_ignoresEmailsAndMentionsInCode() {
        // WHY: a hand-off starts a real run. An address like bob@beta or an
        // example in code is not the author handing the floor to anyone.
        let round = BotGroupRoundID()
        let author = turn(alpha, round: round, state: .running)
        let reply = """
        Mail bob@beta or x_@gamma. Use `@beta` inline, ``say @gamma``, or:
        ```
        @beta run
        ```
        ~~~
        @gamma run
        ~~~
        Unclosed fence:
        ```
        @beta
        """
        let plan = BotGroupTurnPlanner.planHandOff(
            replyText: reply,
            author: author,
            groupTurns: [author],
            latestRoundID: round,
            participants: participants,
            maxAutoHops: 4
        )
        XCTAssertEqual(plan, .none)

        let prose = BotGroupTurnPlanner.planHandOff(
            replyText: "See `code` then (@gamma) and,@beta please.",
            author: author,
            groupTurns: [author],
            latestRoundID: round,
            participants: participants,
            maxAutoHops: 4
        )
        XCTAssertEqual(prose.turns.map(\.botID), [gamma.id, beta.id], "prose mentions after punctuation still hand off")
    }

    func test_supersededRound_handsOffNothing() {
        // WHY: a reply that lands after the user wrote again must not start
        // new turns on the old topic.
        let oldRound = BotGroupRoundID()
        let author = turn(alpha, round: oldRound, state: .running)
        let plan = BotGroupTurnPlanner.planHandOff(
            replyText: "@beta please continue",
            author: author,
            groupTurns: [author],
            latestRoundID: BotGroupRoundID(),
            participants: participants,
            maxAutoHops: 4
        )
        XCTAssertEqual(plan, .none)
    }
}
