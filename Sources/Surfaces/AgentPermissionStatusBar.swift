import SwiftUI
import DesignSystemKit

/// Shared compact permission chrome. Full access stays visible without a
/// paragraph above every conversation; the exact scope and downgrade action
/// remain available to keyboard and accessibility users.
struct AgentPermissionStatusBar: View {
    let scopeDescription: String
    let onSwitchToSupervised: () -> Void
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundColor(DS.Palette.danger)
                .accessibilityHidden(true)
            Text("Full access is on")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            Button { showsDetails.toggle() } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .help("Full access details")
            .accessibilityLabel("Full access details")
            .popover(isPresented: $showsDetails) {
                Text(scopeDescription)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                    .padding(DS.Space.lg)
                    .frame(idealWidth: 320, maxWidth: 360, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Switch to supervised", action: onSwitchToSupervised)
                .buttonStyle(.borderless)
                .font(DS.Font.caption)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.xs)
        .background(DS.Palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
        .accessibilityIdentifier("agent.fullAccessBanner")
    }
}
