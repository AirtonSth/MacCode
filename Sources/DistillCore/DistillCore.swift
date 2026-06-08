import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

public enum DistillMode: String, Codable, Sendable, Equatable {
    case commandOutput
    case longText
    case watchSummary
    case sr1Humanize
}

public enum DistillPriority: Int, Codable, Sendable, Comparable {
    case background = 0
    case agent = 1
    case interactive = 2

    public static func < (lhs: DistillPriority, rhs: DistillPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct DistillRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let mode: DistillMode
    public let priority: DistillPriority
    public let input: String
    public let question: String?
    public let provider: String?
    public let recordSavings: Bool?
    public let maxOutputCharacters: Int

    public init(
        id: UUID = UUID(),
        mode: DistillMode,
        priority: DistillPriority = .agent,
        input: String,
        question: String? = nil,
        provider: String? = nil,
        recordSavings: Bool = false,
        maxOutputCharacters: Int = 4_000
    ) {
        self.id = id
        self.mode = mode
        self.priority = priority
        self.input = input
        self.question = question?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.recordSavings = recordSavings
        self.maxOutputCharacters = max(128, maxOutputCharacters)
    }
}

public struct DistillResponse: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let output: String
    public let inputCharacters: Int
    public let outputCharacters: Int
    public let inputTokens: Int
    public let outputTokens: Int

    public init(requestID: UUID, output: String, inputCharacters: Int, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.requestID = requestID
        self.output = output
        self.inputCharacters = inputCharacters
        self.outputCharacters = output.count
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
    }

    /// Tokens removed by compression. Never negative: a longer "compressed"
    /// output (rare model misbehavior) reports zero savings, not negative.
    public var savedTokens: Int { max(inputTokens - outputTokens, 0) }
}

/// Deterministic, model-agnostic token estimator. The distilled output is only
/// ever sent to the provider in compressed form, so the *raw* token cost is
/// never observed from the provider — it must be estimated. The same estimator
/// is applied to input and output, so the delta is an honest, consistent
/// measure of how much compression removed (an estimate, not a billed count).
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        let chars = text.count
        guard chars > 0 else { return 0 }
        // OpenAI's published rule of thumb (~4 chars/token for English) blended
        // with a word-count floor so short, word-dense lines aren't undercounted.
        let byChars = Int((Double(chars) / 4.0).rounded())
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).count
        let byWords = Int((Double(words) * 1.3).rounded())
        return max(1, max(byChars, byWords))
    }
}

public struct DistillSavingsRecord: Sendable, Equatable {
    public let provider: String
    public let mode: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let savedTokens: Int

    public init(provider: String, mode: String, inputTokens: Int, outputTokens: Int, savedTokens: Int) {
        self.provider = provider
        self.mode = mode
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.savedTokens = max(0, savedTokens)
    }
}

public enum DistillSavingsCalculator {
    public static func record(for request: DistillRequest, response: DistillResponse, defaultProvider: String = "unknown") -> DistillSavingsRecord? {
        guard request.recordSavings == true else { return nil }
        let provider = request.provider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? defaultProvider

        switch request.mode {
        case .commandOutput:
            // Honest token accounting: the raw command output is replaced by the
            // distilled output before it ever reaches the provider, so savings =
            // estimate(raw input) - estimate(distilled output). The response
            // already carries those estimates from the scheduler.
            return DistillSavingsRecord(
                provider: provider,
                mode: "command-output",
                inputTokens: response.inputTokens,
                outputTokens: response.outputTokens,
                savedTokens: response.savedTokens
            )
        case .sr1Humanize:
            // The agent emitted the compressed SR1 response instead of the full
            // human-language answer; savings = estimate(human text the agent
            // avoided) - estimate(SR1 text it actually produced).
            let sr1 = sr1ResponseSource(from: request.input)
            let input = TokenEstimator.estimate(response.output)
            let output = TokenEstimator.estimate(sr1)
            return DistillSavingsRecord(
                provider: provider,
                mode: "sr1-humanize",
                inputTokens: input,
                outputTokens: output,
                savedTokens: max(input - output, 0)
            )
        case .longText, .watchSummary:
            return DistillSavingsRecord(
                provider: provider,
                mode: request.mode.rawValue,
                inputTokens: response.inputTokens,
                outputTokens: response.outputTokens,
                savedTokens: response.savedTokens
            )
        }
    }

    private static func sr1ResponseSource(from input: String) -> String {
        let marker = "SR1_RESPONSE:"
        guard let range = input.range(of: marker) else {
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return input[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DistillError: Error, Sendable, Equatable {
    case emptyInput
    case queueFull
    case invalidOutput
}

public protocol DistillRuntime: Sendable {
    func distill(_ request: DistillRequest) async throws -> String

    /// Called by the scheduler when no requests remain in flight. Runtimes that hold
    /// a GPU buffer cache (MLX) return it to the OS here so a long-lived warm server
    /// idles near its model's resident size instead of accumulating across requests.
    func reclaimIdleMemory()
}

public extension DistillRuntime {
    /// Runtimes without a reclaimable cache (deterministic/local) need do nothing.
    func reclaimIdleMemory() {}
}

private enum SR1LineParser {
    private static let semanticPrefixes = Set("SCDRONP")
    private static let variableKeyPattern = #"#[A-Za-z][0-9]+"#

    static func parseSemanticLine(_ line: String) -> (prefix: Character, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first?.uppercased().first,
              semanticPrefixes.contains(first) else {
            return nil
        }

        let rest = trimmed.dropFirst()
        guard let delimiter = rest.first else { return nil }

        let content: String
        if delimiter == ":" || delimiter == "=" {
            content = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        } else if delimiter == " " || delimiter == "\t" {
            content = rest.trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        guard !content.isEmpty else { return nil }
        return (first, content)
    }

    static func parseSemanticSegments(_ text: String) -> [(prefix: Character, content: String)] {
        text
            .split(whereSeparator: \.isNewline)
            .flatMap { parseSemanticSegmentsInLine(String($0)) }
    }

    static func expandVariables(in text: String, from source: String) -> String {
        let aliases = extractVariableAliases(source)
        guard !aliases.isEmpty else { return text }

        var expanded = text
        for (key, value) in aliases.sorted(by: { $0.key.count > $1.key.count }) {
            expanded = replacingWholeVariableKey(key, with: value, in: expanded)
        }
        return expanded
    }

    private static func parseSemanticSegmentsInLine(_ rawLine: String) -> [(prefix: Character, content: String)] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }
        let markerRanges = semanticMarkerRanges(in: line)
        guard markerRanges.count >= 2 else {
            return parseSemanticLine(line).map { [$0] } ?? []
        }

        var segments: [(prefix: Character, content: String)] = []
        for index in markerRanges.indices {
            let marker = markerRanges[index]
            let contentStart = line.index(after: marker.range.lowerBound)
            let delimiter = line[contentStart]
            let segmentStart = (delimiter == ":" || delimiter == "=")
                ? line.index(after: contentStart)
                : contentStart
            let segmentEnd = index + 1 < markerRanges.count
                ? markerRanges[index + 1].range.lowerBound
                : line.endIndex
            let content = line[segmentStart..<segmentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !content.isEmpty {
                segments.append((marker.prefix, content))
            }
        }
        return segments
    }

    private static func semanticMarkerRanges(in line: String) -> [(prefix: Character, range: Range<String.Index>)] {
        var result: [(Character, Range<String.Index>)] = []
        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            defer { index = next }
            let prefix = line[index].uppercased().first ?? "\0"
            guard semanticPrefixes.contains(prefix),
                  next < line.endIndex,
                  isSemanticDelimiter(line[next]),
                  isSemanticBoundary(before: index, in: line) else {
                continue
            }
            result.append((prefix, index..<next))
        }
        return result
    }

    private static func isSemanticDelimiter(_ character: Character) -> Bool {
        character == ":" || character == "=" || character == " " || character == "\t"
    }

    private static func isSemanticBoundary(before index: String.Index, in line: String) -> Bool {
        if index == line.startIndex { return true }
        var cursor = line.index(before: index)
        while cursor > line.startIndex, line[cursor].isWhitespace {
            cursor = line.index(before: cursor)
        }
        let previous = line[cursor]
        return previous == "." || previous == ";" || previous == "!" || previous == "?"
    }

    private static func extractVariableAliases(_ text: String) -> [String: String] {
        var aliases: [String: String] = [:]
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            for (key, value) in keyValueAliases(in: line) {
                aliases[key] = value
            }
            for (key, value) in valueKeyAliases(in: line) {
                aliases[key] = value
            }
        }
        return aliases
    }

    private static func keyValueAliases(in line: String) -> [(String, String)] {
        let pattern = #"(#[A-Za-z][0-9]+)\s*=\s*([^;\n]+?)(?=(?:\s+#[A-Za-z][0-9]+\s*=)|$)"#
        return regexMatches(pattern: pattern, in: line).compactMap { result in
            guard result.numberOfRanges >= 3,
                  let keyRange = Range(result.range(at: 1), in: line),
                  let valueRange = Range(result.range(at: 2), in: line),
                  let value = cleanedVariableValue(String(line[valueRange])) else {
                return nil
            }
            return (String(line[keyRange]), value)
        }
    }

    private static func valueKeyAliases(in line: String) -> [(String, String)] {
        let pattern = #"(^|[.;]\s+)([^#=;\n]{2,100}?)\s*=\s*(#[A-Za-z][0-9]+)(?=\s|[.;,]|$)"#
        return regexMatches(pattern: pattern, in: line).compactMap { result in
            guard result.numberOfRanges >= 4,
                  let valueRange = Range(result.range(at: 2), in: line),
                  let keyRange = Range(result.range(at: 3), in: line),
                  let value = cleanedVariableValue(String(line[valueRange])) else {
                return nil
            }
            return (String(line[keyRange]), value)
        }
    }

    private static func cleanedVariableValue(_ raw: String) -> String? {
        var value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.localizedCaseInsensitiveContains("dict:") ||
            value.range(of: #"\b[ScdronpSCDRONP]\s*=\s*[A-Za-z-]+"#, options: .regularExpression) != nil {
            return nil
        }
        let segments = parseSemanticSegments(value)
        if segments.count == 1 {
            value = segments[0].content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        }
        guard !value.isEmpty,
              value.range(of: variableKeyPattern, options: .regularExpression) == nil else {
            return nil
        }
        return value
    }

    private static func replacingWholeVariableKey(_ key: String, with value: String, in text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: key) + #"(?![A-Za-z0-9_])"#
        var output = text
        for result in regexMatches(pattern: pattern, in: output).reversed() {
            guard let range = Range(result.range, in: output) else { continue }
            output.replaceSubrange(range, with: value)
        }
        return output
    }

    private static func regexMatches(pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
}

public actor DistillScheduler {
    private let runtime: any DistillRuntime
    private let maxConcurrentRequests: Int
    private let maxQueueDepth: Int
    private var activeRequests = 0
    private var waiters: [CheckedContinuation<Void, Error>] = []

    public init(runtime: any DistillRuntime, maxConcurrentRequests: Int = 8, maxQueueDepth: Int = 0) {
        self.runtime = runtime
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maxQueueDepth = max(0, maxQueueDepth)
    }

    public var activeRequestCount: Int {
        activeRequests
    }

    public var queuedRequestCount: Int {
        waiters.count
    }

    public func submit(_ request: DistillRequest) async throws -> DistillResponse {
        let trimmed = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DistillError.emptyInput }

        try await acquireSlot()
        defer { releaseSlot() }

        let raw = try await runtime.distill(request)
        let output = String(raw.prefix(request.maxOutputCharacters))
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DistillError.invalidOutput
        }
        return DistillResponse(
            requestID: request.id,
            output: output,
            inputCharacters: request.input.count,
            inputTokens: TokenEstimator.estimate(request.input),
            outputTokens: TokenEstimator.estimate(output)
        )
    }

    private func acquireSlot() async throws {
        if activeRequests < maxConcurrentRequests {
            activeRequests += 1
            return
        }
        guard waiters.count < maxQueueDepth else {
            throw DistillError.queueFull
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        guard !waiters.isEmpty else {
            activeRequests -= 1
            // Drained to idle: hand the runtime a chance to return cached GPU memory
            // to the OS. Skipped while requests are still queued/in flight so the
            // cache stays warm during bursts (distill runs back-to-back constantly).
            if activeRequests == 0 {
                runtime.reclaimIdleMemory()
            }
            return
        }
        waiters.removeFirst().resume()
    }
}

public struct LocalDistillRuntime: DistillRuntime {
    public init() {}

    public func distill(_ request: DistillRequest) async throws -> String {
        if request.mode == .commandOutput {
            return Self.commandOutputFallback(
                input: request.input,
                question: request.question,
                maxOutputCharacters: request.maxOutputCharacters
            )
        }
        let lines = request.input
            .split(whereSeparator: \.isNewline)
            .prefix(12)
            .map(String.init)
        let prefix: String
        switch request.mode {
        case .commandOutput:
            prefix = "O"
        case .longText:
            prefix = "S"
        case .watchSummary:
            prefix = "D"
        case .sr1Humanize:
            return Self.humanizeSR1Fallback(request.input, maxOutputCharacters: request.maxOutputCharacters)
        }
        return lines.isEmpty ? "\(prefix) no content" : lines.map { "\(prefix) \($0)" }.joined(separator: "\n")
    }

    static func commandOutputFallback(input: String, question explicitQuestion: String?, maxOutputCharacters: Int) -> String {
        let parsed = splitLegacyCommandPayload(input)
        let question = (explicitQuestion?.nilIfEmpty ?? parsed.question ?? "Compress command output. Return only the useful signal.")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = parsed.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerQuestion = question.lowercased()
        guard !source.isEmpty else {
            if lowerQuestion.contains("none") { return "NONE" }
            return "distill: Insufficient information to output anything."
        }

        let sourceLines = source
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let output: String
        if lowerQuestion.contains("cwd=") && lowerQuestion.contains("files=") {
            let cwd = sourceLines.first ?? source
            let files = sourceLines.dropFirst()
            output = "CWD=\(cwd); FILES=\(files.isEmpty ? "EMPTY" : files.joined(separator: ", "))"
        } else if lowerQuestion.contains("cwd") && lowerQuestion.contains("only") {
            output = sourceLines.first ?? source
        } else if lowerQuestion.contains("filename") || lowerQuestion.contains("file path") || lowerQuestion.contains("paths only") || lowerQuestion.contains("keep paths only") {
            var pathLines = sourceLines
            if lowerQuestion.contains("html") && lowerQuestion.contains("file") {
                pathLines = pathLines.filter { $0.lowercased().contains(".html") }
            }
            output = pathLines.isEmpty ? "NONE" : pathLines.joined(separator: "\n")
        } else if lowerQuestion.contains("exists") && lowerQuestion.contains("missing") {
            output = source.lowercased().contains("code=0") || source.lowercased().contains("exists_code=0") ? "EXISTS" : "MISSING"
        } else if lowerQuestion.contains("pass") || lowerQuestion.contains("fail") {
            output = passFailSummary(source: source, sourceLines: sourceLines, lowerQuestion: lowerQuestion)
        } else if lowerQuestion.contains("status code") {
            output = httpStatusSummary(sourceLines: sourceLines)
        } else if lowerQuestion.contains("json") {
            output = firstLikelyJSON(from: source) ?? "distill: Insufficient information to output anything."
        } else if sourceLines.count <= 12 {
            output = sourceLines.joined(separator: "\n")
        } else {
            let head = sourceLines.prefix(6)
            let tail = sourceLines.suffix(4)
            output = (head + ["... \(sourceLines.count - 10) lines omitted ..."] + tail).joined(separator: "\n")
        }

        return String(output.prefix(maxOutputCharacters))
    }

    private static func splitLegacyCommandPayload(_ input: String) -> (question: String?, output: String) {
        guard let promptRange = input.range(of: "PROMPT:\n"),
              let inputRange = input.range(of: "\n\nINPUT:\n"),
              promptRange.upperBound <= inputRange.lowerBound else {
            return (nil, input)
        }
        let question = String(input[promptRange.upperBound..<inputRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let output = String(input[inputRange.upperBound...])
        return (question, output)
    }

    private static func passFailSummary(source: String, sourceLines: [String], lowerQuestion: String) -> String {
        let lowerSource = source.lowercased()
        let badLines = sourceLines.filter { line in
            let lowerLine = line.lowercased()
            if lowerLine.contains("0 failures") || lowerLine.contains("no failures") {
                return false
            }
            return lowerLine.contains("fail") ||
                lowerLine.contains("failed") ||
                lowerLine.contains("error") ||
                lowerLine.contains("crashloop") ||
                lowerLine.contains("nonzero") ||
                lowerLine.contains("exit 1")
        }
        if !badLines.isEmpty {
            return "FAIL " + badLines.prefix(3).joined(separator: "; ")
        }
        if lowerSource.contains("http/1.1 200") || lowerSource.contains("http/2 200") || lowerSource.contains(" 200 ") {
            return "PASS HTTP 200"
        }
        if lowerSource.contains("passed") || lowerSource.contains("pass") || lowerSource.contains("0 failures") || lowerSource.contains("exit 0") || lowerSource.contains("exists_code=0") {
            return "PASS"
        }
        if lowerQuestion.contains("if code 0") {
            return lowerSource.contains("code=0") || lowerSource.contains("exists_code=0") ? "EXISTS" : "MISSING"
        }
        return "distill: Insufficient information to output anything."
    }

    private static func httpStatusSummary(sourceLines: [String]) -> String {
        let status = sourceLines.first { $0.lowercased().hasPrefix("http/") } ?? "HTTP status missing"
        let contentType = sourceLines.first { $0.lowercased().hasPrefix("content-type:") } ?? "content-type missing"
        let verdict = status.contains(" 200") ? "PASS" : "FAIL"
        return "\(verdict) \(status); \(contentType)"
    }

    private static func firstLikelyJSON(from source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
        return trimmed
    }

    static func humanizeSR1Fallback(_ input: String, maxOutputCharacters: Int) -> String {
        let portuguese = input.localizedCaseInsensitiveContains("portuguese") ||
            input.localizedCaseInsensitiveContains("português")
        let source = input.components(separatedBy: "SR1_RESPONSE:").last ?? input
        let labels: [Character: String] = portuguese
            ? ["S": "Estado", "C": "Contexto", "D": "Acao", "R": "Risco", "O": "Resultado", "N": "Nao fazer", "P": "Prova"]
            : ["S": "State", "C": "Context", "D": "Action", "R": "Risk", "O": "Outcome", "N": "Do not do", "P": "Proof"]
        let lines = source
            .split(whereSeparator: \.isNewline)
            .flatMap { raw -> [String] in
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return [] }
                let lower = line.lowercased()
                guard lower != "sr1",
                      lower != "dict",
                      lower != "dict:",
                      !lower.hasPrefix("s=state"),
                      !lower.hasPrefix("c=context"),
                      !lower.hasPrefix("d=action"),
                      !lower.hasPrefix("r=risk"),
                      !lower.hasPrefix("o=outcome"),
                      !lower.hasPrefix("n=no-go"),
                      !lower.hasPrefix("p=proof") else {
                    return []
                }
                let segments = SR1LineParser.parseSemanticSegments(line)
                guard !segments.isEmpty else {
                    return [line]
                }
                return segments.map { parsed in
                    guard let label = labels[parsed.prefix] else { return parsed.content }
                    return "\(label): \(parsed.content)"
                }
            }
        let output = lines.isEmpty
            ? (portuguese ? "Nao consegui expandir a resposta comprimida." : "I could not expand the compressed response.")
            : lines.joined(separator: "\n")
        let expanded = SR1LineParser.expandVariables(in: output, from: source)
        return String(expanded.prefix(maxOutputCharacters))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

public struct MLXDistillRuntime: DistillRuntime {
    private let modelContainer: ModelContainer

    /// Upper bound on MLX's reusable Metal buffer cache. By default the cache limit
    /// equals the memory limit (~1.5× the device working set — many GB), so a
    /// long-lived server hoards reusable buffers and never returns them: a ~1GB model
    /// was observed growing past 20GB RSS. A small warm cache keeps recurrent requests
    /// fast while capping steady-state growth; `reclaimIdleMemory()` empties even this
    /// between bursts. 128 MB is comfortably above one distill generation's working set.
    static let gpuCacheLimitBytes = 128 * 1024 * 1024
    /// Hard ceiling on total MLX allocation. Never reached in normal use (a distill run
    /// needs ~1–2GB); it only throttles a pathological concurrent burst instead of letting
    /// the process blow past it on a 16GB machine. malloc waits on scheduled work when hit.
    static let gpuMemoryLimitBytes = 6 * 1024 * 1024 * 1024

    public init(modelDirectory: URL) async throws {
        MLX.Memory.memoryLimit = Self.gpuMemoryLimitBytes
        MLX.Memory.cacheLimit = Self.gpuCacheLimitBytes
        NSLog("RemoteCodeDistillService MLX memory bounded: cacheLimit=\(Self.gpuCacheLimitBytes / 1_048_576)MB memoryLimit=\(Self.gpuMemoryLimitBytes / 1_048_576)MB")
        self.modelContainer = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
    }

    /// Return the bounded GPU buffer cache to the OS once the server drains to idle.
    public func reclaimIdleMemory() {
        MLX.Memory.clearCache()
    }

    public func distill(_ request: DistillRequest) async throws -> String {
        if let deterministic = Self.deterministicCommandOutput(for: request) {
            return deterministic
        }

        let parameters = GenerateParameters(
            maxTokens: Self.maxTokens(for: request),
            temperature: 0,
            topP: 0.9,
            topK: 20
        )
        let session = ChatSession(
            modelContainer,
            instructions: Self.systemInstructions(for: request.mode),
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false]
        )
        let raw = try await session.respond(to: Self.prompt(for: request))
        let output = Self.cleanOutput(raw)
        let normalizedOutput = request.mode == .commandOutput
            ? Self.collapseDuplicatedCommandOutput(output)
            : output
        guard Self.isUsefulOutput(normalizedOutput, mode: request.mode) else {
            return Self.fallbackOutput(for: request)
        }
        return normalizedOutput
    }

    static func deterministicCommandOutput(for request: DistillRequest) -> String? {
        guard request.mode == .commandOutput else { return nil }
        let contract = (request.question?.nilIfEmpty ?? request.input).lowercased()
        let asksForCwdAndFiles = contract.contains("cwd=") && contract.contains("files=")
        let asksForCwdOnly = contract.contains("cwd") && contract.contains("only")
        let asksForTokenVerdict = (contract.contains("pass") || contract.contains("fail")) && contract.contains("only")
        let asksForPathsOnly = contract.contains("filename") ||
            contract.contains("file path") ||
            contract.contains("paths only") ||
            contract.contains("keep paths only")
        let asksForRawJSON = contract.contains("json") && contract.contains("only")
        guard asksForCwdAndFiles || asksForCwdOnly || asksForTokenVerdict || asksForPathsOnly || asksForRawJSON else {
            return nil
        }
        return LocalDistillRuntime.commandOutputFallback(
            input: request.input,
            question: request.question,
            maxOutputCharacters: request.maxOutputCharacters
        )
    }

    private static func systemInstructions(for mode: DistillMode) -> String {
        switch mode {
        case .sr1Humanize:
            return """
            You translate /distill output into human language for a software engineer.
            /distill output is compressed Military English + AR-0/AR-1 for prompts, task specs, commands, or agent instructions.
            It may contain Dict/Dict+, dynamic inline variables, and fixed prefixes S, C, D, R, O, N, P.
            Prefix meanings are usually S=state/status, C=cause/context, D=action/decision, R=risk/blocker, O=outcome/output, N=constraint/no-go, P=pass criteria/proof.
            Expand aliases from Dict and Dict+ when present. Keep aliases unchanged when no definition is present.
            Preserve constraints, pass criteria, required output, blockers, uncertainty, file names, paths, commands, environment variables, IDs, security warnings, and production/data-loss warnings.
            Do not invent missing facts. Do not claim execution happened unless the input says it happened.
            Write concise natural language in the requested language or locale.
            Return only the translation. No preamble. No markdown.
            """
        case .commandOutput, .longText, .watchSummary:
            return """
            You compress shell or command output for another model that will act on your answer.
            Output ONLY the requested format. No preamble. No "Here is". No explanation unless the question asks for one.
            If the question asks for JSON, return raw JSON only, no fences.
            If the question asks for a list, one item per line, no bullets, no numbering.
            If the question asks PASS/FAIL/SAFE/REVIEW/UNSAFE, output that token first on the same line, then the supporting detail.
            Match the language of the question.
            Never invent data not present in the output. If a field is missing, omit it or say so explicitly.
            If the output is insufficient, reply only with "distill: Insufficient information to output anything." in the language of the question.
            If the source is already shorter than your answer would be, reuse the source wording.
            Keep prose answers to one sentence, max three short lines. Structured answers may be longer when the format requires it.
            Never ask for more input.
            """
        }
    }

    private static func prompt(for request: DistillRequest) -> String {
        switch request.mode {
        case .commandOutput:
            let question = request.question?.nilIfEmpty ?? "Compress the command output. Return only the useful signal."
            return """
            /no_think
            Command output:
            \(fitInput(request.input))

            Question: \(question)
            """
        case .longText:
            return """
            /no_think
            Command output:
            \(fitInput(request.input))

            Question: Compress this long text. Return only the useful signal.
            """
        case .watchSummary:
            return """
            /no_think
            Command output:
            \(fitInput(request.input))

            Question: Summarize the relevant change. Return only the useful signal.
            """
        case .sr1Humanize:
            return """
            /no_think
            Rewrite the SR1_RESPONSE into natural language for the user.
            Use TARGET_LANGUAGE.
            Output at most \(request.maxOutputCharacters) characters.
            Output only the final user-facing answer.
            Preserve exact commands, paths, IDs, errors, numbers, statuses, and proof.
            Do not output markdown unless the answer needs a short list.
            Do not output SR1 prefixes, prefix dictionaries, XML tags, or instructions.

            \(request.input)

            OUTPUT:
            """
        }
    }

    private static func maxTokens(for request: DistillRequest) -> Int {
        min(512, max(32, request.maxOutputCharacters / 4))
    }

    private static func fitInput(_ input: String, maxCharacters: Int = 24_000) -> String {
        guard input.count > maxCharacters else { return input }
        let half = max(0, maxCharacters / 2 - 50)
        let head = input.prefix(half)
        let tail = input.suffix(half)
        let dropped = input.count - head.count - tail.count
        return "\(head)\n...\n[\(dropped) chars truncated] ...\n\(tail)"
    }

    static func cleanOutput(_ output: String) -> String {
        var cleaned = output
        while let start = cleaned.range(of: "<think>", options: .caseInsensitive),
              let end = cleaned.range(
                of: "</think>",
                options: .caseInsensitive,
                range: start.upperBound..<cleaned.endIndex
              ) {
            cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        }
        cleaned = cleaned.replacingOccurrences(of: "<think>", with: "", options: .caseInsensitive)
        cleaned = cleaned.replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
        return cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func isUsefulOutput(_ output: String, mode: DistillMode) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return false }

        let lowercased = trimmed.lowercased()
        guard !lowercased.contains("<think>"),
              !lowercased.contains("dict:"),
              !lowercased.contains("s=state"),
              !lowercased.contains("d distill"),
              !lowercased.hasPrefix("prompt:"),
              !lowercased.hasPrefix("input:"),
              !lowercased.contains("\nprompt:"),
              !lowercased.contains("\ninput:") else {
            return false
        }
        if mode == .sr1Humanize, Self.isLikelySR1(trimmed) {
            return false
        }

        let meaningfulCharacters = trimmed.filter { character in
            character.isLetter || character.isNumber
        }
        return meaningfulCharacters.count > 1
    }

    static func collapseDuplicatedCommandOutput(_ output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, lines.count.isMultiple(of: 2) else {
            return output
        }
        let midpoint = lines.count / 2
        let first = Array(lines[..<midpoint])
        let second = Array(lines[midpoint...])
        guard first == second else { return output }
        return first.joined(separator: "\n")
    }

    static func isUsefulDistillOutput(_ output: String) -> Bool {
        isUsefulOutput(output, mode: .longText)
    }

    static func fallbackOutput(for request: DistillRequest) -> String {
        let prefix: String
        switch request.mode {
        case .commandOutput:
            return LocalDistillRuntime.commandOutputFallback(
                input: request.input,
                question: request.question,
                maxOutputCharacters: request.maxOutputCharacters
            )
        case .longText:
            prefix = "S"
        case .watchSummary:
            prefix = "D"
        case .sr1Humanize:
            return LocalDistillRuntime.humanizeSR1Fallback(request.input, maxOutputCharacters: request.maxOutputCharacters)
        }

        let lines = request.input
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { "\(prefix) \($0)" }

        let output = lines.isEmpty ? "\(prefix) no content" : lines.joined(separator: "\n")
        return String(output.prefix(request.maxOutputCharacters))
    }

    private static func isLikelySR1(_ output: String) -> Bool {
        var semanticLines = 0
        var prefixes = Set<Character>()
        for raw in output.split(whereSeparator: \.isNewline).prefix(12) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let segments = SR1LineParser.parseSemanticSegments(line)
            if segments.count >= 2 {
                return true
            }
            if let parsed = segments.first {
                semanticLines += 1
                prefixes.insert(parsed.prefix)
            }
        }
        if semanticLines == 1, let prefix = prefixes.first, prefix != "O" {
            return true
        }
        return semanticLines >= 2 && prefixes.count >= 2
    }
}
