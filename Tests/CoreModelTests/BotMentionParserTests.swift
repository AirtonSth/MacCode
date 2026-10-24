import XCTest
@testable import CoreModel

final class BotMentionParserTests: XCTestCase {
    func test_emailAndAmbiguousNamesDoNotSelectABotButExactHandlesDo() {
        let first = BotDefinition(handle: "first", name: "Reviewer", title: "", description: "")
        let second = BotDefinition(handle: "second", name: "Reviewer", title: "", description: "")
        XCTAssertEqual(BotMentionParser.mentionedBots(in: "mail@first @Reviewer @SECOND @first @second",
            bots: [first, second], excluding: nil).map(\.id), [second.id, first.id])
    }

    func test_peerConsultationIdleWindowRestartsOnProgress() {
        // WHY: a live Bot must not be cut off at 10 minutes of wall time
        // while it is still emitting updates.
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(
            BotPeerDelegation.peerConsultationStillActive(
                now: start.addingTimeInterval(599),
                lastProgress: start,
                idle: 600
            )
        )
        XCTAssertFalse(
            BotPeerDelegation.peerConsultationStillActive(
                now: start.addingTimeInterval(600),
                lastProgress: start,
                idle: 600
            )
        )
        XCTAssertTrue(
            BotPeerDelegation.peerConsultationStillActive(
                now: start.addingTimeInterval(1_200),
                lastProgress: start.addingTimeInterval(700),
                idle: 600
            )
        )
    }

    func test_mentionsResolveIdentityOnly_becauseTheProviderMustAuthorDelegatedPrompts() {
        // WHY: mention parsing may power autocomplete/identity, but must never
        // interpret prose or manufacture the prompt sent to another Bot.
        let bot = BotDefinition(
            handle: "bot",
            name: "Bot",
            title: "",
            description: ""
        )

        XCTAssertEqual(
            BotMentionParser.mentionedBots(
                in: "pergunte ao @bot o nome dele e depois decida o restante",
                bots: [bot],
                excluding: nil
            ).map(\.id),
            [bot.id]
        )
        XCTAssertTrue(BotPeerDelegation.providerDirective.contains("first interpret the complete user request"))
        XCTAssertTrue(BotPeerDelegation.providerDirective.contains("new focused `prompt`"))
        XCTAssertFalse(BotPeerDelegation.providerDirective.contains("Qual é o seu nome?"))
        XCTAssertFalse(BotPeerDelegation.providerDirective.contains("com base na resposta"))
        let directive = BotPeerDelegation.turnDirective(mentionedBots: [bot])
        XCTAssertTrue(directive?.contains("@bot is Bot") == true)
        XCTAssertTrue(directive?.contains(bot.id.value.uuidString.lowercased()) == true)
        XCTAssertTrue(directive?.contains("identity metadata only") == true)
        XCTAssertFalse(directive?.contains("nome dele") == true)
        let environment = BotPeerDelegation.environment(
            addingTurnContextTo: ["KEEP": "1"],
            mentionedBots: [bot]
        )
        XCTAssertEqual(environment[BotPeerDelegation.turnContextEnvironmentKey], directive)
        XCTAssertEqual(environment["KEEP"], "1")
        XCTAssertEqual(
            BotPeerDelegation.environment(
                addingTurnContextTo: environment,
                mentionedBots: []
            )[BotPeerDelegation.turnContextEnvironmentKey],
            nil
        )
    }

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
        XCTAssertEqual(parsed.botID, peer.id)
        let legacy = try XCTUnwrap(BotPeerTranscript.parse(
            "[[rc:bot-from:quinn|Quinn|CRM Controller|circle]]\nInbox is clear."
        ))
        XCTAssertEqual(legacy.body, "Inbox is clear.")
        XCTAssertNil(legacy.botID)
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

    func test_legacyPeerAskTextStillRestoresWithoutLeakingItsWrapper() {
        // WHY: new peer prompts are authored literally by the AI, but existing
        // stored conversations may still contain the retired wrapper.
        let ask = "Ceo asked you:\nbot Pergunte ao bot seu nome e função"
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

    func test_suggestions_matchCaseInsensitivelyWithoutAllocating() {
        // WHY: suggestions() runs per keystroke; SEP-3 removed the per-bot
        // lowercased() allocs. Matching semantics must stay identical,
        // including mixed-case legacy handles and names.
        let lower = BotDefinition(handle: "quinn", name: "Quinn", title: "", description: "")
        let legacy = BotDefinition(handle: "Old_Handle", name: "CRM CONTROLLER", title: "", description: "")
        let bots = [lower, legacy]
        XCTAssertEqual(
            BotMentionParser.suggestions(query: "QU", bots: bots, excluding: nil).map(\.id),
            [lower.id],
            "uppercase query must prefix-match lowercase handle"
        )
        XCTAssertEqual(
            BotMentionParser.suggestions(query: "old_", bots: bots, excluding: nil).map(\.id),
            [legacy.id],
            "lowercase query must prefix-match mixed-case legacy handle"
        )
        XCTAssertEqual(
            BotMentionParser.suggestions(query: "crm", bots: bots, excluding: nil).map(\.id),
            [legacy.id],
            "query must substring-match uppercase name"
        )
        XCTAssertEqual(
            BotMentionParser.suggestions(query: "", bots: bots, excluding: lower.id).map(\.id),
            [legacy.id],
            "empty query keeps all except excluded"
        )
    }

    func test_visibleCaptionsDistinguishMentionFromActualDelegation() {        XCTAssertEqual(BotPeerTranscript.toCaption(name: "Quinn"), "To Quinn")
        XCTAssertEqual(BotPeerTranscript.fromCaption(name: "Quinn"), "From Quinn")
        XCTAssertEqual(BotPeerTranscript.mentionedCaption(name: "Quinn"), "Mentions Quinn")
        XCTAssertEqual(BotPeerTranscript.mentionedCaption(for: BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )), "Mentions Quinn")
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
