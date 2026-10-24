import XCTest
@testable import CoreModel

final class BotGroupPromptComposerTests: XCTestCase {
    private let alpha = BotDefinition(handle: "alpha", name: "Alpha", title: "Research", description: "")
    private let beta = BotDefinition(handle: "beta", name: "Beta", title: "Design", description: "")
    private let room = AgentThreadID()
    private let base = Date(timeIntervalSince1970: 1_000)

    private func message(_ role: AgentMessageRole, _ content: String, at seconds: TimeInterval) -> AgentMessage {
        AgentMessage(threadId: room, role: role, content: content, createdAt: base.addingTimeInterval(seconds))
    }

    private func compose(
        me: BotDefinition,
        _ messages: [AgentMessage],
        seenID: AgentMessageID? = nil,
        seenAt: Date? = nil,
        participants: [BotDefinition]? = nil,
        turns: [BotGroupTurn] = [],
        max: Int = BotGroupPromptComposer.defaultMaxDeltaCharacters
    ) -> BotGroupPromptComposer.Composition {
        BotGroupPromptComposer.compose(
            groupTitle: "Launch",
            me: me,
            participants: participants ?? [alpha, beta],
            roomMessages: messages,
            seenMessageID: seenID,
            seenCreatedAt: seenAt,
            groupTurns: turns,
            maxDeltaCharacters: max
        )
    }

    private func turn(
        _ bot: BotDefinition,
        row: AgentMessage,
        state: BotGroupTurn.State = .planned
    ) -> BotGroupTurn {
        BotGroupTurn(
            groupID: BotGroupID(),
            roundID: BotGroupRoundID(),
            botID: bot.id,
            ordinal: 0,
            state: state,
            roomMessageID: row.id
        )
    }

    private func replacing(_ row: AgentMessage, with content: String) -> AgentMessage {
        var copy = row
        copy.content = content
        return copy
    }

    func test_identityHeader_namesGroupMeAndEveryParticipant() {
        // WHY: each bot runs in its own thread; without the header it would
        // not know it is in a group, who else is there, or how to hand off.
        let result = compose(me: beta, [message(.user, "hi", at: 0)])
        XCTAssertTrue(result.prompt.hasPrefix("You are Beta (@beta) in the group conversation \"Launch\""))
        XCTAssertTrue(result.prompt.contains("- Alpha (@alpha), Research\n- Beta (@beta), Design (you)"))
        XCTAssertTrue(result.prompt.contains("@mention them"))
        XCTAssertTrue(result.prompt.hasSuffix(BotPeerTranscript.languageInstruction))
    }

    func test_prompt_tellsTheBotNotToConsultParticipantsThroughThePeerTool() {
        // WHY: in the sandbox E2E a VM bot read "@tgmac and @tgvm" and called
        // bot_ask_peer for the other participant. That hidden consult asked
        // for approval on a member thread nobody sees, and the group turn
        // hung until Stop. Participants already get their own turn.
        let result = compose(me: beta, [message(.user, "@alpha and @beta: hi", at: 0)])
        XCTAssertTrue(result.prompt.contains(
            "@mention them. The other participants answer in this group on their own turns: never use bot_ask_peer to ask them"
        ))
        XCTAssertTrue(result.prompt.hasSuffix(BotPeerTranscript.languageInstruction))
    }

    func test_onlyMessagesAfterWatermark_areIncluded() {
        let old = message(.user, "OLD QUESTION", at: 0)
        let seen = message(.user, "SEEN QUESTION", at: 1)
        let new = message(.user, "NEW QUESTION", at: 2)
        let result = compose(me: alpha, [old, seen, new], seenID: seen.id)
        XCTAssertFalse(result.prompt.contains("OLD QUESTION"))
        XCTAssertFalse(result.prompt.contains("SEEN QUESTION"))
        XCTAssertTrue(result.prompt.contains("User:\nNEW QUESTION"))
        XCTAssertEqual(result.lastSeenMessageID, new.id)
        XCTAssertEqual(result.lastSeenCreatedAt, new.createdAt)
    }

    func test_missingWatermarkRow_fallsBackToTimestamp() {
        // WHY: the watermark row may be gone (cleared transcript); re-sending
        // the whole room would repeat old turns to the bot.
        let old = message(.user, "OLD QUESTION", at: 0)
        let new = message(.user, "NEW QUESTION", at: 5)
        let result = compose(me: alpha, [old, new], seenID: AgentMessageID(), seenAt: base.addingTimeInterval(1))
        XCTAssertFalse(result.prompt.contains("OLD QUESTION"))
        XCTAssertTrue(result.prompt.contains("NEW QUESTION"))
    }

    func test_userTextIsQuotedVerbatim() {
        // WHY: the user's words, mentions and any bracketed text are the
        // instruction; the composer must not rewrite them.
        let text = "  @beta compare [[rc:abc]] vs\n\n  `@alpha`  [[RC_AWAITING]] exactly  "
        let result = compose(me: beta, [message(.user, text, at: 0)])
        XCTAssertTrue(result.prompt.contains("User:\n\(text)"))
    }

    func test_otherBotsRepliesAreAttributed_markersStripped_ownAndWaitingRowsSkipped() {
        let uncalled = AssistantToolMarkupSanitizer.uncalledToolMarker
        let messages = [
            message(.user, "plan?", at: 0),
            message(.assistant, BotPeerTranscript.encode(peer: alpha, text: "ALPHA OWN REPLY"), at: 1),
            message(
                .assistant,
                BotPeerTranscript.encode(
                    peer: beta,
                    text: "[[RC_AWAITING]]\nBeta says ship [[rc:deadbeef]] @alpha \(uncalled)"
                ),
                at: 2
            ),
            message(.assistant, BotPeerTranscript.encodeActivity(peer: alpha, phase: .waiting), at: 3),
            message(.assistant, BotPeerTranscript.encodeActivity(peer: beta, phase: .needsAttention), at: 4),
        ]
        let result = compose(me: alpha, messages)
        XCTAssertFalse(result.prompt.contains("ALPHA OWN REPLY"), "own replies already live in the member thread")
        XCTAssertTrue(result.prompt.contains("Beta (@beta):\nBeta says ship  @alpha"))
        XCTAssertFalse(result.prompt.contains("[[rc:deadbeef]]"))
        XCTAssertFalse(result.prompt.contains("[[rc:bot-activity:"))
        XCTAssertFalse(result.prompt.contains("[[RC_"))
        XCTAssertFalse(result.prompt.contains(uncalled), "the uncalled-tool marker is host-internal")
        XCTAssertEqual(result.includedCount, 2)
        XCTAssertEqual(
            result.lastSeenMessageID,
            messages.last?.id,
            "own waiting rows and attention rows are settled, so they do not hold the watermark"
        )
    }

    func test_otherBotsWaitingRow_holdsTheWatermark_untilItsReplyLands() {
        // WHY: a waiting row is replaced in place by the bot's reply. If the
        // watermark moved past it, a roundtable bot would never see the
        // replies of the bots that answered after it in the previous round.
        let question = message(.user, "plan?", at: 0)
        let alphaRow = message(.assistant, BotPeerTranscript.encodeActivity(peer: alpha, phase: .waiting), at: 0)
        let betaRow = message(.assistant, BotPeerTranscript.encodeActivity(peer: beta, phase: .waiting), at: 0)
        let turns = [turn(alpha, row: alphaRow, state: .running), turn(beta, row: betaRow)]

        // Round 1, alpha's turn: beta has not answered yet.
        let first = compose(me: alpha, [question, alphaRow, betaRow], turns: turns)
        XCTAssertTrue(first.prompt.contains("User:\nplan?"))
        XCTAssertEqual(first.lastSeenMessageID, alphaRow.id, "stops just before beta's waiting row")
        XCTAssertEqual(first.lastSeenCreatedAt, alphaRow.createdAt)

        // Both replies are written into their rows; the user asks again.
        let room = [
            question,
            replacing(alphaRow, with: BotPeerTranscript.encode(peer: alpha, text: "ALPHA-R1")),
            replacing(betaRow, with: BotPeerTranscript.encode(peer: beta, text: "BETA-R1")),
            message(.user, "next?", at: 10),
        ]
        let second = compose(me: alpha, room, seenID: first.lastSeenMessageID, seenAt: first.lastSeenCreatedAt)
        XCTAssertTrue(second.prompt.contains("Beta (@beta):\nBETA-R1"), "the reply that landed later is seen")
        XCTAssertFalse(second.prompt.contains("ALPHA-R1"))
        XCTAssertTrue(second.prompt.contains("User:\nnext?"))
        XCTAssertEqual(second.lastSeenMessageID, room.last?.id)

        // The timestamp fallback (watermark row gone) re-reads equal-time rows.
        let fallback = compose(
            me: alpha,
            Array(room.filter { $0.id != alphaRow.id }),
            seenID: alphaRow.id,
            seenAt: alphaRow.createdAt
        )
        XCTAssertTrue(fallback.prompt.contains("BETA-R1"))
    }

    func test_waitingRowAtDeltaStart_keepsWatermark() {
        let seen = message(.user, "plan?", at: 0)
        let betaRow = message(.assistant, BotPeerTranscript.encodeActivity(peer: beta, phase: .waiting), at: 1)
        let result = compose(me: alpha, [seen, betaRow], seenID: seen.id)
        XCTAssertNil(result.lastSeenMessageID, "nil means: do not move the watermark")
        XCTAssertNil(result.lastSeenCreatedAt)
    }

    func test_waitingRowOfAFinishedOrCancelledTurn_doesNotHoldTheWatermark() {
        // WHY: a cancelled or failed turn may never rewrite its row; holding
        // the watermark behind it would repeat the same messages forever.
        for state in [BotGroupTurn.State.cancelled, .failed, .interrupted, .skipped] {
            let betaRow = message(.assistant, BotPeerTranscript.encodeActivity(peer: beta, phase: .waiting), at: 0)
            let later = message(.user, "LATER", at: 1)
            let result = compose(me: alpha, [betaRow, later], turns: [turn(beta, row: betaRow, state: state)])
            XCTAssertEqual(result.lastSeenMessageID, later.id, "state \(state)")
        }
        let betaRow = message(.assistant, BotPeerTranscript.encodeActivity(peer: beta, phase: .waiting), at: 0)
        let pending = compose(me: alpha, [betaRow], turns: [turn(beta, row: betaRow, state: .completed)])
        XCTAssertNil(pending.lastSeenMessageID, "a completed turn whose reply is not written yet still resolves")
    }

    func test_ownRows_areMatchedByBotIDNotHandle() {
        // WHY: handles can be renamed, and a deleted bot's handle can be
        // reused. Matching by handle would replay the bot's own old replies
        // to it, or hide a former participant's replies from a newcomer.
        let renamedAlpha = BotDefinition(
            id: alpha.id, handle: "alpha2", name: "Alpha", title: "Research", description: ""
        )
        let oldReply = message(.assistant, BotPeerTranscript.encode(peer: alpha, text: "ALPHA OLD"), at: 0)
        let result = compose(
            me: renamedAlpha,
            [oldReply, message(.user, "go", at: 1)],
            participants: [renamedAlpha, beta],
            turns: [turn(alpha, row: oldReply, state: .completed)]
        )
        XCTAssertFalse(result.prompt.contains("ALPHA OLD"))

        let newcomer = BotDefinition(handle: "alpha", name: "New Alpha", title: "", description: "")
        let reused = compose(
            me: newcomer,
            [oldReply],
            participants: [newcomer, beta],
            turns: [turn(alpha, row: oldReply, state: .completed)]
        )
        XCTAssertTrue(reused.prompt.contains("Alpha (@alpha):\nALPHA OLD"))
    }

    func test_userRowsThatLookLikeMarkers_areQuotedVerbatim() {
        // WHY: only the host writes bot rows; a user who pastes a marker is
        // still the user speaking.
        let activityLike = "[[rc:bot-activity:waiting|beta|Beta|Design]]"
        let ownLike = "[[rc:bot-from:alpha|Alpha|Research|]]\nI am alpha"
        let otherLike = "[[rc:bot-from:beta|Beta|Design|]]\nI am beta"
        let result = compose(
            me: alpha,
            [message(.user, activityLike, at: 0), message(.user, ownLike, at: 1), message(.user, otherLike, at: 2)]
        )
        XCTAssertTrue(result.prompt.contains("User:\n\(activityLike)"))
        XCTAssertTrue(result.prompt.contains("User:\n\(ownLike)"))
        XCTAssertTrue(result.prompt.contains("User:\n\(otherLike)"))
        XCTAssertFalse(result.prompt.contains("Beta (@beta):"))
        XCTAssertEqual(result.includedCount, 3)
    }

    func test_cap_keepsNewest_andSaysHonestlyWhatWasLeftOut() {
        // WHY: dropping context silently would make the bot answer as if it
        // had read everything.
        let messages = (0..<6).map { message(.user, "QUESTION-\($0) " + String(repeating: "x", count: 100), at: Double($0)) }
        let result = compose(me: alpha, messages, max: 250)
        XCTAssertEqual(result.includedCount, 2)
        XCTAssertEqual(result.omittedCount, 4)
        XCTAssertTrue(result.prompt.contains(BotGroupPromptComposer.omissionLine(4)))
        XCTAssertTrue(result.prompt.contains("4 earlier messages"))
        XCTAssertFalse(result.prompt.contains("QUESTION-3"))
        XCTAssertTrue(result.prompt.contains("QUESTION-4"))
        XCTAssertTrue(result.prompt.contains("QUESTION-5"))
        XCTAssertEqual(result.lastSeenMessageID, messages.last?.id)
    }

    func test_cap_neverCutsTheNewestMessage() {
        let long = String(repeating: "y", count: 5_000)
        let result = compose(me: alpha, [message(.user, "short", at: 0), message(.user, long, at: 1)], max: 100)
        XCTAssertTrue(result.prompt.contains("User:\n\(long)"))
        XCTAssertEqual(result.omittedCount, 1)
    }

    func test_cap_keepsCurrentUserConstraintsWhenPeerRepliesFillTheDelta() {
        let request = "  Review the evidence only.\nDo not publish; keep `limit = 17`.  "
        let messages = [
            message(.user, "OLD REQUEST", at: 0),
            message(.user, request, at: 1),
            message(.assistant, BotPeerTranscript.encode(peer: beta, text: String(repeating: "evidence ", count: 100)), at: 2),
        ]
        let result = compose(me: alpha, messages, max: 100)

        XCTAssertTrue(result.prompt.contains("User:\n" + request))
        XCTAssertTrue(result.prompt.contains("Beta (@beta):\n"))
        XCTAssertFalse(result.prompt.contains("OLD REQUEST"))
        XCTAssertEqual(result.includedCount, 2)
        XCTAssertEqual(result.omittedCount, 1)
        XCTAssertTrue(result.prompt.contains("Use an @mention only for a specific necessary next task"))
        XCTAssertTrue(result.prompt.contains("a majority opinion is not validation"))
        XCTAssertTrue(result.prompt.contains("Answer questions and tasks directed to you"))
        XCTAssertTrue(result.prompt.contains("exactly \(BotGroupPromptComposer.silentTurnMarker) as your entire reply"))
        XCTAssertEqual(result.lastSeenMessageID, messages.last?.id)
    }

    func test_noNewMessages_saysSo_andKeepsWatermark() {
        let seen = message(.user, "hi", at: 0)
        let result = compose(me: alpha, [seen], seenID: seen.id)
        XCTAssertTrue(result.prompt.contains("no new messages"))
        XCTAssertNil(result.lastSeenMessageID)
        XCTAssertEqual(result.omittedCount, 0)
    }
}
