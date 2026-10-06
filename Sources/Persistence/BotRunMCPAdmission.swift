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
}
