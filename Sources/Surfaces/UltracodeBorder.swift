import SwiftUI
import AppKit
import DesignSystemKit

/// Rotating purple gradient border + soft glow for the composer card while Ultracode is on.
/// `angleOverride` pins the gradient (render tests); otherwise it rotates one lap per
/// `AgentUltracodeBorderPresentation.lapSeconds`, or stays static under Reduce Motion.
/// The rotation holds its angle while the window is not key or the composer is hidden
/// (background tab, closed window): the timeline otherwise keeps ticking at 30 Hz there.
public struct UltracodeBorder: ViewModifier {
    public var active: Bool
    public var angleOverride: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var onScreen = true
    /// Gradient frames built (one per timeline tick); tests assert pauses with it.
    nonisolated(unsafe) static var frameCountForTesting = 0

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
        let ticking = animated && AgentUltracodeBorderPresentation.isTicking(
            reduceMotion: reduceMotion,
            windowIsKey: controlActiveState == .key,
            onScreen: onScreen
        )
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !ticking)) { timeline in
            let _ = Self.frameCountForTesting += 1
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
        .background(UltracodeBorderVisibilityProbe(onScreen: $onScreen))
        .allowsHitTesting(false)
    }
}

/// Reports whether the border's AppKit host is in a window and not hidden by an
/// ancestor (`isHidden` tab caches keep SwiftUI timelines running).
private struct UltracodeBorderVisibilityProbe: NSViewRepresentable {
    @Binding var onScreen: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { onScreen = $0 }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = { onScreen = $0 }
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var reported: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func viewDidHide() { super.viewDidHide(); report() }
        override func viewDidUnhide() { super.viewDidUnhide(); report() }

        private func report() {
            let visible = window != nil && !isHiddenOrHasHiddenAncestor
            guard visible != reported else { return }
            reported = visible
            // AppKit calls these mid-update; never write SwiftUI state synchronously.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reported == visible else { return }
                self.onChange?(visible)
            }
        }
    }
}
