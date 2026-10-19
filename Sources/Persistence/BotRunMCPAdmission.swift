import Foundation
import CoreModel

/// Which managed MCPs a provider run may see, keyed on the host-stamped
/// `RC_REMOTE_CODE_BOT_ID` (`AppContext.subagentTelemetryEnvironment` sets it
/// only for threads linked to a Bot conversation).
///
/// bot-computer, bot-browser and bot-web resolve every tool call against that
/// id and fail with `callerMissing` without it, so a non-bot Agent App run
/// must not be offered them. bot-self-config is deliberately not bot-only:
/// Agent App runs use it for `bot_ask_peer` delegation and the `rc_*` host
/// catalog.
public enum BotRunMCPAdmission: Sendable {
    public static let botOnlyServerNames = [
        BotBrowserMCPAdmit.serverName,
        BotComputerMCPAdmit.serverName,
        BotWebMCPAdmit.serverName,
    ]

    public static func isBotRun(environment: [String: String]) -> Bool {
        environment[BotSelfConfigCatalog.callerEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Distill launch toggles that stop it importing the user's Mac-only MCPs
    /// from `~/.claude.json` (cua, cua-driver, computer-use-mcp) and Cursor
    /// config into a bot run. Verified against distill 2.0.30 `inspect`.
    public static let distillUserMCPImportOffEnvironment = [
        "GROK_CLAUDE_MCPS_ENABLED": "0",
        "GROK_CURSOR_MCPS_ENABLED": "0",
    ]

    /// Per-run flag stamped by the host from the Bot's Caveman setting:
    /// `1` = caveman (the default for every Bot except Titio), `0` = full prose.
    public static let cavemanEnvironmentKey = "RC_REMOTE_CODE_BOT_CAVEMAN"

    public static func botWantsCaveman(environment: [String: String]) -> Bool {
        environment[cavemanEnvironmentKey] == "1"
    }

    /// Distill always adds its terse "caveman" `<output_style>` to its system
    /// prompt (default level `full`, drops articles: "Fala tarefa."); `off` is
    /// ignored. A caveman Bot gets `full`; a Bot with Caveman off gets `lite`,
    /// the level that keeps articles and full sentences, over any host value.
    public static func distillBotReplyStyleEnvironment(environment: [String: String]) -> [String: String] {
        ["GROK_CAVEMAN": botWantsCaveman(environment: environment) ? "full" : "lite"]
    }

    /// ACP `session/new` `_meta.rules` for bot sessions with Caveman off:
    /// Distill appends it to its system prompt as `<human_rules>`, the level
    /// that can override its `<output_style>` the way Distill's own harness
    /// roles do. The per-turn reply style line is the backstop for resumed
    /// sessions, which keep the system prompt they were created with.
    public static let distillBotReplyRules =
        "Bot reply style, set by the RemoteCode host harness (not the user): for everything you write to the user, ignore the <output_style> section and any caveman or terse style in this system prompt and write normal, complete prose. \(BotStandingInstructions.replyStyleLine) Sound like a person, not an AI: no filler openers such as \"Great question\" or \"Certainly!\", no inflated or promotional wording, no habitual em dashes, no lists of three added for rhythm, no closing offers of more help. Never drop articles or write status-line fragments such as \"Page open. Say task.\"."

    /// `rules` for an ACP `session/new` of this run: bots only, so a non-bot
    /// Agent App Distill thread keeps Distill's own style.
    public static func distillSessionRules(environment: [String: String]) -> String? {
        guard isBotRun(environment: environment) else { return nil }
        return distillBotReplyRules
    }
}
