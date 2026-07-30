import Foundation
import CryptoKit
import CoreModel

/// Core logic of the managed `distill` CLI, ported off Python to native Swift (N1)
/// and made FAIL-OPEN (N2/N5). The shipped Python CLI failed CLOSED: on any error it
/// wrote stderr + `sys.exit(code)` with EMPTY stdout — but `cmd | distill` had already
/// consumed the original via the pipe, so the tool output was lost unrecoverably.
///
/// This never loses data: in compress mode, on ANY failure (no state, transport error,
/// non-200, empty output) it writes the buffered raw stdin verbatim to stdout and exits 0.
/// On success it emits the compressed output, plus a `[[rc:<handle>]]` marker when the
/// sidecar stored the original (so the agent can recover it via `distill retrieve`).
///
/// Transport is injected so the logic is unit-testable without a network; the executable
/// wires a real URLSession transport.
public struct ManagedDistillCLI: Sendable {
    public typealias Transport = @Sendable (URLRequest) async -> (data: Data, status: Int)?
    /// Live paid-feature admission. The executable wires this to the authoritative
    /// app setting plus the current sidecar lease; it is deliberately independent
    /// of inherited environment hints, which can outlive a toggle or app teardown.
    ///
    /// This is re-evaluated before every lossy/local optimization and immediately
    /// before every `/v1/distill` transport call. A denial always returns the
    /// original stdin bytes and never calls the transport.
    public typealias DistillAdmission = @Sendable () -> Bool

    /// Per-request stdin chunk size. Inputs above this are split into multiple bounded
    /// distill calls; if any chunk fails, the CLI emits the original stdin verbatim.
    public static let stdinCapBytes: Int = 512 * 1_024

    /// Pure seam: returns true when `byteCount` exceeds `cap`. Extracted so tests can
    /// verify cap logic without constructing a full CLI instance or any I/O.
    public static func exceedsStdinCap(byteCount: Int, cap: Int) -> Bool {
        byteCount > cap
    }

    /// Stable per-request mutation identity. The caller supplies canonical bytes
    /// (sorted-key JSON for distill requests); retries reuse the identity while
    /// distinct requests in one provider attempt cannot collide accidentally.
    public static func recoveryOperationID(kind: String, canonicalPayload: Data) -> String {
        let stablePayload: Data
        if kind == "distill",
           var object = (try? JSONSerialization.jsonObject(with: canonicalPayload)) as? [String: Any] {
            object.removeValue(forKey: "id")
            stablePayload = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? canonicalPayload
        } else {
            stablePayload = canonicalPayload
        }
        var material = Data()
        let kindData = Data(kind.utf8)
        material.append(Data("\(kindData.count):".utf8))
        material.append(kindData)
        material.append(Data("|\(stablePayload.count):".utf8))
        material.append(stablePayload)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return "tscli1.\(digest)"
    }

    public struct State: Sendable, Equatable {
        public let baseURL: String
        public let authToken: String
        public init(baseURL: String, authToken: String) {
            self.baseURL = baseURL
            self.authToken = authToken
        }
    }

    public let arguments: [String]
    public let stdin: Data
    public let state: State?
    public let provider: String?
    public let recoveryContext: TokenSaverRecoveryRequestContext?
    /// Unique logical invocation identity. Reusing one CLI value for a transport
    /// retry preserves idempotency; a new CLI invocation always gets a new value.
    public let invocationID: String
    public let maxOutputCharacters: Int
    /// Per-request reversible-store floor (nil = server default). The RTK command wrappers set
    /// a low value so compressed output always carries a `[[rc:<handle>]]` recovery marker.
    public let reversibleStoreMinBytes: Int?
    public let distillAdmission: DistillAdmission
    public let transport: Transport

    public init(
        arguments: [String],
        stdin: Data,
        state: State?,
        provider: String? = nil,
        recoveryContext: TokenSaverRecoveryRequestContext? = nil,
        invocationID: String = UUID().uuidString.lowercased(),
        maxOutputCharacters: Int = 4_000,
        reversibleStoreMinBytes: Int? = nil,
        distillAdmission: @escaping DistillAdmission = { true },
        transport: @escaping Transport
    ) {
        self.arguments = arguments
        self.stdin = stdin
        self.state = state
        // Prefer explicit provider, then recovery-scope provider, so savings land
        // on claude/codex/grok instead of "unknown" when only headers are set.
        let recoveryProvider = recoveryContext?.provider
        self.provider = Self.resolveProvider(explicit: provider, recoveryProvider: recoveryProvider)
        self.recoveryContext = recoveryContext?.hasCompleteScope == true ? recoveryContext : nil
        self.invocationID = invocationID
        self.maxOutputCharacters = max(128, maxOutputCharacters)
        self.reversibleStoreMinBytes = reversibleStoreMinBytes
        self.distillAdmission = distillAdmission
        self.transport = transport
    }

    /// Pure seam: coalesce CLI env provider with recovery-scope provider.
    /// Empty / whitespace-only values are treated as missing.
    public static func resolveProvider(explicit: String?, recoveryProvider: String?) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let recoveryProvider = recoveryProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recoveryProvider.isEmpty {
            return recoveryProvider
        }
        return nil
    }

    public func run() async -> (stdout: Data, exitCode: Int32) {
        if arguments.first == "retrieve" {
            return await retrieve(handle: arguments.dropFirst().first ?? "")
        }
        if arguments.first == "stats" {
            return await stats()
        }
        if arguments.first == "dsl" {
            return dsl(arguments: Array(arguments.dropFirst()))
        }
        // task-07: `hook` is reserved before any prompt parsing / generic compress path.
        if let command = arguments.first,
           TokenSaverProtocolV2.routeCLISubcommand(command) == "hook_handler"
            || Self.reservedSubcommands.contains(command) {
            return unsupportedReservedSubcommand(command)
        }
        let prompt = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return await compress(prompt: prompt)
    }

    private static let reservedSubcommands: Set<String> = [
        "rank",
        "wrap",
        TokenSaverProtocolV2.reservedHookSubcommand
    ]

    private func unsupportedReservedSubcommand(_ command: String) -> (Data, Int32) {
        let message = "distill \(command): reserved subcommand is not implemented by this managed CLI\n"
        return (Data(message.utf8), 1)
    }

    private func dsl(arguments: [String]) -> (Data, Int32) {
        guard arguments.first == "learn-thread",
              arguments.dropFirst().contains("--stdin") else {
            return (Data("distill dsl: reserved subcommand is not implemented by this managed CLI\n".utf8), 1)
        }
        guard !stdin.isEmpty else {
            return (Data("distill dsl learn-thread: no transcript on stdin\n".utf8), 1)
        }
        let message = "distill dsl learn-thread: accepted \(stdin.count) bytes\n"
        return (Data(message.utf8), 0)
    }

    // MARK: - compress (fail-open)

    private func compress(prompt: String) async -> (Data, Int32) {
        // Fail-open: hand back exactly what was piped in. exit 0 so the agent never
        // sees an error in place of its tool output.
        func failOpen() -> (Data, Int32) { (stdin, 0) }

        guard !stdin.isEmpty else { return (Data(), 0) }
        guard distillAdmission() else { return failOpen() }
        guard let input = String(data: stdin, encoding: .utf8) else { return failOpen() }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return failOpen() }

        // Live Wave A/B lossless pre-pass: shrink before (or without) the sidecar.
        // Only when Token Saver env is present (hint) so free builds never save tokens.
        let tokenSaverHintOn = ProcessInfo.processInfo.environment["RC_TOKEN_SAVER_DISTILL_HINT"] == "1"
            || ProcessInfo.processInfo.environment["RC_TOKEN_SAVER_WAVE_LIVE"] != nil
        if tokenSaverHintOn,
           let pre = TokenSaverWaveLosslessPrepass.apply(input: input, toolHint: prompt) {
            guard distillAdmission() else { return failOpen() }
            FileHandle.standardError.write(Data(
                "rc-wave-prepass wave=\(pre.waveID) trigger=\(pre.trigger) saved_bytes=\(pre.savedBytes) frac=\(String(format: "%.3f", pre.savedFraction))\n".utf8
            ))
            return (Data((pre.output + "\n").utf8), 0)
        }

        if ManagedDistillCLI.exceedsStdinCap(byteCount: stdin.count, cap: ManagedDistillCLI.stdinCapBytes) {
            return await compressChunks(input: input, prompt: prompt)
        }
        guard let state, let url = URL(string: state.baseURL + "/v1/distill") else { return failOpen() }

        let request = DistillRequest(
            mode: .commandOutput,
            priority: .agent,
            input: input,
            question: prompt.isEmpty ? nil : prompt,
            provider: provider,
            recordSavings: true,
            maxOutputCharacters: maxOutputCharacters,
            reversibleStoreMinBytes: reversibleStoreMinBytes
        )
        guard let body = Self.canonicalBody(request) else { return failOpen() }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyRecoveryScope(to: &urlRequest)
        urlRequest.setValue(invocationID, forHTTPHeaderField: "X-RemoteCode-Invocation-ID")
        urlRequest.setValue(Self.recoveryOperationID(kind: "distill", canonicalPayload: body), forHTTPHeaderField: "X-RemoteCode-Operation-ID")
        urlRequest.httpBody = body

        guard distillAdmission() else { return failOpen() }
        guard let (data, status) = await transport(urlRequest), status == 200,
              let response = try? JSONDecoder().decode(DistillResponse.self, from: data),
              !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failOpen()
        }
        guard response.routeStage != .verbatim else { return failOpen() }
        var out = response.output
        if let handle = response.originalHandle, !handle.isEmpty {
            out += "\n[[rc:\(handle)]]"
        }
        return (Data((out + "\n").utf8), 0)
    }

    private func compressChunks(input: String, prompt: String) async -> (Data, Int32) {
        func failOpen() -> (Data, Int32) { (stdin, 0) }
        guard let state, let url = URL(string: state.baseURL + "/v1/distill") else { return failOpen() }
        let chunks = Self.utf8Chunks(input, maxBytes: Self.stdinCapBytes)
        guard chunks.count > 1 else { return failOpen() }

        var emitted: [String] = []
        emitted.reserveCapacity(chunks.count)
        for (offset, chunk) in chunks.enumerated() {
            let question = Self.chunkQuestion(prompt: prompt, index: offset + 1, count: chunks.count)
            let request = DistillRequest(
                mode: .commandOutput,
                priority: .agent,
                input: chunk,
                question: question,
                provider: provider,
                recordSavings: true,
                maxOutputCharacters: maxOutputCharacters,
                reversibleStoreMinBytes: reversibleStoreMinBytes
            )
            guard let body = Self.canonicalBody(request) else { return failOpen() }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyRecoveryScope(to: &urlRequest)
            urlRequest.setValue("\(invocationID).chunk-\(offset + 1)", forHTTPHeaderField: "X-RemoteCode-Invocation-ID")
            urlRequest.setValue(Self.recoveryOperationID(kind: "distill", canonicalPayload: body), forHTTPHeaderField: "X-RemoteCode-Operation-ID")
            urlRequest.httpBody = body

            guard distillAdmission() else { return failOpen() }
            guard let (data, status) = await transport(urlRequest), status == 200,
                  let response = try? JSONDecoder().decode(DistillResponse.self, from: data),
                  !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failOpen()
            }
            guard response.routeStage != .verbatim else { return failOpen() }
            var out = response.output
            if let handle = response.originalHandle, !handle.isEmpty {
                out += "\n[[rc:\(handle)]]"
            }
            emitted.append(out)
        }
        return (Data((emitted.joined(separator: "\n\n") + "\n").utf8), 0)
    }

    static func utf8Chunks(_ input: String, maxBytes: Int) -> [String] {
        guard input.utf8.count > maxBytes, maxBytes > 0 else { return [input] }
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        for character in input {
            let text = String(character)
            let bytes = text.utf8.count
            if currentBytes > 0, currentBytes + bytes > maxBytes {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            if bytes > maxBytes {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                    currentBytes = 0
                }
                chunks.append(text)
            } else {
                current.append(character)
                currentBytes += bytes
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func chunkQuestion(prompt: String, index: Int, count: Int) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "Chunk \(index)/\(count): preserve local errors, paths, identifiers, numbers, and retrieve-worthy details."
        return trimmed.isEmpty ? suffix : "\(trimmed)\n\(suffix)"
    }

    // MARK: - retrieve (no stdin to preserve → exit 1 on miss)

    private func retrieve(handle: String) async -> (Data, Int32) {
        guard !handle.isEmpty, let state, let url = URL(string: state.baseURL + "/v1/retrieve/\(handle)") else {
            return (Data("distill retrieve: missing handle or service\n".utf8), 1)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
        applyRecoveryScope(to: &urlRequest)
        urlRequest.setValue(Self.recoveryOperationID(kind: "retrieve", canonicalPayload: Data(handle.utf8)), forHTTPHeaderField: "X-RemoteCode-Operation-ID")
        guard let (data, status) = await transport(urlRequest), status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["found"] as? Bool) == true,
              let original = obj["original"] as? String else {
            return (Data("distill retrieve: original unavailable\n".utf8), 1)
        }
        return (Data(original.utf8), 0)
    }

    private func stats() async -> (Data, Int32) {
        guard let state, let url = URL(string: state.baseURL + "/v1/stats") else {
            return (Data("distill stats: service unavailable\n".utf8), 1)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
        guard let (data, status) = await transport(urlRequest), status == 200,
              let snapshot = try? JSONDecoder().decode(DistillStatsSnapshot.self, from: data) else {
            return (Data("distill stats: stats unavailable\n".utf8), 1)
        }
        return (Data(Self.formatStats(snapshot).utf8), 0)
    }

    static func formatStats(_ snapshot: DistillStatsSnapshot) -> String {
        var lines = [
            "saved_tokens=\(snapshot.totalSavedTokens)",
            "runs=\(snapshot.totalRuns)"
        ]
        for provider in snapshot.providers {
            lines.append("provider \(provider.provider): saved=\(provider.savedTokens) input=\(provider.inputTokens) output=\(provider.outputTokens) runs=\(provider.runs)")
        }
        for mode in snapshot.modes {
            lines.append("mode \(mode.provider)/\(mode.mode): saved=\(mode.savedTokens) runs=\(mode.runs)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func canonicalBody(_ request: DistillRequest) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(request)
    }

    public static func recoveryContext(environment: [String: String]) -> TokenSaverRecoveryRequestContext? {
        let context = TokenSaverRecoveryRequestContext(
            workspaceID: environment["RC_TOKEN_SAVER_WORKSPACE_ID"] ?? "",
            projectID: environment["RC_TOKEN_SAVER_PROJECT_ID"] ?? "",
            threadID: environment["RC_TOKEN_SAVER_THREAD_ID"] ?? "",
            provider: environment["REMOTE_CODE_AGENT_PROVIDER"] ?? "",
            attemptID: environment["RC_TOKEN_SAVER_ATTEMPT_ID"] ?? "",
            operationID: ""
        )
        return context.hasCompleteScope ? context : nil
    }

    private func applyRecoveryScope(to request: inout URLRequest) {
        guard let recoveryContext else { return }
        request.setValue(recoveryContext.workspaceID, forHTTPHeaderField: "X-RemoteCode-Workspace-ID")
        request.setValue(recoveryContext.projectID, forHTTPHeaderField: "X-RemoteCode-Project-ID")
        request.setValue(recoveryContext.threadID, forHTTPHeaderField: "X-RemoteCode-Thread-ID")
        request.setValue(recoveryContext.provider, forHTTPHeaderField: "X-RemoteCode-Provider")
        request.setValue(recoveryContext.attemptID, forHTTPHeaderField: "X-RemoteCode-Attempt-ID")
    }
}
