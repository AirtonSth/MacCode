import Foundation

/// Why a just-finished full-access turn is treated as *incomplete* and may be
/// auto-nudged instead of left as a misleading green "completed".
///
/// Causes share one scheduler streak counter but use different max bounds,
/// prompts, and delays:
/// - `workflowHandoff`: agent stopped between multi-phase skill steps
///   (e.g. "Next: Phase 3 — Review") while the user task is still open.
/// - `uncalledToolInvocation`: turn ended by emitting raw tool-invocation
///   markup as plain text (tool unavailable / not actually invoked) — see
///   `AssistantToolMarkupSanitizer`.
/// - `backgroundAwait`: agent stopped while waiting on an external async job
///   (deploy/CI/recording) — see `BackgroundAwaitContinuation`.
public enum IncompleteTurnContinuationReason: String, Sendable, Equatable {
    case workflowHandoff
    case uncalledToolInvocation
    case backgroundAwait
}

/// Host recovery for full-access turns that end before the *user task* is done.
///
/// Classifies the final assistant message, chooses a reason-specific prompt and
/// delay, and gates auto-nudge (completed + autonomous + bounded). Workflow
/// handoffs are classified **before** uncalled-tool and background waits so a
/// misused `[[RC_AWAITING]]` on a phase boundary gets the workflow prompt
/// (not BashOutput / re-invoke-tool).
public enum IncompleteTurnContinuation {
    /// Bound for multi-phase skill handoffs. sam-work has 8 phases; agents often
    /// stop once per phase, so 5 was too low and left mid-skill green "completed".
    public static let maxWorkflowAutoContinuations = 12

    /// Bound for true background-job stalls (unchanged — runaway standing-by).
    public static let maxBackgroundAutoContinuations = BackgroundAwaitContinuation.maxAutoContinuations

    /// Bound for turns that ended by emitting uncalled tool markup as text.
    /// Same tight budget as background stalls — re-emitting markup must not loop.
    public static let maxUncalledToolAutoContinuations = maxBackgroundAutoContinuations

    /// Back-compat alias used by UI/tests that only need "a bound exists".
    public static let maxAutoContinuations = maxWorkflowAutoContinuations

    /// Near-immediate resume for phase handoffs (no external job to wait on).
    /// Coordinator schedules only after the finishing run is removed from
    /// `activeThreads`, so zero delay is safe against the idle validity check.
    public static let workflowContinuationDelay: TimeInterval = 0

    /// Near-immediate resume when the prior turn only dumped tool markup — no
    /// external job to poll; the agent must try again with available tools.
    public static let uncalledToolContinuationDelay: TimeInterval = 0

    /// Nudge when the agent stopped mid multi-phase skill (sam-work, etc.).
    public static let workflowContinuationPrompt = """
    Continue the multi-phase workflow from the next announced phase through completion of the original user task. Do not stop between phases. Do not emit \(BackgroundAwaitContinuation.awaitingMarker) for phase handoffs. Only stop when the full task is done, blocked on the user, or blocked on external background/async work (then use the background-await protocol).
    """

    /// Nudge when the prior turn ended by printing a tool invocation as plain text
    /// instead of actually calling a tool (often because the tool was unavailable
    /// in a headless run). Forbids re-emitting markup.
    public static let uncalledToolContinuationPrompt = """
    Your previous turn ended by emitting a tool invocation as plain text rather than executing a real tool call (the tool may have been unavailable). Do not re-emit raw tool-invocation markup. Continue the original user task using the tools that are actually available, or complete the work without that tool if it cannot be invoked. Only stop when the task is done, blocked on the user, or blocked on external background/async work (then use the background-await protocol).
    """

    public static func maxAutoContinuations(for reason: IncompleteTurnContinuationReason) -> Int {
        switch reason {
        case .workflowHandoff: return maxWorkflowAutoContinuations
        case .uncalledToolInvocation: return maxUncalledToolAutoContinuations
        case .backgroundAwait: return maxBackgroundAutoContinuations
        }
    }

    /// Classify an incomplete turn. `nil` means a genuine terminal final (or
    /// nothing the host should auto-resume).
    ///
    /// Order is load-bearing: workflow handoff wins over uncalled-tool and the
    /// background marker so Phase-boundary misuse of `[[RC_AWAITING]]` is
    /// recovered with the workflow prompt (incident 4E3163DC Phase 1). Uncalled
    /// tool markup wins over background-await phrasing so a turn that only dumped
    /// an unexecuted tool gets the re-invoke-with-available-tools prompt.
    public static func classify(_ finalMessage: String?) -> IncompleteTurnContinuationReason? {
        if IncompleteWorkflowContinuation.isIncompleteWorkflowHandoff(finalMessage) {
            return .workflowHandoff
        }
        if let finalMessage, AssistantToolMarkupSanitizer.containsUncalledToolSignal(finalMessage) {
            return .uncalledToolInvocation
        }
        if BackgroundAwaitContinuation.isAwaitingBackgroundWork(finalMessage) {
            return .backgroundAwait
        }
        return nil
    }

    public static func isIncompleteTurn(_ finalMessage: String?) -> Bool {
        classify(finalMessage) != nil
    }

    /// True for the host-written nudges above. Those user rows are machine
    /// input, shown as a system line instead of a user bubble.
    public static func isSyntheticPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasons: [IncompleteTurnContinuationReason] = [.workflowHandoff, .uncalledToolInvocation, .backgroundAwait]
        return reasons.contains { prompt(for: $0).trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
    }

    public static func prompt(for reason: IncompleteTurnContinuationReason) -> String {
        switch reason {
        case .workflowHandoff:
            return workflowContinuationPrompt
        case .uncalledToolInvocation:
            return uncalledToolContinuationPrompt
        case .backgroundAwait:
            return BackgroundAwaitContinuation.continuationPrompt
        }
    }

    /// Background waits keep the configurable job-poll delay; workflow handoffs
    /// and uncalled-tool recoveries resume immediately (after terminal cleanup).
    public static func delay(
        for reason: IncompleteTurnContinuationReason,
        backgroundDelay: TimeInterval
    ) -> TimeInterval {
        switch reason {
        case .workflowHandoff:
            return workflowContinuationDelay
        case .uncalledToolInvocation:
            return uncalledToolContinuationDelay
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
        priorAutoContinuations: Int
    ) -> IncompleteTurnContinuationReason? {
        guard status == .completed, isAutonomous else { return nil }
        guard let reason = classify(finalMessage) else { return nil }
        guard priorAutoContinuations < maxAutoContinuations(for: reason) else { return nil }
        return reason
    }
}

/// High-precision detector for multi-phase skill handoffs that end a turn while
/// the overall task is still open (e.g. sam-work Phase 2 → "Next: Phase 3").
///
/// Patterns require a **numbered** phase transition on a recent line. Free-text
/// roadmaps, delegated "next phase: ops", and user-gated language are excluded.
public enum IncompleteWorkflowContinuation {
    /// User-handoff / deferral language that must not auto-nudge even if a phase
    /// phrase appears (precision guard — same spirit as background-await user-waits).
    private static let userHandoffPhrases = [
        "if you want", "if you'd like", "if you would like",
        "when you're ready", "when you are ready",
        "on your end", "for you to", "let me know",
        "optional", "later if", "in a follow-up", "as a follow-up",
        "belongs to", "on your side"
    ]

    /// Whole-task completion language that means the host should NOT auto-nudge
    /// even if a numbered "next phase" appears in a retrospective.
    private static let overallDonePhrases = [
        "all phases complete", "all phases completed",
        "workflow complete", "workflow completed",
        "original task is done", "original task is complete",
        "nothing left to do", "task is fully complete",
        "sam-work complete", "end-to-end complete"
    ]

    /// Numbered phase transitions only, line-anchored within the recent tail.
    private static let handoffRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(?m)^\s*\*{0,2}proceeding to phase\s+\d+"#,
            #"(?m)^\s*\*{0,2}next:\s*phase\s+\d+"#
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
        // Prefer recent lines: phase handoffs are announced at the end of the turn.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(8).joined(separator: "\n")
        let lowered = tail.lowercased()
        if userHandoffPhrases.contains(where: { lowered.contains($0) }) {
            return false
        }
        if overallDonePhrases.contains(where: { lowered.contains($0) }) {
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
