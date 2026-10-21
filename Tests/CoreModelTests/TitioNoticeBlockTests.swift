import XCTest
@testable import CoreModel

/// The ```notice block. iOS parses the same block with the same rules, so a
/// notice message keeps its identity and state on both clients.
final class TitioNoticeBlockTests: XCTestCase {
    private let fence = "```notice\n{\"key\":\"run.R1.failed\",\"kind\":\"runFailed\",\"source\":{\"workspace\":\"api\"},\"state\":\"open\"}\n```"

    func test_validBlockIsRemovedAndBecomesTheIdentity() {
        // WHY: the card needs the notice key and state; the text must not show raw JSON.
        let parsed = TitioNoticeBlock.parse("Deploy failed.\n\n" + fence)
        XCTAssertEqual(parsed.text, "Deploy failed.")
        XCTAssertEqual(parsed.block, TitioNoticeBlock(key: "run.R1.failed", kind: "runFailed", source: ["workspace": "api"], state: "open"))
        XCTAssertEqual(parsed.block?.isOpen, true)
    }

    func test_unclosedBlockIsHiddenWhileItStreams() {
        // WHY: half a JSON block must not flash in the chat while it streams.
        XCTAssertEqual(TitioNoticeBlock.parse("Deploy failed.\n```notice\n{\"key\":\"run").text, "Deploy failed.")
        XCTAssertNil(TitioNoticeBlock.parse("Deploy failed.\n```notice\n{\"key\":\"run").block)
    }

    func test_closedInvalidBlockStaysAsWritten() {
        // WHY: nothing is lost when the host block is malformed.
        let message = "Hi\n```notice\n{\"kind\":\"runFailed\"}\n```"
        XCTAssertEqual(TitioNoticeBlock.parse(message), .init(text: message, block: nil), "missing key")
    }

    func test_unknownKindAndStateStillParse() {
        // WHY: a newer host may write kinds or states this client does not know.
        let parsed = TitioNoticeBlock.parse("Hi\n```notice\n{\"key\":\"k\",\"kind\":\"futureKind\",\"state\":\"futureState\"}\n```")
        XCTAssertEqual(parsed.block?.kind, "futureKind")
        XCTAssertEqual(parsed.block?.state, "futureState")
        XCTAssertEqual(parsed.block?.isOpen, false)
    }

    func test_blockAfterChoicesBothParse() {
        // WHY: a notice card carries a choices block, then the notice block last.
        let message = "Body\n\n```choices\n{\"options\":[\"A\",\"B\"],\"notice\":\"run.R1.failed\"}\n```\n\n" + fence
        let notice = TitioNoticeBlock.parse(message)
        XCTAssertEqual(notice.block?.key, "run.R1.failed")
        let choices = BotChoicesBlock.parse(notice.text)
        XCTAssertEqual(choices.choices?.options, ["A", "B"])
        XCTAssertEqual(choices.text, "Body")
    }

    func test_withStateRewritesOnlyTheState() {
        let message = "Body\n\n" + fence
        let rewritten = TitioNoticeBlock.withState(message, state: "acknowledged")
        XCTAssertEqual(TitioNoticeBlock.parse(rewritten).block?.state, "acknowledged")
        XCTAssertEqual(TitioNoticeBlock.parse(rewritten).block?.source, ["workspace": "api"])
        XCTAssertEqual(TitioNoticeBlock.parse(rewritten).text, "Body")
        XCTAssertEqual(TitioNoticeBlock.withState("No block.", state: "done"), "No block.")
    }

    func test_renderIsOneSortedLineThatParsesBack() {
        let rendered = TitioNoticeBlock.render(key: "k/1", kind: "runFailed", source: [:], state: "open")
        XCTAssertEqual(rendered, "```notice\n{\"key\":\"k/1\",\"kind\":\"runFailed\",\"state\":\"open\"}\n```", "slashes stay unescaped; no empty source")
        XCTAssertEqual(TitioNoticeBlock.parse(rendered).block?.key, "k/1")
    }
}
