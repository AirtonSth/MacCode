import SwiftUI
import CoreModel
import DesignSystemKit

/// Blobatar renderer. Picker tiles stay `.frozen` (bloub BotTile).
public struct BotBlobatarView: View {
    public var name: String
    public var spec: BotBlobatarSpec
    public var size: CGFloat
    public var motion: BotBlobatarMotionMode
    public var handle: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    public init(
        name: String,
        spec: BotBlobatarSpec,
        size: CGFloat,
        motion: BotBlobatarMotionMode = .frozen,
        handle: String = ""
    ) {
        self.name = name
        self.spec = spec
        self.size = size
        self.motion = motion
        self.handle = handle
    }

    public var body: some View {
        let figure = BotBlobatar.figure(name: name, spec: spec, handle: handle)
        let motionSeed = spec.renderSeed(liveName: name, handle: handle)
        let paused = reduceMotion || motion == .frozen || (motion == .hover && !hovering)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
            let pose = paused
                ? BotBlobatarMotion.still
                : BotBlobatar.motion(
                    name: motionSeed,
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    expression: spec.expression,
                    amplitude: 1
                )
            Canvas { context, canvasSize in
                draw(figure: figure, motion: pose, in: context, canvasSize: canvasSize)
            }
        }
        .frame(width: size, height: size)
        .onHover { hovering = $0 }
        .accessibilityHidden(true)
    }

    private func draw(
        figure: BotBlobatarFigure,
        motion: BotBlobatarMotion,
        in context: GraphicsContext,
        canvasSize: CGSize
    ) {
        let scale = min(canvasSize.width, canvasSize.height) / 100
        let scaleOnly = CGAffineTransform(scaleX: scale, y: scale)
        var body = scaleOnly
        if figure.bodyOffsetY != 0 {
            body = body.translatedBy(x: 0, y: figure.bodyOffsetY)
        }
        body = body
            .translatedBy(x: 50 + motion.shakeX, y: 50 + motion.bobY + motion.shakeY)
            .scaledBy(x: motion.breatheX, y: motion.breatheY)
            .translatedBy(x: -50, y: -50)
        if let plate = backgroundPath(figure) {
            context.fill(Path(plate).applying(scaleOnly), with: .color(color(figure.palette.bg)))
        }
        let head = color(figure.palette.head)
        for petal in figure.petals {
            let rect = CGRect(x: petal.cx - petal.r, y: petal.cy - petal.r, width: petal.r * 2, height: petal.r * 2)
            context.fill(Path(ellipseIn: rect).applying(body), with: .color(head))
        }
        context.fill(bodyPath(figure).applying(body), with: .color(head))
        let ink = color(figure.palette.eye)
        let glance = size >= 40 ? motion : BotBlobatarMotion(
            breatheX: motion.breatheX,
            breatheY: motion.breatheY,
            bobY: motion.bobY,
            blink: motion.blink,
            glanceX: 0,
            glanceY: 0,
            shakeX: motion.shakeX,
            shakeY: motion.shakeY
        )
        for capsule in figure.eyes {
            var eye = body.translatedBy(x: glance.glanceX, y: glance.glanceY)
            eye = eye.translatedBy(x: capsule.cx, y: capsule.cy)
                .scaledBy(x: 1, y: glance.blink)
                .translatedBy(x: -capsule.cx, y: -capsule.cy)
            context.fill(superellipse(capsule).applying(eye), with: .color(ink))
        }
    }

    private func backgroundPath(_ figure: BotBlobatarFigure) -> CGPath? {
        switch figure.background {
        case .none:
            return nil
        case .square:
            return CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
        case .circle:
            return superellipse(BotBlobatarEllipse(cx: 50, cy: 50, rx: 50, ry: 50, n: 2, rot: 0)).cgPath
        case .squircle:
            return superellipse(BotBlobatarEllipse(cx: 50, cy: 50, rx: 50, ry: 50, n: 6, rot: 0)).cgPath
        }
    }

    private func bodyPath(_ figure: BotBlobatarFigure) -> Path {
        if figure.resolvedShape == .organic || figure.resolvedShape == .cloud {
            return blobPath(
                cx: figure.body.cx,
                cy: figure.body.cy,
                rx: figure.body.rx,
                ry: figure.body.ry,
                radii: figure.radii,
                rot: figure.resolvedShape == .cloud ? 0 : figure.body.rot
            )
        }
        return superellipse(figure.body)
    }

    private func superellipse(_ e: BotBlobatarEllipse) -> Path {
        let n = max(1.2, e.n)
        let k = min(1, (8 * pow(2, -1 / n) - 4) / 3)
        let a = e.rx
        let b = e.ry
        let ak = a * k
        let bk = b * k
        let pts: [(Double, Double)] = [
            (a, 0),
            (a, bk), (ak, b), (0, b),
            (-ak, b), (-a, bk), (-a, 0),
            (-a, -bk), (-ak, -b), (0, -b),
            (ak, -b), (a, -bk), (a, 0),
        ]
        let t = e.rot * .pi / 180
        let cosT = cos(t)
        let sinT = sin(t)
        func map(_ p: (Double, Double)) -> CGPoint {
            CGPoint(
                x: e.cx + p.0 * cosT - p.1 * sinT,
                y: e.cy + p.0 * sinT + p.1 * cosT
            )
        }
        var path = Path()
        path.move(to: map(pts[0]))
        var i = 1
        while i + 2 < pts.count {
            path.addCurve(to: map(pts[i + 2]), control1: map(pts[i]), control2: map(pts[i + 1]))
            i += 3
        }
        path.closeSubpath()
        return path
    }

    private func blobPath(cx: Double, cy: Double, rx: Double, ry: Double, radii: [Double], rot: Double) -> Path {
        let count = radii.count
        guard count >= 3 else {
            return superellipse(BotBlobatarEllipse(cx: cx, cy: cy, rx: rx, ry: ry, n: 2, rot: rot))
        }
        let t0 = rot * .pi / 180
        let points: [CGPoint] = radii.enumerated().map { i, m in
            let a = t0 + (2 * .pi * Double(i)) / Double(count)
            return CGPoint(x: cx + rx * m * cos(a), y: cy + ry * m * sin(a))
        }
        func at(_ i: Int) -> CGPoint {
            points[((i % count) + count) % count]
        }
        var path = Path()
        path.move(to: at(0))
        for i in 0..<count {
            let p0 = at(i - 1)
            let p1 = at(i)
            let p2 = at(i + 1)
            let p3 = at(i + 2)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
        path.closeSubpath()
        return path
    }

    private func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Studio composer. Control set is blobatar's editor; tiles follow bloub.
struct BotBlobatarEditor: View {
    @Binding var token: String
    var seed: String
    var handle: String = ""

    private var spec: BotBlobatarSpec {
        BotBlobatarSpec.parse(token) ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            section("shape") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.sm), count: 4), spacing: DS.Space.md) {
                    ForEach(BotBlobatarShape.allCases, id: \.self) { shape in
                        tile(
                            label: shape.rawValue,
                            selected: spec.shape == shape,
                            identifier: "bots.studio.avatar.shape.\(shape.rawValue)",
                            preview: previewing { $0.shape = shape }
                        ) {
                            apply { $0.shape = shape }
                        }
                    }
                }
            }
            section("expression") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.sm), count: 4), spacing: DS.Space.md) {
                    ForEach(BotBlobatarExpression.allCases, id: \.self) { expression in
                        tile(
                            label: expression.rawValue,
                            selected: spec.expression == expression,
                            identifier: "bots.studio.avatar.expression.\(expression.rawValue)",
                            preview: previewing { $0.expression = expression }
                        ) {
                            apply { $0.expression = expression }
                        }
                    }
                }
            }
            section("background") {
                backgroundPills
            }
            section("hue") {
                hueRow
            }
        }
        .padding(DS.Space.xl)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .accessibilityIdentifier("bots.studio.avatar")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            content()
        }
    }

    private func tile(label: String, selected: Bool, identifier: String, preview: BotBlobatarSpec, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs) {
                BotBlobatarView(name: seed, spec: preview, size: 36, motion: .frozen, handle: handle)
                Text(label)
                    .font(DS.Font.caption2)
                    .foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.surfaceOverlay : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var backgroundPills: some View {
        HStack(spacing: 0) {
            ForEach(BotBlobatarBackground.allCases, id: \.self) { background in
                let selected = spec.background == background
                Button {
                    apply { $0.background = background }
                } label: {
                    Text(background.rawValue)
                        .font(DS.Font.caption.weight(selected ? .semibold : .regular))
                        .foregroundColor(selected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.sm)
                        .frame(maxWidth: .infinity)
                        .background(selected ? DS.Palette.text : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(background.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("bots.studio.avatar.background.\(background.rawValue)")
            }
        }
        .padding(2)
        .background(DS.Palette.surfaceOverlay)
        .clipShape(Capsule())
        .accessibilityIdentifier("bots.studio.avatar.background")
    }

    private var hueRow: some View {
        HStack(spacing: DS.Space.sm) {
            let autoSelected = spec.hue == .auto
            Button {
                apply { $0.hue = .auto }
            } label: {
                Text("auto")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(autoSelected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.sm)
                    .background(autoSelected ? DS.Palette.text : Color.clear)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("auto")
            .accessibilityAddTraits(autoSelected ? .isSelected : [])
            .accessibilityIdentifier("bots.studio.avatar.hue.auto")

            ForEach(BotBlobatar.studioHues, id: \.id) { swatch in
                let selected = spec.hue == .named(swatch.id)
                Button {
                    apply { $0.hue = .named(swatch.id) }
                } label: {
                    Circle()
                        .fill(Color(
                            red: Double((swatch.preview >> 16) & 0xFF) / 255,
                            green: Double((swatch.preview >> 8) & 0xFF) / 255,
                            blue: Double(swatch.preview & 0xFF) / 255
                        ))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                        .overlay(
                            Circle()
                                .strokeBorder(selected ? DS.Palette.text : Color.clear, lineWidth: 2)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.id)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("bots.studio.avatar.hue.\(swatch.id)")
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("bots.studio.avatar.hue")
    }

    private func previewing(_ mutate: (inout BotBlobatarSpec) -> Void) -> BotBlobatarSpec {
        var next = spec
        mutate(&next)
        return next
    }

    private func apply(_ mutate: (inout BotBlobatarSpec) -> Void) {
        var next = spec
        mutate(&next)
        if next.isDefaultAppearance {
            next.frozenSeed = nil
        } else if next.frozenSeed == nil || next.frozenSeed?.isEmpty == true {
            next.frozenSeed = seed
        }
        token = next.token
    }
}
