import AgentRuntime
import DistillCore
import Darwin
import Foundation
import Persistence

@main
struct RemoteCodeDistillServiceMain {
    static func main() async {
        // CLI mode: invoked as `distill` (the installed symlink's basename) or with a
        // leading `cli` arg. Native Swift, fail-open — replaces the old Python CLI (N1).
        let rawArgs = CommandLine.arguments
        let programName = (rawArgs.first as NSString?)?.lastPathComponent ?? ""
        if programName == "distill" {
            await runCLI(arguments: Array(rawArgs.dropFirst()))
            return
        }
        if rawArgs.dropFirst().first == "cli" {
            await runCLI(arguments: Array(rawArgs.dropFirst(2)))
            return
        }
        if programName == "rc-retrieve-mcp" || rawArgs.dropFirst().first == "mcp" {
            await runMCP()
            return
        }

        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--help") {
                print(helpText)
                return
            }

            let configuration = try DistillServiceConfiguration.parse(arguments: arguments)
            let baseRuntime = try await runtime(for: configuration)
            // Per-call deadline + fail-open so a stalled/cold generation never blocks
            // the agent loop (N2). Warmup below pays the cold-start before we serve.
            let scheduler = DistillScheduler(
                runtime: DeadlineDistillRuntime(
                    wrapping: baseRuntime,
                    deadlineMilliseconds: configuration.mlxCallDeadlineMS
                ),
                maxConcurrentRequests: configuration.maxConcurrentRequests,
                maxQueueDepth: configuration.maxQueueDepth
            )
            // One DB connection shared by the savings ledger and the CCR store so
            // /v1/retrieve reads exactly what store-before-loss wrote (DB-path parity).
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: configuration.appSupportDirectory).run()
            let savingsRepo = TokenSaverSavingsRepository(db: db)
            let reversibleStore = SidecarReversibleStore(store: ReversibleContentStore(db: db))
            let eventWriter = DistillSidecarEventWriter()
            let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler, reversibleStore: reversibleStore, startsReady: false) { request, response in
                guard let record = DistillSavingsCalculator.record(for: request, response: response) else {
                    return
                }
                do {
                    _ = try savingsRepo.record(
                        provider: record.provider,
                        mode: record.mode,
                        inputTokens: record.inputTokens,
                        outputTokens: record.outputTokens,
                        savedTokens: record.savedTokens,
                        cacheState: record.cacheState
                    )
                    eventWriter.writeSavingsRecorded(record)
                } catch {
                    FileHandle.standardError.write(Data("RemoteCodeDistillService savings record failed: \(error)\n".utf8))
                }
            }
            let ready = try await server.start()
            // Pay the model cold-start NOW, while /readyz still reports 503, so the
            // first real agent turn never awaits a cold model. Only after warmup do
            // we flip readiness and emit the ready event the controller waits for.
            await baseRuntime.warmup()
            server.markReady()
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
        let provider = env["REMOTE_CODE_AGENT_PROVIDER"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxChars = Int(env["REMOTE_CODE_DISTILL_MAX_OUTPUT_CHARS"] ?? "") ?? 4_000
        let cli = ManagedDistillCLI(
            arguments: arguments,
            stdin: stdin,
            state: loadCLIState(),
            provider: (provider?.isEmpty == false) ? provider : nil,
            maxOutputCharacters: maxChars
        ) { request in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                return nil
            }
        }
        let (out, code) = await cli.run()
        FileHandle.standardOutput.write(out)
        Darwin.exit(code)
    }

    /// Retrieve-only MCP server (P3-T5): newline-delimited JSON-RPC 2.0 over stdio. Exposes
    /// rc_retrieve, backed by the sidecar's GET /v1/retrieve. Fail-soft: an unavailable
    /// service yields a "not found" tool result, never a crash.
    private static func runMCP() async {
        let state = loadCLIState()
        let server = ManagedRetrieveMCP { handle in
            guard let state, let url = URL(string: state.baseURL + "/v1/retrieve/\(handle)") else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["found"] as? Bool) == true else {
                return nil
            }
            return obj["original"] as? String
        }
        while let line = readLine(strippingNewline: true) {
            if let response = await server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    private static func loadCLIState() -> ManagedDistillCLI.State? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = env["REMOTE_CODE_DISTILL_STATE_PATH"], !override.isEmpty {
            // Explicit override is authoritative — do not fall through to channel paths.
            candidates = [override]
        } else {
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
            return ManagedDistillCLI.State(baseURL: baseURL, authToken: token)
        }
        return nil
    }

    private static func runtime(for configuration: DistillServiceConfiguration) async throws -> any DistillRuntime {
        if ProcessInfo.processInfo.environment["REMOTE_CODE_DISTILL_ALLOW_TEST_RUNTIME"] == "1" {
            return LocalDistillRuntime()
        }

        let appSupport = URL(fileURLWithPath: configuration.appSupportDirectory, isDirectory: true)
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupport)
        let validation = installer.validateInstalledModel()
        guard validation.state == .installed, let manifest = installer.loadManifest() else {
            throw DistillServiceError.modelValidationFailed(validation.reason)
        }
        return try await MLXDistillRuntime(modelDirectory: installer.modelStorageDirectory(revision: manifest.revision))
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
      --model-id samuelfaj/distill-1.7B-4bit-MLX
      --model-url https://huggingface.co/samuelfaj/distill-1.7B-4bit-MLX
      --max-concurrent-requests 8
      --max-queue-depth 64
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

private final class DistillSidecarEventWriter: @unchecked Sendable {
    private struct SavingsRecordedEvent: Codable {
        let event = "savings_recorded"
        let provider: String
        let mode: String
        let inputTokens: Int
        let outputTokens: Int
        let savedTokens: Int

        enum CodingKeys: String, CodingKey {
            case event
            case provider
            case mode
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case savedTokens = "saved_tokens"
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
                savedTokens: record.savedTokens
            )
            guard let data = try? self.encoder.encode(event) else { return }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
