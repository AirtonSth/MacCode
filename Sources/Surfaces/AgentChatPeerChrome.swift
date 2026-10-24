import CoreModel
import DesignSystemKit
import SwiftUI

/// Mention identity is separate from admitted peer work and its activity rows.
public struct AgentChatMentionedPeersHeader: View {
    public let bots: [BotDefinition]
    public var accessibilityIdentifier: String

    public init(bots: [BotDefinition], accessibilityIdentifier: String = "agent.peer.mentioned") {
        self.bots = bots
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: DS.Space.xs) {
            ForEach(bots, id: \.id) { bot in
                AgentChatPeerIdentityHeader(
                    name: bot.name, handle: bot.handle, symbol: bot.avatarSymbol,
                    trailing: true, caption: BotPeerTranscript.mentionedCaption(for: bot),
                    accessibilityIdentifier: "\(accessibilityIdentifier).\(bot.handle)"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// One teammate identity row for a bot-to-bot hop. Desk and Agent App
/// mount this so avatar, name, and @handle stay one control.
public struct AgentChatPeerIdentityHeader: View {
    public let name: String
    public let handle: String
    public var symbol: String?
    public var trailing: Bool
    public var caption: String
    public var accessibilityIdentifier: String

    public init(
        name: String,
        handle: String,
        symbol: String? = nil,
        trailing: Bool,
        caption: String,
        accessibilityIdentifier: String
    ) {
        self.name = name
        self.handle = handle
        self.symbol = symbol
        self.trailing = trailing
        self.caption = caption
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        HStack(spacing: DS.Space.sm) {
            if !trailing {
                avatar
            }
            VStack(alignment: trailing ? .trailing : .leading, spacing: DS.Space.xxs) {
                Text(caption)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                Text(BotPeerTranscript.handleLabel(handle))
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            .multilineTextAlignment(trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            if trailing {
                avatar
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption), \(BotPeerTranscript.handleLabel(handle))")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var avatar: some View {
        BotsAvatarView(name: name, handle: handle, symbol: symbol, size: 22)
    }
}

/// Section banner for a consecutive hop with the same peer.
public struct AgentChatPeerGroupHeader: View {
    public let hostName: String
    public let hostHandle: String
    public var hostSymbol: String?
    public let peerName: String
    public let peerHandle: String
    public var peerSymbol: String?
    public let count: Int
    public var accessibilityIdentifier: String

    public init(
        hostName: String,
        hostHandle: String,
        hostSymbol: String? = nil,
        peerName: String,
        peerHandle: String,
        peerSymbol: String? = nil,
        count: Int,
        accessibilityIdentifier: String = "bots.desk.peer.group"
    ) {
        self.hostName = hostName
        self.hostHandle = hostHandle
        self.hostSymbol = hostSymbol
        self.peerName = peerName
        self.peerHandle = peerHandle
        self.peerSymbol = peerSymbol
        self.count = count
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        HStack(spacing: DS.Space.sm) {
            ZStack(alignment: .leading) {
                if !hostName.isEmpty {
                    BotsAvatarView(
                        name: hostName,
                        handle: hostHandle,
                        symbol: hostSymbol,
                        size: 22
                    )
                }
                BotsAvatarView(
                    name: peerName,
                    handle: peerHandle,
                    symbol: peerSymbol,
                    size: 22
                )
                .padding(.leading, hostName.isEmpty ? 0 : 14)
            }
            .frame(width: hostName.isEmpty ? 22 : 36, height: 22, alignment: .leading)
            Text(BotPeerTranscript.groupCaption(
                hostName: hostName,
                peerName: peerName,
                count: count
            ))
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Space.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(BotPeerTranscript.groupCaption(
            hostName: hostName,
            peerName: peerName,
            count: count
        ))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
