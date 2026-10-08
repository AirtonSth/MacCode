import SwiftUI
import DesignSystemKit

/// Rotating purple gradient border + soft glow for the composer card while Ultracode is on.
/// `angleOverride` pins the gradient (render tests); otherwise it rotates one lap per
/// `AgentUltracodeBorderPresentation.lapSeconds`, or stays static under Reduce Motion.
public struct UltracodeBorder: ViewModifier {
    public var active: Bool
    public var angleOverride: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(active: Bool, angleOverride: Double? = nil) {
        self.active = active
        self.angleOverride = angleOverride
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if active { border.transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: active)
    }

    private var border: some View {
        let animated = angleOverride == nil
            && AgentUltracodeBorderPresentation.isAnimated(reduceMotion: reduceMotion)
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            let lap = AgentUltracodeBorderPresentation.lapSeconds
            let angle = angleOverride ?? (animated
                ? timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: lap) / lap * 360
                : 0)
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            DS.Palette.ultracode,
                            DS.Palette.ultracodeDeep,
                            DS.Palette.ultracode.opacity(0.35),
                            DS.Palette.ultracode
                        ],
                        center: .center,
                        angle: .degrees(angle)
                    ),
                    lineWidth: 1.5
                )
                .shadow(color: DS.Palette.ultracode.opacity(0.35), radius: 6)
        }
        .allowsHitTesting(false)
    }
}
