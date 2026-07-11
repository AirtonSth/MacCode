import Foundation
import CoreModel

/// Stable row order for Remote Code Pet Atlas v1.
///
/// Do not reorder cases without shipping a new atlas schema version. The raw value is
/// also the manifest key used by the renderer and settings diagnostics.
public enum PetAnimationState: String, CaseIterable, Codable, Sendable, Equatable {
    case idle
    case listening
    case thinking
    case coding
    case editing
    case terminal
    case search
    case gitReview
    case success
    case approval
    case question
    case waiting
    case failed
    case interrupted
    case reconnecting
    case sleeping

    /// Maps provider item types into the atlas vocabulary. `nil` is a deliberate
    /// noise decision, not an unknown mapping.
    public static func state(for itemType: AssistantItemType) -> PetAnimationState? {
        switch itemType {
        case .reasoning, .plan, .contextCompaction:
            return .thinking
        case .tool, .mcpToolCall, .dynamicToolCall, .collabToolCall:
            return .coding
        case .commandExecution:
            return .terminal
        case .fileChange:
            return .editing
        case .webSearch:
            return .search
        case .imageView, .review:
            return .gitReview
        case .error:
            return .failed
        case .assistantMessage:
            return nil
        }
    }

    /// Semantic precedence. Values are intentionally sparse so later adapters can
    /// add local detail without changing the ordering contract.
    private var priority: Int {
        switch self {
        case .idle: return 0
        case .sleeping: return 100
        case .waiting: return 200
        case .reconnecting: return 300
        case .coding: return 400
        case .thinking: return 500
        case .listening: return 600
        case .editing: return 610
        case .terminal: return 620
        case .search: return 630
        case .gitReview: return 640
        case .interrupted: return 700
        case .success: return 800
        case .failed: return 900
        case .question: return 1_000
        case .approval: return 1_010
        }
    }

    public static func highestPriority(in states: [PetAnimationState]) -> PetAnimationState? {
        states.max { lhs, rhs in lhs.priority < rhs.priority }
    }
}
