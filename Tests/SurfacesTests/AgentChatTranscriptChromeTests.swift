import XCTest
import CoreModel
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

    func test_admitsSend_matchesAgentAppEmptyRule_becauseAttachmentsCountAsATurn() {
        // WHY: Agent App send is enabled with files and empty text. Desk must
        // use the same admission so attach-only turns are not silently dropped.
        XCTAssertFalse(AgentChatTranscriptChrome.admitsSend(text: "  ", attachmentCount: 0))
        XCTAssertTrue(AgentChatTranscriptChrome.admitsSend(text: "go", attachmentCount: 0))
        XCTAssertTrue(AgentChatTranscriptChrome.admitsSend(text: "", attachmentCount: 1))
    }

    func test_displayUserLine_prefixesAttachmentsLikeAgentApp() {
        // WHY: the transcript must show what was attached, the same way Agent
        // App suffixes 📎 names onto the user line.
        let file = AgentAttachment(path: "/tmp/brief.pdf", displayName: "brief.pdf", kind: .file)
        XCTAssertEqual(
            AgentChatTranscriptChrome.displayUserLine(text: "Review this", attachments: [file]),
            "Review this\n\n📎 brief.pdf"
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.displayUserLine(text: "  ", attachments: [file]),
            "📎 brief.pdf"
        )
    }

    func test_deskWorkingLabel_usesAgentAppThinkingPhase() {
        // WHY: a live bot turn must show the same working phrase Agent App
        // uses, not only a work-log pill.
        let start = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 12)
        XCTAssertNil(AgentChatTranscriptChrome.deskWorkingLabel(runIsLive: false, startedAt: start, now: now))
        XCTAssertEqual(
            AgentChatTranscriptChrome.deskWorkingLabel(runIsLive: true, startedAt: start, now: now),
            AgentWorkingStripPresentation.label(phase: .thinking, elapsedSeconds: 12)
        )
    }

    func test_deskWorkingLabel_seesStreamingTools_becauseAThinkingPillIsNotEnough() {
        // WHY: when the live turn is running tools, Desk must switch the
        // composer phase to Tools — the same signal Agent App uses — not stay
        // stuck on Thinking with hasStreamingTools hardcoded false.
        let start = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 12)
        XCTAssertEqual(
            AgentChatTranscriptChrome.deskWorkingLabel(
                runIsLive: true,
                startedAt: start,
                hasStreamingTools: true,
                now: now
            ),
            AgentWorkingStripPresentation.label(phase: .tools, elapsedSeconds: 12)
        )
    }

    func test_userBubbleVoiceOverSpeaksMessage_becauseRoleLabelHidThePrompt() throws {
        // WHY: Computer Use on Desk saw user bubbles as AXStaticText value
        // `user` and the copy control as AXButton `user`. The parent
        // accessibilityLabel("user") overwrote the prompt. Name the bubble
        // with the message text; keep Copy message on the button.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatTranscriptChrome.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "public struct AgentChatUserBubble") else {
            return XCTFail("AgentChatUserBubble must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\npublic struct AgentChatAssistantReply")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertFalse(
            slice.contains(".accessibilityLabel(\"user\")"),
            "parent must not name the whole bubble user"
        )
        XCTAssertTrue(
            slice.contains(".accessibilityLabel(text)"),
            "bubble body must expose the prompt as the VoiceOver name"
        )
        XCTAssertTrue(
            slice.contains(".accessibilityLabel(\"Copy message\")"),
            "copy control must stay Copy message after the role label is gone"
        )
    }

    func test_assistantReplyVoiceOverSpeaksMessage_becauseRoleLabelHidTheReply() throws {
        // WHY: Computer Use on Desk saw assistant replies as AXTextArea
        // label `assistant` while the value was the message. VoiceOver
        // speaks the label first, so the role hid the reply. Name the
        // markdown body with the message text; keep Copy message.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatTranscriptChrome.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "public struct AgentChatAssistantReply") else {
            return XCTFail("AgentChatAssistantReply must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\npublic struct AgentChatComposerBar")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertFalse(
            slice.contains(".accessibilityLabel(\"assistant\")"),
            "reply body must not be named assistant"
        )
        XCTAssertTrue(
            slice.contains(".accessibilityLabel(text)"),
            "reply body must expose the message as the VoiceOver name"
        )
        XCTAssertTrue(
            slice.contains(".accessibilityLabel(\"Copy message\")"),
            "copy control must stay Copy message after the role label is gone"
        )
    }

    func test_assistantCopyMatchesUserCopyChrome_becauseTenPointIconIsInvisibleOnDesk() throws {
        // WHY: Desk assistant Copy message painted at 10x12.5 while the
        // user bubble already frames the same glyph at 18x18. Users cannot
        // find or hit the leftover tiny control.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatTranscriptChrome.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "public struct AgentChatAssistantReply") else {
            return XCTFail("AgentChatAssistantReply must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\npublic struct AgentChatComposerBar")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains(".font(.system(size: 11, weight: .regular))"))
        XCTAssertTrue(slice.contains(".frame(width: 18, height: 18)"))
        XCTAssertFalse(
            slice.contains(".font(.system(size: 10))"),
            "assistant Copy must not stay a 10pt leftover icon"
        )
    }
}
