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

    func test_noticeStackShowsTheNewestThreeAndCountsTheRest() {
        // WHY: a pile of decisions must not bury the transcript; the label says
        // how many more are open, in the notices' own language.
        let notices = (0..<5).map { AgentChatChoicesCard.Pending.openNotices(
            in: [notice("k\($0)", question: "O que deseja fazer?", at: Double($0))], dismissed: []
        )[0] }
        let stack = AgentChatChoicesCard.Pending.noticeStack(notices, preferredLanguages: ["pt-BR"])
        XCTAssertEqual(stack.visible.map(\.choices.notice), ["k2", "k3", "k4"])
        XCTAssertEqual(stack.hiddenCount, 2)
        XCTAssertEqual(TitioNoticeCopy.openDecisionsLabel(extra: stack.hiddenCount, language: stack.language),
                       "+2 decisões abertas")
        let english = AgentChatChoicesCard.Pending.noticeStack(Array(notices.prefix(4)), preferredLanguages: ["en-US"])
        XCTAssertEqual(english.hiddenCount, 1)
        let small = AgentChatChoicesCard.Pending.noticeStack(Array(notices.prefix(2)))
        XCTAssertEqual(small.hiddenCount, 0)
        XCTAssertEqual(small.visible.count, 2)
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
        // must be checked right after the send interceptor, before any run.
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

    func test_theChoicesCardObservesTheComposerDraftAndTheTranscript() throws {
        // WHY: the card lived in the view body that observes only the view
        // model; the draft and messages publish on their own objects, so
        // typing never disabled the card and a tap overwrote the draft.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let surface = try String(contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"))
        XCTAssertTrue(surface.contains("""
            ComposerReactiveScope(composerState: vm.composerState) {
                            TranscriptReactiveScope(transcriptState: vm.transcriptState) {
                                choicesCardRow
            """), "the card row is rendered inside both observing scopes")
        let card = try XCTUnwrap(surface.range(of: "private var choicesCardRow: some View {"))
        let body = String(surface[card.upperBound...].prefix(2_000))
        XCTAssertTrue(body.contains("guard vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"),
                      "a tap re-checks the draft before replacing the prompt")
    }
}

/// Verbosity Human hides a turn's work but not its failures (iOS parity).
final class AgentChatHiddenWorkErrorTests: XCTestCase {
    func test_humanVerbosityStillShowsErrorsButNoToolRows() {
        // WHY: with tool rows hidden, an error the user cannot see reads as a
        // silent success; iOS keeps error items visible in the same mode.
        let activity = [
            AssistantItem(id: "tool-1", turnId: "t1", type: .tool, body: "pwd", startedAtMs: 1),
            AssistantItem(id: "err-1", turnId: "t1", type: .error, body: "Provider crashed", startedAtMs: 2),
        ]
        XCTAssertEqual(AgentChatLiveTurnChrome.visibleErrors(in: activity).map(\.id), ["err-1"])
    }
}
