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
        let env = ProviderProxyPolicy.alwaysOnTelemetryEnvironment(
            ProcessInfo.processInfo.environment
        )
        let basename = ProviderProxyPolicy.commandBasename(command)
        let liveRuntime = validatedPaidRuntime(environment: env)
        let runtimeEnvironment = liveRuntime.environment

        // The deterministic sam-grok-worker ABI is fully representable by the
        // native Agent App middleware. Promote it before raw permission/receipt
        // handling so the persisted Agent App run is the sole lifecycle row.
        let parentRunScope = runtimeEnvironment["RC_REMOTE_CODE_ROOT_RUN_ID"]
            ?? runtimeEnvironment["RC_TOKEN_SAVER_ROOT_RUN_ID"]
            ?? runtimeEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"]
        if runtimeEnvironment["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"] == "1",
           ProviderProxyPolicy.hasTelemetryScope(environment: runtimeEnvironment),
           parentRunScope.flatMap(UUID.init(uuidString:)) != nil,
           let delegation = ProviderProxyPolicy.samGrokWorkerAgentAppDelegation(
                providerBasename: basename,
                arguments: arguments
           ) {
            return runAgentAppDelegation(
                delegation,
                environment: runtimeEnvironment
            ).exitCode
        }

        // Fail open: no telemetry scope → raw exec, no receipt.
        guard ProviderProxyPolicy.hasTelemetryScope(environment: env) else {
            var unscopedEnvironment = runtimeEnvironment
            unscopedEnvironment.removeValue(
                forKey: AgentDelegationCapabilityTransport.environmentKey
            )
            guard let realExe = resolveRealExecutable(
                command: basename,
                environment: unscopedEnvironment
            ) else {
                FileHandle.standardError.write(
                    Data("\(basename): command not found (RemoteCode provider proxy)\n".utf8)
                )
                return 127
            }
            return runInheritingAllStreams(
                executable: realExe,
                args: arguments,
                environment: unscopedEnvironment
            )
        }

        let requestedPermission: AgentPermissionMode?
        let parsedPermission = ProviderProxyPolicy.explicitPermissionRequest(
            providerBasename: basename,
            arguments: arguments,
            environment: runtimeEnvironment
        )
        switch ProviderProxyPolicy.effectiveRawPermissionRequest(parsedPermission) {
        case .inherited:
            preconditionFailure("effective raw permission cannot remain inherited")
        case .explicit(let mode):
            requestedPermission = mode
        case .invalid(let reason):
            return denyPermission("\(basename): \(reason)")
        }

        // Every non-promoted provider CLI remains on its exact raw ABI. Its
        // external receipt is the authoritative lifecycle row.
        let childRunId: AgentRunID?
        let childDelegationCapability: String?
        switch beginReceipt(
            providerBasename: basename,
            // Raw provider argv is not a trustworthy metadata boundary: an
            // unknown option may consume a following `--model` lookalike from
            // prompt data. Only the strict promoted contract persists a model.
            model: nil,
            requestedPermissionMode: requestedPermission,
            environment: runtimeEnvironment
        ) {
        case .started(let runId, let capability):
            childRunId = runId
            childDelegationCapability = capability
        case .unavailable:
            childRunId = nil
            childDelegationCapability = nil
        case .permissionDenied(let reason):
            return denyPermission("\(basename): \(reason)")
        }
        let childEnvironment = makeChildEnvironment(
            environment: runtimeEnvironment,
            targetProviderBasename: basename,
            childRunId: childRunId,
            childDelegationCapability: childDelegationCapability,
            paidAdmission: liveRuntime.admission
        )
        if let childRunId {
            scheduleExternalReceiptLeaseRenewal(
                runId: childRunId,
                environment: childEnvironment
            )
        }
        let outcome: ProcessOutcome
        var usage: AssistantTokenUsage?
        if let realExe = resolveRealExecutable(
            command: basename,
            environment: childEnvironment
        ) {
            let effectiveArguments = providerRuntimeArguments(
                providerBasename: basename,
                arguments: arguments,
                environment: childEnvironment
            )
            if let captureFormat = ProviderProxyPolicy.usageCaptureFormat(
                providerBasename: basename,
                arguments: arguments
            ),
            let provider = AgentProvider(rawValue: basename) {
                let usageSession = RawProviderUsageSession(
                    providerBasename: basename,
                    environment: childEnvironment
                )
                let onJSONLine: (@Sendable (Data) -> Void)?
                if captureFormat.isLineDelimited {
                    onJSONLine = { line in
                        if let observed = ProviderProxyPolicy.streamJSONTokenUsage(
                            from: line,
                            provider: provider
                        ) {
                            usageSession.observe(observed)
                        }
                    }
                } else {
                    onJSONLine = nil
                }
                let captured = runTeeingStandardOutputDetailed(
                    executable: realExe,
                    args: effectiveArguments,
                    environment: childEnvironment,
                    captureFinalOutput: !captureFormat.isLineDelimited,
                    onJSONLine: onJSONLine
                )
                outcome = captured.outcome
                if let output = captured.standardOutput {
                    switch captureFormat {
                    case .grokJSON:
                        if let final = ProviderProxyPolicy.grokJSONTokenUsage(from: output) {
                            usageSession.observe(final)
                        }
                    case .claudeJSON:
                        if let final = ProviderProxyPolicy.claudeJSONTokenUsage(from: output) {
                            usageSession.observe(final)
                        }
                    case .grokJSONLines, .claudeJSONLines, .codexJSONLines:
                        break
                    }
                }
                usageSession.flush()
                usage = usageSession.effective
            } else {
                outcome = runInheritingAllStreamsDetailed(
                    executable: realExe,
                    args: effectiveArguments,
                    environment: childEnvironment
                )
            }
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
                usage: usage,
                environment: childEnvironment
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
        // `rc2 agent-app` now sends parent scope to the host, which records the
        // actual AgentRunID. Do not create a synthetic proxy lifecycle around it.
        runAgentAppCLIOutcome(
            arguments: arguments,
            environment: environment
        ).exitCode
    }

    private static func runAgentAppDelegation(
        _ delegation: ProviderAgentAppDelegation,
        environment: [String: String]
    ) -> ProcessOutcome {
        runAgentAppCLIOutcome(
            arguments: delegation.arguments,
            environment: environment
        )
    }

    /// Inject the same host-owned runtime guidance used by Agent App adapters
    /// while preserving the provider CLI's original sandbox/tool/session ABI.
    /// This is limited to documented provider append/config switches.
    private static func providerRuntimeArguments(
        providerBasename: String,
        arguments: [String],
        environment: [String: String]
    ) -> [String] {
        guard let provider = AgentProvider(
            rawValue: ProviderProxyPolicy.commandBasename(providerBasename)
        ) else {
            return arguments
        }
        return AgentSkillInstaller.providerProxyArguments(
            provider: provider,
            arguments: arguments,
            environment: environment
        )
    }

    private static func denyPermission(_ reason: String) -> Int32 {
        FileHandle.standardError.write(
            Data("RemoteCode provider proxy denied permission escalation: \(reason)\n".utf8)
        )
        return 77 // EX_NOPERM
    }

    private struct PaidRuntimeAdmission {
        let receipt: TokenSaverExecutionReceipt
        let graphifyActive: Bool
    }

    private struct ValidatedPaidRuntime {
        let environment: [String: String]
        let admission: PaidRuntimeAdmission?
    }

    /// Re-read the persisted setting for every nested provider launch. Inherited
    /// environment is only capability transport; it cannot resurrect Token
    /// Saver or Graphify after the user turns either feature off.
    private static func validatedPaidRuntime(
        environment: [String: String]
    ) -> ValidatedPaidRuntime {
        guard let controller = AgentProvider(
            rawValue: environment["REMOTE_CODE_AGENT_PROVIDER"] ?? ""
        ),
        let receipt = TokenSaverExecutionReceiptSeam.receipt(from: environment),
        receipt.admitted,
        receipt.sameUser,
        receipt.provider == controller.rawValue,
        receipt.threadId == (
            environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"]
                ?? environment["RC_TOKEN_SAVER_THREAD_ID"]
                ?? ""
        ),
        let settings = liveAppSettings(environment: environment),
        settings.tokenSaverEnabled else {
            return ValidatedPaidRuntime(
                environment: ProviderProxyPolicy.paidRuntimeEnvironment(
                    environment: environment,
                    tokenSaverRuntimeActive: false,
                    graphifyRuntimeActive: false
                ),
                admission: nil
            )
        }

        if let receiptRoot = receipt.rootRunId {
            let inheritedRoot = environment["RC_REMOTE_CODE_ROOT_RUN_ID"]
                ?? environment["RC_TOKEN_SAVER_ROOT_RUN_ID"]
                ?? environment["RC_TOKEN_SAVER_ATTEMPT_ID"]
            guard inheritedRoot == receiptRoot else {
                return ValidatedPaidRuntime(
                    environment: ProviderProxyPolicy.paidRuntimeEnvironment(
                        environment: environment,
                        tokenSaverRuntimeActive: false,
                        graphifyRuntimeActive: false
                    ),
                    admission: nil
                )
            }
        }

        let graphifyActive = settings.isGraphifyRuntimeActive
            && receipt.capabilities.graphify == true
        var validated = ProviderProxyPolicy.paidRuntimeEnvironment(
            environment: environment,
            tokenSaverRuntimeActive: true,
            graphifyRuntimeActive: graphifyActive
        )

        // Discrete RC_TOKEN_SAVER_* values are rebuilt from the validated
        // receipt so stale/spoofed siblings cannot disagree with it.
        for key in validated.keys where key.hasPrefix("RC_TOKEN_SAVER_") {
            validated.removeValue(forKey: key)
        }
        validated.merge(
            TokenSaverExecutionReceiptSeam.environment(from: receipt)
        ) { _, receiptValue in receiptValue }
        if receipt.capabilities.distill != true {
            for key in validated.keys where key.hasPrefix("RC_DISTILL_") {
                validated.removeValue(forKey: key)
            }
        }
        if receipt.capabilities.postToolUse != true {
            validated.removeValue(forKey: "REMOTE_CODE_DISTILL_STATE_PATH")
        }
        return ValidatedPaidRuntime(
            environment: validated,
            admission: PaidRuntimeAdmission(
                receipt: receipt,
                graphifyActive: graphifyActive
            )
        )
    }

    private static func liveAppSettings(
        environment: [String: String]
    ) -> AppSettings? {
        let override = environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = bundledReleaseChannel()
        guard override?.isEmpty == false || channel != nil else { return nil }
        do {
            let (_, db) = try Bootstrap(
                channel: channel ?? .debug,
                appSupportOverride: override?.isEmpty == false ? override : nil
            ).run()
            return SettingsStore(db: db).reload()
        } catch {
            return nil
        }
    }

    private static func makeChildEnvironment(
        environment: [String: String],
        targetProviderBasename: String,
        childRunId: AgentRunID?,
        childDelegationCapability: String?,
        paidAdmission: PaidRuntimeAdmission?
    ) -> [String: String] {
        guard let targetProvider = AgentProvider(
            rawValue: ProviderProxyPolicy.commandBasename(targetProviderBasename)
        ) else {
            return ProviderProxyPolicy.paidRuntimeEnvironment(
                environment: environment,
                tokenSaverRuntimeActive: false,
                graphifyRuntimeActive: false
            )
        }

        let childId = childRunId?.value.uuidString
        let tokenSaverEnvironment: [String: String]? = {
            guard let childId,
                  let admission = paidAdmission else {
                return nil
            }
            let parent = admission.receipt
            // Nested launch re-probes the Distill lease so a parent that started
            // while the sidecar was still starting does not permanently starve
            // child Codex/Claude/Grok processes of distill + managed_path.
            let statePath = providerDistillStatePath(environment: environment)
            let sidecarLive = TokenSaverSidecarLeaseProbe.isHealthy(
                stateFileURL: statePath.map { URL(fileURLWithPath: $0) }
            )
            let seed = TokenSaverExecutionReceipt(
                rootRunId: childId,
                threadId: parent.threadId,
                attemptId: childId,
                provider: parent.provider,
                admitted: parent.admitted,
                sameUser: parent.sameUser,
                denialReason: parent.denialReason,
                capabilities: parent.capabilities,
                disabledLanes: parent.disabledLanes,
                enabledLanes: parent.enabledLanes,
                workspaceId: parent.workspaceId,
                projectId: parent.projectId,
                waveLive: parent.waveLive
            )
            let retargeted = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                receipt: seed,
                sidecarAvailable: sidecarLive || parent.capabilities.distill == true,
                provider: targetProvider,
                waveLive: parent.waveLive
            )
            // Graphify stays gated by live settings, not only the parent snapshot.
            let graphifyActive = admission.graphifyActive
                && retargeted.capabilities.graphify == true
            let childCapabilities = TokenSaverExecutionReceipt.Capabilities(
                distill: retargeted.capabilities.distill,
                graphify: graphifyActive,
                postToolUse: ProviderProxyPolicy.childPostToolUseCapability(
                    targetProvider: targetProvider,
                    distillAvailable: retargeted.capabilities.distill == true
                ),
                recoveryScope: retargeted.capabilities.recoveryScope,
                managedPath: retargeted.capabilities.managedPath
            )
            let childReceipt = TokenSaverExecutionReceipt(
                rootRunId: childId,
                threadId: retargeted.threadId,
                attemptId: childId,
                provider: targetProvider.rawValue,
                admitted: retargeted.admitted,
                sameUser: retargeted.sameUser,
                denialReason: retargeted.denialReason,
                capabilities: childCapabilities,
                disabledLanes: retargeted.disabledLanes,
                enabledLanes: retargeted.enabledLanes,
                workspaceId: retargeted.workspaceId,
                projectId: retargeted.projectId,
                waveLive: retargeted.waveLive
            )
            var childRuntime = TokenSaverExecutionReceiptSeam.environment(from: childReceipt)
            if childCapabilities.postToolUse == true,
               let statePath {
                childRuntime["REMOTE_CODE_DISTILL_STATE_PATH"] = statePath
            }
            // Child process PATH must put managed wrappers first when distill is admitted.
            if childCapabilities.managedPath == true {
                let managedBin = environment["RC_REMOTE_CODE_MANAGED_BIN"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let bin = (managedBin?.isEmpty == false)
                    ? managedBin!
                    : AgentSkillInstaller.defaultManagedCLIBinDirectory().path
                let current = environment["PATH"]
                    ?? ProcessInfo.processInfo.environment["PATH"]
                    ?? ""
                let parts = current
                    .split(separator: ":", omittingEmptySubsequences: false)
                    .map(String.init)
                    .filter { $0 != bin }
                childRuntime["PATH"] = ([bin] + parts).joined(separator: ":")
                childRuntime["RC_REMOTE_CODE_MANAGED_BIN"] = bin
            }
            return childRuntime
        }()
        return ProviderProxyPolicy.childScopedEnvironment(
            environment: environment,
            targetProvider: targetProvider,
            childRunId: childId,
            childDelegationCapability: childDelegationCapability,
            tokenSaverEnvironment: tokenSaverEnvironment
        )
    }

    private static func providerDistillStatePath(
        environment: [String: String]
    ) -> String? {
        if let inherited = environment["REMOTE_CODE_DISTILL_STATE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !inherited.isEmpty {
            return inherited
        }
        if let appSupport = environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !appSupport.isEmpty {
            return URL(fileURLWithPath: appSupport, isDirectory: true)
                .appendingPathComponent("Distill", isDirectory: true)
                .appendingPathComponent("DistillCLIState.json")
                .path
        }
        guard let channel = bundledReleaseChannel() else { return nil }
        return AppPaths.appSupportDirectory(for: channel)
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
            .path
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
        return runInheritingAllStreamsDetailed(
            executable: rc2,
            args: effectiveArguments,
            environment: environment
        )
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

    private final class RawProviderUsageSession: @unchecked Sendable {
        private let providerBasename: String
        private let environment: [String: String]
        private let stateLock = NSLock()
        private var accumulator = ProviderProxyUsageAccumulator()
        private let persistenceQueue = DispatchQueue(
            label: "remotecode.provider-proxy.usage"
        )
        private var commitBuffer = ProviderProxyUsageCommitBuffer()
        private static let finalFlushRetryDelays: [TimeInterval] = [0.025, 0.1]

        init(providerBasename: String, environment: [String: String]) {
            self.providerBasename = providerBasename
            self.environment = environment
        }

        func observe(_ usage: AssistantTokenUsage) {
            stateLock.lock()
            let update = accumulator.record(usage)
            stateLock.unlock()
            guard let delta = update.delta else { return }
            persistenceQueue.async { [self] in
                commitBuffer.enqueue(
                    delta: delta,
                    session: update.effective
                )
                persistBufferedUsage(maxAttempts: 1)
            }
        }

        var effective: AssistantTokenUsage? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return accumulator.effective
        }

        func flush() {
            persistenceQueue.sync { [self] in
                persistBufferedUsage(
                    maxAttempts: Self.finalFlushRetryDelays.count + 1,
                    retryDelay: { retryNumber in
                        let index = min(
                            max(0, retryNumber - 1),
                            Self.finalFlushRetryDelays.count - 1
                        )
                        Thread.sleep(
                            forTimeInterval: Self.finalFlushRetryDelays[index]
                        )
                    }
                )
            }
        }

        private func persistBufferedUsage(
            maxAttempts: Int,
            retryDelay: (Int) -> Void = { _ in }
        ) {
            _ = commitBuffer.persistPending(
                maxAttempts: maxAttempts,
                retryDelay: retryDelay
            ) { [providerBasename, environment] attempt in
                ProviderProxyRunner.recordRawProviderUsage(
                    delta: attempt.delta,
                    session: attempt.session,
                    providerBasename: providerBasename,
                    environment: environment,
                    eligibleRunCandidate: attempt.eligibleRunCandidate
                )
            }
        }
    }

    private struct ProcessOutcome {
        var exitCode: Int32
        var terminationStatus: Int32
        var wasUncaughtSignal: Bool
        var forwardedSignal: Int32?
    }

    private struct CapturedProcessOutcome {
        var outcome: ProcessOutcome
        /// Nil means capture exceeded the bounded parser buffer. All bytes were
        /// still forwarded to stdout; only usage attribution is unavailable.
        var standardOutput: Data?
    }

    private static let maximumUsageCaptureBytes = 32 * 1_024 * 1_024

    private static func runInheritingAllStreams(
        executable: String,
        args: [String],
        environment: [String: String]
    ) -> Int32 {
        runInheritingAllStreamsDetailed(
            executable: executable,
            args: args,
            environment: environment
        ).exitCode
    }

    private static func runInheritingAllStreamsDetailed(
        executable: String,
        args: [String],
        environment: [String: String]
    ) -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
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
        return waitForProcess(process)
    }

    /// Preserve provider JSON stdout bytes and order while retaining a bounded
    /// copy solely for usage parsing. Stdin/stderr and exit/signal semantics
    /// remain identical to the transparent raw provider path.
    private static func runTeeingStandardOutputDetailed(
        executable: String,
        args: [String],
        environment: [String: String],
        captureFinalOutput: Bool,
        onJSONLine: (@Sendable (Data) -> Void)?
    ) -> CapturedProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            FileHandle.standardError.write(
                Data("\(ProviderProxyPolicy.commandBasename(executable)): \(error.localizedDescription)\n".utf8)
            )
            return CapturedProcessOutcome(
                outcome: ProcessOutcome(
                    exitCode: 126,
                    terminationStatus: 126,
                    wasUncaughtSignal: false,
                    forwardedSignal: nil
                ),
                standardOutput: nil
            )
        }
        // The child owns its duplicated write descriptor after spawn. Closing
        // the parent copy guarantees the drain observes EOF at process exit.
        try? outputPipe.fileHandleForWriting.close()

        var captured = Data()
        var exceededCaptureBound = false
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drain.leave() }
            var lineDecoder = ProviderProxyJSONLineDecoder()
            while true {
                let chunk: Data
                do {
                    chunk = try outputPipe.fileHandleForReading.read(upToCount: 64 * 1_024) ?? Data()
                } catch {
                    break
                }
                if chunk.isEmpty { break }
                if let onJSONLine {
                    for line in ProviderProxyPolicy.forwardAndDecodeJSONLines(
                        chunk,
                        decoder: &lineDecoder,
                        forward: { FileHandle.standardOutput.write($0) }
                    ) {
                        onJSONLine(line)
                    }
                } else {
                    FileHandle.standardOutput.write(chunk)
                }
                if captureFinalOutput {
                    if !exceededCaptureBound,
                       chunk.count <= maximumUsageCaptureBytes - captured.count {
                        captured.append(chunk)
                    } else {
                        exceededCaptureBound = true
                        captured.removeAll(keepingCapacity: false)
                    }
                }
            }
            if let onJSONLine {
                for line in lineDecoder.finish() {
                    onJSONLine(line)
                }
            }
        }

        let outcome = waitForProcess(process)
        drain.wait()
        try? outputPipe.fileHandleForReading.close()
        let data = captureFinalOutput && !exceededCaptureBound ? captured : nil
        return CapturedProcessOutcome(outcome: outcome, standardOutput: data)
    }

    private static func waitForProcess(_ process: Process) -> ProcessOutcome {
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

    private enum ReceiptStart {
        case started(AgentRunID, delegationCapability: String)
        case unavailable
        case permissionDenied(String)
    }

    private static func beginReceipt(
        providerBasename: String,
        model: String?,
        requestedPermissionMode: AgentPermissionMode?,
        environment: [String: String]
    ) -> ReceiptStart {
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
                killSwitch: { false },
                costEstimator: AgentOrchestrationRuntime.productionCostEstimator
            )
            guard let threadUUID = UUID(
                uuidString: environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"]
                    ?? environment["RC_TOKEN_SAVER_THREAD_ID"]
                    ?? ""
            ),
                  let parentProvider = AgentProvider(rawValue: environment["REMOTE_CODE_AGENT_PROVIDER"] ?? "")
            else {
                return requestedPermissionMode == nil
                    ? .unavailable
                    : .permissionDenied("persisted parent scope is unavailable")
            }
            // Nested worker identity is the invoked provider basename; parent
            // provider stays on the env for Token Saver inheritance context.
            let nestedProvider = AgentProvider(rawValue: providerBasename) ?? parentProvider
            let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parentRunId: AgentRunID? = UUID(
                uuidString: environment["RC_REMOTE_CODE_ROOT_RUN_ID"]
                    ?? environment["RC_TOKEN_SAVER_ROOT_RUN_ID"]
                    ?? environment["RC_TOKEN_SAVER_ATTEMPT_ID"]
                    ?? ""
            ).map { AgentRunID($0) }
            if requestedPermissionMode != nil, parentRunId == nil {
                return .permissionDenied("persisted parent receipt is unavailable")
            }
            guard let parentRunId,
                  let parentCapability = environment[
                    AgentDelegationCapabilityTransport.environmentKey
                  ],
                  AgentDelegationCapabilityTransport.isWellFormed(
                    parentCapability
                  ) else {
                return .permissionDenied("persisted parent authority is unavailable")
            }
            let nodeId = ProviderProxyPolicy.makeNodeId(
                providerBasename: providerBasename,
                processIdentifier: getpid(),
                monotonicNanos: DispatchTime.now().uptimeNanoseconds
            )
            let childRunId = AgentRunID()
            let childCapability = AgentDelegationCapability.issue()
            _ = try runtime.recordAuthorizedExternalChild(
                runId: childRunId,
                threadId: AgentThreadID(threadUUID),
                provider: nestedProvider,
                // The parent instance/model describe the controller, not the
                // nested CLI. Never attribute a Codex parent instance/model to
                // a Grok or Claude child; no target-specific identity is
                // reconstructed from prompt/argv content here.
                providerInstanceId: nestedProvider.rawValue,
                model: trimmedModel?.isEmpty == false ? trimmedModel! : "unknown",
                nodeId: nodeId,
                parentRunId: parentRunId,
                parentThreadId: AgentThreadID(threadUUID),
                parentCapability: parentCapability,
                childCapability: childCapability,
                requestedPermissionMode: requestedPermissionMode
            )
            return .started(childRunId, delegationCapability: childCapability)
        } catch {
            // Explicit authority must be proven against the persisted parent.
            // Pure telemetry still fails open for an argv with no permission flag.
            return requestedPermissionMode == nil
                ? .unavailable
                : .permissionDenied("requested mode exceeds or cannot verify the persisted parent")
        }
    }

    private static var finalizationTracker = ProviderProxyFinalizationTracker()
    private static let finalizeLock = NSLock()
    private static let externalReceiptLeaseRenewalInterval: TimeInterval = 6 * 60 * 60
    private static let externalReceiptLeaseRetryInterval: TimeInterval = 60

    /// The proxy owns the provider process for its full lifetime. Keep the
    /// external receipt lease alive for unusually long workers; process exit
    /// naturally cancels any outstanding future heartbeat.
    private static func scheduleExternalReceiptLeaseRenewal(
        runId: AgentRunID,
        environment: [String: String],
        delay: TimeInterval = ProviderProxyRunner.externalReceiptLeaseRenewalInterval
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(1, delay)
        ) {
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
                _ = try runtime.renewExternalReceiptLease(
                    runId: runId,
                    ownerProcessID: ProcessInfo.processInfo.processIdentifier
                )
                scheduleExternalReceiptLeaseRenewal(
                    runId: runId,
                    environment: environment
                )
            } catch {
                scheduleExternalReceiptLeaseRenewal(
                    runId: runId,
                    environment: environment,
                    delay: externalReceiptLeaseRetryInterval
                )
            }
        }
    }

    /// Raw workers do not emit Agent App stream events, so mirror their
    /// provider-reported usage into the same local snapshot used by the
    /// sidebar. Actual tokens are always recorded; host admission controls only
    /// whether the run is eligible for paid Token Saver savings.
    @discardableResult
    private static func recordRawProviderUsage(
        delta: AssistantTokenUsage,
        session: AssistantTokenUsage,
        providerBasename: String,
        environment: [String: String],
        eligibleRunCandidate: Int
    ) -> ProviderProxyUsagePersistenceResult {
        // Actual provider usage is always-on telemetry. Paid eligibility is
        // independently revalidated at write time so disabling Token Saver
        // mid-run records tokens but never claims savings.
        let liveRuntime = validatedPaidRuntime(environment: environment)
        guard delta.totalTokens > 0,
              let provider = AgentProvider(
                rawValue: ProviderProxyPolicy.commandBasename(providerBasename)
              ),
              let controller = AgentProvider(
                rawValue: liveRuntime.environment["REMOTE_CODE_AGENT_PROVIDER"] ?? ""
              ),
              provider == controller else {
            return ProviderProxyUsagePersistenceResult(
                persisted: false,
                eligibleRunRecorded: false
            )
        }
        let appSupportDirectory: URL?
        if let override = liveRuntime.environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            appSupportDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else if let channel = bundledReleaseChannel() {
            appSupportDirectory = AppPaths.appSupportDirectory(for: channel)
        } else {
            appSupportDirectory = nil
        }
        guard let appSupportDirectory else {
            return ProviderProxyUsagePersistenceResult(
                persisted: false,
                eligibleRunRecorded: false
            )
        }
        do {
            let eligibleRuns = ProviderProxyPolicy.rawUsageEligibleRuns(
                tokenSaverAdmitted: liveRuntime.admission != nil,
                candidate: eligibleRunCandidate
            )
            _ = try TokenSaverUsageStore(appSupportDirectory: appSupportDirectory).record(
                provider: provider,
                actualProviderTokens: delta.totalTokens,
                estimatedRawTokens: delta.totalTokens,
                actualProviderBilledTokenUnits: delta.billedTotalTokenUnits,
                estimatedRawBilledTokenUnits: delta.billedTotalTokenUnits,
                eligibleRuns: eligibleRuns,
                currentSessionTokens: session.totalTokens,
                currentSessionLimitTokens: session.contextWindow
            )
            TokenSaverUsageCrossProcess.notifyStoreChanged()
            return ProviderProxyUsagePersistenceResult(
                persisted: true,
                eligibleRunRecorded: eligibleRuns > 0
            )
        } catch {
            return ProviderProxyUsagePersistenceResult(
                persisted: false,
                eligibleRunRecorded: false
            )
        }
    }

    private static func endReceiptOnce(
        runId: AgentRunID,
        status: AgentRunStatus,
        usage: AssistantTokenUsage?,
        environment: [String: String]
    ) {
        finalizeLock.lock()
        let claimed = finalizationTracker.claim(runId.value)
        finalizeLock.unlock()
        guard claimed else { return }

        var succeeded = false
        for attempt in 0..<3 {
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
                    killSwitch: { false },
                    costEstimator: AgentOrchestrationRuntime.productionCostEstimator
                )
                try runtime.finalizeReceipt(runId: runId, status: status, usage: usage)
                succeeded = true
                break
            } catch {
                if attempt < 2 { usleep(useconds_t((attempt + 1) * 10_000)) }
            }
        }
        finalizeLock.lock()
        finalizationTracker.complete(runId.value, succeeded: succeeded)
        finalizeLock.unlock()
    }
}
