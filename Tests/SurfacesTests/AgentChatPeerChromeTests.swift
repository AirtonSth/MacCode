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

    func test_waitingActivityPutsMatchingBotAvatarLeadingAndSpinnerTrailing() throws {
        // WHY: the waiting Bot is the identity of the row, so its avatar
        // owns the leading slot at spinner size; the spinner stays at the
        // trailing edge instead of crowding the face.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatSharedChrome.swift"),
            encoding: .utf8
        )
        let row = try XCTUnwrap(source.range(of: "public struct AgentChatPeerActivityRow"))
        let slice = String(source[row.lowerBound...])
        let stack = try XCTUnwrap(slice.range(of: "HStack(alignment: .center, spacing: DS.Space.sm)"))
        let stackSlice = String(slice[stack.lowerBound...])
        let details = try XCTUnwrap(stackSlice.range(of: "VStack(alignment: .leading"))
        let leadingChrome = String(stackSlice[..<details.lowerBound])
        let trailingChrome = String(stackSlice[details.upperBound...])
        XCTAssertTrue(leadingChrome.contains("BotsAvatarView("))
        XCTAssertFalse(leadingChrome.contains("stateIcon"))
        XCTAssertTrue(trailingChrome.contains("Spacer(minLength: 0)"))
        let spacer = try XCTUnwrap(trailingChrome.range(of: "Spacer(minLength: 0)"))
        let stateIcon = try XCTUnwrap(trailingChrome.range(of: "stateIcon"))
        XCTAssertLessThan(spacer.lowerBound, stateIcon.lowerBound)
        XCTAssertTrue(leadingChrome.contains("size: Self.chromeSize"))
        XCTAssertTrue(slice.contains("private static let chromeSize: CGFloat = 22"))
        XCTAssertTrue(slice.contains(".controlSize(.regular)"))
        XCTAssertTrue(slice.contains(".frame(width: Self.chromeSize, height: Self.chromeSize)"))
        XCTAssertTrue(slice.contains("Circle().fill(DS.Palette.accent.opacity(0.16))"))
    }
}
