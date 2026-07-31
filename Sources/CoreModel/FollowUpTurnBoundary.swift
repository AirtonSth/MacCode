import Foundation

/// Cross-provider contract for multi-turn follow-ups after session resume.
///
/// Grok ACP `session/load`, Claude resume, and Codex `thread/resume` may restore
/// provider context without re-executing tools. Historical timeline items must
/// never attach under a newer user message. Adapters enforce this at the source;
/// this helper documents and tests the shared product rule.
public enum FollowUpTurnBoundary {
    /// Timeline events that belong to a user-facing agent turn.
    public static func isUserFacingTimelineEvent(_ event: AssistantEvent) -> Bool {
        switch event {
        case .turnStarted,
             .itemStarted,
             .itemDelta,
             .itemState,
             .itemProgress,
             .itemCompleted,
             .turnCompleted,
             .activePlanUpdated,
             .proposedPlan:
            return true
        default:
            return false
        }
    }

    /// Whether a live follow-up may accept timeline events yet.
    ///
    /// Before the user turn is armed (`turnStarted` for the new prompt),
    /// adapters must not publish historical load/resume replay as live work.
    public static func mayAcceptTimelineEvent(
        userTurnArmed: Bool,
        event: AssistantEvent
    ) -> Bool {
        if userTurnArmed { return true }
        return !isUserFacingTimelineEvent(event)
    }
}
