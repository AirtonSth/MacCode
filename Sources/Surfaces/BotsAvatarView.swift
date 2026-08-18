import SwiftUI
import CoreModel
import DesignSystemKit

/// Shared teammate avatar. Desk roster and both composers mount this view.
public struct BotsAvatarView: View {
    public let name: String
    public let handle: String
    public var symbol: String?
    public var size: CGFloat = 36
    public var attention: BotAttentionState = .none

    public init(
        name: String,
        handle: String,
        symbol: String? = nil,
        size: CGFloat = 36,
        attention: BotAttentionState = .none
    ) {
        self.name = name
        self.handle = handle
        self.symbol = symbol
        self.size = size
        self.attention = attention
    }

    public var body: some View {
        Group {
            if let symbol, let spec = BotBlobatarSpec.parse(symbol) {
                BotBlobatarView(
                    name: name.isEmpty ? handle : name,
                    spec: spec.liveFaced(attention: attention),
                    size: size,
                    motion: .frozen,
                    handle: handle
                )
            } else {
                symbolFallback
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var symbolFallback: some View {
        let ink = avatarColor(for: handle)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(ink)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: max(11, size * 0.42), weight: .semibold))
                    .foregroundColor(.white)
            } else {
                Text(initials(for: name))
                    .font(.system(size: max(11, size * 0.36), weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func avatarColor(for handle: String) -> Color {
        let palette: [UInt32] = [
            0x7B5CFF, 0x3B82F6, 0xF59E0B, 0x22C55E, 0xEC4899, 0x06B6D4,
        ]
        let index = abs(handle.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }) % palette.count
        return Color(hex: palette[index])
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        if letters.isEmpty { return "B" }
        return letters.joined().uppercased()
    }
}
