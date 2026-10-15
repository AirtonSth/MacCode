import XCTest
@testable import CoreModel

/// WHY: replying to a Bot message (owner request 2026-10-15) carries the quote
/// inside the sent text. The Bot must read which message is answered, the
/// transcript must show a quote strip (never the raw `>` line) after restart,
/// and iOS composes/parses the identical format.
final class AgentReplyQuoteTests: XCTestCase {
    func test_composedReplyRoundTripsToQuoteAndBody() throws {
        let sent = AgentReplyQuote.compose(excerpt: "Abri 2 tarefas novas de consultas lentas", text: "Qual é a mais urgente?")
        XCTAssertEqual(sent, "> Replying to: “Abri 2 tarefas novas de consultas lentas”\n\nQual é a mais urgente?")
        let parsed = try XCTUnwrap(AgentReplyQuote.parse(sent))
        XCTAssertEqual(parsed.excerpt, "Abri 2 tarefas novas de consultas lentas")
        XCTAssertEqual(parsed.body, "Qual é a mais urgente?")
    }

    func test_excerptIsOnePlainClippedLineOfTheQuotedMessage() {
        // The quote line must stay one line: Markdown and later lines would
        // break the format the transcript and iOS parse.
        let message = "**Abri 2 tarefas** novas: [Studio #3109](https://x.y/3109)\n\nSecond paragraph"
        XCTAssertEqual(AgentReplyQuote.excerpt(of: message), "Abri 2 tarefas novas: Studio #3109")
        let long = String(repeating: "a", count: 400)
        XCTAssertLessThanOrEqual(AgentReplyQuote.excerpt(of: long).count, AgentReplyQuote.maxExcerptCharacters + 1)
    }

    func test_replyingToAReplyQuotesOnlyItsBody() {
        let earlier = AgentReplyQuote.compose(excerpt: "first", text: "second")
        XCTAssertEqual(AgentReplyQuote.excerpt(of: earlier), "second")
    }

    func test_ordinaryQuotesAndMessagesAreNotTreatedAsReplies() {
        // A user's own Markdown quote must render as typed.
        XCTAssertNil(AgentReplyQuote.parse("> just a quote\n\ntext"))
        XCTAssertNil(AgentReplyQuote.parse("hello"))
        XCTAssertNil(AgentReplyQuote.parse("> Replying to: “only a quote”"), "a quote with no reply text is not a reply")
        XCTAssertEqual(AgentReplyQuote.strippingQuote("hello"), "hello")
    }
}
