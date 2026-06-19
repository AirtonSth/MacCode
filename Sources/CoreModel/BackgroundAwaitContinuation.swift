import Foundation

/// Detects when an autonomous agent run finished while the agent was still
/// *waiting on a background job it launched* — e.g. it ended its turn narrating
/// "Standing by for the demo recording to complete." — rather than because the
/// task was actually done, and decides whether the host should auto-nudge the
/// agent to resume.
///
/// WHY: a long full-access run can spawn a background process (a Playwright
/// recording, a build) and then END ITS TURN narrating that it is "awaiting" the
/// result. The provider SDK emits its terminal `result` → the run is marked
/// `.completed`, but the work is not finished and nothing ever wakes the agent
/// back up. The app has NO visibility into background shells (the provider SDK
/// manages them opaquely), so it cannot observe the job's true completion;
/// instead it re-invokes the agent with a bounded "check the background task and
/// continue" nudge, and the agent polls the job itself.
///
/// The detector is intentionally CONSERVATIVE: it requires an explicit
/// "awaiting / standing by" phrase AND a background-work noun, so a normal final
/// answer that merely mentions "background" (e.g. "I ran the tests in the
/// background earlier; all pass.") or that ends "standing by for your next
/// instruction." does not trip it. False positives only cost one bounded,
/// autonomous-only nudge; false negatives leave the run flagged for the user.
public enum BackgroundAwaitContinuation {
    /// Max consecutive auto-nudges per thread before the host stops and leaves the
    /// run flagged as awaiting for the user to drive manually. Bounds runaway token
    /// spend when the agent keeps standing by.
    public static let maxAutoContinuations = 5

    /// The nudge sent to re-invoke a stalled agent. Provider-agnostic and explicit
    /// about both branches (done vs still-running) so the agent does the right
    /// thing without re-launching duplicate work, and forbids another bare
    /// "standing by" stop.
    public static let continuationPrompt = """
    The background task you launched may now be finished. Check its output (for example with BashOutput on the background shell you started) and continue the original task to completion. If it is still running, wait briefly and check again. Do not stop until the task is actually done — do not just say you are standing by.
    """

    /// Phrases the agent uses to narrate that it is *waiting* on something.
    private static let awaitingPhrases = [
        "standing by", "stand by for", "awaiting", "await the", "waiting for", "waiting on"
    ]

    /// Nouns that mark the thing being waited on as a *background job* (not a user
    /// hand-off). Kept tight to the demonstrated background-work vocabulary to
    /// avoid tripping on normal final answers.
    private static let backgroundNouns = [
        "background", "completion notification", "demo recording", "the recording", "vite rebuild", "rebuild"
    ]

    /// True iff `finalMessage` reads like the agent stopped while waiting on a
    /// background job rather than because it finished the task.
    public static func isAwaitingBackgroundWork(_ finalMessage: String?) -> Bool {
        guard let lowered = finalMessage?.lowercased() else { return false }
        let text = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard awaitingPhrases.contains(where: { text.contains($0) }) else { return false }
        return backgroundNouns.contains(where: { text.contains($0) })
    }

    /// Whether the host should auto-nudge a just-finished run to resume.
    ///
    /// Only `.completed` autonomous (full-access) runs that trip the detector and
    /// are under the per-thread bound qualify — so supervised runs and runs that
    /// genuinely finished are never auto-nudged.
    public static func shouldAutoContinue(
        status: AgentRunStatus,
        finalMessage: String?,
        isAutonomous: Bool,
        priorAutoContinuations: Int,
        maxAutoContinuations: Int = maxAutoContinuations
    ) -> Bool {
        guard status == .completed, isAutonomous else { return false }
        guard priorAutoContinuations < maxAutoContinuations else { return false }
        return isAwaitingBackgroundWork(finalMessage)
    }
}
