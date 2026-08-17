import Foundation

/// Studio Avatar composer. Token lives in `BotDefinition.avatarSymbol`.
///
/// Geometry and trait hashing follow Alain00/blobatar (MIT). Tile UX
/// (frozen previews, selected chip, circular hue swatches) follows
/// jeremy-prt/bloub (MIT). No npm package, no animation engine.
public enum BotBlobatarShape: String, CaseIterable, Sendable {
    case auto, round, organic, boxy, nub, cloud, sun

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .round: return "Round"
        case .organic: return "Organic"
        case .boxy: return "Boxy"
        case .nub: return "Nub"
        case .cloud: return "Cloud"
        case .sun: return "Sun"
        }
    }

    /// Midpoint of blobatar's frozen `shapeOf` bands.
    var traitPosition: Double? {
        switch self {
        case .auto: return nil
        case .round: return 0.14
        case .organic: return 0.43
        case .boxy: return 0.65
        case .nub: return 0.78
        case .cloud: return 0.885
        case .sun: return 0.965
        }
    }
}

public enum BotBlobatarExpression: String, CaseIterable, Sendable {
    case idle, happy, sad, mad

    public var displayName: String {
        rawValue.capitalized
    }
}

public enum BotBlobatarBackground: String, CaseIterable, Sendable {
    case none, squircle, circle, square

    public var displayName: String {
        rawValue.capitalized
    }
}

public enum BotBlobatarHue: Equatable, Sendable, Hashable {
    case auto
    case named(String)

    public var token: String {
        switch self {
        case .auto: return "auto"
        case .named(let id): return id
        }
    }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .named(let id): return id.capitalized
        }
    }

    public var degrees: Double? {
        switch self {
        case .auto: return nil
        case .named(let id): return BotBlobatar.studioHues.first { $0.id == id }?.degrees
        }
    }
}

public struct BotBlobatarHueSwatch: Equatable, Sendable {
    public let id: String
    public let degrees: Double
    public let preview: UInt32
}

public struct BotBlobatarSpec: Equatable, Sendable {
    public var shape: BotBlobatarShape
    public var expression: BotBlobatarExpression
    public var background: BotBlobatarBackground
    public var hue: BotBlobatarHue

    public static let `default` = BotBlobatarSpec(
        shape: .auto,
        expression: .idle,
        background: .none,
        hue: .auto
    )

    public static let tokenPrefix = "blobatar:v1:"

    public init(
        shape: BotBlobatarShape = .auto,
        expression: BotBlobatarExpression = .idle,
        background: BotBlobatarBackground = .none,
        hue: BotBlobatarHue = .auto
    ) {
        self.shape = shape
        self.expression = expression
        self.background = background
        self.hue = hue
    }

    public var token: String {
        "\(Self.tokenPrefix)\(shape.rawValue):\(expression.rawValue):\(background.rawValue):\(hue.token)"
    }

    public var advertisedName: String {
        if shape != .auto { return shape.displayName }
        if expression != .idle { return expression.displayName }
        if background != .none { return background.displayName }
        if hue != .auto { return hue.displayName }
        return "Auto"
    }

    public static func parse(_ raw: String) -> BotBlobatarSpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix(tokenPrefix) {
            return parseToken(String(lower.dropFirst(tokenPrefix.count)))
        }
        if let shape = BotBlobatarShape(rawValue: lower), shape != .auto {
            return BotBlobatarSpec(shape: shape)
        }
        if let expression = BotBlobatarExpression(rawValue: lower), expression != .idle {
            return BotBlobatarSpec(expression: expression)
        }
        if let background = BotBlobatarBackground(rawValue: lower), background != .none {
            return BotBlobatarSpec(background: background)
        }
        if BotBlobatar.studioHues.contains(where: { $0.id == lower }) {
            return BotBlobatarSpec(hue: .named(lower))
        }
        if lower == "auto" || lower == "blobatar" { return .default }
        return nil
    }

    private static func parseToken(_ body: String) -> BotBlobatarSpec? {
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              let shape = BotBlobatarShape(rawValue: parts[0]),
              let expression = BotBlobatarExpression(rawValue: parts[1]),
              let background = BotBlobatarBackground(rawValue: parts[2])
        else { return nil }
        let hue: BotBlobatarHue
        if parts[3] == "auto" {
            hue = .auto
        } else if BotBlobatar.studioHues.contains(where: { $0.id == parts[3] }) {
            hue = .named(parts[3])
        } else {
            return nil
        }
        return BotBlobatarSpec(shape: shape, expression: expression, background: background, hue: hue)
    }
}

public struct BotBlobatarPalette: Equatable, Sendable {
    public var bg: UInt32
    public var head: UInt32
    public var eye: UInt32
}

public struct BotBlobatarEllipse: Equatable, Sendable {
    public var cx: Double
    public var cy: Double
    public var rx: Double
    public var ry: Double
    public var n: Double
    public var rot: Double

    public init(cx: Double, cy: Double, rx: Double, ry: Double, n: Double, rot: Double) {
        self.cx = cx
        self.cy = cy
        self.rx = rx
        self.ry = ry
        self.n = n
        self.rot = rot
    }
}

public struct BotBlobatarPetal: Equatable, Sendable {
    public var cx: Double
    public var cy: Double
    public var r: Double
}

public enum BotBlobatarResolvedShape: String, Sendable {
    case round, organic, boxy, nub, cloud, sun
}

public struct BotBlobatarFigure: Equatable, Sendable {
    public var resolvedShape: BotBlobatarResolvedShape
    public var body: BotBlobatarEllipse
    public var radii: [Double]
    public var petals: [BotBlobatarPetal]
    public var eyes: [BotBlobatarEllipse]
    public var bodyOffsetY: Double
    public var palette: BotBlobatarPalette
    public var background: BotBlobatarBackground
}

public enum BotBlobatar {
    public static let studioHues: [BotBlobatarHueSwatch] = [
        .init(id: "pink", degrees: 350, preview: 0xF472B6),
        .init(id: "coral", degrees: 20, preview: 0xFB923C),
        .init(id: "amber", degrees: 42, preview: 0xF59E0B),
        .init(id: "green", degrees: 135, preview: 0x4ADE80),
        .init(id: "teal", degrees: 175, preview: 0x2DD4BF),
        .init(id: "sky", degrees: 205, preview: 0x38BDF8),
        .init(id: "indigo", degrees: 250, preview: 0x818CF8),
        .init(id: "violet", degrees: 290, preview: 0xC084FC),
    ]

    public static func figure(name: String, spec: BotBlobatarSpec) -> BotBlobatarFigure {
        let seed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let traits = Traits(seed: seed.isEmpty ? "bot" : seed, overrides: overrides(for: spec))
        var layout = layout(traits)
        let pose = Pose.forExpression(spec.expression)
        layout = pose.bake(layout)
        var palette = palette(hue: spec.hue.degrees ?? traits.num("hue", 0, 360), tone: traits("tone"))
        if spec.expression == .mad {
            palette.head = mixHex(palette.head, 0xE8483F, 0.62)
            palette.eye = contrastEye(against: palette.head)
        }
        return BotBlobatarFigure(
            resolvedShape: layout.shape,
            body: layout.body,
            radii: layout.radii,
            petals: layout.petals,
            eyes: layout.eyes,
            bodyOffsetY: pose.bdy,
            palette: palette,
            background: spec.background
        )
    }

    private static func overrides(for spec: BotBlobatarSpec) -> [String: Double] {
        var map: [String: Double] = [:]
        if let shape = spec.shape.traitPosition {
            map["shape"] = shape
        }
        return map
    }
}

// MARK: - Hash / traits (blobatar)

private struct Traits {
    let state: UInt32
    let overrides: [String: Double]

    init(seed: String, overrides: [String: Double]) {
        let normalized = seed.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let bytes = Array(normalized.utf8)
        self.state = feed(1779033703 ^ UInt32(truncatingIfNeeded: bytes.count), bytes)
        self.overrides = overrides
    }

    func callAsFunction(_ key: String) -> Double {
        if let override = overrides[key] {
            return override > 0 ? (override < 1 ? override : 0.999999) : 0
        }
        var mixed = feed(state, [0xFF])
        mixed = feed(mixed, Array(key.utf8))
        return Double(finalize(mixed)) / 4_294_967_296.0
    }

    func num(_ key: String, _ min: Double, _ max: Double) -> Double {
        min + self(key) * (max - min)
    }

    func int(_ key: String, _ min: Int, _ max: Int) -> Int {
        min + Int(floor(self(key) * Double(max - min + 1)))
    }

    func jitter(_ key: String, _ amount: Double) -> Double {
        (self(key) * 2 - 1) * amount
    }
}

private func imul(_ a: UInt32, _ b: UInt32) -> UInt32 {
    UInt32(bitPattern: Int32(bitPattern: a) &* Int32(bitPattern: b))
}

private func feed(_ h: UInt32, _ bytes: [UInt8]) -> UInt32 {
    var h = h
    for byte in bytes {
        h = imul(h ^ UInt32(byte), 3_432_918_353)
        h = (h << 13) | (h >> 19)
    }
    return h
}

private func finalize(_ h: UInt32) -> UInt32 {
    var h = h
    h = imul(h ^ (h >> 16), 2_246_822_507)
    h = imul(h ^ (h >> 13), 3_266_489_909)
    return h ^ (h >> 16)
}

// MARK: - Layout (blobatar styles/blob.ts)

private struct Layout {
    var shape: BotBlobatarResolvedShape
    var body: BotBlobatarEllipse
    var radii: [Double]
    var petals: [BotBlobatarPetal]
    var eyes: [BotBlobatarEllipse]
}

private func shapeOf(_ v: Double) -> BotBlobatarResolvedShape {
    if v < 0.28 { return .round }
    if v < 0.58 { return .organic }
    if v < 0.72 { return .boxy }
    if v < 0.84 { return .nub }
    if v < 0.93 { return .cloud }
    return .sun
}

private func coreScale(_ shape: BotBlobatarResolvedShape) -> Double {
    switch shape {
    case .round: return 1
    case .boxy: return 0.86
    case .organic: return 0.98
    case .cloud: return 0.78
    case .sun: return 0.7
    case .nub: return 0.88
    }
}

private func layout(_ t: Traits) -> Layout {
    let shape = shapeOf(t("shape"))
    let r = t.num("body.r", 31, 38) * coreScale(shape)
    let rx = r
    let ry = r * t.num("body.ratio", 0.92, 1.08)
    let n = shape == .boxy ? t.num("body.n", 3.4, 6) : t.num("body.n", 1.9, 2.5)
    let rot = shape == .boxy ? t.num("body.rot", -20, 20) : 0
    let pointCount = t.int("body.pts", 6, 8)
    let radii = (0..<pointCount).map { 1 + t.jitter("body.r\($0)", 0.16) }
    let body = BotBlobatarEllipse(
        cx: 50 + t.jitter("body.x", 1.5),
        cy: 50 + t.jitter("body.y", 1.5),
        rx: rx,
        ry: ry,
        n: n,
        rot: rot
    )

    let gx = t.jitter("gaze.x", 0.09) * rx
    let gy = t.num("gaze.y", -0.2, 0.08) * ry
    let er0 = t.num("eye.rx", 0.075, 0.105) * rx
    let ratio = t.num("eye.ratio", 1.9, 3.2)
    let scale = t.num("eye.scale", 0.78, 1.24)
    let stretch = t.num("eye.stretch", 0.85, 1.18)
    let clearance = t.num("eye.gap", 0.1, 0.24) * rx
    let wide = er0 * max(1, scale)
    let tall = er0 * ratio * max(1, scale * stretch)
    let gap0 = wide + rx * 0.03 + clearance
    let tight = (shape == .organic || shape == .cloud) ? (radii.min() ?? 1) * 0.95 : 1
    let need = (abs(gx) + gap0 + hypot(wide, tall)) / rx
    let fit = need > tight * 0.9 ? (tight * 0.9) / need : 1
    let er = er0 * fit
    let gap = gap0 * fit
    let eyeRy = er * ratio
    let maxLean = 12.0
    let room = max(0, min(1, (clearance * fit) / (tall * fit)))
    let bound = min(maxLean, asin(min(1, room)) * 180 / .pi)
    let lean = t.num("eye.lean", -1, 1) * bound
    let lean2 = max(-maxLean, min(maxLean, lean + t.jitter("eye.lean2", 3.5)))

    var petals: [BotBlobatarPetal] = []
    if shape == .sun {
        let count = t.int("sun.n", 6, 9)
        let dist = r * t.num("sun.dist", 1.0, 1.08)
        let pr = r * t.num("sun.r", 0.2, 0.26)
        let off = t.num("sun.rot", 0, 2 * .pi)
        for i in 0..<count {
            let a = off + (2 * .pi * Double(i)) / Double(count)
            petals.append(.init(cx: body.cx + cos(a) * dist, cy: body.cy + sin(a) * dist, r: pr))
        }
    } else if shape == .cloud {
        let count = t.int("cloud.n", 4, 6)
        for i in 0..<count {
            let a = .pi + (.pi * (Double(i) + 0.5)) / Double(count)
            petals.append(.init(
                cx: body.cx + cos(a) * r * 0.8,
                cy: body.cy + sin(a) * r * 0.5,
                r: r * t.num("cloud.r\(i)", 0.44, 0.62)
            ))
        }
    } else if shape == .nub {
        let count = t.int("nub.n", 1, 2)
        for i in 0..<count {
            let a = t.num("nub.a\(i)", 0, 2 * .pi)
            petals.append(.init(
                cx: body.cx + cos(a) * r * 0.88,
                cy: body.cy + sin(a) * r * 0.88,
                r: r * t.num("nub.r\(i)", 0.24, 0.4)
            ))
        }
    }

    return Layout(
        shape: shape,
        body: body,
        radii: radii,
        petals: petals,
        eyes: [
            .init(cx: body.cx + gx - gap, cy: body.cy + gy, rx: er, ry: eyeRy, n: t.num("eye.n", 3.5, 6), rot: lean),
            .init(
                cx: body.cx + gx + gap,
                cy: body.cy + gy + t.jitter("eye.dy", 0.04) * ry,
                rx: er * scale,
                ry: eyeRy * scale * stretch,
                n: t.num("eye.n", 3.5, 6),
                rot: lean2
            ),
        ]
    )
}

// MARK: - Expression bake (blobatar expression.ts)

private struct Pose {
    var esx: Double
    var esy: Double
    var tilt: Double
    var edy: Double
    var edx: Double
    var esx2: Double
    var esy2: Double
    var tilt2: Double
    var lock: Double
    var bdy: Double

    static let idle = Pose(esx: 1, esy: 1, tilt: 0, edy: 0, edx: 0, esx2: 0, esy2: 0, tilt2: 0, lock: 0, bdy: 0)
    static let happy = Pose(esx: 1.72, esy: 0.3, tilt: 8, edy: -1.5, edx: 1.5, esx2: 0.08, esy2: 0.05, tilt2: -16, lock: 1, bdy: -2.2)
    static let sad = Pose(esx: 0.6, esy: 0.56, tilt: 26, edy: 3.6, edx: 1.9, esx2: -0.05, esy2: -0.07, tilt2: -7, lock: 1, bdy: 2.6)
    static let mad = Pose(esx: 1.85, esy: 0.26, tilt: -33, edy: 0.4, edx: 0.6, esx2: 0, esy2: -0.03, tilt2: 5, lock: 1, bdy: 0.8)

    static func forExpression(_ expression: BotBlobatarExpression) -> Pose {
        switch expression {
        case .idle: return .idle
        case .happy: return .happy
        case .sad: return .sad
        case .mad: return .mad
        }
    }

    func bake(_ layout: Layout) -> Layout {
        var next = layout
        next.eyes = layout.eyes.enumerated().map { i, eye in
            var eye = eye
            eye.cx += edx * (i == 0 ? -1 : 1)
            eye.cy += edy
            eye.rx *= esx + (i == 0 ? 0 : esx2)
            eye.ry *= esy + (i == 0 ? 0 : esy2)
            eye.rot = eye.rot * (1 - lock) + (tilt + (i == 0 ? 0 : tilt2)) * (i == 0 ? -1 : 1)
            return eye
        }
        return next
    }
}

// MARK: - Palette (compact OKLCh, blobatar color.ts)

private struct OKLCh {
    var l: Double
    var c: Double
    var h: Double
}

private func palette(hue: Double, tone: Double) -> BotBlobatarPalette {
    let swatch: (l: Double, c: Double)
    if tone < 0.2 {
        swatch = (0.86, 0.085)
    } else if tone < 0.36 {
        swatch = (0.9, 0.028)
    } else if tone < 0.62 {
        swatch = (0.73, 0.135)
    } else if tone < 0.8 {
        swatch = (0.62, 0.165)
    } else if tone < 0.93 {
        swatch = (0.87, 0.16)
    } else {
        swatch = (0.34, 0.035)
    }
    let darkSurface = OKLCh(l: 0.145, c: 0, h: 0)
    var head = ensureContrast(OKLCh(l: swatch.l, c: swatch.c, h: hue), against: darkSurface, min: 1.5)
    let bg = OKLCh(l: 0.965, c: 0.01, h: hue)
    head = ensureContrast(head, against: bg, min: 1.25)
    var eye = head.l >= 0.5
        ? OKLCh(l: 0.17, c: 0.02, h: hue)
        : OKLCh(l: 0.97, c: 0.012, h: hue)
    eye = ensureContrast(eye, against: head, min: 4.5)
    return BotBlobatarPalette(bg: toHex(bg), head: toHex(head), eye: toHex(eye))
}

private func toLinear(_ color: OKLCh) -> (Double, Double, Double) {
    let r = color.h * .pi / 180
    let a = color.c * cos(r)
    let b = color.c * sin(r)
    let l_ = color.l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = color.l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = color.l - 0.0894841775 * a - 1.291485548 * b
    let L = l_ * l_ * l_
    let M = m_ * m_ * m_
    let S = s_ * s_ * s_
    return (
        4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
        -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
        -0.0041960863 * L - 0.7034186147 * M + 1.707614701 * S
    )
}

private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

private func resolve(_ color: OKLCh) -> (Double, Double, Double) {
    var rgb = toLinear(color)
    func inGamut(_ c: (Double, Double, Double)) -> Bool {
        c.0 >= -1e-4 && c.0 <= 1 + 1e-4
            && c.1 >= -1e-4 && c.1 <= 1 + 1e-4
            && c.2 >= -1e-4 && c.2 <= 1 + 1e-4
    }
    if !inGamut(rgb) {
        var lo = 0.0
        var hi = color.c
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if inGamut(toLinear(OKLCh(l: color.l, c: mid, h: color.h))) { lo = mid } else { hi = mid }
        }
        rgb = toLinear(OKLCh(l: color.l, c: lo, h: color.h))
    }
    return (clamp01(rgb.0), clamp01(rgb.1), clamp01(rgb.2))
}

private func luminance(_ color: OKLCh) -> Double {
    let rgb = resolve(color)
    return 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
}

private func contrast(_ a: OKLCh, _ b: OKLCh) -> Double {
    let x = luminance(a)
    let y = luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

private func ensureContrast(_ fg: OKLCh, against bg: OKLCh, min: Double) -> OKLCh {
    if contrast(fg, bg) >= min { return fg }
    let lean: Double = fg.l >= bg.l ? 1 : -1
    for dir in [lean, -lean] {
        var probe = fg
        for _ in 0..<60 {
            probe.l = clamp01(probe.l + dir * 0.02)
            if contrast(probe, bg) >= min { return probe }
            if probe.l == 0 || probe.l == 1 { break }
        }
    }
    let black = OKLCh(l: 0, c: 0, h: fg.h)
    let white = OKLCh(l: 1, c: 0, h: fg.h)
    return contrast(black, bg) >= contrast(white, bg) ? black : white
}

private func toHex(_ color: OKLCh) -> UInt32 {
    let rgb = resolve(color)
    func enc(_ v: Double) -> UInt32 {
        let s = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt32(clamp01(s) * 255.0 + 0.5)
    }
    return (enc(rgb.0) << 16) | (enc(rgb.1) << 8) | enc(rgb.2)
}

private func mixHex(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    func ch(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) }
    func mix(_ x: Double, _ y: Double) -> UInt32 { UInt32(x + (y - x) * t + 0.5) }
    let r = mix(ch(a, 16), ch(b, 16))
    let g = mix(ch(a, 8), ch(b, 8))
    let bl = mix(ch(a, 0), ch(b, 0))
    return (r << 16) | (g << 8) | bl
}

private func contrastEye(against head: UInt32) -> UInt32 {
    let r = Double((head >> 16) & 0xFF)
    let g = Double((head >> 8) & 0xFF)
    let b = Double(head & 0xFF)
    let luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    return luma >= 0.5 ? 0x2A1A14 : 0xF7F3EE
}
