import CoreModel
import Foundation

/// Host-side decision for appending `| distill "<question>"` to a shell command.
///
/// This is **command rewrite**, not provider PostToolUse output rewrite.
/// Grok PreToolUse documents `updatedInput`; Claude PreToolUse uses the same
/// shape. Codex still relies on PATH wrappers (no `updatedInput` output rewrite).
///
/// Token Saver off must return `.skipNotAdmitted` so callers fail open.
public enum ShellDistillPipeAdmission: Sendable {
    public enum Decision: Equatable, Sendable {
        case skipNotAdmitted
        case skipNotShell
        case skipAlreadyPiped
        case skipExactOutput
        case skipGUI
        case skipNotWrapEligible
        case skipMissingDistill
        case pipe(rewritten: String)
    }

    /// Interactive / TUI basenames — never auto-pipe (they are not stdout reports).
    public static let guiCommands: Set<String> = [
        "vim", "nvim", "vi", "view", "less", "more", "most",
        "top", "htop", "btop", "nano", "pico", "emacs",
        "open", "code", "cursor", "xed", "man",
        "tig", "lazygit", "tmux", "screen",
    ]

    public static let defaultQuestion = CommandWrapPolicy.extractionQuery(forCommand: "git")
        ?? "Keep the lines most important for understanding this output, verbatim; preserve exact literals, identifiers, signatures, numbers, and code; drop only boilerplate and repetition."

    public static func isShellLikeTool(_ toolName: String) -> Bool {
        let normalized = toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        return ToolOutputCompressionPolicy.shellLikeNormalizedToolNames.contains(normalized)
    }

    public static func distillExecutablePath(
        processArguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        if let argv0 = processArguments.first,
           (argv0 as NSString).lastPathComponent == "distill",
           !argv0.isEmpty {
            return argv0
        }
        if let managed = environment["RC_REMOTE_CODE_MANAGED_BIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !managed.isEmpty {
            return (managed as NSString).appendingPathComponent("distill")
        }
        return (homeDirectory as NSString)
            .appendingPathComponent(".remote-code/bin/distill")
    }

    public static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func rewrittenCommand(
        _ command: String,
        distillExecutable: String,
        question: String = defaultQuestion
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
            + " | "
            + posixSingleQuoted(distillExecutable)
            + " "
            + posixSingleQuoted(question)
    }

    /// Classify a provider shell tool invocation.
    ///
    /// `distillExecutable` must be an existing binary when `admitted` is true;
    /// missing binary fails open so we never rewrite to a broken pipe.
    public static func decide(
        admitted: Bool,
        toolName: String,
        command: String,
        distillExecutable: String?,
        distillExists: Bool,
        question: String = defaultQuestion
    ) -> Decision {
        guard admitted else { return .skipNotAdmitted }
        guard isShellLikeTool(toolName) else { return .skipNotShell }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skipNotWrapEligible }
        if ToolOutputCompressionPolicy.lastPipelineCommandIsVoluntaryDistill(trimmed) {
            return .skipAlreadyPiped
        }
        guard let invocation = ToolOutputCompressionPolicy.lastInvocation(trimmed) else {
            return .skipNotWrapEligible
        }
        if guiCommands.contains(invocation.name) {
            return .skipGUI
        }
        if isExactLastInvocation(invocation) {
            return .skipExactOutput
        }
        guard WrappedCommandCatalog.commandSet.contains(invocation.name) else {
            return .skipNotWrapEligible
        }
        guard let distillExecutable, !distillExecutable.isEmpty, distillExists else {
            return .skipMissingDistill
        }
        return .pipe(rewritten: rewrittenCommand(
            trimmed,
            distillExecutable: distillExecutable,
            question: question
        ))
    }

    private static func isExactLastInvocation(_ invocation: (name: String, args: [String])) -> Bool {
        if WrappedCommandCatalog.isExactOutputCommand(invocation.name) {
            return true
        }
        if invocation.name == "git", CommandWrapPolicy.isExactGitSubcommand(invocation.args) {
            return true
        }
        if CommandWrapPolicy.isExactPatchInvocation(command: invocation.name, args: invocation.args) {
            return true
        }
        return false
    }
}
