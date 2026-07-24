import Foundation

/// The distill dialect's semantic line prefixes, defined in exactly ONE place.
///
/// WHY this constant exists: the seven characters used to be hand-copied into
/// every consumer — `SR1LineParser` (DistillCore), `SR1ResponseDetector`
/// (AgentRuntime), the inline check in `AgentRunCoordinator`'s streaming buffer
/// gate — plus two independently duplicated alias regexes. Those are not
/// documentation, they are live behaviour gates: they decide whether provider
/// text is held back, routed to humanization, and badged before a human reads
/// it. A partial edit therefore desyncs generation from detection in one of two
/// directions, both silent: a retired prefix stays recognized (spec drift), or a
/// live prefix stops being recognized and raw compressed text reaches the chat
/// UI untranslated. Deriving every consumer from here makes an uneven edit
/// impossible, which is the precondition for changing the dialect at all.
public enum DistillSemanticPrefixes {
    /// S=state, C=context, D=action, R=risk, O=outcome, N=no-go, P=proof.
    public static let characters = "SCDRONP"

    /// Uppercase set used by every parser after it uppercases the candidate.
    public static let set = Set(characters)

    /// Matches an inline `X=word` alias declaration for a semantic prefix, e.g.
    /// `S=state` or `p=proof`, used to reject dictionary declarations when
    /// harvesting variable aliases.
    ///
    /// NOTE: the historical character class is `ScdronpSCDRONP` — it omits
    /// lowercase `s`. That asymmetry is preserved verbatim on purpose: this
    /// change de-duplicates two identical copies, it does not fix behaviour.
    /// Widening the class to lowercase `s` would newly reject values such as
    /// `s=state`, which is a behaviour change that needs its own test and its
    /// own decision.
    public static let aliasDeclarationPattern = #"\b[ScdronpSCDRONP]\s*=\s*[A-Za-z-]+"#

    /// True when `character` is a semantic prefix, matching case-insensitively
    /// the way every call site does (uppercase, then membership test).
    public static func contains(_ character: Character) -> Bool {
        guard let upper = character.uppercased().first else { return false }
        return set.contains(upper)
    }
}
