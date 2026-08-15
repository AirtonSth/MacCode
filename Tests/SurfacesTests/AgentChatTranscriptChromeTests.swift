import XCTest
@testable import Surfaces

final class AgentChatTranscriptChromeTests: XCTestCase {

    func test_bubbleMetricsMatchAgentApp_becauseDeskMustShareTheSameChatChrome() {
        // WHY: Bots Desk is supposed to look like Agent App chat. If these
        // numbers drift, user bubbles wrap at a different width and the
        // copy/timestamp row hangs past the pane again.
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleMaxWidth,
            AgentAppView.userMessageBubbleMaxWidth
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleLeadingGutter,
            AgentAppView.userMessageBubbleLeadingGutter
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleMinWidth,
            AgentAppView.userMessageBubbleMinWidth
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: 900),
            AgentAppView.userMessageBubbleWidthCap(columnWidth: 900)
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: 280),
            AgentAppView.userMessageBubbleWidthCap(columnWidth: 280)
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: 40),
            AgentAppView.userMessageBubbleWidthCap(columnWidth: 40)
        )
        XCTAssertEqual(AgentChatTranscriptChrome.sendCircleSize, 28)
        XCTAssertGreaterThanOrEqual(AgentChatTranscriptChrome.sendHitTarget, 44)
    }

    func test_relativeTimestampMatchesAgentApp_includingJustNowWindow() {
        // WHY: both transcripts must say "just now" for the same instant so
        // Desk does not invent a second time language.
        let now = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 59)
        let older = Date(timeIntervalSince1970: 40)
        XCTAssertEqual(
            AgentChatTranscriptChrome.relativeTimestamp(recent, now: now),
            AgentAppView.relativeTimestamp(recent, now: now)
        )
        XCTAssertEqual(AgentChatTranscriptChrome.relativeTimestamp(recent, now: now), "just now")
        XCTAssertEqual(
            AgentChatTranscriptChrome.relativeTimestamp(older, now: now),
            AgentAppView.relativeTimestamp(older, now: now)
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.absoluteTimestamp(now),
            AgentAppView.absoluteTimestamp(now)
        )
    }

    func test_composerPlaceholderMatchesAgentAppWording() {
        // WHY: Agent App reads "Ask Grok for changes…". Desk must not drop
        // back to a custom "Message bot" / "Send" dialect.
        XCTAssertEqual(
            AgentChatTranscriptChrome.composerPlaceholder(providerDisplayName: "Grok"),
            "Ask Grok for changes…"
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.composerPlaceholder(providerDisplayName: "Claude"),
            "Ask Claude for changes…"
        )
    }
}
