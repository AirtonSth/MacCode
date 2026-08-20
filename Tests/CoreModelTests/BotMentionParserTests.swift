import XCTest
@testable import CoreModel

final class BotMentionParserTests: XCTestCase {
    func test_peerActivityRoundTripsBothPhasesAndIdentity() throws {
        let peer = BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )

        for phase in [BotPeerActivityPhase.waiting, .needsAttention] {
            let content = BotPeerTranscript.encodeActivity(peer: peer, phase: phase)
            let parsed = try XCTUnwrap(BotPeerTranscript.parseActivity(content))
            XCTAssertEqual(parsed.phase, phase)
            XCTAssertEqual(parsed.name, "Quinn")
            XCTAssertEqual(parsed.title, "CRM Controller")
            XCTAssertEqual(parsed.handle, "quinn")
            XCTAssertEqual(parsed.identityLine, "Quinn - CRM Controller - quinn")
        }
    }

    func test_peerReplyParsingPreservesCaptionBodyAndIdentity() throws {
        let peer = BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )

        let parsed = try XCTUnwrap(BotPeerTranscript.parse(
            BotPeerTranscript.encode(peer: peer, text: "Inbox is clear.")
        ))
        XCTAssertEqual(parsed.caption, "From Quinn")
        XCTAssertEqual(parsed.body, "Inbox is clear.")
        XCTAssertEqual(parsed.name, "Quinn")
        XCTAssertEqual(parsed.title, "CRM Controller")
        XCTAssertEqual(parsed.handle, "quinn")
        XCTAssertEqual(parsed.avatarSymbol, peer.avatarSymbol)
    }

    func test_hostHopPromptKeepsUserLanguageAndStripsMentionHandles() {
        // WHY: hop used to be English-only "Quinn replied:" and could
        // re-enter mention-send via @handle. The host must see the original
        // ask without an @token.
        let hop = BotPeerTranscript.hostHopPrompt(
            peerName: "Quinn",
            reply: "Inbox is clear.",
            userText: "@quinn qual é o nome?"
        )
        XCTAssertTrue(hop.contains("Quinn replied:"))
        XCTAssertTrue(hop.contains("Inbox is clear."))
        XCTAssertTrue(hop.contains("The user wrote:"))
        XCTAssertTrue(hop.contains("qual é o nome?"))
        XCTAssertTrue(hop.contains(BotPeerTranscript.languageInstruction))
        XCTAssertFalse(hop.contains("@quinn"))
        XCTAssertFalse(BotPeerTranscript.containsMentionToken(hop, handle: "quinn"))
        XCTAssertTrue(BotPeerTranscript.isHostHopUserText(hop))
        XCTAssertTrue(BotPeerTranscript.isHostHopUserText("Bot replied:\n**Nome:** Bot"))
        XCTAssertFalse(BotPeerTranscript.isHostHopUserText("Pergunte ao bot seu nome"))
    }

    func test_peerAskPromptIsInternalAndStripsToDisplayText() {
        // WHY: the asked bot ran "Ceo asked you:" as the provider user
        // line. Desk must treat that wrapper as internal and show the
        // original ask under From-host chrome.
        let ask = BotPeerTranscript.peerAskPrompt(
            hostName: "Ceo",
            text: "@bot Pergunte ao bot seu nome e função"
        )
        XCTAssertTrue(ask.contains("Ceo asked you:"))
        XCTAssertTrue(ask.contains("Pergunte ao bot seu nome e função"))
        XCTAssertFalse(ask.contains("@bot"))
        XCTAssertTrue(BotPeerTranscript.isPeerAskUserText(ask))
        XCTAssertTrue(BotPeerTranscript.isPeerAskUserText(
            "An Agent App teammate asked you:\nPergunte ao bot"
        ))
        XCTAssertFalse(BotPeerTranscript.isPeerAskUserText("Pergunte ao bot seu nome e função"))
        XCTAssertEqual(
            BotPeerTranscript.displayTextFromPeerAsk(ask),
            "bot Pergunte ao bot seu nome e função"
        )
        XCTAssertFalse(BotPeerTranscript.isHostHopUserText(ask))
    }

    func test_visibleCaptionsAreToFromName_becauseIdentityLineIsNotChatChrome() {
        XCTAssertEqual(BotPeerTranscript.toCaption(name: "Quinn"), "To Quinn")
        XCTAssertEqual(BotPeerTranscript.fromCaption(name: "Quinn"), "From Quinn")
        XCTAssertEqual(BotPeerTranscript.messagedCaption(for: BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )), "To Quinn")
        XCTAssertEqual(
            BotPeerTranscript.groupCaption(hostName: "Ceo", peerName: "Bot", count: 3),
            "3 messages · Ceo × Bot"
        )
        XCTAssertEqual(
            BotPeerTranscript.groupCaption(hostName: "", peerName: "Quinn", count: 2),
            "2 messages · Quinn"
        )
    }
}
