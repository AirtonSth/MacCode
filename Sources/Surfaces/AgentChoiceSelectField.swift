import DesignSystemKit
import SwiftUI

/// Shared select field for Auto profile and other form selects. One look, one
/// accessibility label and one menu behavior, instead of native pop-up Pickers.
public struct AgentChoiceSelectField<Value: Hashable>: View {
    public typealias Option = (value: Value, title: String, subtitle: String?)

    public let caption: String
    public let options: [Option]
    public let selection: Binding<Value>
    public let placeholder: String?
    public let trailing: String?
    public let trailingTint: Color
    public let leading: AnyView?
    public let describe: (Value) -> String
    public let identifier: String

    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(caption: String, options: [Option], selection: Binding<Value>, placeholder: String? = nil,
                trailing: String? = nil, trailingTint: Color = DS.Palette.textTertiary, leading: AnyView? = nil,
                describe: @escaping (Value) -> String = { String(describing: $0) }, identifier: String) {
        self.caption = caption
        self.options = options
        self.selection = selection
        self.placeholder = placeholder
        self.trailing = trailing
        self.trailingTint = trailingTint
        self.leading = leading
        self.describe = describe
        self.identifier = identifier
    }

    public var body: some View {
        let raw = describe(selection.wrappedValue)
        let matched = options.first { $0.value == selection.wrappedValue }?.title
        let display = AgentChoiceSelectPresentation.display(matchedTitle: matched, rawValue: raw, placeholder: placeholder)
        // A saved value no option offers stays selectable-as-is in the menu, labelled "Unavailable: …".
        let menuOptions: [Option] = matched == nil && !raw.isEmpty
            ? [(value: selection.wrappedValue, title: display.text, subtitle: nil)] + options
            : options
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(caption)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textSecondary)
                .accessibilityHidden(true)
            Menu {
                ForEach(Array(menuOptions.enumerated()), id: \.offset) { _, option in
                    Button {
                        selection.wrappedValue = option.value
                    } label: {
                        let title = option.subtitle.map { "\(option.title) · \($0)" } ?? option.title
                        if option.value == selection.wrappedValue {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            } label: {
                fieldContent(display)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(AgentChoiceSelectButtonStyle(hovering: hovering, focused: focused, unavailable: display.isUnavailable))
            .focused($focused)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
            .accessibilityLabel(AgentChoiceSelectPresentation.accessibilityLabel(caption: caption, text: display.text))
            .accessibilityIdentifier(identifier)
            .help(display.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldContent(_ display: AgentChoiceSelectPresentation.Display) -> some View {
        let textColor = display.isUnavailable ? DS.Palette.warning
            : display.isPlaceholder ? DS.Palette.textSecondary : DS.Palette.text
        return HStack(spacing: DS.Space.sm) {
            if let leading { leading }
            Text(display.text)
                .font(DS.Font.body)
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Space.xs)
            if let trailing {
                Text(trailing)
                    .font(DS.Font.caption2.monospacedDigit())
                    .foregroundColor(trailingTint)
                    .lineLimit(1)
                    .fixedSize()
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DS.Space.md)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
    }
}

/// Field chrome for `AgentChoiceSelectField`: fill, hairline, hover, focus accent, press scale.
private struct AgentChoiceSelectButtonStyle: ButtonStyle {
    let hovering: Bool
    let focused: Bool
    let unavailable: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let active = isEnabled
        let fill = active && hovering ? DS.Palette.surfaceOverlay : DS.Palette.surfaceRaised
        let border = focused ? DS.Palette.accent
            : active && hovering ? DS.Palette.lineStrong
            : unavailable ? DS.Palette.warning.opacity(0.6)
            : DS.Palette.line
        let pressed = configuration.isPressed && !reduceMotion
        return configuration.label
            .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(border, lineWidth: focused ? 1.5 : DS.Border.hairline)
            )
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .opacity(active ? 1 : 0.5)
    }
}

/// Text decisions for `AgentChoiceSelectField`, kept pure so they can be tested without rendering.
public enum AgentChoiceSelectPresentation {
    public struct Display: Equatable {
        public let text: String
        public let isUnavailable: Bool
        public let isPlaceholder: Bool

        public init(text: String, isUnavailable: Bool, isPlaceholder: Bool) {
            self.text = text
            self.isUnavailable = isUnavailable
            self.isPlaceholder = isPlaceholder
        }
    }

    /// A value matching an option shows that option. An empty value shows the placeholder.
    /// Any other value no option matches is kept visible as unavailable instead of silently dropped.
    public static func display(matchedTitle: String?, rawValue: String, placeholder: String?) -> Display {
        if let matchedTitle { return Display(text: matchedTitle, isUnavailable: false, isPlaceholder: false) }
        if rawValue.isEmpty { return Display(text: placeholder ?? "", isUnavailable: false, isPlaceholder: true) }
        return Display(text: "Unavailable: \(rawValue)", isUnavailable: true, isPlaceholder: false)
    }

    public static func accessibilityLabel(caption: String, text: String) -> String {
        "\(caption), \(text)"
    }
}
