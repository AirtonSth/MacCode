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
        XCTAssertEqual(parsed.caption, "Message from Quinn - CRM Controller - quinn")
        XCTAssertEqual(parsed.body, "Inbox is clear.")
        XCTAssertEqual(parsed.name, "Quinn")
        XCTAssertEqual(parsed.title, "CRM Controller")
        XCTAssertEqual(parsed.handle, "quinn")
    }
}
