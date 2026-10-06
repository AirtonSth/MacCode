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
        max: Int = BotGroupPromptComposer.defaultMaxDeltaCharacters
    ) -> BotGroupPromptComposer.Composition {
        BotGroupPromptComposer.compose(
            groupTitle: "Launch",
            me: me,
            participants: [alpha, beta],
            roomMessages: messages,
            seenMessageID: seenID,
            seenCreatedAt: seenAt,
            maxDeltaCharacters: max
        )
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
        let messages = [
            message(.user, "plan?", at: 0),
            message(.assistant, BotPeerTranscript.encode(peer: alpha, text: "ALPHA OWN REPLY"), at: 1),
            message(
                .assistant,
                BotPeerTranscript.encode(peer: beta, text: "[[RC_AWAITING]]\nBeta says ship [[rc:deadbeef]] @alpha"),
                at: 2
            ),
            message(.assistant, BotPeerTranscript.encodeActivity(peer: beta, phase: .waiting), at: 3),
        ]
        let result = compose(me: alpha, messages)
        XCTAssertFalse(result.prompt.contains("ALPHA OWN REPLY"), "own replies already live in the member thread")
        XCTAssertTrue(result.prompt.contains("Beta (@beta):\nBeta says ship  @alpha"))
        XCTAssertFalse(result.prompt.contains("[[rc:"))
        XCTAssertFalse(result.prompt.contains("[[RC_"))
        XCTAssertEqual(result.includedCount, 2)
        XCTAssertEqual(result.lastSeenMessageID, messages.last?.id, "skipped rows still advance the watermark")
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

    func test_noNewMessages_saysSo_andKeepsWatermark() {
        let seen = message(.user, "hi", at: 0)
        let result = compose(me: alpha, [seen], seenID: seen.id)
        XCTAssertTrue(result.prompt.contains("no new messages"))
        XCTAssertNil(result.lastSeenMessageID)
        XCTAssertEqual(result.omittedCount, 0)
    }
}
