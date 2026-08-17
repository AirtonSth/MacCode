import Foundation

/// Content type a payload is classified into before compression.
public enum DistillContentType: String, Codable, Sendable, Equatable {
    case json
    case diff
    case log
    case searchResults = "search_results"
    case buildOutput = "build_output"
    case stackTrace = "stack_trace"
    case testReport = "test_report"
    case sourceCode = "source_code"
    case html
    case mixed
    case prose
}

public struct DistillContentSubtypeDecision: Equatable, Sendable {
    public let contentType: DistillContentType
    public let confidence: Double

    public init(contentType: DistillContentType, confidence: Double) {
        self.contentType = contentType
        self.confidence = confidence
    }

    fileprivate func isConfident(minimumConfidence: Double) -> Bool {
        confidence.isFinite && confidence >= minimumConfidence
    }
}

public typealias DistillContentSubtypeClassifier = @Sendable (String) -> DistillContentSubtypeDecision?

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
    /// Context pressure from 0.0 (low) to 1.0 (high). When present, lossless
    /// routes require a larger win as pressure grows: output/input 0.85 -> 0.65.
    public let contextPressure: Double?
    /// Handle for the byte-exact original. Required by element-dropping routes.
    public let reversibleHandle: String?
    /// Later-phase prose pruning lane. Default OFF until corpus gates pass.
    public let allowLossyProsePruning: Bool
    /// Optional contract/query used by extractive prose pruning. This is a
    /// BERT-ready seam: deterministic BM25 works now; encoder scores can add
    /// keeps later without deciding drops alone.
    public let query: String?

    public init(
        allowElementDropping: Bool = false,
        minGainRatio: Double = 0.10,
        contextPressure: Double? = nil,
        reversibleHandle: String? = nil,
        allowLossyProsePruning: Bool = false,
        query: String? = nil
    ) {
        self.allowElementDropping = allowElementDropping
        self.minGainRatio = minGainRatio
        self.contextPressure = contextPressure.map(Self.clampPressure)
        let handle = reversibleHandle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reversibleHandle = handle?.isEmpty == false ? handle : nil
        self.allowLossyProsePruning = allowLossyProsePruning
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmedQuery?.isEmpty == false ? trimmedQuery : nil
    }

    /// Lossless-only routing (default-on, no store required).
    public static let losslessOnly = DistillRouterOptions(allowElementDropping: false)

    public static func pressure(inputCharacters: Int, outputBudgetCharacters: Int) -> Double? {
        guard inputCharacters > outputBudgetCharacters, outputBudgetCharacters > 0 else { return nil }
        let ratio = Double(inputCharacters) / Double(outputBudgetCharacters)
        return clampPressure((ratio - 1.0) / 3.0)
    }

    public static func adaptiveMinGainRatio(contextPressure: Double) -> Double {
        let pressure = clampPressure(contextPressure)
        let outputRatio = 0.85 - (0.20 * pressure)
        return 1.0 - outputRatio
    }

    public func effectiveMinGainRatio(lossless: Bool) -> Double {
        guard lossless, let contextPressure else { return minGainRatio }
        return max(minGainRatio, Self.adaptiveMinGainRatio(contextPressure: contextPressure))
    }

    private static func clampPressure(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

/// headroom's ContentRouter, ported native: detect the payload type and dispatch
/// to the cheapest sufficient deterministic compressor BEFORE the model is ever
/// invoked. Deterministic-first, model last (G4). Pure value type, no I/O, no GPU.
public struct DistillContentRouter: Sendable {
    public static let subtypeClassifierConfidenceThreshold = 0.82

    public init() {}

    /// Classify on a bounded sample so huge payloads stay cheap to inspect.
    public func classify(_ text: String, classifier: DistillContentSubtypeClassifier? = nil) -> DistillContentType {
        if JSONCrusher.looksLikeJSON(text) { return .json }
        if DiffCrusher.looksLikeDiff(text) { return .diff }
        if StackTraceCrusher.looksLikeStackTrace(text) { return .stackTrace }
        if TestReportCrusher.looksLikeTestReport(text) { return .testReport }
        if looksLikeHTML(text) { return .html }
        if looksLikeBuildOutput(text) { return .buildOutput }
        if looksLikeSearchResults(text) { return .searchResults }
        if looksLikeSourceCode(text) { return .sourceCode }
        if LogCollapser.looksLikeLog(text) { return .log }
        if let decision = classifier?(text),
           decision.isConfident(minimumConfidence: Self.subtypeClassifierConfidenceThreshold) {
            return decision.contentType
        }
        return .prose
    }

    /// Route a payload through the cheapest sufficient deterministic compressor.
    /// Returns nil to fall through to the model (prose, or no worthwhile gain).
    /// Never inflates: a result is returned only when it is at least
    /// `options.minGainRatio` smaller than the input.
    public func route(
        _ input: String,
        options: DistillRouterOptions = .losslessOnly,
        classifier: DistillContentSubtypeClassifier? = nil
    ) -> DistillRouteResult? {
        route(input, options: options, classifier: classifier, allowMixedRouting: true)
    }

    private func route(
        _ input: String,
        options: DistillRouterOptions,
        classifier: DistillContentSubtypeClassifier?,
        allowMixedRouting: Bool
    ) -> DistillRouteResult? {
        let type = classify(input, classifier: classifier)
        let candidate: DistillRouteResult?
        switch type {
        case .json:
            candidate = (JSONCrusher.tabularCSV(input) ?? JSONCrusher.minify(input))
                .map { DistillRouteResult(output: $0, contentType: .json, lossless: true) }
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
        case .stackTrace:
            if options.allowElementDropping {
                candidate = StackTraceCrusher.crush(input, handle: options.reversibleHandle)
                    .map { DistillRouteResult(output: $0, contentType: .stackTrace, lossless: false) }
            } else {
                candidate = nil
            }
        case .testReport:
            if options.allowElementDropping {
                candidate = TestReportCrusher.crush(input, handle: options.reversibleHandle)
                    .map { DistillRouteResult(output: $0, contentType: .testReport, lossless: false) }
            } else {
                candidate = nil
            }
        case .buildOutput:
            if options.allowElementDropping,
               let crushed = BuildProgressCrusher.crush(input, handle: options.reversibleHandle) {
                candidate = DistillRouteResult(output: crushed, contentType: .buildOutput, lossless: false)
            } else {
                candidate = LogCollapser.collapse(input).map {
                    DistillRouteResult(output: $0, contentType: .buildOutput, lossless: true)
                }
            }
        case .searchResults:
            // Search output often contains repeated match rows.
            candidate = LogCollapser.collapse(input).map { DistillRouteResult(output: $0, contentType: type, lossless: true) }
        case .sourceCode:
            if options.allowElementDropping, let handle = options.reversibleHandle {
                candidate = SourceCodeSkeletonizer.skeletonize(input, droppedHandle: handle)
                    .map { DistillRouteResult(output: $0, contentType: .sourceCode, lossless: false) }
            } else {
                candidate = nil
            }
        case .html:
            if options.allowElementDropping, let handle = options.reversibleHandle {
                candidate = HTMLStructuralCompressor.compress(input, droppedHandle: handle)
                    .map { DistillRouteResult(output: $0, contentType: .html, lossless: false) }
            } else {
                candidate = nil
            }
        case .mixed:
            candidate = nil
        case .prose:
            // Prose may still be JSON-ish embedded; a cheap lossless minify probe
            // is free. Otherwise the model handles prose.
            if options.allowElementDropping, options.allowLossyProsePruning {
                candidate = ProsePruningLane.prune(input, handle: options.reversibleHandle, question: options.query)
                    .map { DistillRouteResult(output: $0, contentType: .prose, lossless: false) }
            } else {
                candidate = JSONCrusher.minify(input).map { DistillRouteResult(output: $0, contentType: .json, lossless: true) }
            }
        }

        guard let result = candidate,
              meetsGain(input: input, output: result.output, ratio: options.effectiveMinGainRatio(lossless: result.lossless)) else {
            if allowMixedRouting {
                return routeMixedSections(input, options: options)
            }
            return nil
        }
        return result
    }

    private func routeMixedSections(_ input: String, options: DistillRouterOptions) -> DistillRouteResult? {
        let sections = input.components(separatedBy: "\n\n")
        guard sections.count > 1 else { return nil }

        var routedAny = false
        var lossless = true
        let outputs = sections.map { section -> String in
            guard let result = route(section, options: options, classifier: nil, allowMixedRouting: false) else {
                return section
            }
            routedAny = true
            lossless = lossless && result.lossless
            return result.output
        }
        guard routedAny else { return nil }
        let output = outputs.joined(separator: "\n\n")
        guard meetsGain(
            input: input,
            output: output,
            ratio: options.effectiveMinGainRatio(lossless: lossless)
        ) else {
            return nil
        }
        return DistillRouteResult(output: output, contentType: .mixed, lossless: lossless)
    }

    /// PERF: gain ratio used Character.count (O(n) grapheme walk) twice per route
    /// decision on multi-KB tool dumps. utf8.count is O(1) and matches byte-oriented
    /// Token Saver savings; ASCII-heavy command/build/test output is identical.
    private func meetsGain(input: String, output: String, ratio: Double) -> Bool {
        let inputBytes = input.utf8.count
        guard inputBytes > 0 else { return false }
        let outputBytes = output.utf8.count
        guard outputBytes < inputBytes else { return false }
        let reduction = 1.0 - (Double(outputBytes) / Double(inputBytes))
        return reduction >= ratio
    }

    private func looksLikeHTML(_ text: String) -> Bool {
        let sample = text.prefix(16_384).lowercased()
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") { return true }
        return (sample.contains("<html") && sample.contains("</html>")) ||
            (sample.contains("<body") && sample.contains("</body>")) ||
            (sample.contains("<div") && sample.contains("</div>"))
    }

    private func looksLikeBuildOutput(_ text: String) -> Bool {
        let sample = text.prefix(16_384).lowercased()
        let strongMarkers = [
            "** build failed **",
            "build failed",
            "build succeeded",
            "compile swift module",
            "compiling ",
            "linking ",
            "npm err!",
            "test suite failed",
            "execution failed for task"
        ]
        if strongMarkers.contains(where: { sample.contains($0) }) { return true }

        var hits = 0
        for line in sample.split(separator: "\n", omittingEmptySubsequences: true).prefix(120) {
            if line.contains(" error:") || line.hasPrefix("error:") ||
                line.contains(" warning:") || line.hasPrefix("warning:") ||
                line.contains("swiftc") || line.contains("xcodebuild") ||
                line.contains("failed test") {
                hits += 1
            }
            if hits >= 2 { return true }
        }
        return false
    }

    private func looksLikeSearchResults(_ text: String) -> Bool {
        var fileMatchLines = 0
        var urlLines = 0
        for line in text.prefix(16_384).split(separator: "\n", omittingEmptySubsequences: true).prefix(120) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isFileLineSearchResult(trimmed) { fileMatchLines += 1 }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") { urlLines += 1 }
            if fileMatchLines >= 2 || urlLines >= 2 { return true }
        }
        return false
    }

    private func isFileLineSearchResult(_ line: String) -> Bool {
        let parts = line.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[0].isEmpty else { return false }
        return Int(parts[1]) != nil
    }

    private func looksLikeSourceCode(_ text: String) -> Bool {
        let lines = text.prefix(16_384).split(separator: "\n", omittingEmptySubsequences: true).prefix(120)
        guard lines.count >= 2 else { return false }

        var hits = 0
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("import ") || line.hasPrefix("from ") && line.contains(" import ") ||
                line.hasPrefix("func ") || line.hasPrefix("def ") ||
                line.hasPrefix("class ") || line.hasPrefix("struct ") ||
                line.hasPrefix("enum ") || line.hasPrefix("protocol ") ||
                line.hasPrefix("extension ") || line.hasPrefix("public ") ||
                line.hasPrefix("private ") || line.hasPrefix("internal ") ||
                line.hasPrefix("let ") || line.hasPrefix("var ") ||
                line.hasPrefix("const ") || line.hasPrefix("function ") ||
                line.contains(" -> ") || line.contains("=>") ||
                line.hasSuffix("{") || line == "}" {
                hits += 1
            }
            if hits >= 2 { return true }
        }
        return false
    }
}
