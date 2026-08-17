import Foundation

/// Post-MLX adopt: useful-output check, then N5 fail-open. This is what Grok
/// actually receives after a tool-output distill. Tests must drive this, not a
/// reimplementation.
public enum DistillAdopt {
    public static func servedOutput(modelOutput: String, request: DistillRequest) -> String {
        let cleaned = MLXDistillRuntime.cleanOutput(modelOutput)
        let normalized = request.mode == .commandOutput
            ? MLXDistillRuntime.collapseDuplicatedCommandOutput(cleaned)
            : cleaned
        guard MLXDistillRuntime.isUsefulOutput(normalized, mode: request.mode) else {
            return MLXDistillRuntime.fallbackOutput(for: request)
        }
        return MLXDistillRuntime.guardLossyProseOutput(normalized, request: request)
    }
}

/// The instruction + user-prompt strings the local distill model sees.
/// `MLXDistillRuntime` is the only caller; tests pin these so a silent revert
/// of the compression prompt is a failing test.
public enum DistillPrompt {
    public static func systemInstructions(for mode: DistillMode) -> String {
        switch mode {
        case .wireEncode:
            return """
            Compress a software task in any human language into a compact English semantic brief for another AI agent.
            Preserve negation, modality, ordering, conditions, commands, paths, URLs, IDs, hashes, numbers, units, errors, quotes, code, approvals, security warnings, and data-loss warnings verbatim.
            Drop repetition, filler, hedging, and politeness. Never invent facts, aliases, tags, or a transport grammar.
            Output only the compact English brief. Swift owns the RC Wire framing.
            """
        case .wireRenderEnglish:
            return """
            Render valid RC Wire v1 response frames as concise fluent prose in the trusted target language supplied by the host (default English).
            Preserve every fact, negation, condition, command, path, URL, ID, hash, number, unit, error, quote, code span, approval, warning, outcome, evidence, risk, and question.
            Do not invent facts or claim work that the frames do not report.
            Return only the answer in that language. Never output RCW1 tags or explain the protocol.
            """
        case .naturalLanguage:
            return """
            Rewrite the supplied content as one concise natural-language English sentence.
            Preserve exact facts, names, numbers, statuses, paths, commands, and warnings.
            Return only the sentence.
            """
        case .commandOutput:
            return commandOutputSystemInstructions
        case .longText, .watchSummary:
            return longTextSystemInstructions
        }
    }

    /// Density marker tests assert is present so the Grok-corpus prompt rewrite cannot be unused.
    public static let densityMarker = "Target at most one third of the source length"

    public static let commandOutputSystemInstructions = """
    You compress tool or command output for another coding agent that will act next.
    Keep only the next-action signal: exit status, errors, failing tests, commands, paths, file:line, numbers, IDs, hashes, warnings, and negation. Copy those tokens exactly. Do not paraphrase them.
    Never drop a path, file:line, number, ID, hash, command, or error token that appears in the source.
    Drop only progress bars, repeated headers, identical consecutive lines (keep one copy plus the count), usage/help, HTML chrome, and politeness.
    Output ONLY the requested format. No preamble. No "Here is". No "OUTPUT:". No markdown fences. No explanation unless the question asks for one.
    If the question asks for JSON, return raw JSON only, no fences.
    If the question asks for a list, one item per line, no bullets, no numbering.
    If the question asks PASS/FAIL/SAFE/REVIEW/UNSAFE, output that token first on the same line, then the supporting detail.
    Match the language of the question.
    Never invent data not present in the output. If a field is missing, omit it or say so explicitly.
    If the output is insufficient, reply only with "distill: Insufficient information to output anything." in the language of the question.
    If the source is already shorter than your answer would be, reuse the source wording.
    \(densityMarker) whenever every pinned literal still fits.
    Never ask for more input.
    """

    public static let longTextSystemInstructions = """
    You compress long text into concise plain language for another AI model.
    Copy every command, file path, file:line, error string, number, ID, status, and proof exactly. Do not paraphrase them.
    Never drop a path, file:line, number, ID, hash, command, or error token that appears in the source.
    Drop filler, repetition, hedging, politeness, restated instructions, progress, and chrome.
    No preamble, no explanation, no markdown, no "OUTPUT:".
    If the source is already shorter than your answer would be, reuse the source wording.
    \(densityMarker) whenever every pinned literal still fits.
    """

    public static func userPrompt(for request: DistillRequest) -> String {
        switch request.mode {
        case .commandOutput:
            let rawQuestion = request.question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let question = rawQuestion.isEmpty
                ? "Compress the command output. Return only the useful signal."
                : rawQuestion
            return """
            /no_think
            Command output:
            \(MLXDistillRuntime.fitInput(request.input))

            Question: \(question)
            """
        case .longText:
            return """
            /no_think
            Compress the following into concise plain language.
            Copy exact commands, paths, file:line, errors, numbers, IDs, and status. Do not echo this instruction.

            \(MLXDistillRuntime.fitInput(request.input))
            """
        case .watchSummary:
            return """
            /no_think
            Summarize the relevant change in concise plain language.
            Copy exact commands, paths, file:line, errors, numbers, IDs. Do not echo this instruction.

            \(MLXDistillRuntime.fitInput(request.input))
            """
        case .wireEncode:
            return """
            /no_think
            Compress this user task, in any language, into one compact English semantic brief.
            Keep every protected literal and intent-critical condition verbatim.

            \(request.input)

            BRIEF:
            """
        case .wireRenderEnglish:
            let language = MLXDistillRuntime.wireRenderLanguageIdentifier(request.question)
            return """
            /no_think
            Render these RC Wire v1 response frames in BCP-47 language \(language).

            \(request.input)

            ANSWER:
            """
        case .naturalLanguage:
            return """
            /no_think
            Rewrite as one concise English sentence, preserving exact facts.

            \(request.input)

            SENTENCE:
            """
        }
    }
}
