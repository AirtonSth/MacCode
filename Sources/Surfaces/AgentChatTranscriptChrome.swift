import AppKit
import CoreModel
import DesignSystemKit
import SwiftUI
import UniformTypeIdentifiers

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

    public static func displayUserLine(text: String, attachments: [AgentAttachment]) -> String {
        let names = attachments.map(\.displayName).filter { !$0.isEmpty }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if names.isEmpty { return trimmed }
        let suffix = "📎 " + names.joined(separator: ", ")
        if trimmed.isEmpty { return suffix }
        return trimmed + "\n\n" + suffix
    }

    public static func admitsSend(text: String, attachmentCount: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0
    }

    public static func deskWorkingLabel(
        runIsLive: Bool,
        startedAt: Date?,
        hasStreamingTools: Bool = false,
        now: Date = Date()
    ) -> String? {
        let phase = AgentWorkingStripPresentation.phase(
            runIsLive: runIsLive,
            isAwaitingBackground: false,
            backgroundShellCount: 0,
            activeSubagentCount: 0,
            hasStreamingTools: hasStreamingTools
        )
        let elapsed = startedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        return AgentWorkingStripPresentation.label(phase: phase, elapsedSeconds: elapsed)
    }

    public static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg", "avif"].contains(ext)
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
    public var copyIdentifier: String? = nil
    public var header: AnyView? = nil
    public var belowBubble: AnyView? = nil

    public init(
        text: String,
        createdAt: Date,
        columnWidth: CGFloat = 10_000,
        accessibilityIdentifier: String = "agent.userMessageBubble",
        roleIdentifier: String = "bots.desk.role.user",
        copyIdentifier: String? = nil,
        header: AnyView? = nil,
        belowBubble: AnyView? = nil
    ) {
        self.text = text
        self.createdAt = createdAt
        self.columnWidth = columnWidth
        self.accessibilityIdentifier = accessibilityIdentifier
        self.roleIdentifier = roleIdentifier
        self.copyIdentifier = copyIdentifier
        self.header = header
        self.belowBubble = belowBubble
    }

    public var body: some View {
        let bubbleMax = AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: columnWidth)
        let textMax = max(0, bubbleMax - (DS.Space.xl * 2))
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: AgentChatTranscriptChrome.userMessageBubbleLeadingGutter)
            VStack(alignment: .trailing, spacing: DS.Space.xs) {
                if let header {
                    header
                }
                ViewThatFits(in: .horizontal) {
                    bubbleLabel
                        .fixedSize(horizontal: true, vertical: true)
                    bubbleLabel
                        .frame(maxWidth: textMax, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: bubbleMax, alignment: .trailing)
                .accessibilityIdentifier(accessibilityIdentifier)
                if let belowBubble {
                    belowBubble
                        .frame(maxWidth: bubbleMax, alignment: .trailing)
                }
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
                    .accessibilityIdentifier(copyIdentifier ?? "agent.userMessage.copy")
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
            .accessibilityLabel(text)
    }
}

public struct AgentChatAssistantReply: View {
    public let text: String
    public var roleIdentifier: String = "bots.desk.role.assistant"
    public var copyIdentifier: String? = nil
    public var content: AnyView? = nil

    public init(
        text: String,
        roleIdentifier: String = "bots.desk.role.assistant",
        copyIdentifier: String? = nil,
        content: AnyView? = nil
    ) {
        self.text = text
        self.roleIdentifier = roleIdentifier
        self.copyIdentifier = copyIdentifier
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let content {
                content
            } else {
                AgentMessageMarkdownView(text: text)
                    .foregroundColor(DS.Palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(roleIdentifier)
                    .accessibilityLabel(text)
            }
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
                .accessibilityIdentifier(copyIdentifier ?? "agent.assistantMessage.copy")
                .help("Copy message")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct AgentChatComposerBar: View {
    @Binding public var text: String
    public let attachments: [AgentAttachment]
    public let placeholder: String
    public let sendEnabled: Bool
    public let runActive: Bool
    public let isStopping: Bool
    public let workingLabel: String?
    public let attachEnabled: Bool
    public let onSend: () -> Void
    public let onStop: () -> Void
    public let onAttach: ([String]) -> Void
    public let onRemoveAttachment: (AgentAttachment) -> Void
    public var composerIdentifier: String = "bots.desk.composer"
    public var sendIdentifier: String = "bots.desk.send"
    public var leadingControls: AnyView?
    public var suggestions: [AgentComposerSuggestion] = []
    public var onApplySuggestion: ((AgentComposerSuggestion) -> Void)?
    public var onCursorMoved: ((Int) -> Void)?
    public var suggestionIdentifier: String = "bots.desk.suggestion.popup"
    public var focusTick: Int = 0
    public var onPreviousHistory: () -> Bool = { false }
    public var onNextHistory: () -> Bool = { false }
    public var onTextEdited: () -> Void = {}
    public var header: AnyView?
    public var showsAttach: Bool = true
    public var attachmentChipPrefix: String = "bots.desk.attachment."
    public var attachmentsIdentifier: String = "bots.desk.attachments"
    public var runStatusCaption: String?
    public var onFileDrop: (([String]) -> Void)?

    @State private var editorHeight: CGFloat = AgentComposerTextEditor.minHeight
    @State private var suggestionSelectedIndex: Int?
    @State private var suggestionPopupDismissed = false

    public init(
        text: Binding<String>,
        attachments: [AgentAttachment] = [],
        placeholder: String,
        sendEnabled: Bool,
        runActive: Bool = false,
        isStopping: Bool = false,
        workingLabel: String? = nil,
        attachEnabled: Bool = true,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void = {},
        onAttach: @escaping ([String]) -> Void = { _ in },
        onRemoveAttachment: @escaping (AgentAttachment) -> Void = { _ in },
        composerIdentifier: String = "bots.desk.composer",
        sendIdentifier: String = "bots.desk.send",
        leadingControls: AnyView? = nil,
        suggestions: [AgentComposerSuggestion] = [],
        onApplySuggestion: ((AgentComposerSuggestion) -> Void)? = nil,
        onCursorMoved: ((Int) -> Void)? = nil,
        suggestionIdentifier: String = "bots.desk.suggestion.popup",
        focusTick: Int = 0,
        onPreviousHistory: @escaping () -> Bool = { false },
        onNextHistory: @escaping () -> Bool = { false },
        onTextEdited: @escaping () -> Void = {},
        header: AnyView? = nil,
        showsAttach: Bool = true,
        attachmentChipPrefix: String = "bots.desk.attachment.",
        attachmentsIdentifier: String = "bots.desk.attachments",
        runStatusCaption: String? = nil,
        onFileDrop: (([String]) -> Void)? = nil
    ) {
        self._text = text
        self.attachments = attachments
        self.placeholder = placeholder
        self.sendEnabled = sendEnabled
        self.runActive = runActive
        self.isStopping = isStopping
        self.workingLabel = workingLabel
        self.attachEnabled = attachEnabled
        self.onSend = onSend
        self.onStop = onStop
        self.onAttach = onAttach
        self.onRemoveAttachment = onRemoveAttachment
        self.composerIdentifier = composerIdentifier
        self.sendIdentifier = sendIdentifier
        self.leadingControls = leadingControls
        self.suggestions = suggestions
        self.onApplySuggestion = onApplySuggestion
        self.onCursorMoved = onCursorMoved
        self.suggestionIdentifier = suggestionIdentifier
        self.focusTick = focusTick
        self.onPreviousHistory = onPreviousHistory
        self.onNextHistory = onNextHistory
        self.onTextEdited = onTextEdited
        self.header = header
        self.showsAttach = showsAttach
        self.attachmentChipPrefix = attachmentChipPrefix
        self.attachmentsIdentifier = attachmentsIdentifier
        self.runStatusCaption = runStatusCaption
        self.onFileDrop = onFileDrop
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let header {
                header
            }
            if let workingLabel {
                AgentChatWorkingPill(label: workingLabel, identifier: "agent.workingPhase")
                    .accessibilityIdentifier("bots.desk.workingPhase")
            }
            if !attachments.isEmpty {
                AgentChatAttachmentChips(
                    attachments: attachments,
                    onRemove: onRemoveAttachment,
                    chipIdentifierPrefix: attachmentChipPrefix,
                    stripIdentifier: attachmentsIdentifier
                )
                .padding(.horizontal, DS.Space.lg)
                .padding(.top, DS.Space.md)
            }
            AgentComposerTextEditor(
                text: $text,
                height: $editorHeight,
                focusTick: focusTick,
                placeholder: placeholder,
                accessibilityIdentifier: composerIdentifier,
                onSend: onSend,
                onPreviousHistory: onPreviousHistory,
                onNextHistory: onNextHistory,
                onTextEdited: {
                    suggestionPopupDismissed = false
                    onTextEdited()
                },
                onFileDrop: onFileDrop ?? onAttach,
                onCursorMoved: { offset in onCursorMoved?(offset) },
                onCaretRectChanged: { _ in },
                popupIsOpen: {
                    ComposerSuggestionNavigation.isOpen(
                        count: suggestions.count,
                        dismissed: suggestionPopupDismissed
                    )
                },
                onPopupNavUp: {
                    suggestionSelectedIndex = ComposerSuggestionNavigation.moveUp(
                        selected: suggestionSelectedIndex,
                        count: suggestions.count
                    )
                },
                onPopupNavDown: {
                    suggestionSelectedIndex = ComposerSuggestionNavigation.moveDown(
                        selected: suggestionSelectedIndex,
                        count: suggestions.count
                    )
                },
                onPopupApply: { applyHighlightedSuggestion() },
                onPopupDismiss: { suggestionPopupDismissed = true }
            )
            .frame(height: editorHeight)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.sm)
            .padding(.bottom, DS.Space.xs)
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier(composerIdentifier)
            .onChange(of: suggestions.map(\.id)) { _ in
                suggestionSelectedIndex = ComposerSuggestionNavigation.reset()
            }
            if ComposerSuggestionNavigation.isOpen(
                count: suggestions.count,
                dismissed: suggestionPopupDismissed
            ) {
                AgentComposerSuggestionPanel(
                    suggestions: suggestions,
                    highlightedIndex: suggestionSelectedIndex,
                    identifier: suggestionIdentifier,
                    onSelect: { suggestion in
                        onApplySuggestion?(suggestion)
                        suggestionPopupDismissed = true
                    }
                )
            }
            HStack(spacing: DS.Space.sm) {
                if showsAttach {
                    Button(action: pickAttachments) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!attachEnabled)
                    .foregroundColor(DS.Palette.textSecondary)
                    .help("Attach files")
                    .accessibilityLabel("Attach files")
                    .accessibilityIdentifier("agent.attach")
                }
                if let leadingControls {
                    leadingControls
                }
                Spacer(minLength: 0)
                if runActive {
                    if let runStatusCaption {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                            .accessibilityLabel(runStatusCaption)
                    }
                    stopButton
                    Rectangle()
                        .fill(DS.Palette.line)
                        .frame(width: DS.Border.hairline, height: 18)
                        .padding(.horizontal, DS.Space.xxs)
                }
                sendButton
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(from: providers)
        }
    }

    private var sendButton: some View {
        Button(action: onSend) {
            ZStack {
                Circle()
                    .fill(sendEnabled ? DS.Palette.accent : DS.Palette.surfaceRaised)
                    .frame(
                        width: AgentChatTranscriptChrome.sendCircleSize,
                        height: AgentChatTranscriptChrome.sendCircleSize
                    )
                Image(systemName: runActive ? "text.line.first.and.arrowtriangle.forward" : "arrow.up")
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
        .accessibilityLabel(runActive ? "Queue message" : "Send")
        .accessibilityIdentifier(sendIdentifier)
        .help(runActive ? "Queue message for this thread" : "Send prompt")
    }

    private var stopButton: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .fill(isStopping ? DS.Palette.surfaceRaised : DS.Palette.danger)
                    .frame(
                        width: AgentChatTranscriptChrome.sendCircleSize,
                        height: AgentChatTranscriptChrome.sendCircleSize
                    )
                if isStopping {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(DS.Palette.textSecondary)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DS.Palette.bg)
                }
            }
            .frame(
                width: AgentChatTranscriptChrome.sendHitTarget,
                height: AgentChatTranscriptChrome.sendHitTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStopping ? "Force stop running agent" : "Stop running agent")
        .accessibilityIdentifier("agent.composer.stop")
        .help(isStopping
              ? "Still stopping — click again to force-stop the provider"
              : "Stop running agent")
    }

    private func applyHighlightedSuggestion() {
        guard !suggestions.isEmpty else { return }
        let index = suggestionSelectedIndex ?? 0
        guard suggestions.indices.contains(index) else { return }
        onApplySuggestion?(suggestions[index])
        suggestionSelectedIndex = ComposerSuggestionNavigation.reset()
        suggestionPopupDismissed = true
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            onAttach(panel.urls.map(\.path))
        }
    }

    private func loadDroppedFiles(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { onAttach([url.path]) }
            }
        }
        return true
    }
}
