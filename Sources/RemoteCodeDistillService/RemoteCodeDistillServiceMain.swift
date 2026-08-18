import AgentRuntime
import CoreModel
import DistillCore
import Darwin
import Foundation
import Persistence

/// Authoritative, fail-closed admission for paid `/v1/distill` work.
///
/// Inherited hints and a previously installed CLI symlink are routing aids, not
/// authority: both can outlive a toggle. The live sidecar state-file lease is
/// re-read before any short positive DB-admission cache on every request.
/// Removing the lease is the first step of controller teardown, so a process that
/// already loaded stale settings cannot submit compression while the sidecar exits.
private final class LiveTokenSaverDistillAdmission: @unchecked Sendable {
    private struct StateLease: Decodable, Equatable {
        let baseURL: String
        let authToken: String
        let pid: Int32

        enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
            case authToken = "auth_token"
            case pid
        }
    }

    private let stateURL: URL
    private let expectedBaseURL: String?
    private let expectedAuthToken: String
    private let expectedPID: Int32
    private let settingsStore: SettingsStore
    private let settingsRepository: SettingsRepository

    init?(state: ManagedDistillCLI.State?, statePath: String?) {
        guard let state,
              let statePath,
              !statePath.isEmpty else {
            return nil
        }
        let stateURL = URL(fileURLWithPath: statePath).standardizedFileURL
        guard stateURL.lastPathComponent == "DistillCLIState.json",
              stateURL.deletingLastPathComponent().lastPathComponent == "Distill",
              Self.isOwnedRegularFile(stateURL),
              let lease = Self.readLease(stateURL),
              lease.baseURL == state.baseURL,
              lease.authToken == state.authToken,
              lease.pid > 1 else {
            return nil
        }

        let appSupport = stateURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let stores = Self.makeSettingsStores(appSupport: appSupport) else {
            return nil
        }

        self.stateURL = stateURL
        self.expectedBaseURL = lease.baseURL
        self.expectedAuthToken = lease.authToken
        self.expectedPID = lease.pid
        self.settingsStore = stores.store
        self.settingsRepository = stores.repository
    }

    /// Server-side gate. The ready-state file is written by the owning app only
    /// after startup, so this initializer validates the DB now and the lease on
    /// each later request.
    init?(appSupportDirectory: String, authToken: String, pid: Int32) {
        let appSupport = URL(fileURLWithPath: appSupportDirectory).standardizedFileURL
        guard !authToken.isEmpty,
              pid > 1,
              let stores = Self.makeSettingsStores(appSupport: appSupport) else {
            return nil
        }
        self.stateURL = appSupport
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        self.expectedBaseURL = nil
        self.expectedAuthToken = authToken
        self.expectedPID = pid
        self.settingsStore = stores.store
        self.settingsRepository = stores.repository
    }

    // Short positive DB-admission cache: N MCP children call isAdmitted per tool.
    // The state-file lease is still checked before this cache on every request;
    // controller teardown removes that lease first, so toggle-off fails closed.
    private static let admissionCacheLock = NSLock()
    private static var admissionCache: (token: String, admitted: Bool, expires: Date)?

    func isAdmitted() -> Bool {
        let now = Date()
        guard Self.isOwnedRegularFile(stateURL),
              let lease = Self.readLease(stateURL),
              lease.authToken == expectedAuthToken,
              lease.pid == expectedPID,
              expectedBaseURL.map({ lease.baseURL == $0 }) ?? true,
              Self.processIsAlive(expectedPID) else {
            return false
        }
        Self.admissionCacheLock.lock()
        if let cache = Self.admissionCache,
           cache.token == expectedAuthToken,
           cache.admitted,
           cache.expires > now {
            Self.admissionCacheLock.unlock()
            return true
        }
        Self.admissionCacheLock.unlock()
        // `reload` bypasses the SettingsStore instance cache. Read errors
        // degrade to AppSettings defaults, whose Token Saver gate is OFF.
        let admitted = settingsStore.reload().tokenSaverEnabled && hasActiveSubscription()
        if admitted {
            Self.admissionCacheLock.lock()
            Self.admissionCache = (expectedAuthToken, true, now.addingTimeInterval(2))
            Self.admissionCacheLock.unlock()
        }
        return admitted
    }

    // PERF: admission re-reads DistillCLIState.json on every /v1/distill gate.
    // JSONDecoder is not thread-safe — share one under a short lock instead of
    // allocating per probe (lease wire decode unchanged).
    private static let leaseDecodeLock = NSLock()
    private static let leaseDecoder = JSONDecoder()

    private static func readLease(_ url: URL) -> StateLease? {
        guard let data = try? Data(contentsOf: url, options: [.uncached]) else {
            return nil
        }
        leaseDecodeLock.lock()
        defer { leaseDecodeLock.unlock() }
        return try? leaseDecoder.decode(StateLease.self, from: data)
    }

    private static func makeSettingsStores(
        appSupport: URL
    ) -> (store: SettingsStore, repository: SettingsRepository)? {
        let databaseURL = appSupport.appendingPathComponent("remotecode.sqlite")
        // Readonly: MCP children and admission probes must not open N writer
        // connections against the multi-GB app DB (multi-thread codex fan-out).
        guard isOwnedRegularFile(databaseURL),
              let db = try? SQLiteDB(path: databaseURL.path, readonly: true) else {
            return nil
        }
        return (SettingsStore(db: db), SettingsRepository(db: db))
    }

    private func hasActiveSubscription() -> Bool {
        guard let json = try? settingsRepository.get("private.account.session"),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = object["user"] as? [String: Any],
              user["subscribed"] as? Bool == true else {
            return false
        }
        return true
    }

    private static func isOwnedRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let owner = attributes[.ownerAccountID] as? NSNumber else {
            return false
        }
        return owner.uint32Value == getuid()
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}

@main
struct RemoteCodeDistillServiceMain {
    static func main() async {
        // CLI mode: invoked as `distill` (the installed symlink's basename) or with a
        // leading `cli` arg. Native Swift, fail-open — replaces the old Python CLI (N1).
        let rawArgs = CommandLine.arguments
        let programName = (rawArgs.first as NSString?)?.lastPathComponent ?? ""
        if programName == "distill" {
            if rawArgs.dropFirst().first == "subagent" {
                await runSubagentTelemetry(arguments: Array(rawArgs.dropFirst(2)))
                return
            }
            await runCLI(arguments: Array(rawArgs.dropFirst()))
            return
        }
        if rawArgs.dropFirst().first == "cli" {
            if rawArgs.dropFirst(2).first == "subagent" {
                await runSubagentTelemetry(arguments: Array(rawArgs.dropFirst(3)))
                return
            }
            await runCLI(arguments: Array(rawArgs.dropFirst(2)))
            return
        }
        if programName == "RemoteCodeDistillService",
           rawArgs.dropFirst().first == "subagent" {
            await runSubagentTelemetry(arguments: Array(rawArgs.dropFirst(2)))
            return
        }
        if programName == AgentSkillInstaller.agentAppMiddlewareCommand {
            let code = ProviderProxyRunner.runAgentAppCLI(
                arguments: Array(rawArgs.dropFirst())
            )
            Darwin.exit(code)
        }
        if programName == "rc-retrieve-mcp" || rawArgs.dropFirst().first == "mcp" {
            await runMCP()
            return
        }
        if programName == "rc-computer-use-mcp"
            || rawArgs.dropFirst().first == ComputerUseHostQueue.cliArgument {
            await runComputerUseMCP()
            return
        }
        if programName == "rc-bot-self-config"
            || rawArgs.dropFirst().first == BotSelfConfigCatalog.cliArgument {
            runBotSelfConfigMCP()
            return
        }
        if programName == "rc-bot-browser"
            || rawArgs.dropFirst().first == BotBrowserCatalog.cliArgument {
            runBotBrowserMCP()
            return
        }
        if programName == "rc-bot-web"
            || rawArgs.dropFirst().first == BotWebCatalog.cliArgument {
            runBotWebMCP()
            return
        }
        // Nested provider PATH controller: invoked via managed symlinks
        // (~/.remote-code/bin/{grok,claude,codex}) or explicit `provider-proxy <name> …`.
        // Records content-free Subagents receipts and execs the real CLI outside managed bin.
        // Independent of Token Saver command-compression wrappers.
        if ProviderProxyPolicy.isProviderProxy(programName) {
            let code = ProviderProxyRunner.run(command: programName, arguments: Array(rawArgs.dropFirst()))
            Darwin.exit(code)
        }
        if rawArgs.dropFirst().first == "provider-proxy", rawArgs.count >= 3 {
            let code = ProviderProxyRunner.run(command: rawArgs[2], arguments: Array(rawArgs.dropFirst(3)))
            Darwin.exit(code)
        }
        // RTK-style transparent command wrappers: invoked via a symlink whose basename is a
        // wrapped command (e.g. ~/.remote-code/bin/rg), or explicitly as `… wrap <cmd> <args>`.
        if CommandWrapPolicy.isWrapped(programName) {
            await runWrap(command: programName, arguments: Array(rawArgs.dropFirst()))
            return
        }
        if rawArgs.dropFirst().first == "wrap", rawArgs.count >= 3 {
            await runWrap(command: rawArgs[2], arguments: Array(rawArgs.dropFirst(3)))
            return
        }

        let programArguments = Array(rawArgs.dropFirst())
        // Unknown symlink basenames (node/env leftovers) must exec the real
        // binary. parse() treats `/opt/homebrew/bin/codex` as a flag name.
        guard DistillServiceLaunch.shouldStartHTTPService(
            programName: programName,
            arguments: programArguments
        ) else {
            let code = CommandWrapRunner.runPassthroughInheritingStreams(
                command: programName,
                args: programArguments
            )
            Darwin.exit(code)
        }

        do {
            if programArguments.contains("--help") {
                print(helpText)
                return
            }

            let configuration = try DistillServiceConfiguration.parse(arguments: programArguments)
            let runtimeResolution = try await runtime(for: configuration)
            let baseRuntime = runtimeResolution.runtime
            if let fallbackReason = runtimeResolution.fallbackReason {
                FileHandle.standardError.write(Data("RemoteCodeDistillService MLX runtime failed; using deterministic fallback: \(fallbackReason)\n".utf8))
            }
            // Shared metrics recorder: wired to both the HTTP server (which reads
            // it for /metrics) and to DeadlineDistillRuntime.onFallback (which
            // increments fallbackRequests on every deadline-exceeded path).
            // WHY: without this wiring fallback responses went through the success
            // path, so fallbackRequests stayed zero even when the model never warmed
            // up -- a permanently-cold model was undetectable via /metrics.
            let sharedMetrics = DistillServiceMetricsRecorder()
            // BERT-first lane (C3): a real encoder extracts the relevant lines of large
            // command output before the LLM is touched — and runs even when the LLM failed
            // to load (deterministic fallback above), so the BERT technique always
            // contributes. nil embedder => behaves exactly like the base runtime.
            let encoderRuntime = EncoderFirstRuntime(
                wrapping: baseRuntime,
                encoderLane: EncoderFirstRuntime.makeEncoderLane()
            )
            // Per-call deadline + fail-open so a stalled/cold generation never blocks
            // the agent loop (N2). Warmup below pays the cold-start before we serve.
            let scheduler = DistillScheduler(
                runtime: DeadlineDistillRuntime(
                    wrapping: encoderRuntime,
                    deadlineMilliseconds: configuration.mlxCallDeadlineMS,
                    onFallback: { await sharedMetrics.recordFallback() }
                ),
                maxConcurrentRequests: configuration.maxConcurrentRequests,
                maxQueueDepth: configuration.maxQueueDepth,
                maxQueueWaitMilliseconds: configuration.maxQueueWaitMilliseconds,
                // C5: feed per-request engine routing (deterministic / BERT / MLX) into the
                // metrics recorder so the BERT-first payoff is observable in /metrics.
                routeRecorder: { event in await sharedMetrics.recordRoute(event) }
            )
            // One DB connection shared by the savings ledger and the CCR store so
            // /v1/retrieve reads exactly what store-before-loss wrote (DB-path parity).
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: configuration.appSupportDirectory).run()
            let savingsRepo = TokenSaverSavingsRepository(db: db)
            // Unscoped CCR path: command-output store-before-loss fallback when
            // project-scoped lane retention is unavailable (projectless threads).
            let reversibleStore = SidecarReversibleStore(store: ReversibleContentStore(db: db))
            let scopedRecoveryStore = SidecarScopedRecoveryStore(
                worker: TokenSaverRuntimeRecoveryWorker(db: db),
                store: TokenSaverScopedRecoveryStore(db: db),
                appSupportDirectory: configuration.appSupportDirectory
            )
            let statsProvider = SidecarDistillStatsProvider(repository: savingsRepo)
            // Same DB as the savings ledger: forfeited-compression denial audits
            // land in token_saver_audit_events for operator visibility.
            let auditEventsRepo = TokenSaverAuditEventRepository(db: db)
            let eventWriter = DistillSidecarEventWriter()
            let liveDistillAdmission = LiveTokenSaverDistillAdmission(
                appSupportDirectory: configuration.appSupportDirectory,
                authToken: configuration.authToken,
                pid: getpid()
            )
            // Shared fail-open persist for DistillSavingsRecord (success + forfeit).
            // Persistence errors must never block or crash the HTTP response path.
            let persistSavings: DistillHTTPServer.SavingsRecordHandler = { record in
                do {
                    _ = try savingsRepo.record(
                        provider: record.provider,
                        mode: record.mode,
                        inputTokens: record.inputTokens,
                        outputTokens: record.outputTokens,
                        savedTokens: record.savedTokens,
                        cacheState: record.cacheState,
                        contentType: "unknown",
                        engine: record.routeStage?.rawValue ?? "unknown",
                        attributability: record.attributability,
                        delivered: record.delivered,
                        threadID: record.threadID
                    )
                } catch {
                    FileHandle.standardError.write(Data("RemoteCodeDistillService savings record failed: \(error)\n".utf8))
                }
            }
            let server = DistillHTTPServer(
                configuration: configuration,
                scheduler: scheduler,
                reversibleStore: reversibleStore,
                scopedRecoveryStore: scopedRecoveryStore,
                statsProvider: statsProvider,
                startsReady: false,
                metricsRecorder: sharedMetrics,
                onSuccess: { request, response, threadID in
                    guard let record = DistillSavingsCalculator.record(
                        for: request,
                        response: response,
                        threadID: threadID
                    ) else {
                        return
                    }
                    await persistSavings(record)
                    eventWriter.writeSavingsRecorded(record)
                },
                // WHY: DistillCore emitForfeitedCompression only fires these optional
                // seams. Without them, delivered=0 forfeit rows and token_saver_denial
                // audits exist only in unit tests — production operators see nothing.
                onSavingsRecord: { record in
                    await persistSavings(record)
                },
                onAuditEvent: { eventKind, reason, countValue in
                    do {
                        try auditEventsRepo.append(
                            eventKind: eventKind,
                            countValue: countValue,
                            reason: reason
                        )
                    } catch {
                        FileHandle.standardError.write(Data("RemoteCodeDistillService audit event failed: \(error)\n".utf8))
                    }
                },
                distillAdmission: { liveDistillAdmission?.isAdmitted() == true }
            )
            let ready = try await server.start()
            // Pay the model cold-start NOW, while /readyz still reports 503, so the
            // first real agent turn never awaits a cold model. Only after warmup do
            // we flip readiness and emit the ready event the controller waits for.
            // If warmup fails, skip markReady() so /readyz stays 503 and the
            // controller sees a degraded service rather than a falsely-ready one.
            do {
                // Warm both the encoder lane and the base runtime before readiness.
                try await encoderRuntime.warmup()
                server.markReady()
            } catch {
                FileHandle.standardError.write(Data("RemoteCodeDistillService warmup failed (service degraded, /readyz will stay 503): \(error)\n".utf8))
            }
            let encoder = JSONEncoder()
            let payload = try encoder.encode(ready)
            FileHandle.standardOutput.write(payload)
            FileHandle.standardOutput.write(Data("\n".utf8))

            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            server.stop()
        } catch {
            FileHandle.standardError.write(Data("RemoteCodeDistillService failed: \(error)\n".utf8))
            Darwin.exit(2)
        }
    }

    private static func runCLI(arguments: [String]) async {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let env = ProcessInfo.processInfo.environment
        let recoveryContext = ManagedDistillCLI.recoveryContext(environment: env)
        let provider = ManagedDistillCLI.resolveProvider(
            explicit: env["REMOTE_CODE_AGENT_PROVIDER"],
            recoveryProvider: recoveryContext?.provider
        )
        let maxChars = Int(env["REMOTE_CODE_DISTILL_MAX_OUTPUT_CHARS"] ?? "") ?? 4_000
        let session = createConfiguredURLSession()
        let loadedState = loadCLIStateSnapshot()
        let admission = LiveTokenSaverDistillAdmission(
            state: loadedState?.state,
            statePath: loadedState?.path
        )
        let cli = ManagedDistillCLI(
            arguments: arguments,
            stdin: stdin,
            state: loadedState?.state,
            provider: provider,
            recoveryContext: recoveryContext,
            maxOutputCharacters: maxChars,
            distillAdmission: { admission?.isAdmitted() == true }
        ) { request in
            guard admission?.isAdmitted() == true else { return nil }
            do {
                var scopedRequest = request
                applyRecoveryHeaders(to: &scopedRequest, environment: env)
                let (data, response) = try await session.data(for: scopedRequest)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                return nil
            }
        }
        // Flush stdout before any deferred Wave A ledger POST so the pipe
        // consumer never waits on the sidecar RTT for already-compressed bytes.
        let result = await cli.runResult()
        FileHandle.standardOutput.write(result.stdout)
        try? FileHandle.standardOutput.synchronize()
        if let deferred = result.deferredSideEffect {
            await deferred()
        }
        Darwin.exit(result.exitCode)
    }

    /// Provider-neutral begin/end bridge for skill-controlled nested workers
    /// that are **not** a bare `grok`/`claude`/`codex` shell invocation.
    /// Nested provider CLIs are handled automatically by the PATH provider
    /// proxy (`ProviderProxyRunner`); skills should not wrap those basenames
    /// manually. This CLI still records metadata only — prompts, output, and
    /// secrets never enter the orchestration ledger.
    private static func runSubagentTelemetry(arguments: [String]) async {
        let env = ProcessInfo.processInfo.environment
        let appSupportOverride = env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]
        do {
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
            guard let operation = arguments.first else { throw TelemetryError.usage }
            switch operation {
            case "begin":
                let nodeId = try argument(named: "--node", in: arguments)
                guard let scope = RemoteCodeSubagentTelemetryScope(environment: env),
                      let provider = AgentProvider(rawValue: env["REMOTE_CODE_AGENT_PROVIDER"] ?? ""),
                      let parentRunId = scope.parentRunId,
                      let parentThreadId = scope.parentThreadId,
                      let parentCapability = scope.parentCapability else {
                    throw TelemetryError.missingScope
                }
                let finalizationCapability = AgentDelegationCapability.issue()
                let child = try runtime.recordAuthenticatedTelemetryChild(
                    runId: AgentRunID(),
                    threadId: scope.threadId,
                    provider: provider,
                    providerInstanceId: env["REMOTE_CODE_PROVIDER_INSTANCE_ID"] ?? provider.rawValue,
                    model: env["REMOTE_CODE_AGENT_MODEL"] ?? "unknown",
                    nodeId: nodeId,
                    parentRunId: parentRunId,
                    parentThreadId: parentThreadId,
                    parentCapability: parentCapability,
                    finalizationCapability: finalizationCapability,
                    ownerProcessID: getppid() > 1 ? getppid() : getpid()
                )
                guard let childRunId = child.runId,
                      let handle = AgentExternalReceiptHandle.encode(
                        runId: childRunId,
                        finalizationCapability: finalizationCapability
                      ) else {
                    throw TelemetryError.invalidReceipt
                }
                print(handle)
            case "end":
                guard let handle = AgentExternalReceiptHandle.decode(
                    try argument(named: "--run-id", in: arguments)
                ) else {
                    throw TelemetryError.usage
                }
                guard let scope = RemoteCodeSubagentTelemetryScope(environment: env),
                      let parentRunId = scope.parentRunId,
                      let parentThreadId = scope.parentThreadId,
                      let parentCapability = scope.parentCapability else {
                    throw TelemetryError.missingScope
                }
                guard let status = AgentRunStatus(
                    rawValue: try argument(named: "--status", in: arguments)
                ), [.completed, .failed, .cancelled].contains(status) else {
                    throw TelemetryError.usage
                }
                try runtime.finalizeAuthenticatedExternalReceipt(
                    runId: handle.runId,
                    status: status,
                    parentRunId: parentRunId,
                    parentThreadId: parentThreadId,
                    parentCapability: parentCapability,
                    finalizationCapability: handle.finalizationCapability,
                    ownerProcessID: getppid() > 1 ? getppid() : getpid()
                )
            default:
                throw TelemetryError.usage
            }
        } catch {
            FileHandle.standardError.write(Data("RemoteCode subagent telemetry unavailable: \(error)\n".utf8))
            Darwin.exit(1)
        }
        Darwin.exit(0)
    }

    private static func argument(named name: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            throw TelemetryError.usage
        }
        return arguments[index + 1]
    }

    private enum TelemetryError: Error {
        case usage
        case missingScope
        case invalidReceipt
    }

    /// Transparent command-wrapper mode (RTK port). Runs the real command, and when this wrapper
    /// is the terminal command feeding the agent, compresses its stdout via the resident sidecar
    /// (reversible — a `[[rc:<handle>]]` marker lets the agent recover the exact bytes). Always
    /// exits with the REAL command's status. Fail-open throughout: any failure passes the raw
    /// output through unchanged so a command's output is never lost or corrupted.
    ///
    /// Stdout is written inside `CommandWrapRunner.run` before any deferred Wave A ledger POST
    /// (mirrors `runCLI`: deliver bytes first, then await the side effect).
    private static func runWrap(command: String, arguments: [String]) async {
        let session = createConfiguredURLSession()
        let (exitCode, deferred) = await CommandWrapRunner.run(command: command, args: arguments) { captured, query, storeFloorBytes in
            let env = ProcessInfo.processInfo.environment
            let recoveryContext = ManagedDistillCLI.recoveryContext(environment: env)
            let provider = ManagedDistillCLI.resolveProvider(
                explicit: env["REMOTE_CODE_AGENT_PROVIDER"],
                recoveryProvider: recoveryContext?.provider
            )
            let maxChars = Int(env["REMOTE_CODE_DISTILL_MAX_OUTPUT_CHARS"] ?? "") ?? 4_000
            let loadedState = loadCLIStateSnapshot()
            let admission = LiveTokenSaverDistillAdmission(
                state: loadedState?.state,
                statePath: loadedState?.path
            )
            // Per-command extraction query: nil (no question → deterministic router) for
            // search/listings; a neutral extractive query for cat/sed so the service routes to its
            // BERT lane (verbatim line selection) instead of the misfiring intent extractor.
            let cli = ManagedDistillCLI(
                arguments: query.map { [$0] } ?? [],
                stdin: captured,
                state: loadedState?.state,
                provider: provider,
                recoveryContext: recoveryContext,
                maxOutputCharacters: maxChars,
                reversibleStoreMinBytes: storeFloorBytes,
                distillAdmission: { admission?.isAdmitted() == true }
            ) { request in
                guard admission?.isAdmitted() == true else { return nil }
                do {
                    var scopedRequest = request
                    applyRecoveryHeaders(to: &scopedRequest, environment: env)
                    let (data, response) = try await session.data(for: scopedRequest)
                    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
                } catch {
                    return nil
                }
            }
            // runResult (not run): keep Wave A ledger POST deferred until after stdout is written.
            let result = await cli.runResult()
            // compress() is fail-open: code 0 carries either the compressed text (+handle) or, on
            // any sidecar failure, the raw bytes verbatim. A non-zero code is the oversize-input
            // rejection — fall back to the captured bytes rather than emitting that error.
            guard result.exitCode == 0 else { return nil }
            return (result.stdout, result.deferredSideEffect)
        }
        if let deferred {
            await deferred()
        }
        Darwin.exit(exitCode)
    }

    // PERF: MCP stats/compress (and concurrent tool calls) allocated
    // JSONDecoder/JSONEncoder per request. Share process-wide codecs under a
    // short lock; sortedKeys on compress bodies keeps recovery operation
    // digests identical to the prior per-call encoder.
    private static let mcpCodecLock = NSLock()
    private static let mcpDecoder = JSONDecoder()
    private static let mcpSortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Token Saver MCP server (P3-T5): newline-delimited JSON-RPC 2.0 over stdio.
    /// Exposes retrieve/search/stats plus gated rc_compress through the local sidecar.
    /// Fail-soft: an unavailable service yields an MCP error result, never a crash.
    private static func runMCP() async {
        let loadedState = loadCLIStateSnapshot()
        let state = loadedState?.state
        let admission = LiveTokenSaverDistillAdmission(
            state: state,
            statePath: loadedState?.path
        )
        let session = createConfiguredURLSession()
        let environment = ProcessInfo.processInfo.environment
        let server = ManagedRetrieveMCP(
            retrieve: { handle in
                guard let state, let url = URL(string: state.baseURL + "/v1/retrieve/\(handle)") else { return nil }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
                applyRecoveryHeaders(to: &request, environment: environment)
                request.setValue(ManagedDistillCLI.recoveryOperationID(kind: "retrieve", canonicalPayload: Data(handle.utf8)), forHTTPHeaderField: "X-RemoteCode-Operation-ID")
                guard let (data, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["found"] as? Bool) == true else {
                    return nil
                }
                return obj["original"] as? String
            },
            stats: {
                guard let state, let url = URL(string: state.baseURL + "/v1/stats") else { return nil }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
                guard let (data, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return nil
                }
                mcpCodecLock.lock()
                defer { mcpCodecLock.unlock() }
                return try? mcpDecoder.decode(DistillStatsSnapshot.self, from: data)
            },
            compress: { distillRequest in
                guard admission?.isAdmitted() == true else { return nil }
                guard let state, let url = URL(string: state.baseURL + "/v1/distill") else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                applyRecoveryHeaders(to: &request, environment: environment)
                mcpCodecLock.lock()
                request.httpBody = try? mcpSortedEncoder.encode(distillRequest)
                mcpCodecLock.unlock()
                if let body = request.httpBody {
                    request.setValue(distillRequest.id.uuidString.lowercased(), forHTTPHeaderField: "X-RemoteCode-Invocation-ID")
                    request.setValue(ManagedDistillCLI.recoveryOperationID(kind: "distill", canonicalPayload: body), forHTTPHeaderField: "X-RemoteCode-Operation-ID")
                }
                guard admission?.isAdmitted() == true else { return nil }
                guard let (data, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return nil
                }
                mcpCodecLock.lock()
                defer { mcpCodecLock.unlock() }
                return try? mcpDecoder.decode(DistillResponse.self, from: data)
            },
            scopedRecoveryAvailable: hasCompleteRecoveryScope(environment: environment)
        )
        while let line = readLine(strippingNewline: true) {
            if let response = await server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    /// RemoteCode-owned computer-use MCP (stdio). HID calls share ComputerUseHostQueue.
    private static func runComputerUseMCP() async {
        let server = ManagedComputerUseMCP()
        while let line = readLine(strippingNewline: true) {
            if let response = await server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    /// Bot-owned Studio settings. Bound to RC_REMOTE_CODE_BOT_ID on the calling run.
    private static func runBotSelfConfigMCP() {
        let server = ManagedBotSelfConfigMCP()
        while let line = readLine(strippingNewline: true) {
            if let response = server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    private static func runBotBrowserMCP() {
        let server = ManagedBotBrowserMCP()
        while let line = readLine(strippingNewline: true) {
            if let response = server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    private static func runBotWebMCP() {
        let server = ManagedBotWebMCP()
        while let line = readLine(strippingNewline: true) {
            if let response = server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    private static func createConfiguredURLSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }

    private static func applyRecoveryHeaders(to request: inout URLRequest, environment: [String: String]) {
        let mappings = [
            ("RC_TOKEN_SAVER_WORKSPACE_ID", "X-RemoteCode-Workspace-ID"),
            ("RC_TOKEN_SAVER_PROJECT_ID", "X-RemoteCode-Project-ID"),
            ("RC_TOKEN_SAVER_THREAD_ID", "X-RemoteCode-Thread-ID"),
            ("REMOTE_CODE_AGENT_PROVIDER", "X-RemoteCode-Provider"),
            ("RC_TOKEN_SAVER_ATTEMPT_ID", "X-RemoteCode-Attempt-ID"),
        ]
        for (environmentKey, header) in mappings {
            guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            request.setValue(value, forHTTPHeaderField: header)
        }
    }

    private static func hasCompleteRecoveryScope(environment: [String: String]) -> Bool {
        [
            "RC_TOKEN_SAVER_WORKSPACE_ID",
            "RC_TOKEN_SAVER_PROJECT_ID",
            "RC_TOKEN_SAVER_THREAD_ID",
            "REMOTE_CODE_AGENT_PROVIDER",
            "RC_TOKEN_SAVER_ATTEMPT_ID",
        ].allSatisfy {
            environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private struct LoadedCLIState {
        let state: ManagedDistillCLI.State
        let path: String
    }

    private static func loadCLIStateSnapshot() -> LoadedCLIState? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = env["REMOTE_CODE_DISTILL_STATE_PATH"], !override.isEmpty {
            // Explicit override is authoritative — do not fall through to channel paths.
            candidates = [override]
        } else {
            if let appSupport = env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !appSupport.isEmpty {
                candidates.append(
                    URL(fileURLWithPath: appSupport, isDirectory: true)
                        .appendingPathComponent("Distill", isDirectory: true)
                        .appendingPathComponent("DistillCLIState.json")
                        .path
                )
            }
            for channel in [ReleaseChannel.stable, .canary, .debug] {
                candidates.append(
                    AppPaths.appSupportDirectory(for: channel)
                        .appendingPathComponent("Distill", isDirectory: true)
                        .appendingPathComponent("DistillCLIState.json")
                        .path
                )
            }
        }
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let baseURL = obj["base_url"] as? String,
                  let token = obj["auth_token"] as? String,
                  !baseURL.isEmpty, !token.isEmpty else {
                continue
            }
            return LoadedCLIState(
                state: ManagedDistillCLI.State(baseURL: baseURL, authToken: token),
                path: path
            )
        }
        return nil
    }

    private struct RuntimeResolution {
        let runtime: any DistillRuntime
        let fallbackReason: String?
    }

    private static func runtime(for configuration: DistillServiceConfiguration) async throws -> RuntimeResolution {
        if ProcessInfo.processInfo.environment["REMOTE_CODE_DISTILL_ALLOW_TEST_RUNTIME"] == "1" {
            return RuntimeResolution(runtime: LocalDistillRuntime(), fallbackReason: nil)
        }

        let appSupport = URL(fileURLWithPath: configuration.appSupportDirectory, isDirectory: true)
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupport)
        let validation = installer.validateInstalledTokenSaverModels()
        guard validation.state == .installed, let manifest = installer.loadManifest() else {
            throw DistillServiceError.modelValidationFailed(validation.reason)
        }
        do {
            return RuntimeResolution(
                runtime: try await MLXDistillRuntime(modelDirectory: installer.modelStorageDirectory(modelID: manifest.modelID, revision: manifest.revision)),
                fallbackReason: nil
            )
        } catch {
            return RuntimeResolution(runtime: LocalDistillRuntime(), fallbackReason: String(describing: error))
        }
    }

    private static let helpText = """
    RemoteCodeDistillService

    Required:
      --auth-token <token>
      --app-support-dir <path>

    Optional:
      --host 127.0.0.1
      --port 0
      --runtime mlx
      --model-id \(DistillApprovedModel.id)
      --model-url \(DistillApprovedModel.url)
      --max-concurrent-requests 8
      --max-queue-depth 64
      --max-queue-wait-ms 1500
      --idle-timeout-ms 300000
    """
}

/// Adapts the Persistence `ReversibleContentStore` to DistillCore's injected
/// `ReversibleStoring` protocol, keeping DistillCore free of a Persistence dependency.
private struct SidecarReversibleStore: ReversibleStoring {
    let store: ReversibleContentStore
    func storeOriginal(_ data: Data) throws -> String { try store.store(data) }
    func retrieveOriginal(_ handle: String) throws -> Data? { try store.retrieve(handle) }
}

private struct SidecarScopedRecoveryStore: TokenSaverScopedRecoveryStoring {
    let worker: TokenSaverRuntimeRecoveryWorker
    let store: TokenSaverScopedRecoveryStore
    let appSupportDirectory: String

    func lookupInvocation(context: TokenSaverRecoveryRequestContext) throws -> TokenSaverScopedInvocationState? {
        guard let state = try worker.invocationState(
            scope: scope(context),
            invocationID: context.invocationID,
            operationID: context.operationID
        ) else { return nil }
        return .init(
            state: TokenSaverScopedRecoveryState(rawValue: state.state.rawValue) ?? .acked,
            transportOutcome: TokenSaverScopedDeliveryOutcome(rawValue: state.transportOutcome.rawValue) ?? .acked
        )
    }

    func prepareOriginal(_ data: Data, context: TokenSaverRecoveryRequestContext, lane: String) throws -> TokenSaverScopedPreparation {
        let prepared = try worker.prepareOriginal(
            data,
            scope: scope(context),
            operationID: context.operationID,
            invocationID: context.invocationID,
            lane: lane,
            expiresAt: nil,
            disk: try diskSnapshot()
        )
        return .init(
            capability: prepared.capability,
            idempotencyKey: prepared.idempotencyKey,
            readBackVerified: prepared.readBackVerified
        )
    }

    func retrieveOriginal(capability: String, context: TokenSaverRecoveryRequestContext) throws -> Data? {
        try store.retrieve(capability: capability, scope: scope(context))
    }

    func markDelivered(capability: String, idempotencyKey: String, context: TokenSaverRecoveryRequestContext, outcome: TokenSaverScopedDeliveryOutcome) throws -> Bool {
        let mapped = TokenSaverRecoveryTransportOutcome(rawValue: outcome.rawValue) ?? .failed
        return try store.markDelivered(
            capability: capability,
            scope: scope(context),
            idempotencyKey: idempotencyKey,
            outcome: mapped
        )
    }

    func ack(capability: String, idempotencyKey: String, context: TokenSaverRecoveryRequestContext) throws -> Bool {
        try store.ack(capability: capability, scope: scope(context), idempotencyKey: idempotencyKey)
    }

    private func scope(_ context: TokenSaverRecoveryRequestContext) -> TokenSaverPersistentScope {
        .init(
            workspaceID: context.workspaceID,
            projectID: context.projectID,
            threadID: context.threadID,
            provider: context.provider,
            attemptID: context.attemptID
        )
    }

    private func diskSnapshot() throws -> TokenSaverRecoveryDiskSnapshot {
        let values = try URL(fileURLWithPath: appSupportDirectory).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        return .init(
            freeBytes: values.volumeAvailableCapacityForImportantUsage ?? 0,
            totalBytes: Int64(values.volumeTotalCapacity ?? 0)
        )
    }
}

private struct SidecarDistillStatsProvider: DistillStatsProviding {
    let repository: TokenSaverSavingsRepository

    func statsSnapshot() throws -> DistillStatsSnapshot {
        let summary = try repository.summary()
        return DistillStatsSnapshot(
            totalSavedTokens: summary.totalSavedTokens,
            totalRuns: summary.totalRuns,
            providers: summary.providers.map {
                DistillStatsProviderSavings(
                    provider: $0.provider,
                    savedTokens: $0.savedTokens,
                    inputTokens: $0.inputTokens,
                    outputTokens: $0.outputTokens,
                    runs: $0.runs
                )
            },
            modes: summary.modes.map {
                DistillStatsModeSavings(
                    provider: $0.provider,
                    mode: $0.mode,
                    savedTokens: $0.savedTokens,
                    runs: $0.runs
                )
            }
        )
    }
}

private final class DistillSidecarEventWriter: @unchecked Sendable {
    private struct SavingsRecordedEvent: Codable {
        let event = "savings_recorded"
        let provider: String
        let mode: String
        let inputTokens: Int
        let outputTokens: Int
        let savedTokens: Int
        let threadID: String

        enum CodingKeys: String, CodingKey {
            case event
            case provider
            case mode
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case savedTokens = "saved_tokens"
            case threadID = "thread_id"
        }
    }

    private let queue = DispatchQueue(label: "io.remotecode.distill.sidecar.events")
    private let encoder = JSONEncoder()

    func writeSavingsRecorded(_ record: DistillSavingsRecord) {
        queue.async {
            let event = SavingsRecordedEvent(
                provider: record.provider,
                mode: record.mode,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                savedTokens: record.savedTokens,
                threadID: record.threadID
            )
            guard let data = try? self.encoder.encode(event) else { return }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
