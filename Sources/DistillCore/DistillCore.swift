import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

public enum DistillMode: String, Codable, Sendable, Equatable {
    case commandOutput
    case longText
    case watchSummary
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
    public let maxOutputCharacters: Int

    public init(
        id: UUID = UUID(),
        mode: DistillMode,
        priority: DistillPriority = .agent,
        input: String,
        maxOutputCharacters: Int = 4_000
    ) {
        self.id = id
        self.mode = mode
        self.priority = priority
        self.input = input
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

public enum DistillError: Error, Sendable, Equatable {
    case emptyInput
    case queueFull
    case invalidOutput
}

public protocol DistillRuntime: Sendable {
    func distill(_ request: DistillRequest) async throws -> String
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
            return
        }
        waiters.removeFirst().resume()
    }
}

public struct LocalDistillRuntime: DistillRuntime {
    public init() {}

    public func distill(_ request: DistillRequest) async throws -> String {
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
        }
        return lines.isEmpty ? "\(prefix) no content" : lines.map { "\(prefix) \($0)" }.joined(separator: "\n")
    }
}

public struct MLXDistillRuntime: DistillRuntime {
    private let modelContainer: ModelContainer

    public init(modelDirectory: URL) async throws {
        self.modelContainer = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
    }

    public func distill(_ request: DistillRequest) async throws -> String {
        let parameters = GenerateParameters(
            maxTokens: Self.maxTokens(for: request),
            temperature: 0,
            topP: 0.9,
            topK: 20
        )
        let session = ChatSession(
            modelContainer,
            instructions: Self.systemInstructions,
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false]
        )
        let raw = try await session.respond(to: Self.prompt(for: request))
        let output = Self.cleanOutput(raw)
        guard Self.isUsefulDistillOutput(output) else {
            return Self.fallbackOutput(for: request)
        }
        return output
    }

    private static let systemInstructions = """
    You are RemoteCode Token Saver.
    Compress meaning, not correctness.
    Return only /distill language.
    Do not use thinking tags or hidden reasoning.
    Start every line with one prefix letter: S, C, D, R, O, N, or P.
    Never define the prefixes.
    Use short command lines.
    Preserve exact commands, paths, IDs, errors, and pass criteria.
    Do not add prose, greetings, or markdown.
    """

    private static func prompt(for request: DistillRequest) -> String {
        let mode: String
        switch request.mode {
        case .commandOutput:
            mode = "command output"
        case .longText:
            mode = "long text"
        case .watchSummary:
            mode = "watch summary"
        }
        return """
        /no_think
        Compress the \(mode) input into /distill.
        Output at most \(request.maxOutputCharacters) characters.
        Output only the compressed result.
        Do not output markdown, XML tags, prefix definitions, or instructions.
        Each output line must begin with S, C, D, R, O, N, or P.
        Preserve exact commands, paths, IDs, errors, and pass criteria.

        INPUT:
        \(request.input)

        OUTPUT:
        """
    }

    private static func maxTokens(for request: DistillRequest) -> Int {
        min(512, max(32, request.maxOutputCharacters / 4))
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

    static func isUsefulDistillOutput(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return false }

        let lowercased = trimmed.lowercased()
        guard !lowercased.contains("<think>"),
              !lowercased.contains("s=state"),
              !lowercased.contains("d distill") else {
            return false
        }

        let meaningfulCharacters = trimmed.filter { character in
            character.isLetter || character.isNumber
        }
        return meaningfulCharacters.count > 1
    }

    static func fallbackOutput(for request: DistillRequest) -> String {
        let prefix: String
        switch request.mode {
        case .commandOutput:
            prefix = "O"
        case .longText:
            prefix = "S"
        case .watchSummary:
            prefix = "D"
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
}
