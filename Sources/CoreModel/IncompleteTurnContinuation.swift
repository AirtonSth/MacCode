import Foundation

/// Why a just-finished full-access turn is treated as *incomplete* and may be
/// auto-nudged instead of left as a misleading green "completed".
///
/// Two causes share one scheduler budget but need different prompts and delays:
/// - `workflowHandoff`: agent stopped between multi-phase skill steps
///   (e.g. "Next: Phase 3 — Review") while the user task is still open.
/// - `backgroundAwait`: agent stopped while waiting on an external async job
///   (deploy/CI/recording) — see `BackgroundAwaitContinuation`.
public enum IncompleteTurnContinuationReason: String, Sendable, Equatable {
    case workflowHandoff
    case backgroundAwait
}

/// Host recovery for full-access turns that end before the *user task* is done.
///
/// Classifies the final assistant message, chooses a reason-specific prompt and
/// delay, and gates auto-nudge the same way as background-await (completed +
/// autonomous + bounded). Workflow handoffs are classified **before** background
/// waits so a misused `[[RC_AWAITING]]` on a phase boundary gets the workflow
/// prompt (not BashOutput / "background task may be finished").
public enum IncompleteTurnContinuation {
    /// Shared with `BackgroundAwaitContinuation` so mixed stalls on one thread
    /// cannot unbounded-loop. After exhaustion the UI still shows non-green
    /// "awaiting" from `classify` — never silent green "done".
    public static let maxAutoContinuations = BackgroundAwaitContinuation.maxAutoContinuations

    /// Near-immediate resume for phase handoffs (no external job to wait on).
    public static let workflowContinuationDelay: TimeInterval = 0

    /// Nudge when the agent stopped mid multi-phase skill (sam-work, etc.).
    public static let workflowContinuationPrompt = """
    Continue the multi-phase workflow from the next announced phase through completion of the original user task. Do not stop between phases. Do not emit \(BackgroundAwaitContinuation.awaitingMarker) for phase handoffs. Only stop when the full task is done, blocked on the user, or blocked on external background/async work (then use the background-await protocol).
    """

    /// Classify an incomplete turn. `nil` means a genuine terminal final (or
    /// nothing the host should auto-resume).
    ///
    /// Order is load-bearing: workflow handoff wins over the background marker so
    /// Phase-boundary misuse of `[[RC_AWAITING]]` is recovered with the workflow
    /// prompt (incident 4E3163DC Phase 1).
    public static func classify(_ finalMessage: String?) -> IncompleteTurnContinuationReason? {
        if IncompleteWorkflowContinuation.isIncompleteWorkflowHandoff(finalMessage) {
            return .workflowHandoff
        }
        if BackgroundAwaitContinuation.isAwaitingBackgroundWork(finalMessage) {
            return .backgroundAwait
        }
        return nil
    }

    public static func isIncompleteTurn(_ finalMessage: String?) -> Bool {
        classify(finalMessage) != nil
    }

    public static func prompt(for reason: IncompleteTurnContinuationReason) -> String {
        switch reason {
        case .workflowHandoff:
            return workflowContinuationPrompt
        case .backgroundAwait:
            return BackgroundAwaitContinuation.continuationPrompt
        }
    }

    /// Background waits keep the configurable job-poll delay; workflow handoffs
    /// resume immediately.
    public static func delay(
        for reason: IncompleteTurnContinuationReason,
        backgroundDelay: TimeInterval
    ) -> TimeInterval {
        switch reason {
        case .workflowHandoff:
            return workflowContinuationDelay
        case .backgroundAwait:
            return backgroundDelay
        }
    }

    /// Auto-nudge decision for a just-finished run. Returns the reason when a
    /// nudge should be scheduled; `nil` otherwise.
    public static func shouldAutoContinue(
        status: AgentRunStatus,
        finalMessage: String?,
        isAutonomous: Bool,
        priorAutoContinuations: Int,
        maxAutoContinuations: Int = maxAutoContinuations
    ) -> IncompleteTurnContinuationReason? {
        guard status == .completed, isAutonomous else { return nil }
        guard priorAutoContinuations < maxAutoContinuations else { return nil }
        return classify(finalMessage)
    }
}

/// High-precision detector for multi-phase skill handoffs that end a turn while
/// the overall task is still open (e.g. sam-work Phase 2 → "Next: Phase 3").
///
/// WHY free-text is a backstop only: agents paraphrase. Patterns are deliberately
/// tight (numbered phase transitions near the message tail) so optional roadmaps
/// and "next steps for you" do not auto-start another full-access run.
public enum IncompleteWorkflowContinuation {
    /// User-handoff / deferral language that must not auto-nudge even if a phase
    /// phrase appears (precision guard — same spirit as background-await user-waits).
    private static let userHandoffPhrases = [
        "if you want", "if you'd like", "if you would like",
        "when you're ready", "when you are ready",
        "on your end", "for you to", "let me know",
        "optional", "later if", "in a follow-up", "as a follow-up"
    ]

    /// Strong terminal transitions from the demonstrated incident family.
    /// Matched case-insensitively on the message tail. Deliberately does NOT
    /// match bare "PHASE N RESULT" (that appears on finished phase summaries
    /// without implying another host turn) — require an explicit next/proceeding
    /// transition.
    private static let handoffRegexes: [NSRegularExpression] = {
        let patterns = [
            #"proceeding to phase\s+\d+"#,
            #"\*{0,2}next:\s*phase\s+\d+"#,
            #"next phase\s*[:—\-]\s*\w+"#
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// True when the final message looks like a mid-workflow phase stop rather
    /// than a finished answer or a wait on the user.
    public static func isIncompleteWorkflowHandoff(_ finalMessage: String?) -> Bool {
        guard let raw = finalMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        // Prefer the tail: phase handoffs are announced at the end of the turn.
        let tail = String(raw.suffix(800))
        let lowered = tail.lowercased()
        if userHandoffPhrases.contains(where: { lowered.contains($0) }) {
            return false
        }
        // Explicit overall stop / blocked must not auto-continue.
        if lowered.contains("**blocked") || lowered.hasPrefix("blocked:") || lowered.contains("blocked: cannot") {
            return false
        }
        let ns = tail as NSString
        let range = NSRange(location: 0, length: ns.length)
        for regex in handoffRegexes {
            if regex.firstMatch(in: tail, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }
}
