import XCTest
import CoreModel
@testable import Surfaces

/// Reply-quote jump: a tap must land on the message the user quoted, not on a
/// later message that happens to repeat the words.
final class AgentReplyQuoteTargetTests: XCTestCase {
    private let thread = AgentThreadID()

    private func message(_ role: AgentMessageRole, _ text: String, at offset: TimeInterval = 0) -> AgentMessage {
        AgentMessage(id: AgentMessageID(), threadId: thread, role: role, content: text,
                     createdAt: Date(timeIntervalSince1970: 1_792_094_460 + offset))
    }

    func test_findsQuotedAssistantMessageByExcerpt() {
        // WHY: the quote line only carries the excerpt, so the jump needs a text match.
        let answer = message(.assistant, "The build failed on the signing step.", at: 0)
        let reply = message(.user, "> Replying to: “The build failed”\n\nwhy?", at: 1)

        XCTAssertEqual(
            AgentReplyQuoteTarget.messageID(for: "The build failed", in: [answer, reply], before: reply.id),
            answer.id
        )
    }

    func test_ignoresTrailingEllipsisOfClippedExcerpt() {
        // WHY: long excerpts are clipped with "…"; the clipped text must still match its source.
        let answer = message(.assistant, "The build failed on the signing step.", at: 0)
        let reply = message(.user, "x", at: 1)

        XCTAssertEqual(
            AgentReplyQuoteTarget.messageID(for: "The build failed on…", in: [answer, reply], before: reply.id),
            answer.id
        )
    }

    func test_picksLatestEarlierMatchAndIgnoresLaterMessages() {
        // WHY: a repeated phrase must jump to the nearest earlier source, and a
        // later message (after the quoting reply) must never be the target.
        let older = message(.assistant, "Deploy is green.", at: 0)
        let newer = message(.assistant, "Deploy is green again.", at: 1)
        let reply = message(.user, "> Replying to: “Deploy is green”\n\nok", at: 2)
        let later = message(.assistant, "Deploy is green, shipping.", at: 3)

        XCTAssertEqual(
            AgentReplyQuoteTarget.messageID(for: "Deploy is green", in: [older, newer, reply, later], before: reply.id),
            newer.id
        )
    }

    func test_returnsNilWhenNoEarlierAssistantMessageMatches() {
        // WHY: an unloaded or user-only source must not jump to an unrelated row.
        let user = message(.user, "The build failed", at: 0)
        let reply = message(.user, "x", at: 1)

        XCTAssertNil(AgentReplyQuoteTarget.messageID(for: "The build failed", in: [user, reply], before: reply.id))
    }

    func test_matchesProvenanceLabelPrefixOfNoticeMessage() {
        // WHY: Titio excerpts carry "workspace › bot: " before the notice text; the
        // quote must still find the notice card's message.
        let notice = message(
            .assistant,
            "Approve the deploy?\n\n```notice\n{\"key\":\"k\",\"kind\":\"approval\",\"source\":{\"workspace\":\"Acme\",\"bot\":\"Ops\"},\"state\":\"open\"}\n```",
            at: 0
        )
        let reply = message(.user, "x", at: 1)

        XCTAssertEqual(
            AgentReplyQuoteTarget.messageID(for: "Acme › Ops: Approve the deploy?", in: [notice, reply], before: reply.id),
            notice.id
        )
    }
}
