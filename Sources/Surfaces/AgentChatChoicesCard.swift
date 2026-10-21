import CoreModel
import DesignSystemKit
import SwiftUI

/// Ready-made answers under a reply: lettered options the user taps, plus
/// "Type your own answer". One component for every chat that shows a reply
/// with a `choices` block (`BotChoicesBlock`).
public struct AgentChatChoicesCard: View {
    public let choices: BotChoicesBlock
    public let identifier: String
    /// The composer holds a draft or attachments: answering here would
    /// replace them, so the card waits.
    public let isBlockedByDraft: Bool
    /// False for a Titio notice card: only the options the host stored can be
    /// acted on, so there is no "Type your own answer" field.
    public let allowsOwnAnswer: Bool
    public let onAnswer: (String) -> Void
    public let onDismiss: () -> Void

    public static let blockedByDraftMessage = "Send or clear your draft to answer here."

    @State private var selected: Set<Int> = []
    @State private var ownAnswer = ""
    @FocusState private var ownAnswerFocused: Bool

    public init(
        choices: BotChoicesBlock,
        identifier: String,
        isBlockedByDraft: Bool = false,
        allowsOwnAnswer: Bool = true,
        onAnswer: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.choices = choices
        self.identifier = identifier
        self.isBlockedByDraft = isBlockedByDraft
        self.allowsOwnAnswer = allowsOwnAnswer
        self.onAnswer = onAnswer
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if choices.notice != nil, !choices.source.isEmpty {
                provenance
            }
            header
            VStack(spacing: 0) {
                ForEach(Array(choices.options.enumerated()), id: \.offset) { index, option in
                    if index > 0 {
                        Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                    }
                    optionRow(index: index, option: option)
                }
            }
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .stroke(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .disabled(isBlockedByDraft)
            .opacity(isBlockedByDraft ? 0.5 : 1)
            if isBlockedByDraft {
                Text(Self.blockedByDraftMessage)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("\(identifier).blocked")
            } else if allowsOwnAnswer {
                ownAnswerField
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            sourceLabel("workspace", name: "Workspace", symbol: "folder")
            sourceLabel("bot", name: "Bot", symbol: "person.crop.circle")
            sourceLabel("conversation", name: "Conversation", symbol: "bubble.left.and.bubble.right")
        }
        .font(DS.Font.caption)
        .foregroundColor(DS.Palette.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(identifier).source")
    }

    @ViewBuilder
    private func sourceLabel(_ key: String, name: String, symbol: String) -> some View {
        if let value = choices.source[key], !value.isEmpty {
            Label {
                Text(value).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).frame(width: 16)
            }
            .accessibilityLabel("\(name): \(value)")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if let question = choices.question {
                    Text(question)
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hint = choices.hint ?? (choices.multiple ? "Pick one or more." : nil) {
                    Text(hint)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.md)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss choices")
            .accessibilityIdentifier("\(identifier).dismiss")
        }
    }

    private func optionRow(index: Int, option: String) -> some View {
        let isSelected = selected.contains(index)
        return Button {
            if choices.multiple {
                if isSelected { selected.remove(index) } else { selected.insert(index) }
            } else if let answer = choices.answer(selecting: [index]) {
                onAnswer(answer)
            }
        } label: {
            HStack(spacing: DS.Space.lg) {
                Text(BotChoicesBlock.letter(at: index))
                    .font(DS.Font.captionStrong)
                    .foregroundColor(isSelected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(isSelected ? DS.Palette.accent : DS.Palette.surfaceOverlay)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .stroke(DS.Palette.lineStrong, lineWidth: isSelected ? 0 : DS.Border.hairline)
                    )
                Text(option)
                    .font(.system(size: 14))
                    .foregroundColor(DS.Palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if choices.multiple, isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DS.Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
        .buttonStyle(AgentChatChoiceRowStyle())
        .accessibilityLabel("\(BotChoicesBlock.letter(at: index)), \(option)")
        .accessibilityAddTraits(choices.multiple && isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).option.\(index)")
    }

    private var ownAnswerField: some View {
        HStack(spacing: DS.Space.md) {
            TextField("Type your own answer", text: $ownAnswer)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(DS.Palette.text)
                .focused($ownAnswerFocused)
                .onSubmit(sendOwnAnswer)
                .accessibilityIdentifier("\(identifier).own")
            if choices.multiple && ownAnswer.isEmpty {
                Button("Send") {
                    if let answer = choices.answer(selecting: selected) { onAnswer(answer) }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("\(identifier).send")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .frame(minHeight: 40)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(ownAnswerFocused ? DS.Palette.accent : DS.Palette.lineStrong, lineWidth: 1)
        )
        .animation(DS.Motion.micro, value: ownAnswerFocused)
    }

    private func sendOwnAnswer() {
        let text = ownAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ownAnswer = ""
        onAnswer(text)
    }
}

extension AgentChatChoicesCard {
    /// The reply whose choices still wait for an answer: the newest message,
    /// from the assistant, while nothing runs.
    public struct Pending: Equatable {
        public let messageID: String
        public let choices: BotChoicesBlock

        /// Never a notice card: a notice is answered by (message id, option
        /// index) through the host's notice stack. Drawn here, its label would
        /// be sent as chat text, which acts on nothing (a surface without the
        /// notice hook, such as a desk mounted before the inbox was known).
        public static func latest(in messages: [AgentMessage], isRunning: Bool) -> Pending? {
            guard !isRunning,
                  let last = messages.last(where: { $0.role != .system }),
                  last.role == .assistant,
                  let choices = BotChoicesBlock.parse(last.content).choices,
                  choices.notice == nil else { return nil }
            return Pending(messageID: last.id.value.uuidString.lowercased(), choices: choices)
        }

        /// Every assistant message whose choices carry a `notice` key, in
        /// chronological order, minus the dismissed ones (hub spec §7). A
        /// message keeps its card until the host resolves the notice and
        /// rewrites it without the block, so clients keep no decision state.
        public static func openNotices(in messages: [AgentMessage], dismissed: Set<String>) -> [Pending] {
            messages.compactMap { message in
                guard message.role == .assistant,
                      let choices = BotChoicesBlock.parse(message.content).choices,
                      choices.notice != nil else { return nil }
                let id = message.id.value.uuidString.lowercased()
                return dismissed.contains(id) ? nil : Pending(messageID: id, choices: choices)
            }
        }

    }

    /// Cards the user closed stay closed after RemoteCode reopens.
    public enum DismissedStore {
        static let key = "agent.choices.dismissed.v1"
        static let limit = 200

        public static func load(_ defaults: UserDefaults = .standard) -> Set<String> {
            Set(defaults.stringArray(forKey: key) ?? [])
        }

        public static func insert(_ messageID: String, _ defaults: UserDefaults = .standard) {
            var ids = defaults.stringArray(forKey: key) ?? []
            ids.removeAll { $0 == messageID }
            ids.append(messageID)
            defaults.set(Array(ids.suffix(limit)), forKey: key)
        }
    }
}

/// Hover wash and a quick press dip for one option row.
private struct AgentChatChoiceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background(
                    configuration.isPressed ? DS.Palette.surfaceOverlay
                        : hovering ? DS.Palette.hover : Color.clear
                )
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}
