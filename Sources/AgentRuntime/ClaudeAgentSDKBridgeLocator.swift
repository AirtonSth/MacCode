import Foundation

/// Locates `ClaudeAgentSDKBridge.mjs` at **runtime** without baking CI compile
/// paths into the binary.
///
/// WHY: the previous default used `#filePath`, which embeds the absolute path
/// of the source file at compile time. Release builds on GitLab Runner then
/// looked for:
///   `/Users/…/.gitlab-runner/builds/…/Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs`
/// on customer machines — Claude failed with "bridge script not found" even
/// when the CLI was installed. Never use `Bundle.module` either (SPM accessor
/// fatalErrors for Contents/Resources app layouts).
public enum ClaudeAgentSDKBridgeLocator {
    public static let fileName = "ClaudeAgentSDKBridge.mjs"

    /// First readable candidate, or `nil` when none exist.
    public static func resolvePath(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        main: Bundle = .main,
        fileManager: FileManager = .default
    ) -> String? {
        for path in candidatePaths(
            override: override,
            environment: environment,
            main: main,
            fileManager: fileManager
        ) where fileManager.isReadableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Ordered search paths. Public for unit tests.
    public static func candidatePaths(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        main: Bundle = .main,
        fileManager: FileManager = .default
    ) -> [String] {
        var paths: [String] = []

        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            paths.append((override as NSString).expandingTildeInPath)
        }

        if let env = environment["RC_CLAUDE_AGENT_SDK_BRIDGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            paths.append((env as NSString).expandingTildeInPath)
        }

        // Packaged app: scripts/package-app.sh copies the bridge into
        // Contents/Resources/ClaudeAgentSDKBridge.mjs
        if let resources = main.resourceURL {
            paths.append(resources.appendingPathComponent(fileName).path)
        }
        let mainURL = main.bundleURL
        paths.append(
            mainURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(fileName)
                .path
        )
        if let exeDir = main.executableURL?.deletingLastPathComponent() {
            paths.append(
                exeDir
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent(fileName)
                    .path
            )
            paths.append(exeDir.appendingPathComponent(fileName).path)
        }

        // Already-provisioned Application Support cache (after first successful run).
        paths.append(defaultCacheBridgePath(environment: environment).path)

        // Local checkout: sibling of this source file (only valid when the
        // developer builds on the same machine).
        let compileTimeSibling = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
            .path
        paths.append(compileTimeSibling)

        // Walk up from cwd / package root for Sources/AgentRuntime/… (swift test).
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        paths.append(
            cwd
                .appendingPathComponent("Sources/AgentRuntime", isDirectory: true)
                .appendingPathComponent(fileName)
                .path
        )
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AgentRuntime
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // package root
        paths.append(
            packageRoot
                .appendingPathComponent("Sources/AgentRuntime", isDirectory: true)
                .appendingPathComponent(fileName)
                .path
        )

        var seen = Set<String>()
        return paths.filter { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.contains(standardized) { return false }
            seen.insert(standardized)
            return true
        }
    }

    public static func defaultCacheBridgePath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["RC_CLAUDE_AGENT_SDK_CACHE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent(fileName)
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("RemoteCode", isDirectory: true)
            .appendingPathComponent("AgentRuntime", isDirectory: true)
            .appendingPathComponent("ClaudeAgentSDKBridge", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Human-readable failure when no candidate is readable.
    public static func notFoundMessage(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        main: Bundle = .main
    ) -> String {
        let tried = candidatePaths(override: override, environment: environment, main: main)
            .filter { !shouldRedactFromUserMessage($0) }
            .prefix(6)
            .joined(separator: "; ")
        let suffix = tried.isEmpty
            ? "Install/update MacCode so Contents/Resources/ClaudeAgentSDKBridge.mjs is present."
            : "Tried: \(tried)"
        return "Claude Agent SDK bridge script not found (searched app Resources, Application Support cache, and local sources). \(suffix)"
    }

    /// Compile-time / CI absolute paths must not reappear in customer error text
    /// (Airton-class `.gitlab-runner/builds/…` symptom under packaging miss).
    public static func shouldRedactFromUserMessage(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("/.gitlab-runner/builds/")
            || lower.contains("/builds/") && lower.contains("gitlab")
    }
}
