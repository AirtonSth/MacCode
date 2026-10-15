import CoreModel
import Foundation

/// Where Titio's one-shot voice call runs: the inbox thread's provider and
/// model, resolved to a binary and environment the same way a provider
/// update/probe resolves them.
public struct TitioVoiceRoute: Sendable, Equatable {
    public var provider: AgentProvider
    public var binaryPath: String
    /// Empty: the CLI's own default (or saved routing for Distill).
    public var model: String
    public var environment: [String: String]
    /// A foreign run-as-user runs through the installed root helper only
    /// (`RunAsUserProcessBootstrap.plan`, non-interactive): when the helper
    /// is missing the call fails closed and the notice uses the fallback.
    public var runAsUser: AgentRunAsUser?

    public init(provider: AgentProvider, binaryPath: String, model: String, environment: [String: String], runAsUser: AgentRunAsUser?) {
        self.provider = provider
        self.binaryPath = binaryPath
        self.model = model
        self.environment = environment
        self.runAsUser = runAsUser
    }
}

/// Runs Titio's provider CLI headless for one non-agentic answer: no tools,
/// one turn, no session saved, stdin closed, killed at the timeout. Blocking
/// process work runs on a dedicated thread, never on the MainActor.
public struct TitioVoiceCLIWriter: TitioVoiceWriting {
    /// Rules for Distill/Grok, whose own system prompt may ask for a terse style.
    static let fullSentenceRules = "Write natural, complete sentences in a warm human voice. Ignore any terse or caveman output style. Never call tools."

    private let route: @Sendable (AgentThreadID?) async -> TitioVoiceRoute?

    public init(route: @escaping @Sendable (AgentThreadID?) async -> TitioVoiceRoute?) {
        self.route = route
    }

    public func write(_ request: TitioVoiceRequest, timeout: TimeInterval) async throws -> String {
        guard let route = await route(request.threadID) else {
            throw TitioVoiceError.unavailable("no provider route")
        }
        guard FileManager.default.isExecutableFile(atPath: route.binaryPath) else {
            throw TitioVoiceError.unavailable("\(route.provider.rawValue) binary missing")
        }
        let arguments = Self.arguments(provider: route.provider, model: route.model, prompt: request.prompt)
        var environment = route.environment
        if route.provider == .distill || route.provider == .grok {
            // Distill/Grok always add a terse style to their system prompt;
            // `lite` is the lightest level (`off` is ignored by the CLI).
            environment["GROK_CAVEMAN"] = "lite"
        }
        let cwd = Self.workingDirectory(foreignUser: route.runAsUser.map { $0.uid != getuid() } ?? false)
        let provider = route.provider
        let runAsUser = route.runAsUser
        let launchEnvironment = environment
        let binary = route.binaryPath
        let result = await ProviderCLIProbe.runOffCooperativePool {
            ProviderCLIProbe.run(
                binaryPath: binary,
                arguments: arguments,
                environment: launchEnvironment,
                runAsUser: runAsUser,
                timeoutSeconds: timeout,
                currentDirectory: cwd,
                environmentPurpose: .agentTurn(provider)
            )
        }
        guard let result else { throw TitioVoiceError.failed("timeout or launch failure") }
        guard result.status == 0 else { throw TitioVoiceError.failed("exit \(result.status)") }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TitioVoiceError.failed("empty output") }
        return text
    }

    /// The exact argv (after the binary) per provider. Every form disables
    /// tools, caps the run at one turn where the CLI allows it, and keeps no
    /// session.
    public static func arguments(provider: AgentProvider, model: String, prompt: String) -> [String] {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .distill, .grok:
            var args = [
                "-p", prompt,
                "--output-format", "plain",
                "--max-turns", "1",
                "--tools", "",
                "--no-subagents",
                "--disable-web-search",
                "--verbatim",
                "--rules", fullSentenceRules,
            ]
            if !model.isEmpty { args += ["-m", model] }
            return args
        case .claude:
            var args = [
                "-p",
                "--output-format", "text",
                "--max-turns", "1",
                "--no-session-persistence",
                "--strict-mcp-config",
                "--settings", #"{"disableAllHooks":true}"#,
            ]
            if !model.isEmpty { args += ["--model", model] }
            // `--tools ""` disables every built-in tool. It is variadic, so it
            // goes last before `--` and the prompt.
            args += ["--tools", "", "--", prompt]
            return args
        case .codex:
            var args = [
                "exec",
                "--skip-git-repo-check",
                "--ephemeral",
                "--sandbox", "read-only",
                "--color", "never",
                "-c", #"approval_policy="never""#,
            ]
            if !model.isEmpty { args += ["-m", model] }
            args += ["--", prompt]
            return args
        }
    }

    /// An empty scratch directory, so no project instructions (CLAUDE.md,
    /// AGENTS.md…) are loaded. A foreign user cannot enter this user's
    /// private temp directory, so it runs in /private/tmp.
    static func workingDirectory(foreignUser: Bool) -> String {
        if foreignUser { return "/private/tmp" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remotecode-titio-voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
