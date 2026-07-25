import Foundation

/// Discovers the slash-invocable entries an interactive `claude` session would
/// expose under `/`, so the Agent App composer can autocomplete them: project-
/// AND user-scoped skills (`.claude/skills/<name>/SKILL.md`) and custom commands
/// (`.claude/commands/<name>.md`), plus the built-in Claude slash commands.
///
/// The Agent App runs `claude --setting-sources user,project,local`, so all of
/// these actually resolve at run time; this enumeration only powers the menu.
/// Project scope is why a skill living in the open folder (e.g. `/task` in
/// `2-tasks-repos/.claude`) must appear — the cached provider probe only ever
/// saw the user's `~/.claude`.
public enum ClaudeSlashCommandDiscovery {
    /// Built-in Claude Code slash commands worth surfacing in the composer.
    /// Local RemoteCode handlers (/clear, /model, ...) are merged separately by
    /// the caller; these are the claude-native ones the app does not own, most
    /// importantly `/mcp` (the reported gap).
    public static let builtInClaudeCommands = [
        "/mcp", "/agents", "/context", "/compact", "/cost", "/config", "/help"
    ]

    /// Bare skill/command names (no leading slash) discovered under the project
    /// `cwd` and the user `home`, de-duplicated and sorted. Project entries and
    /// user entries share one namespace (a project skill shadows a user skill of
    /// the same name at run time, but for the menu we only need the name once).
    public static func discover(cwd: String?, home: String) -> [String] {
        var names = Set<String>()
        for root in claudeRoots(cwd: cwd, home: home) {
            names.formUnion(skillNames(in: root.appendingPathComponent("skills", isDirectory: true)))
            names.formUnion(commandNames(in: root.appendingPathComponent("commands", isDirectory: true)))
        }
        return names.sorted()
    }

    /// The `.claude` directories to scan: the project's (cwd) first, then the
    /// user's home. A nil/empty cwd yields only the user root.
    static func claudeRoots(cwd: String?, home: String) -> [URL] {
        var roots: [URL] = []
        if let cwd, !cwd.trimmingCharacters(in: .whitespaces).isEmpty {
            roots.append(URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(".claude", isDirectory: true))
        }
        let userClaude = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        if !roots.contains(where: { $0.standardizedFileURL == userClaude.standardizedFileURL }) {
            roots.append(userClaude)
        }
        return roots
    }

    /// `<root>/<name>/SKILL.md` → `<name>`.
    static func skillNames(in skillsDir: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDir else { return nil }
            let skillFile = url.appendingPathComponent("SKILL.md")
            return FileManager.default.fileExists(atPath: skillFile.path) ? url.lastPathComponent : nil
        }
    }

    /// `<root>/<name>.md` → `<name>` (top-level markdown command files).
    static func commandNames(in commandsDir: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: commandsDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            return name.isEmpty ? nil : name
        }
    }
}
