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
        XCTAssertTrue(source.contains("accessibilityIdentifier: \"agent.peer.mentioned\""))
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

    func test_waitingActivityUsesSpinnerBeforeMatchingBotAvatar() throws {
        // WHY: a 14pt small spinner disappears against the dark transcript,
        // and the waiting Bot must remain visible immediately to its right.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatSharedChrome.swift"),
            encoding: .utf8
        )
        let row = try XCTUnwrap(source.range(of: "public struct AgentChatPeerActivityRow"))
        let slice = String(source[row.lowerBound...])
        let stack = try XCTUnwrap(slice.range(of: "HStack(alignment: .top, spacing: DS.Space.sm)"))
        let stackSlice = String(slice[stack.lowerBound...])
        let details = try XCTUnwrap(stackSlice.range(of: "VStack(alignment: .leading"))
        let leadingChrome = String(stackSlice[..<details.lowerBound])
        let stateIcon = try XCTUnwrap(leadingChrome.range(of: "stateIcon"))
        let botAvatar = try XCTUnwrap(leadingChrome.range(of: "BotsAvatarView("))
        XCTAssertLessThan(stateIcon.lowerBound, botAvatar.lowerBound)
        XCTAssertTrue(leadingChrome.contains("size: 22"))
        XCTAssertTrue(slice.contains(".controlSize(.regular)"))
        XCTAssertTrue(slice.contains(".frame(width: 22, height: 22)"))
        XCTAssertTrue(slice.contains("Circle().fill(DS.Palette.accent.opacity(0.16))"))
    }
}
