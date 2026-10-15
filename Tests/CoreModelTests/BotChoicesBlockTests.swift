import XCTest
@testable import CoreModel

/// The ready-made answers block. iOS parses the same block with the same
/// rules and the same vectors (contract 2026-10-15), so a message shows the
/// same card on both sides.
final class BotChoicesBlockTests: XCTestCase {
    func test_V1_validBlockBecomesACardAndLeavesTheText() {
        let parsed = BotChoicesBlock.parse("Hi\n\n```choices\n{\"question\":\"Pick\",\"options\":[\"A one\",\"B two\"]}\n```")
        XCTAssertEqual(parsed.text, "Hi")
        XCTAssertEqual(parsed.choices, BotChoicesBlock(question: "Pick", hint: nil, multiple: false, options: ["A one", "B two"]))
    }

    func test_V2_oneOptionIsNotAChoiceSoTheTextStays() {
        let message = "Hi\n```choices\n{\"options\":[\"x\"]}\n```"
        XCTAssertEqual(BotChoicesBlock.parse(message), .init(text: message, choices: nil))
    }

    func test_V3_streamingBlockIsHiddenUntilItCloses() {
        // WHY: half a JSON block must not flash in the chat while it streams.
        XCTAssertEqual(BotChoicesBlock.parse("Hi\n```choices\n{\"options\":[\"x\",\"y\""), .init(text: "Hi", choices: nil))
    }

    func test_V4_invalidJSONIsShownAsWrittenSoNothingIsLost() {
        let message = "Hi\n```choices\nnot json\n```"
        XCTAssertEqual(BotChoicesBlock.parse(message), .init(text: message, choices: nil))
    }

    func test_V5_optionsAreTrimmedDedupedAndCappedAtSix() {
        let parsed = BotChoicesBlock.parse("```choices\n{\"options\":[\" a \",\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\"]}\n```")
        XCTAssertEqual(parsed.choices?.options, ["a", "b", "c", "d", "e", "f"])
    }

    func test_V6_fenceWordIsCaseInsensitiveAndMultipleIsRead() {
        let parsed = BotChoicesBlock.parse("```CHOICES\n{\"multiple\":true,\"options\":[\"x\",\"y\"]}\n```")
        XCTAssertEqual(parsed.text, "")
        XCTAssertEqual(parsed.choices?.multiple, true)
    }

    func test_answersAreTheOptionTextsInListOrder() {
        let choices = BotChoicesBlock(question: nil, hint: nil, multiple: true, options: ["Ler chats", "Ofertas", "Nada"])
        XCTAssertEqual(choices.answer(selecting: [2, 0]), "Ler chats, Nada")
        XCTAssertNil(choices.answer(selecting: []), "nothing picked sends nothing")
        XCTAssertEqual(BotChoicesBlock.letter(at: 0), "A")
        XCTAssertEqual(BotChoicesBlock.letter(at: 5), "F")
    }

    func test_plainMessagesPassThroughUntouched() {
        let message = "Here is code:\n```swift\nlet x = 1\n```"
        XCTAssertEqual(BotChoicesBlock.parse(message), .init(text: message, choices: nil))
    }
}

extension BotChoicesBlockTests {
    func test_windowsLineEndingsParseLikeIOS() {
        // WHY: iOS trims "\r" on fence lines; both sides must agree on CRLF text.
        let parsed = BotChoicesBlock.parse("Hi\r\n```choices\r\n{\"options\":[\"x\",\"y\"]}\r\n```\r")
        XCTAssertEqual(parsed.choices?.options, ["x", "y"])
    }
}

/// Titio notice cards carry an optional `notice` key (hub spec §7). Clients use
/// it to route a tap to the host ledger instead of sending the option text, so
/// it must parse, and blocks without it must behave exactly as before.
extension BotChoicesBlockTests {
    func test_noticeKeyParsesOnHostWrittenCards() {
        let parsed = BotChoicesBlock.parse("Decide\n\n```choices\n{\"notice\":\"thread.T.attention.R\",\"options\":[\"Aprovar\",\"Recusar\"],\"question\":\"O que deseja fazer?\"}\n```")
        XCTAssertEqual(parsed.text, "Decide")
        XCTAssertEqual(parsed.choices?.notice, "thread.T.attention.R")
        XCTAssertEqual(parsed.choices?.options, ["Aprovar", "Recusar"])
    }

    func test_blocksWithoutNoticeStayOrdinaryCards() {
        // WHY: every Bot card written before this change has no key; it must keep
        // sending the option text as a normal message.
        let parsed = BotChoicesBlock.parse("Hi\n```choices\n{\"options\":[\"x\",\"y\"]}\n```")
        XCTAssertNil(parsed.choices?.notice)
        XCTAssertEqual(parsed.choices, BotChoicesBlock(question: nil, hint: nil, multiple: false, options: ["x", "y"]))
    }

    func test_blankOrNonStringNoticeIsIgnored() {
        // WHY: only a real key may route to the ledger; junk must not make a card "special".
        XCTAssertNil(BotChoicesBlock.parse("```choices\n{\"notice\":\"  \",\"options\":[\"x\",\"y\"]}\n```").choices?.notice)
        XCTAssertNil(BotChoicesBlock.parse("```choices\n{\"notice\":7,\"options\":[\"x\",\"y\"]}\n```").choices?.notice)
        XCTAssertNotEqual(
            BotChoicesBlock(question: nil, hint: nil, multiple: false, options: ["x", "y"], notice: "k"),
            BotChoicesBlock(question: nil, hint: nil, multiple: false, options: ["x", "y"]),
            "a notice card is a different card"
        )
    }
}
