import XCTest
import CoreModel
@testable import Surfaces

final class AgentChatPeerChromeTests: XCTestCase {
    func test_peerIdentityHeaderUsesBotAvatar_becauseInitialsAreNotTheTeammate() throws {
        // WHY: Desk hop chrome painted a letter tile. Agent App and Desk
        // must share one header that forwards the blobatar token.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatPeerChrome.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("public struct AgentChatPeerIdentityHeader"))
        XCTAssertTrue(source.contains("BotsAvatarView(name: name, handle: handle, symbol: symbol, size: 22)"))
        XCTAssertTrue(source.contains("BotPeerTranscript.handleLabel(handle)"))
        XCTAssertTrue(source.contains("public struct AgentChatPeerGroupHeader"))
    }

    func test_agentAppMountsSharedPeerHeader() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("AgentChatPeerIdentityHeader("))
        XCTAssertTrue(source.contains("accessibilityIdentifier: \"agent.peer.messaged\""))
        XCTAssertTrue(source.contains("accessibilityIdentifier: \"agent.peer.from\""))
        XCTAssertTrue(source.contains("AgentChatPeerGroupHeader("))
        XCTAssertTrue(source.contains("accessibilityIdentifier: \"agent.peer.group\""))
        XCTAssertTrue(source.contains("isInternalPeerHopUserMessage"))
        XCTAssertTrue(source.contains("resolvedPeerAvatarSymbol"))
        let row = source.range(of: "private func messageRow")
        let slice = String(source[row!.lowerBound...])
        let parse = slice.range(of: "BotPeerTranscript.parse(msg.content)")
        let badge = slice.range(of: "showsTokenSaverOptimizedBadge")
        XCTAssertNotNil(parse)
        XCTAssertNotNil(badge)
        XCTAssertLessThan(parse!.lowerBound, badge!.lowerBound)
    }

    func test_resolvedPeerAvatarUsesLiveBotWhenEncodedSymbolIsEmpty() {
        let quinn = BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM",
            description: "",
            avatarSymbol: "star.fill"
        )
        XCTAssertEqual(
            AgentAppView.resolvedPeerAvatarSymbol(handle: "quinn", encoded: "", bots: [quinn]),
            "star.fill"
        )
        XCTAssertEqual(
            AgentAppView.resolvedPeerAvatarSymbol(
                handle: "quinn",
                encoded: "leaf.fill",
                bots: [quinn]
            ),
            "leaf.fill"
        )
    }
}
