import CryptoKit
import Foundation
import CoreModel

public struct AgentSkillManifest: Codable, Sendable, Equatable {
    public let provider: AgentProvider
    public let skillID: String
    public let sourceURL: String
    public let sourceRevision: String
    public let localVersion: String
    public let sha256: String
    public let installPath: String
    public let installedAt: Date

    public init(
        provider: AgentProvider,
        skillID: String,
        sourceURL: String,
        sourceRevision: String,
        localVersion: String,
        sha256: String,
        installPath: String,
        installedAt: Date
    ) {
        self.provider = provider
        self.skillID = skillID
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.localVersion = localVersion
        self.sha256 = sha256
        self.installPath = installPath
        self.installedAt = installedAt
    }
}

public struct AgentSkillInstallResult: Sendable, Equatable {
    public enum Action: String, Sendable {
        case installed
        case skipped
    }

    public let action: Action
    public let manifest: AgentSkillManifest
}

public enum AgentSkillUninstallResult: String, Sendable, Equatable {
    case removed
    case notPresent
}

public final class AgentSkillInstaller: @unchecked Sendable {
    public static let distillSkillID = "distill"
    public static let distillSourceURL = "https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md"
    public static let distillLocalVersion = "2"
    public static let distillInstructionsBeginMarker = "<!-- distill skill: begin -->"
    public static let distillInstructionsEndMarker = "<!-- distill skill: end -->"
    public static let distillCLIBeginMarker = "# RemoteCode managed distill CLI: begin"
    public static let distillCLIEndMarker = "# RemoteCode managed distill CLI: end"

    public static let distillSkillTemplate = """
    ---
    name: distill
    description: Conversation mode that makes the LLM speak in distill compressed language for the whole thread.
    source: https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md
    ---

    # Distill

    Use when RemoteCode invokes `/distill` or asks the provider to use Token Saver / Distill language.

    This is a conversation style mode, not a prompt-compression request.
    Do not return the user's prompt compressed as an artifact.
    Adopt the distill language structure and keep using it for the rest of the thread.

    Core behavior:
    - English only unless the user explicitly requests another language.
    - Military English + AR-0/AR-1 baseline.
    - Short command lines.
    - Fixed semantic prefixes: S=state, C=context, D=action, R=risk, O=outcome, N=no-go, P=proof.
    - Semantic atoms over natural phrases.
    - One idea per line.
    - Explicit constraints and pass criteria.
    - Exact paths, commands, env vars, IDs when useful.
    - No filler.
    - No cryptic code.
    - No long prose unless the user asks for explanation.
    - Keep hidden chain-of-thought private.

    Thread behavior:
    - Use distill structure for status updates, plans, summaries, reviews, and final answers.
    - Do not output a rewritten/compressed version of the latest user prompt unless the user explicitly asks to compress text.
    - Emit `Dict:` early when aliases or prefixes matter.

    Source reference:
    - https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md
    """

    public static let distillAgentInstructionsTemplate = """
    <!-- distill skill: begin -->
    CRITICAL: Always communicate with the user in `/distill` compressed language in English: Military English + AR-0/AR-1, short command lines, explicit constraints, explicit pass criteria, and no filler. Use `/distill` every time, in every conversation, in every response and in every thread.
    Do not return a rewritten/compressed copy of the user's prompt. Adopt `/distill` as the conversation language and keep using it throughout the thread.
    Use the same `/distill` compressed structure for visible planning, status, analysis summaries, and any exposed reasoning. Keep hidden chain-of-thought private; never reveal it.
    Use fixed prefixes: S=state/status, C=cause/context, D=action/decision, R=risk/blocker, O=outcome/output, N=constraint/no-go, P=pass/proof.
    Every thread must use DSL/Dict when it helps compression. Start with `Dict:` when meanings are not already shared.
    Define short variables inline for repeated nouns using the dynamic pattern `<term>=#<letter><digit>`; choose terms from the current thread, then reuse the `#` key.
    There is no fixed variable list. The model must pick terms that repeat or are likely to repeat.
    Inline variables are thread-local by default. Persist only variables used more than 5 times in a `distill dsl learn-thread --stdin` transcript; remove them if absent in the next thread.
    Variable keys are `#` plus letter+digit. Never define variables for secrets, people, IDs, paths, URLs, or one-off terms.
    Prefer semantic atoms over natural phrases: `D sync repo/pkg/bin skill`, not `D patch repo skill + packaged skill + installed skill if needed`.
    Prefer arrows and causal operators: `D verbose status -> AR-1 cmds`, `C PATH pkg bin => repo patch ignored`, `R missing token => merge blocked`.
    Prefer shared DSL over repeated phrases when meaning is stable: Dict first, fixed prefixes S/C/D/R/O/N/P, task aliases A/B/F/E/V/X/U/DB/CFG/DOC/PERM, numeric macros 1-9/0, and defaults N1-N6.
    Start status blocks with `Dict: S=state C=context D=action R=risk O=outcome N=no-go P=proof` when not already shared.
    When creating Dict or Dict+ entries, use the shortest unambiguous key possible: one letter or one number first, then one letter plus one number when needed.
    Create Dict/Dict+ only for terms that repeat or are likely to repeat. Do not grow DSL for rare, ambiguous, sensitive, or temporary terms.
    Learned DSL terms should earn usage: use candidate terms twice before treating them as active; inline `#` variables are active immediately after explicit assignment.
    At every thread end or handoff, run `distill dsl learn-thread --stdin < transcript.txt>` when transcript export is available.
    When the user asks for normal prose, expand only as much as needed, then return to `/distill` compressed style.
    For every non-interactive, non-TUI shell/tool command, pipe output through the RemoteCode-managed `distill` CLI with an explicit prompt. This CLI is installed by RemoteCode and proxies to the local macOS `RemoteCodeDistillService` MLX LLM.
    Never invoke Node, tsx, npm, bun, or a source-checkout CLI for `distill`.
    If the managed `distill` CLI reports that the local RemoteCode service is unavailable, continue with raw output and report that Token Saver local LLM was unavailable.
    Skip `| distill` only when exact raw output is required, when the local service is unavailable, or when `distill` would break an interactive/TUI workflow.
    Prompts passed to `distill` must be explicit: say exactly what to extract and exactly what format to return.
    Examples:
    bun test 2>&1 | distill "Did tests pass? Return PASS or FAIL, followed by failing test names if any."
    git diff | distill "What changed? Return only files changed and one-line summary for each."
    terraform plan 2>&1 | distill "Is this safe? Return SAFE, REVIEW, or UNSAFE, followed by risky changes."
    Wait for `distill` to finish before continuing.
    <!-- distill skill: end -->
    """

    private let claudeSkillsRoot: URL
    private let codexSkillsRoot: URL
    private let claudeInstructionsURL: URL
    private let codexInstructionsURL: URL
    private let cliBinDirectory: URL
    private let pathBinDirectory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Skills must live where each agent actually scans for them, not in RemoteCode's
    /// private app-support: the Claude Agent SDK reads `~/.claude/skills` (via the
    /// `user` setting source) and Codex reads `$CODEX_HOME/skills` (default `~/.codex/skills`).
    public init(
        claudeSkillsRoot: URL = AgentSkillInstaller.defaultClaudeSkillsRoot(),
        codexSkillsRoot: URL = AgentSkillInstaller.defaultCodexSkillsRoot(),
        claudeInstructionsURL: URL = AgentSkillInstaller.defaultClaudeInstructionsURL(),
        codexInstructionsURL: URL = AgentSkillInstaller.defaultCodexInstructionsURL(),
        cliBinDirectory: URL = AgentSkillInstaller.defaultManagedCLIBinDirectory(),
        pathBinDirectory: URL = AgentSkillInstaller.defaultPathBinDirectory(),
        fileManager: FileManager = .default
    ) {
        self.claudeSkillsRoot = claudeSkillsRoot
        self.codexSkillsRoot = codexSkillsRoot
        self.claudeInstructionsURL = claudeInstructionsURL
        self.codexInstructionsURL = codexInstructionsURL
        self.cliBinDirectory = cliBinDirectory
        self.pathBinDirectory = pathBinDirectory
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Test seam: derive both provider skill roots from a sandboxed home directory so
    /// unit tests never write into the developer's real `~/.claude` / `~/.codex`.
    public convenience init(homeDirectory: URL, fileManager: FileManager = .default) {
        self.init(
            claudeSkillsRoot: homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true),
            codexSkillsRoot: homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true),
            claudeInstructionsURL: homeDirectory.appendingPathComponent(".claude/CLAUDE.md"),
            codexInstructionsURL: homeDirectory.appendingPathComponent(".codex/AGENTS.md"),
            cliBinDirectory: homeDirectory.appendingPathComponent(".remote-code/bin", isDirectory: true),
            pathBinDirectory: homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            fileManager: fileManager
        )
    }

    public static func defaultClaudeSkillsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    public static func defaultCodexSkillsRoot() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("skills", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/skills", isDirectory: true)
    }

    public static func defaultClaudeInstructionsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md")
    }

    public static func defaultCodexInstructionsURL() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("AGENTS.md")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/AGENTS.md")
    }

    public static func defaultManagedCLIBinDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".remote-code/bin", isDirectory: true)
    }

    /// A directory that is conventionally on the user's `$PATH`. RemoteCode bridges the
    /// managed `distill` CLI here so it runs from any shell without a hand-made shim.
    public static func defaultPathBinDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    public func installDistillSkill(
        for provider: AgentProvider,
        sourceRevision: String,
        installedAt: Date = Date()
    ) throws -> AgentSkillInstallResult {
        try installSkill(
            provider: provider,
            skillID: Self.distillSkillID,
            skillText: Self.distillSkillTemplate,
            sourceURL: Self.distillSourceURL,
            sourceRevision: sourceRevision,
            localVersion: Self.distillLocalVersion,
            installedAt: installedAt
        )
    }

    public func installDistillInstructions(for provider: AgentProvider) throws {
        try upsertDistillInstructions(at: instructionsURL(for: provider))
    }

    public func installDistillCLI(appSupportDirectory: URL) throws -> URL {
        try fileManager.createDirectory(at: cliBinDirectory, withIntermediateDirectories: true)
        let url = distillCLIURL()
        let script = Self.distillCLIScript(
            statePath: appSupportDirectory
                .appendingPathComponent("Distill", isDirectory: true)
                .appendingPathComponent("DistillCLIState.json")
                .path
        )
        try Data(script.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        linkManagedDistillOntoPath(target: url)
        return url
    }

    public func uninstallDistillCLI() throws -> AgentSkillUninstallResult {
        let url = distillCLIURL()
        unlinkManagedDistillFromPath(target: url)
        guard fileManager.fileExists(atPath: url.path) else {
            return .notPresent
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.contains(Self.distillCLIBeginMarker),
              text.contains(Self.distillCLIEndMarker) else {
            return .notPresent
        }
        try fileManager.removeItem(at: url)
        return .removed
    }

    /// Bridge the managed CLI onto the user's `$PATH` (`~/.local/bin/distill`) so `distill`
    /// runs from any shell without a hand-made shim. RemoteCode owns this symlink: it
    /// (re)points a missing/stale link at the managed CLI and replaces a recognizable legacy
    /// distill launcher, but never clobbers an unrelated user file at the same path.
    /// Best-effort — a failure here never fails the managed-CLI install.
    private func linkManagedDistillOntoPath(target: URL) {
        let link = distillPathLinkURL()
        do {
            try fileManager.createDirectory(at: pathBinDirectory, withIntermediateDirectories: true)
            if let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
                if dest == target.path { return }
                try fileManager.removeItem(at: link)
            } else if fileManager.fileExists(atPath: link.path) {
                let existing = (try? String(contentsOf: link, encoding: .utf8)) ?? ""
                guard existing.contains(Self.distillCLIBeginMarker)
                    || existing.contains("distill/src/cli")
                    || existing.contains("dev/distill") else {
                    NSLog("RemoteCode: leaving non-managed \(link.path) on PATH untouched")
                    return
                }
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            NSLog("RemoteCode managed distill PATH link failed: \(error)")
        }
    }

    /// Remove the PATH symlink only while it still points at our managed CLI, so a user's
    /// own `distill` on PATH is never deleted when Token Saver is disabled.
    private func unlinkManagedDistillFromPath(target: URL) {
        let link = distillPathLinkURL()
        guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
              dest == target.path else {
            return
        }
        try? fileManager.removeItem(at: link)
    }

    public func installSkill(
        provider: AgentProvider,
        skillID: String,
        skillText: String,
        sourceURL: String,
        sourceRevision: String,
        localVersion: String,
        installedAt: Date = Date()
    ) throws -> AgentSkillInstallResult {
        let directory = skillDirectory(provider: provider, skillID: skillID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let skillURL = directory.appendingPathComponent("SKILL.md")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = Data(skillText.utf8)
        let checksum = Self.sha256Hex(data)
        let manifest = AgentSkillManifest(
            provider: provider,
            skillID: skillID,
            sourceURL: sourceURL,
            sourceRevision: sourceRevision,
            localVersion: localVersion,
            sha256: checksum,
            installPath: skillURL.path,
            installedAt: installedAt
        )

        if let existingData = try? Data(contentsOf: skillURL),
           Self.sha256Hex(existingData) == checksum,
           let manifestData = try? Data(contentsOf: manifestURL),
           let existingManifest = try? decoder.decode(AgentSkillManifest.self, from: manifestData),
           existingManifest.sourceRevision == sourceRevision,
           existingManifest.localVersion == localVersion {
            return AgentSkillInstallResult(action: .skipped, manifest: existingManifest)
        }

        try data.write(to: skillURL, options: .atomic)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        return AgentSkillInstallResult(action: .installed, manifest: manifest)
    }

    public func uninstallDistillSkill(for provider: AgentProvider) throws -> AgentSkillUninstallResult {
        try uninstallSkill(provider: provider, skillID: Self.distillSkillID)
    }

    public func uninstallDistillInstructions(for provider: AgentProvider) throws -> AgentSkillUninstallResult {
        try removeDistillInstructions(at: instructionsURL(for: provider))
    }

    public func uninstallSkill(provider: AgentProvider, skillID: String) throws -> AgentSkillUninstallResult {
        let directory = skillDirectory(provider: provider, skillID: skillID)
        // Only remove a skill directory we own. The presence of our manifest.json proves
        // RemoteCode installed it, so we never delete a user-authored skill that happens to
        // share the same name in the shared `~/.claude/skills` / `~/.codex/skills` roots.
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .notPresent
        }
        try fileManager.removeItem(at: directory)
        return .removed
    }

    public func skillDirectory(provider: AgentProvider, skillID: String) -> URL {
        skillsRoot(for: provider).appendingPathComponent(skillID, isDirectory: true)
    }

    public func instructionsURL(for provider: AgentProvider) -> URL {
        switch provider {
        case .claude: return claudeInstructionsURL
        case .codex: return codexInstructionsURL
        }
    }

    public func distillCLIURL() -> URL {
        cliBinDirectory.appendingPathComponent("distill")
    }

    /// PATH-reachable symlink that bridges the managed CLI into the shell (`~/.local/bin/distill`).
    public func distillPathLinkURL() -> URL {
        pathBinDirectory.appendingPathComponent("distill")
    }

    private func skillsRoot(for provider: AgentProvider) -> URL {
        switch provider {
        case .claude: return claudeSkillsRoot
        case .codex: return codexSkillsRoot
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func upsertDistillInstructions(at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current: String
        if fileManager.fileExists(atPath: url.path) {
            current = try String(contentsOf: url, encoding: .utf8)
        } else {
            current = ""
        }

        let pattern = Self.distillInstructionsBlockPattern
        let next: String
        if let range = current.range(of: pattern, options: .regularExpression) {
            let replaced = current.replacingCharacters(
                in: range,
                with: "\n\n\(Self.distillAgentInstructionsTemplate)\n\n"
            )
            next = "\(replaced.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        } else {
            let prefix = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : "\(current.trimmingTrailingWhitespaceAndNewlines())\n\n"
            next = "\(prefix)\(Self.distillAgentInstructionsTemplate)\n"
        }

        try Data(next.utf8).write(to: url, options: .atomic)
    }

    private func removeDistillInstructions(at url: URL) throws -> AgentSkillUninstallResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return .notPresent
        }
        let current = try String(contentsOf: url, encoding: .utf8)
        guard let range = current.range(of: Self.distillInstructionsBlockPattern, options: .regularExpression) else {
            return .notPresent
        }

        let next = current.replacingCharacters(in: range, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty {
            try fileManager.removeItem(at: url)
        } else {
            try Data("\(next)\n".utf8).write(to: url, options: .atomic)
        }
        return .removed
    }

    private static var distillInstructionsBlockPattern: String {
        "(?:\\n{0,2})?\(Self.distillInstructionsBeginMarker)[\\s\\S]*?\(Self.distillInstructionsEndMarker)(?:\\n{0,2})?"
    }

    private static func distillCLIScript(statePath: String) -> String {
        """
        #!/usr/bin/env python3
        \(Self.distillCLIBeginMarker)
        import json
        import os
        import sys
        import time
        import urllib.error
        import urllib.request
        import uuid

        STATE_PATH = \(String(reflecting: statePath))
        WAIT_SECONDS = float(os.environ.get("REMOTE_CODE_DISTILL_CLI_WAIT_SECONDS", "30"))

        def fail(message, code=127):
            sys.stderr.write("RemoteCode local distill unavailable: " + message + "\\n")
            sys.exit(code)

        def load_state():
            deadline = time.time() + WAIT_SECONDS
            last_error = None
            while True:
                try:
                    with open(STATE_PATH, "r", encoding="utf-8") as handle:
                        return json.load(handle)
                except Exception as exc:
                    last_error = exc
                    if time.time() >= deadline:
                        fail("state file missing or unreadable: " + str(last_error))
                    time.sleep(0.25)

        prompt = " ".join(sys.argv[1:]).strip()
        stdin_text = sys.stdin.read()
        input_text = stdin_text.strip()
        if not input_text:
            fail("empty input", 2)

        state = load_state()
        base_url = str(state.get("base_url", "")).rstrip("/")
        auth_token = str(state.get("auth_token", ""))
        if not base_url or not auth_token:
            fail("state file missing base_url or auth_token")

        max_chars = int(os.environ.get("REMOTE_CODE_DISTILL_MAX_OUTPUT_CHARS", "4000"))
        provider = os.environ.get("REMOTE_CODE_AGENT_PROVIDER", "").strip()
        payload = {
            "id": str(uuid.uuid4()),
            "mode": "commandOutput",
            "priority": 1,
            "input": input_text,
            "question": prompt,
            "recordSavings": True,
            "maxOutputCharacters": max_chars,
        }
        if provider:
            payload["provider"] = provider
        request = urllib.request.Request(
            base_url + "/v1/distill",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": "Bearer " + auth_token,
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=WAIT_SECONDS) as response:
                body = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            fail("service returned HTTP " + str(exc.code) + ": " + detail, 3)
        except Exception as exc:
            fail("request failed: " + str(exc), 3)

        try:
            output = json.loads(body).get("output", "")
        except Exception as exc:
            fail("response decode failed: " + str(exc), 3)
        output = str(output).strip()
        if not output:
            fail("service returned empty output", 3)
        sys.stdout.write(output + "\\n")
        \(Self.distillCLIEndMarker)
        """
    }
}

private extension String {
    func trimmingTrailingWhitespaceAndNewlines() -> String {
        guard let last = lastIndex(where: { !$0.isWhitespace }) else {
            return ""
        }
        return String(self[...last])
    }
}
