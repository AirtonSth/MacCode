import SwiftUI

// MARK: - Surface containers

public extension View {
    /// Panel: the dense card used for changed-files, plan, feed rows.
    func dsPanel(padding: CGFloat = DS.Space.lg, raised: Bool = false) -> some View {
        self
            .padding(padding)
            .background(raised ? DS.Palette.surfaceRaised : DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
    }

    /// Top/bottom bar background with a single hairline divider edge.
    func dsBar(edge: Edge = .bottom) -> some View {
        self
            .background(DS.Palette.surface)
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            }
    }

    func dsFocusRing(_ visible: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.focusRing, lineWidth: visible ? 2 : 0)
        )
    }
}

// MARK: - Status pill

public struct DSPill: View {
    public enum Tone { case neutral, accent, success, warning, danger }
    let text: String
    let tone: Tone
    public init(_ text: String, tone: Tone = .neutral) { self.text = text; self.tone = tone }

    public var body: some View {
        Text(text)
            .font(DS.Font.caption2.weight(.semibold))
            .foregroundColor(fg)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xxs)
            .background(bg)
            .clipShape(Capsule())
    }
    private var fg: Color {
        switch tone {
        case .neutral: return DS.Palette.textSecondary
        case .accent:  return DS.Palette.accent
        case .success: return DS.Palette.success
        case .warning: return DS.Palette.warning
        case .danger:  return DS.Palette.danger
        }
    }
    private var bg: Color {
        switch tone {
        case .neutral: return DS.Palette.surfaceOverlay
        case .accent:  return DS.Palette.accent.opacity(0.16)
        case .success: return DS.Palette.success.opacity(0.16)
        case .warning: return DS.Palette.warning.opacity(0.16)
        case .danger:  return DS.Palette.danger.opacity(0.16)
        }
    }
}

// MARK: - Icon button (compact, 44pt hit area, on-style states)

public struct DSIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    public init(_ systemName: String, help: String = "", action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hovering ? DS.Palette.text : DS.Palette.textSecondary)
                .frame(width: 26, height: 22)
                .background(hovering ? DS.Palette.hover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Primary / secondary button styles

public struct DSPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.body.weight(.semibold))
            .foregroundColor(DS.Palette.onAccent)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)
            .background(DS.Palette.accent.opacity(configuration.isPressed ? 0.82 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .opacity(1.0)
    }
}

public struct DSSecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.text)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .background(configuration.isPressed ? DS.Palette.pressed : DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
    }
}

// MARK: - Section header

public struct DSSectionHeader: View {
    let title: String
    let trailing: AnyView?
    public init(_ title: String, trailing: AnyView? = nil) {
        self.title = title; self.trailing = trailing
    }
    public var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(title.uppercased())
                .font(DS.Font.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundColor(DS.Palette.textTertiary)
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }
}

// MARK: - Empty state

public struct DSEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    public init(icon: String, title: String, subtitle: String) {
        self.icon = icon; self.title = title; self.subtitle = subtitle
    }
    public var body: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(DS.Palette.textTertiary)
            Text(title).font(DS.Font.title3).foregroundColor(DS.Palette.textSecondary)
            Text(subtitle)
                .font(DS.Font.bodyDense)
                .foregroundColor(DS.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bg)
    }
}
