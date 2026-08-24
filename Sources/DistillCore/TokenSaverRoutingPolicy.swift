import Foundation

public enum TokenSaverRouteStage: String, Codable, Sendable, Equatable {
    case deterministic
    case encoderBERT = "encoder_bert"
    case llmMLX = "llm_mlx"
    case apiExternal = "api_external"
    case verbatim

    public var usesGenerativeModel: Bool {
        self == .llmMLX || self == .apiExternal
    }
}

public enum TokenSaverLaneDisposition: String, Codable, Sendable, Equatable {
    case migratableToDeterministic
    case migratableToBERT
    case genuinelyAbstractive
}

public enum TokenSaverLane: String, Codable, Sendable, Equatable, CaseIterable {
    case commandOutput
    case longText
    case watchSummary
    case wireEncode
    case wireRenderEnglish
    case naturalLanguage
    case followUpPrompt
    case toolOutputHook
}

public struct TokenSaverLaneInventory: Codable, Sendable, Equatable {
    public let lane: TokenSaverLane
    public let currentMLXMode: DistillMode?
    public let disposition: TokenSaverLaneDisposition
    public let justification: String
}

public struct TokenSaverRouteTelemetryEvent: Codable, Sendable, Equatable {
    public let lane: TokenSaverLane
    public let stage: TokenSaverRouteStage
    public let resolvedWithoutLLM: Bool
    public let wallClockMilliseconds: Int

    public init(
        lane: TokenSaverLane,
        stage: TokenSaverRouteStage,
        wallClockMilliseconds: Int
    ) {
        self.lane = lane
        self.stage = stage
        self.resolvedWithoutLLM = !stage.usesGenerativeModel
        self.wallClockMilliseconds = max(0, wallClockMilliseconds)
    }
}

public enum TokenSaverRoutingPolicy {
    public static let orderedStages: [TokenSaverRouteStage] = [
        .deterministic,
        .encoderBERT,
        .llmMLX
    ]

    public static let currentMLXInventory: [TokenSaverLaneInventory] = [
        TokenSaverLaneInventory(
            lane: .commandOutput,
            currentMLXMode: .commandOutput,
            disposition: .migratableToBERT,
            justification: "command output is extractive/classification-heavy; deterministic contracts or BERT scoring should own it"
        ),
        TokenSaverLaneInventory(
            lane: .longText,
            currentMLXMode: .longText,
            disposition: .migratableToBERT,
            justification: "long-text compression is keep/drop extraction once deterministic routers miss"
        ),
        TokenSaverLaneInventory(
            lane: .watchSummary,
            currentMLXMode: .watchSummary,
            disposition: .migratableToBERT,
            justification: "watch summaries are extractive change selection with literal preservation"
        ),
        TokenSaverLaneInventory(
            lane: .wireEncode,
            currentMLXMode: .wireEncode,
            disposition: .genuinelyAbstractive,
            justification: "wire encoding is semantic rewriting into a constrained transport frame"
        ),
        TokenSaverLaneInventory(
            lane: .wireRenderEnglish,
            currentMLXMode: .wireRenderEnglish,
            disposition: .genuinelyAbstractive,
            justification: "wire rendering is translation from a constrained transport frame"
        ),
        TokenSaverLaneInventory(
            lane: .naturalLanguage,
            currentMLXMode: .naturalLanguage,
            disposition: .genuinelyAbstractive,
            justification: "short user-facing summaries are abstractive natural-language generation"
        ),
        TokenSaverLaneInventory(
            lane: .followUpPrompt,
            currentMLXMode: .longText,
            disposition: .migratableToBERT,
            justification: "follow-up prompt compression is text pruning with literal preservation"
        ),
        TokenSaverLaneInventory(
            lane: .toolOutputHook,
            currentMLXMode: .commandOutput,
            disposition: .migratableToDeterministic,
            justification: "Bash/Grep hook output starts deterministic/extractive; WebFetch is the only abstract rewrite exception"
        )
    ]

    public static func stages(for lane: TokenSaverLane) -> [TokenSaverRouteStage] {
        switch lane {
        case .wireEncode, .wireRenderEnglish, .naturalLanguage:
            return orderedStages
        case .commandOutput, .longText, .watchSummary, .followUpPrompt, .toolOutputHook:
            return [.deterministic, .encoderBERT]
        }
    }

    public static func fallbackAfterEncoderFailure(for lane: TokenSaverLane) -> TokenSaverRouteStage {
        switch lane {
        case .wireEncode, .wireRenderEnglish, .naturalLanguage:
            return .deterministic
        case .commandOutput, .longText, .watchSummary, .followUpPrompt, .toolOutputHook:
            return .verbatim
        }
    }

    public static func permitsLLM(lane: TokenSaverLane, justification: String?) -> Bool {
        guard stages(for: lane).contains(.llmMLX),
              let justification = justification?.trimmingCharacters(in: .whitespacesAndNewlines),
              !justification.isEmpty else {
            return false
        }
        return lane == .wireEncode || lane == .wireRenderEnglish || lane == .naturalLanguage
            || justification.localizedCaseInsensitiveContains("abstractive")
    }
}
