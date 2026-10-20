import XCTest
import CoreModel
@testable import Surfaces

/// Titio notice cards on the shared choices card (hub spec §7): every open
/// decision keeps its card until the host rewrites the message, while every
/// other card keeps today's newest-message-only behaviour.
final class AgentChatChoicesNoticeTests: XCTestCase {
    private let thread = AgentThreadID()

    private func message(_ role: AgentMessageRole, _ text: String, at offset: TimeInterval = 0) -> AgentMessage {
        AgentMessage(id: AgentMessageID(), threadId: thread, role: role, content: text,
                     createdAt: Date(timeIntervalSince1970: 1_792_094_460 + offset))
    }

    private func notice(_ key: String, question: String = "What should I do?", at offset: TimeInterval) -> AgentMessage {
        message(.assistant, "I need you to decide something.\n\n"
            + TitioNoticeCopy.choicesBlock(question: question, options: ["Approve", "Decline"], notice: key), at: offset)
    }

    func test_openNoticesListsEveryUnresolvedNoticeOldestFirstNotOnlyTheNewest() {
        // WHY: two approvals can wait at once; a card that is not the newest
        // message must stay tappable until the host resolves it.
        let first = notice("thread.A.attention.1", at: 0)
        let reply = message(.user, "oi", at: 1)
        let second = notice("thread.B.attention.2", at: 2)
        let resolved = message(.assistant, "I need you to decide something.\n\n_Approved by you at 9:00 AM._", at: 3)
        let plain = message(.assistant, "Hi\n\n" + "```choices\n{\"options\":[\"A\",\"B\"]}\n```", at: 4)
        let open = AgentChatChoicesCard.Pending.openNotices(in: [first, reply, second, resolved, plain], dismissed: [])
        XCTAssertEqual(open.map(\.messageID), [first, second].map { $0.id.value.uuidString.lowercased() })
        XCTAssertEqual(open.first?.choices.notice, "thread.A.attention.1")

        let dismissed = AgentChatChoicesCard.Pending.openNotices(
            in: [first, second], dismissed: [first.id.value.uuidString.lowercased()]
        )
        XCTAssertEqual(dismissed.map(\.messageID), [second.id.value.uuidString.lowercased()], "a closed card stays closed")
    }

    func test_noticeKeepsSeparateProvenanceAndExactQuestion() throws {
        let question = String(repeating: "Which release should be deployed? ", count: 8)
        let raw = TitioNoticeCopy.choicesBlock(question: question, options: ["Staging", "Production"], notice: "notice-A",
            source: ["workspace": "MacCode", "bot": "Developer", "conversation": "Release"])
        let choices = try XCTUnwrap(BotChoicesBlock.parse(raw).choices)
        XCTAssertEqual(choices.source["workspace"], "MacCode")
        XCTAssertEqual(choices.source["bot"], "Developer")
        let reply = AgentReplyQuote.compose(excerpt: try XCTUnwrap(choices.question), text: "Staging")
        XCTAssertEqual(AgentReplyQuote.parse(reply)?.excerpt, question.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(AgentReplyQuote.parse(reply)?.body, "Staging")
    }

    func test_newestCardIsUnchangedButNeverDrawsANoticeAsAChatCard() {
        // WHY: ordinary Bot cards keep their newest-only, idle-only rule. A
        // notice block is never the newest-message card on any surface: its
        // label sent as chat text acts on nothing (a desk mounted before the
        // inbox was known would send "Aprovar" to the LLM and approve nothing).
        let plain = message(.assistant, "Hi\n\n" + "```choices\n{\"options\":[\"A\",\"B\"]}\n```")
        XCTAssertNotNil(AgentChatChoicesCard.Pending.latest(in: [plain], isRunning: false))
        XCTAssertNil(AgentChatChoicesCard.Pending.latest(in: [plain], isRunning: true))

        let decision = notice("thread.A.attention.1", at: 0)
        XCTAssertNil(AgentChatChoicesCard.Pending.latest(in: [decision], isRunning: false),
                     "a notice card is answered by message id + option index, never as text")
    }

    func test_inboxSourcePinsTheNoticeStackAndHostHooks() throws {
        // WHY: the Mac card must send (message id, option index) to the host,
        // never the label as chat text, ignore isRunning, and an armed reply
        // must preserve context before ordinary quote composition or any run.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let surface = try String(contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"))
        XCTAssertTrue(surface.contains("handler(pending.messageID, index)"))
        XCTAssertTrue(surface.contains("allowsOwnAnswer: false"))
        let send = try XCTUnwrap(surface.range(of: "public func send() async {"))
        let tail = surface[send.upperBound...]
        let interceptor = try XCTUnwrap(tail.range(of: "embedding?.sendInterceptor"))
        let hostReply = try XCTUnwrap(tail.range(of: "embedding?.hostReplyHandler"))
        let legacy = try XCTUnwrap(tail.range(of: "refuseLegacyProviderThreadRun()"))
        XCTAssertLessThan(interceptor.lowerBound, hostReply.lowerBound)
        XCTAssertLessThan(hostReply.lowerBound, legacy.lowerBound, "the host reply runs before any provider work")
    }

    func test_onlyBotThreadsTurnAChoicesFenceIntoACard() {
        // WHY: a plain coding agent quoting a ```choices fence (e.g. while
        // working on this very feature) lost it from the transcript and Copy,
        // and got a one-tap card that sent text. iOS shows choices in Bot
        // chats only; the Mac Agent App must match.
        let raw = "Here is the format:\n\n```choices\n{\"options\":[\"A\",\"B\"]}\n```"
        XCTAssertEqual(AgentChatAssistantReply(text: raw, stripsChoices: false).text, raw, "a plain agent reply is shown as written")
        XCTAssertEqual(AgentChatAssistantReply(text: raw).text, "Here is the format:", "a Bot reply shows the card instead")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let surface = (try? String(contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"))) ?? ""
        XCTAssertTrue(surface.contains("if vm.showsBotChoices,\n           let pending = AgentChatChoicesCard.Pending.latest("),
                      "the newest-reply card is gated on Bot threads")
    }

    func test_decisionsLiveInTheTimelineUnderTheirMessageNotInABottomDock() throws {
        // WHY: the owner (2026-10-19) wants a decision to read like chat: the message,
        // then "What should be done?" with A/B right under it, then the next message.
        // A dock above the composer piled every decision away from what it was about.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let surface = try String(contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"))
        XCTAssertFalse(surface.contains("agent.choices.scroll"), "no bottom dock above the composer")
        let row = try XCTUnwrap(surface.range(of: "private func transcriptEntryRow("))
        XCTAssertTrue(String(surface[row.upperBound...].prefix(1_200)).contains("inlineNoticeCard(for: message)"),
                      "a notice card renders right under its own message")
        XCTAssertTrue(surface.contains("choicesTimelineTail()"), "the newest reply's answers follow the last timeline row")
        let tail = try XCTUnwrap(surface.range(of: "private func choicesTimelineTail("))
        let body = String(surface[tail.upperBound...].prefix(2_000))
        XCTAssertTrue(body.contains("ComposerReactiveScope(composerState: vm.composerState)"),
                      "typing a draft still disables the ordinary card")
        XCTAssertTrue(body.contains("guard vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"),
                      "a tap re-checks the draft before replacing the prompt")
    }

    func test_collapsedNoticeQuestionsAreNotResurrectedAfterTheNewestMessage() throws {
        // The screenshot's three orphaned questions came from a second rendering
        // of notices whose parent messages were folded into "Earlier in this thread".
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let surface = try String(contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"))
        let start = try XCTUnwrap(surface.range(of: "private func choicesTimelineTail()"))
        let end = try XCTUnwrap(surface.range(of: "private func inlineNoticeCard", range: start.upperBound..<surface.endIndex))
        let tail = surface[start.upperBound..<end.lowerBound]
        XCTAssertFalse(tail.contains("openNotices"), "collapsed questions follow their parent messages")
        XCTAssertFalse(tail.contains("noticeCard("), "questions are never copied to the live turn")
    }
}
