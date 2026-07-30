import AgentRuntime
import CoreModel
import Darwin
import DistillCore
import Foundation
import Persistence

/// OS half of the nested-provider PATH controller.
///
/// Invoked when a managed symlink (`~/.remote-code/bin/{grok,claude,codex}`) is
/// the process basename. Preserves argv/stdin/stdout/stderr/exit status, avoids
/// recursion into the managed bin, and records a content-free Subagents receipt
/// when the parent thread scope is present. Never invents Token Saver admission.
enum ProviderProxyRunner {
    /// Runs the real provider CLI. Always returns the real process exit code
    /// (or 127 when the real executable cannot be resolved).
    static func run(command: String, arguments: [String]) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let basename = ProviderProxyPolicy.commandBasename(command)

        // Fail open: no telemetry scope → raw exec, no receipt.
        guard ProviderProxyPolicy.hasTelemetryScope(environment: env) else {
            guard let realExe = resolveRealExecutable(command: basename, environment: env) else {
                FileHandle.standardError.write(
                    Data("\(basename): command not found (RemoteCode provider proxy)\n".utf8)
                )
                return 127
            }
            return runInheritingAllStreams(executable: realExe, args: arguments)
        }

        let childRunId = beginReceipt(providerBasename: basename, environment: env)
        let outcome: ProcessOutcome
        if let delegation = ProviderProxyPolicy.agentAppDelegation(
            providerBasename: basename,
            arguments: arguments,
            environment: env
        ) {
            outcome = runAgentAppDelegation(delegation, environment: env)
        } else if let realExe = resolveRealExecutable(command: basename, environment: env) {
            outcome = runInheritingAllStreamsDetailed(executable: realExe, args: arguments)
        } else {
            FileHandle.standardError.write(
                Data("\(basename): command not found (RemoteCode provider proxy)\n".utf8)
            )
            outcome = ProcessOutcome(
                exitCode: 127,
                terminationStatus: 127,
                wasUncaughtSignal: false,
                forwardedSignal: nil
            )
        }
        if let childRunId {
            endReceiptOnce(
                runId: childRunId,
                status: ProviderProxyPolicy.runStatus(
                    wasUncaughtSignal: outcome.wasUncaughtSignal,
                    terminationStatus: outcome.terminationStatus,
                    forwardedSignal: outcome.forwardedSignal
                ),
                environment: env
            )
        }
        return outcome.exitCode
    }

    /// Dispatch the explicit `remote-code agent-app …` entry point to the
    /// bundled rc2 binary, preserving stdin/stdout/stderr and exit status.
    static func runAgentAppCLI(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        runAgentAppCLIOutcome(arguments: arguments, environment: environment).exitCode
    }

    private static func runAgentAppDelegation(
        _ delegation: ProviderAgentAppDelegation,
        environment: [String: String]
    ) -> ProcessOutcome {
        var arguments = [
            "agent-app", delegation.provider.rawValue,
            "--prompt-file", delegation.promptFile,
            "--permission", delegation.permissionMode.rawValue,
            "--reasoning-effort", delegation.reasoningEffort.rawValue,
            "--output-format", delegation.outputFormat.rawValue
        ]
        if let model = delegation.model, !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        return runAgentAppCLIOutcome(arguments: arguments, environment: environment)
    }

    private static func runAgentAppCLIOutcome(
        arguments: [String],
        environment: [String: String]
    ) -> ProcessOutcome {
        guard let rc2 = resolveRC2Executable(environment: environment) else {
            FileHandle.standardError.write(
                Data("remote-code agent-app: bundled rc2 executable not found\n".utf8)
            )
            return ProcessOutcome(
                exitCode: 127,
                terminationStatus: 127,
                wasUncaughtSignal: false,
                forwardedSignal: nil
            )
        }
        var effectiveArguments = arguments
        if let socket = ProviderProxyPolicy.agentAppSocketPath(
            environment: environment,
            bundledSocketPath: bundledReleaseChannel().map { AppPaths.socketPath(for: $0) }
        ),
           !arguments.contains("--socket") {
            effectiveArguments.insert(contentsOf: ["--socket", socket], at: 0)
        }
        return runInheritingAllStreamsDetailed(executable: rc2, args: effectiveArguments)
    }

    private static func bundledReleaseChannel() -> ReleaseChannel? {
        guard let current = currentExecutablePath(),
              let canonical = canonicalPath(current) else {
            return nil
        }
        let contentsDirectory = URL(fileURLWithPath: canonical)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = contentsDirectory.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        if let environment = plist["LSEnvironment"] as? [String: Any],
           let channel = environment["RC2_CHANNEL"] as? String,
           let releaseChannel = ReleaseChannel(rawValue: channel) {
            return releaseChannel
        }
        guard let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }
        if bundleID == "io.remotecode.desktop" { return .stable }
        if bundleID.hasSuffix(".canary") { return .canary }
        if bundleID.hasSuffix(".debug") { return .debug }
        return nil
    }

    private static func resolveRC2Executable(environment: [String: String]) -> String? {
        if let override = environment["RC_REMOTE_CODE_RC2_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        guard let current = currentExecutablePath(),
              let canonical = canonicalPath(current) else {
            return nil
        }
        let sibling = (canonical as NSString)
            .deletingLastPathComponent
            .appending("/rc2")
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    // MARK: - real executable

    private static func resolveRealExecutable(command: String, environment: [String: String]) -> String? {
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let managedBin = (CommandLine.arguments.first.map { ($0 as NSString).deletingLastPathComponent } ?? "")
        let selfReal = canonicalPath(currentExecutablePath() ?? CommandLine.arguments.first ?? "")
        return ProviderProxyPolicy.resolveRealExecutable(
            command: command,
            pathEntries: pathEntries,
            managedBinDirectory: managedBin,
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) },
            resolvesToSelf: { candidate in
                guard let selfReal else { return false }
                return canonicalPath(candidate) == selfReal
            }
        )
    }

    private static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - spawn

    private struct ProcessOutcome {
        var exitCode: Int32
        var terminationStatus: Int32
        var wasUncaughtSignal: Bool
        var forwardedSignal: Int32?
    }

    private static func runInheritingAllStreams(executable: String, args: [String]) -> Int32 {
        runInheritingAllStreamsDetailed(executable: executable, args: args).exitCode
    }

    private static func runInheritingAllStreamsDetailed(executable: String, args: [String]) -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // Leave standardInput/Output/Error unset so the child inherits ours.
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(
                Data("\(ProviderProxyPolicy.commandBasename(executable)): \(error.localizedDescription)\n".utf8)
            )
            return ProcessOutcome(
                exitCode: 126,
                terminationStatus: 126,
                wasUncaughtSignal: false,
                forwardedSignal: nil
            )
        }

        // A terminal interrupt or an explicit SIGTERM can target the proxy
        // instead of the real child. Ignore the default action in this short
        // controller process, forward the signal to the real provider, and
        // keep the receipt finalization path alive. The child may also receive
        // the terminal signal directly; the status mapping remains idempotent.
        let signalLock = NSLock()
        var forwardedSignal: Int32?
        let signalQueue = DispatchQueue(label: "remotecode.provider-proxy.signal")
        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM] {
            _ = Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
            source.setEventHandler {
                signalLock.lock()
                if forwardedSignal == nil { forwardedSignal = signalNumber }
                signalLock.unlock()
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, signalNumber)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        process.waitUntilExit()
        for source in signalSources { source.cancel() }
        _ = Darwin.signal(SIGINT, SIG_DFL)
        _ = Darwin.signal(SIGTERM, SIG_DFL)
        signalLock.lock()
        let capturedSignal = forwardedSignal
        signalLock.unlock()
        let wasSignal = process.terminationReason == .uncaughtSignal
        let status = process.terminationStatus
        // Shell-style exit code for signals: 128 + signal when uncaught.
        let exitCode: Int32 = wasSignal ? (128 + status) : status
        return ProcessOutcome(
            exitCode: exitCode,
            terminationStatus: status,
            wasUncaughtSignal: wasSignal,
            forwardedSignal: capturedSignal
        )
    }

    // MARK: - receipts (content-free; fail open)

    private static func beginReceipt(providerBasename: String, environment: [String: String]) -> AgentRunID? {
        do {
            let appSupportOverride = environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]
            let (_, db) = try Bootstrap(
                channel: .debug,
                appSupportOverride: appSupportOverride
            ).run()
            let runtime = AgentOrchestrationRuntime(
                repository: AgentOrchestrationRepository(db: db),
                packageVerification: { true },
                rolloutGate: { true },
                killSwitch: { false }
            )
            guard let threadUUID = UUID(
                uuidString: environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"]
                    ?? environment["RC_TOKEN_SAVER_THREAD_ID"]
                    ?? ""
            ),
                  let parentProvider = AgentProvider(rawValue: environment["REMOTE_CODE_AGENT_PROVIDER"] ?? "")
            else {
                return nil
            }
            // Nested worker identity is the invoked provider basename; parent
            // provider stays on the env for Token Saver inheritance context.
            let nestedProvider = AgentProvider(rawValue: providerBasename) ?? parentProvider
            let parentRunId: AgentRunID? = UUID(
                uuidString: environment["RC_TOKEN_SAVER_ROOT_RUN_ID"]
                    ?? environment["RC_TOKEN_SAVER_ATTEMPT_ID"]
                    ?? ""
            ).map { AgentRunID($0) }
            let nodeId = ProviderProxyPolicy.makeNodeId(
                providerBasename: providerBasename,
                processIdentifier: getpid(),
                monotonicNanos: DispatchTime.now().uptimeNanoseconds
            )
            let childRunId = AgentRunID()
            _ = try runtime.recordExternalChild(
                runId: childRunId,
                threadId: AgentThreadID(threadUUID),
                provider: nestedProvider,
                // The parent instance/model describe the controller, not the
                // nested CLI. Never attribute a Codex parent instance/model to
                // a Grok or Claude child; no target-specific identity is
                // reconstructed from prompt/argv content here.
                providerInstanceId: nestedProvider.rawValue,
                model: "unknown",
                nodeId: nodeId,
                parentRunId: parentRunId
            )
            return childRunId
        } catch {
            // Fail open: telemetry unavailable must not block the real provider.
            FileHandle.standardError.write(
                Data("RemoteCode provider proxy telemetry begin skipped: \(error)\n".utf8)
            )
            return nil
        }
    }

    private static var finalizedRunIds = Set<UUID>()
    private static let finalizeLock = NSLock()

    private static func endReceiptOnce(
        runId: AgentRunID,
        status: AgentRunStatus,
        environment: [String: String]
    ) {
        finalizeLock.lock()
        let already = !finalizedRunIds.insert(runId.value).inserted
        finalizeLock.unlock()
        if already { return }

        do {
            let appSupportOverride = environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]
            let (_, db) = try Bootstrap(
                channel: .debug,
                appSupportOverride: appSupportOverride
            ).run()
            let runtime = AgentOrchestrationRuntime(
                repository: AgentOrchestrationRepository(db: db),
                packageVerification: { true },
                rolloutGate: { true },
                killSwitch: { false }
            )
            try runtime.finalizeReceipt(runId: runId, status: status)
        } catch {
            FileHandle.standardError.write(
                Data("RemoteCode provider proxy telemetry end skipped: \(error)\n".utf8)
            )
        }
    }
}
