import Foundation

/// Token Saver was removed on 2026-10-06. Earlier builds installed hooks,
/// skills, PATH symlinks and multi-GB model weights on the user's machine;
/// this removes them. The app runs it on every launch and at quit (it is
/// idempotent), behind `RC2_DISABLE_MANAGED_DISTILL_RECONCILE`. Every step
/// runs even when an earlier one fails, so one bad file cannot leave the rest
/// installed.
///
/// It never touches the always-on routing (`~/.remote-code/bin` itself, the
/// provider proxies, the Agent App middleware, the shell bridge), a
/// `~/.local/bin/distill` that points anywhere but our managed link, a skill
/// without RemoteCode's manifest, or the user's saved training prompts.
public struct LegacyTokenSaverPurge {
    /// UserDefaults keys that only the removed Token Saver UI wrote.
    public static let userDefaultsKeys = [
        "sidebar.tokenSaver.detailsScope",
        "agent.tokenSaver.displayModesByItem.v2",
    ]

    public let installer: AgentSkillInstaller

    public init(installer: AgentSkillInstaller) {
        self.installer = installer
    }

    /// Removes the Token Saver integration from the user's home and the
    /// app-private skills root. Returns one message per failed step; empty
    /// means everything that was there is gone.
    public func purgeIntegration(defaults: UserDefaults) -> [String] {
        var failures: [String] = []
        func capture(_ label: String, _ operation: () throws -> Void) {
            do {
                try operation()
            } catch {
                failures.append("\(label): \((error as NSError).localizedDescription)")
            }
        }
        capture("command wrapper cleanup") {
            _ = try installer.uninstallCommandWrappers()
        }
        // Unlinks ~/.local/bin/distill only when it points at our managed link.
        capture("Distill CLI cleanup") {
            _ = try installer.uninstallDistillCLI()
        }
        capture("retrieve MCP cleanup") {
            try installer.uninstallRetrieveMCP()
        }
        capture("Grok PreToolUse pipe hook cleanup") {
            _ = try installer.uninstallGrokPreToolPipeHook()
        }
        capture("Grok PostToolUse output hook cleanup") {
            _ = try installer.uninstallGrokPostToolUseHook()
        }
        capture("legacy Distill cleanup") {
            try installer.uninstallLegacyProviderDistillSkills()
        }
        capture("app-private Distill skill cleanup") {
            _ = try installer.uninstallAppPrivateDistillSkill()
        }
        for key in Self.userDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        return failures
    }

    public struct DataPurgeResult: Equatable, Sendable {
        /// Paths that existed and were deleted on this pass.
        public var removed: [String] = []
        public var failures: [String] = []
        /// The kept `TokenSaver/training` folder, when it exists.
        public var keptTrainingDirectory: String?
    }

    /// Where Graphify kept its graphs. It is always the stable app's
    /// Application Support folder, whatever the release channel.
    public static func defaultGraphifyGraphsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("RemoteCode", isDirectory: true)
            .appendingPathComponent("graphify-graphs", isDirectory: true)
    }

    /// Deletes Application Support data that only the removed feature used:
    /// `Distill/` (local model weights, manifests, sidecar lease state) and
    /// Graphify's graphs. Keeps `TokenSaver/`: account usage still lives in
    /// `usage.json`, and `training/*.jsonl` holds prompts the user chose to save.
    /// Slow on multi-GB weights, so callers run it off the main actor.
    public static func purgeAppSupportData(
        appSupportDirectory: URL,
        graphifyGraphsDirectory: URL,
        fileManager: FileManager = .default
    ) -> DataPurgeResult {
        var result = DataPurgeResult()
        let targets = [
            appSupportDirectory.appendingPathComponent("Distill", isDirectory: true),
            graphifyGraphsDirectory,
        ]
        for target in targets where fileManager.fileExists(atPath: target.path) {
            do {
                try fileManager.removeItem(at: target)
                result.removed.append(target.path)
            } catch {
                result.failures.append("\(target.path): \((error as NSError).localizedDescription)")
            }
        }
        let training = appSupportDirectory
            .appendingPathComponent("TokenSaver", isDirectory: true)
            .appendingPathComponent("training", isDirectory: true)
        if fileManager.fileExists(atPath: training.path) {
            result.keptTrainingDirectory = training.path
        }
        return result
    }
}
