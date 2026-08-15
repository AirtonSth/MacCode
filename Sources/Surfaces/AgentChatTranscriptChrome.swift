import AppKit
import DesignSystemKit
import SwiftUI

/// Shared Agent App transcript chrome. Bots Desk uses these views so chat
/// layout, bubble hug, markdown, copy, and composer match Agent App.
public enum AgentChatTranscriptChrome {
    public static let userMessageBubbleMaxWidth: CGFloat = 420
    public static let userMessageBubbleLeadingGutter: CGFloat = 48
    public static let userMessageBubbleMinWidth: CGFloat = 160
    /// Visual send circle matches Agent App; the hit area is expanded to 44pt.
    public static let sendCircleSize: CGFloat = 28
    public static let sendHitTarget: CGFloat = 44

    public static func userMessageBubbleWidthCap(columnWidth: CGFloat) -> CGFloat {
        let usable = columnWidth - userMessageBubbleLeadingGutter
        guard usable.isFinite, usable > 0 else { return userMessageBubbleMinWidth }
        return min(userMessageBubbleMaxWidth, max(userMessageBubbleMinWidth, usable))
    }

    public static func composerPlaceholder(providerDisplayName: String) -> String {
        "Ask \(providerDisplayName) for changes…"
    }

    public static func relativeTimestamp(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    public static func absoluteTimestamp(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }

    public static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

public struct AgentChatUserBubble: View {
    public let text: String
    public let createdAt: Date
    public var columnWidth: CGFloat = 10_000
    public var accessibilityIdentifier: String = "agent.userMessageBubble"
    public var roleIdentifier: String = "bots.desk.role.user"

    public init(
        text: String,
        createdAt: Date,
        columnWidth: CGFloat = 10_000,
        accessibilityIdentifier: String = "agent.userMessageBubble",
        roleIdentifier: String = "bots.desk.role.user"
    ) {
        self.text = text
        self.createdAt = createdAt
        self.columnWidth = columnWidth
        self.accessibilityIdentifier = accessibilityIdentifier
        self.roleIdentifier = roleIdentifier
    }

    public var body: some View {
        let bubbleMax = AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: columnWidth)
        let textMax = max(0, bubbleMax - (DS.Space.xl * 2))
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: AgentChatTranscriptChrome.userMessageBubbleLeadingGutter)
            VStack(alignment: .trailing, spacing: DS.Space.xs) {
                ViewThatFits(in: .horizontal) {
                    bubbleLabel
                        .fixedSize(horizontal: true, vertical: true)
                    bubbleLabel
                        .frame(maxWidth: textMax, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: bubbleMax, alignment: .trailing)
                .accessibilityIdentifier(accessibilityIdentifier)
                HStack(spacing: DS.Space.xs) {
                    Button {
                        AgentChatTranscriptChrome.copyToPasteboard(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .regular))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityLabel("Copy message")
                    .help("Copy message")
                    Text(AgentChatTranscriptChrome.relativeTimestamp(createdAt))
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                        .help(AgentChatTranscriptChrome.absoluteTimestamp(createdAt))
                        .accessibilityIdentifier("bots.desk.timestamp")
                }
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: bubbleMax, alignment: .trailing)
            }
            .frame(maxWidth: bubbleMax, alignment: .trailing)
            .layoutPriority(1)
            .accessibilityIdentifier(roleIdentifier)
            .accessibilityLabel("user")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var bubbleLabel: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(DS.Palette.text)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

public struct AgentChatAssistantReply: View {
    public let text: String
    public var roleIdentifier: String = "bots.desk.role.assistant"

    public init(text: String, roleIdentifier: String = "bots.desk.role.assistant") {
        self.text = text
        self.roleIdentifier = roleIdentifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            AgentMessageMarkdownView(text: text)
                .foregroundColor(DS.Palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(roleIdentifier)
                .accessibilityLabel("assistant")
            HStack(spacing: DS.Space.xs) {
                Button {
                    AgentChatTranscriptChrome.copyToPasteboard(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityLabel("Copy message")
                .help("Copy message")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct AgentChatComposerBar: View {
    @Binding public var text: String
    public let placeholder: String
    public let sendEnabled: Bool
    public let onSend: () -> Void
    public var composerIdentifier: String = "bots.desk.composer"
    public var sendIdentifier: String = "bots.desk.send"

    public init(
        text: Binding<String>,
        placeholder: String,
        sendEnabled: Bool,
        onSend: @escaping () -> Void,
        composerIdentifier: String = "bots.desk.composer",
        sendIdentifier: String = "bots.desk.send"
    ) {
        self._text = text
        self.placeholder = placeholder
        self.sendEnabled = sendEnabled
        self.onSend = onSend
        self.composerIdentifier = composerIdentifier
        self.sendIdentifier = sendIdentifier
    }

    public var body: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .font(.system(size: 13))
                .foregroundColor(DS.Palette.text)
                .padding(.horizontal, DS.Space.lg)
                .padding(.top, DS.Space.sm)
                .padding(.bottom, DS.Space.xs)
                .accessibilityLabel(placeholder)
                .accessibilityIdentifier(composerIdentifier)
                .onSubmit(onSend)
            HStack {
                Spacer(minLength: 0)
                Button(action: onSend) {
                    ZStack {
                        Circle()
                            .fill(sendEnabled ? DS.Palette.accent : DS.Palette.surfaceRaised)
                            .frame(
                                width: AgentChatTranscriptChrome.sendCircleSize,
                                height: AgentChatTranscriptChrome.sendCircleSize
                            )
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(sendEnabled ? DS.Palette.onAccent : DS.Palette.textTertiary)
                    }
                    .frame(
                        width: AgentChatTranscriptChrome.sendHitTarget,
                        height: AgentChatTranscriptChrome.sendHitTarget
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityLabel("Send")
                .accessibilityIdentifier(sendIdentifier)
                .help("Send prompt")
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
        }
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .padding(DS.Space.lg)
        .background(DS.Palette.bg)
    }
}
