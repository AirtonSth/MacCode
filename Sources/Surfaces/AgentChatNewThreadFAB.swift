import DesignSystemKit
import SwiftUI

/// Floating + over the chat timeline that starts a new thread. Shared by the
/// Agent App and the Bot desk so both chats look and act the same.
public struct AgentChatNewThreadFAB: View {
    let help: String
    public let identifier: String
    public let action: () -> Void

    public init(help: String = AgentChatThreadRailCopy.newHelp, identifier: String, action: @escaping () -> Void) {
        self.help = help
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Palette.onAccent)
                .frame(width: DSIconButton.hitTargetSize, height: DSIconButton.hitTargetSize)
                .background(DS.Palette.accent)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }
}
