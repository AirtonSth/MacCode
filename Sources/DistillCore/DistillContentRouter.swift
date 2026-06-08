import Foundation

/// Content type a payload is classified into before compression.
public enum DistillContentType: String, Sendable, Equatable {
    case json
    case diff
    case log
    case prose
}

/// Result of a deterministic route. `lossless == true` means no information was
/// dropped (a re-parse / expand recovers the input), so no CCR handle is needed.
/// `lossless == false` means element-dropping occurred and the caller MUST have
/// stored the original and embedded its handle before using `output`.
public struct DistillRouteResult: Sendable, Equatable {
    public let output: String
    public let contentType: DistillContentType
    public let lossless: Bool

    public init(output: String, contentType: DistillContentType, lossless: Bool) {
        self.output = output
        self.contentType = contentType
        self.lossless = lossless
    }
}

/// Controls how aggressive routing may be on a given call.
public struct DistillRouterOptions: Sendable, Equatable {
    /// Allow element-dropping (lossy) transforms such as diff context windowing.
    /// Only safe when a reversible store is available to recover the original.
    public let allowElementDropping: Bool
    /// Minimum fractional size reduction to accept a route (else fall through to
    /// the model / identity). Below this the win isn't worth the divergence.
    public let minGainRatio: Double

    public init(allowElementDropping: Bool = false, minGainRatio: Double = 0.10) {
        self.allowElementDropping = allowElementDropping
        self.minGainRatio = minGainRatio
    }

    /// Lossless-only routing (default-on, no store required).
    public static let losslessOnly = DistillRouterOptions(allowElementDropping: false)
}

/// headroom's ContentRouter, ported native: detect the payload type and dispatch
/// to the cheapest sufficient deterministic compressor BEFORE the model is ever
/// invoked. Deterministic-first, model last (G4). Pure value type, no I/O, no GPU.
public struct DistillContentRouter: Sendable {
    public init() {}

    /// Classify on a bounded sample so huge payloads stay cheap to inspect.
    public func classify(_ text: String) -> DistillContentType {
        if JSONCrusher.looksLikeJSON(text) { return .json }
        if DiffCrusher.looksLikeDiff(text) { return .diff }
        if LogCollapser.looksLikeLog(text) { return .log }
        return .prose
    }

    /// Route a payload through the cheapest sufficient deterministic compressor.
    /// Returns nil to fall through to the model (prose, or no worthwhile gain).
    /// Never inflates: a result is returned only when it is at least
    /// `options.minGainRatio` smaller than the input.
    public func route(_ input: String, options: DistillRouterOptions = .losslessOnly) -> DistillRouteResult? {
        let type = classify(input)
        let candidate: DistillRouteResult?
        switch type {
        case .json:
            candidate = JSONCrusher.minify(input).map { DistillRouteResult(output: $0, contentType: .json, lossless: true) }
        case .log:
            candidate = LogCollapser.collapse(input).map { DistillRouteResult(output: $0, contentType: .log, lossless: true) }
        case .diff:
            // Diff windowing drops context => element-dropping. Only when allowed
            // (a reversible store is backing it). Otherwise fall through.
            if options.allowElementDropping {
                candidate = DiffCrusher.window(input).map { DistillRouteResult(output: $0, contentType: .diff, lossless: false) }
            } else {
                candidate = nil
            }
        case .prose:
            // Prose may still be JSON-ish embedded; a cheap lossless minify probe
            // is free. Otherwise the model handles prose.
            candidate = JSONCrusher.minify(input).map { DistillRouteResult(output: $0, contentType: .json, lossless: true) }
        }

        guard let result = candidate, meetsGain(input: input, output: result.output, ratio: options.minGainRatio) else {
            return nil
        }
        return result
    }

    private func meetsGain(input: String, output: String, ratio: Double) -> Bool {
        guard input.count > 0, output.count < input.count else { return false }
        let reduction = 1.0 - (Double(output.count) / Double(input.count))
        return reduction >= ratio
    }
}
