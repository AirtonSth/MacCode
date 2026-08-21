import Foundation
import CoreModel

/// Core logic of the managed `distill` CLI, ported off Python to native Swift (N1)
/// and made FAIL-OPEN (N2/N5). The shipped Python CLI failed CLOSED: on any error it
/// wrote stderr + `sys.exit(code)` with EMPTY stdout — but `cmd | distill` had already
/// consumed the original via the pipe, so the tool output was lost unrecoverably.
///
/// This never loses data: in compress mode, on ANY failure (no state, transport error,
/// non-200, empty output) it writes the buffered raw stdin verbatim to stdout and exits 0.
/// On success it emits the compressed output, plus a `[[rc:<handle>]]` marker when the
/// sidecar stored the original (so the agent can recover it via `distill retrieve`), and
/// a trailing applied receipt only when the complete emitted UTF-8 payload is a net shrink.
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

    // PERF: PostToolUse fail-open returns `{}` on every admission/malformed/skip
    // path (many times per Claude tool turn). Share static empty-object bytes.
    // Fixed retrieve/stats error bodies reuse the same pattern as HTTP rejects.
    private static let emptyJSONObjectData = Data([0x7b, 0x7d]) // {}
    private static let emptyJSONOK = RunResult(stdout: emptyJSONObjectData, exitCode: 0)
    private static let retrieveMissingHandleBody = Data("distill retrieve: missing handle or service\n".utf8)
    private static let retrieveUnavailableBody = Data("distill retrieve: original unavailable\n".utf8)
    private static let statsServiceUnavailableBody = Data("distill stats: service unavailable\n".utf8)
    private static let statsUnavailableBody = Data("distill stats: stats unavailable\n".utf8)
    private static let dslReservedBody = Data("distill dsl: reserved subcommand is not implemented by this managed CLI\n".utf8)
    private static let dslNoTranscriptBody = Data("distill dsl learn-thread: no transcript on stdin\n".utf8)

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
        // PERF: DistillSHA256 nibble hex (not String(format:)) for per-request
        // operation IDs on every distill/retrieve; CryptoKit-identical digest.
        let digest = DistillSHA256.hex(material)
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

    /// Result of a CLI invocation. `deferredSideEffect` is optional best-effort
    /// work (Wave A ledger write) that must not delay delivery of `stdout` when
    /// the executable can flush stdout first (see `runResult` + service main).
    public struct RunResult: Sendable {
        public let stdout: Data
        public let exitCode: Int32
        public let deferredSideEffect: (@Sendable () async -> Void)?

        public init(
            stdout: Data,
            exitCode: Int32,
            deferredSideEffect: (@Sendable () async -> Void)? = nil
        ) {
            self.stdout = stdout
            self.exitCode = exitCode
            self.deferredSideEffect = deferredSideEffect
        }
    }

    /// Full result including optional post-stdout side effects. Preferred by the
    /// executable so Wave A ledger POSTs do not delay the pipe consumer.
    public func runResult() async -> RunResult {
        if arguments.first == "retrieve" {
            let (out, code) = await retrieve(handle: arguments.dropFirst().first ?? "")
            return RunResult(stdout: out, exitCode: code)
        }
        if arguments.first == "stats" {
            let (out, code) = await stats()
            return RunResult(stdout: out, exitCode: code)
        }
        if arguments.first == "dsl" {
            let (out, code) = dsl(arguments: Array(arguments.dropFirst()))
            return RunResult(stdout: out, exitCode: code)
        }
        // Claude PostToolUse hook: never fall through to generic compress of the
        // raw hook JSON envelope. Always exit 0 (fail-open) so a live CLI turn
        // is never blocked by hook failures. Propagate nested deferred ledger work
        // so the executable can flush stdout before awaiting it.
        if arguments.first == TokenSaverProtocolV2.reservedHookSubcommand
            || TokenSaverProtocolV2.routeCLISubcommand(arguments.first ?? "") == "hook_handler" {
            return await hook(arguments: Array(arguments.dropFirst()))
        }
        // Remaining reserved subcommands stay loud (not silent compress).
        if let command = arguments.first, Self.reservedSubcommands.contains(command) {
            let (out, code) = unsupportedReservedSubcommand(command)
            return RunResult(stdout: out, exitCode: code)
        }
        let prompt = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return await compress(prompt: prompt)
    }

    /// Runs the CLI and awaits any deferred side effect (ledger write) before
    /// returning. Unit tests use this; the executable prefers `runResult` so it
    /// can flush stdout first.
    public func run() async -> (stdout: Data, exitCode: Int32) {
        let result = await runResult()
        if let deferred = result.deferredSideEffect {
            await deferred()
        }
        return (result.stdout, result.exitCode)
    }

    private static let reservedSubcommands: Set<String> = [
        "rank",
        "wrap",
    ]

    private func unsupportedReservedSubcommand(_ command: String) -> (Data, Int32) {
        let message = "distill \(command): reserved subcommand is not implemented by this managed CLI\n"
        return (Data(message.utf8), 1)
    }

    private func dsl(arguments: [String]) -> (Data, Int32) {
        guard arguments.first == "learn-thread",
              arguments.dropFirst().contains("--stdin") else {
            return (Self.dslReservedBody, 1)
        }
        guard !stdin.isEmpty else {
            return (Self.dslNoTranscriptBody, 1)
        }
        let message = "distill dsl learn-thread: accepted \(stdin.count) bytes\n"
        return (Data(message.utf8), 0)
    }

    // MARK: - hook post-tool-use (fail-open, always exit 0)

    /// Claude PostToolUse hook handler. Reads Claude's hook JSON on stdin
    /// (`tool_name` / `tool_input` / `tool_response` / `hook_event_name`), compresses
    /// the tool output via the existing `/v1/distill` path with `recordSavings: true`,
    /// and emits `hookSpecificOutput.updatedToolOutput` on success.
    ///
    /// ANY failure (malformed input, sidecar down, non-shrink, admission off) yields
    /// `{}` and exit 0 — never non-zero, never hang the interactive turn.
    ///
    /// Propagates nested Wave A ledger `deferredSideEffect` so callers that flush
    /// stdout first (via `runResult`) never wait on the sidecar RTT for bytes they
    /// already hold.
    private func hook(arguments: [String]) async -> RunResult {
        let emptyOK = Self.emptyJSONOK
        switch arguments.first {
        case "post-tool-use":
            return await hookPostToolUse()
        case "pre-tool-pipe":
            return hookPreToolPipe()
        default:
            return emptyOK
        }
    }

    /// Grok/Claude PreToolUse: rewrite wrap-eligible shell `command` to end with
    /// `| <managed-distill> "<question>"`. Not PostToolUse output rewrite.
    /// Fail-open `{}` on any skip so the original command runs unchanged.
    func hookPreToolPipe(
        processArguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> RunResult {
        let emptyOK = Self.emptyJSONOK
        guard distillAdmission() else { return emptyOK }
        guard let envelope = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] else {
            return emptyOK
        }
        let event = Self.hookEventToken(envelope)
        if !event.isEmpty, event != "pretooluse" {
            return emptyOK
        }
        let toolName = Self.hookToolName(envelope)
        guard let input = Self.hookToolInput(envelope),
              let command = input["command"] as? String else {
            return emptyOK
        }
        let distillPath = ShellDistillPipeAdmission.distillExecutablePath(
            processArguments: processArguments,
            environment: environment,
            homeDirectory: homeDirectory
        )
        switch ShellDistillPipeAdmission.decide(
            admitted: true,
            toolName: toolName,
            command: command,
            distillExecutable: distillPath,
            distillExists: fileExists(distillPath)
        ) {
        case .pipe(let rewritten):
            var updated = input
            updated["command"] = rewritten
            let payload: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "updatedInput": updated,
                ] as [String: Any],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                return emptyOK
            }
            return RunResult(stdout: data, exitCode: 0)
        default:
            return emptyOK
        }
    }

    private static func hookEventToken(_ envelope: [String: Any]) -> String {
        let raw = (envelope["hookEventName"] as? String)
            ?? (envelope["hook_event_name"] as? String)
            ?? ""
        return raw
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func hookToolName(_ envelope: [String: Any]) -> String {
        (envelope["toolName"] as? String)
            ?? (envelope["tool_name"] as? String)
            ?? ""
    }

    private static func hookToolInput(_ envelope: [String: Any]) -> [String: Any]? {
        (envelope["toolInput"] as? [String: Any])
            ?? (envelope["tool_input"] as? [String: Any])
    }

    private func hookPostToolUse() async -> RunResult {
        let emptyOK = Self.emptyJSONOK

        guard let envelope = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] else {
            return emptyOK
        }
        if let event = envelope["hook_event_name"] as? String,
           event != "PostToolUse" {
            return emptyOK
        }

        let toolName = envelope["tool_name"] as? String ?? ""
        // Claude Code normalizes Bash stdout before PostToolUse (it removes
        // leading/trailing blank lines), and its Bash response object carries no
        // byte count or terminator metadata. The hook therefore cannot know
        // whether the real process emitted a terminal LF. Never create a claimed
        // byte-exact recovery object from that ambiguous text. Eligible shell
        // commands are compressed earlier by the provider-neutral PATH wrapper,
        // while explicit `| distill` remains available for absolute binaries.
        if Self.isBashTool(toolName) {
            return emptyOK
        }
        // Multimodal: any image part in tool_response → fail-open before text extract.
        // WHY: extractToolOutputText flattens text only; compressing would replace the whole
        // tool_response and drop the image (advisor: mixed text+image defect).
        if Self.toolResponseContainsImage(envelope["tool_response"]) {
            return emptyOK
        }
        let rawOutput = Self.extractToolOutputText(envelope["tool_response"])
        guard !rawOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return emptyOK
        }

        // Policy gate: mutation tools stay raw; image-like text blobs and small
        // outputs fail open. Bash has already failed open above because only the
        // earlier PATH wrapper sees its exact bytes.
        let argsSummary = Self.summarizeToolInput(envelope["tool_input"])
        // Thresholds align with CommandWrapPolicy defaults (aggressive wrap path).
        let decision = ToolOutputCompressionPolicy(
            minBytes: CommandWrapPolicy.defaultMinBytes,
            minLines: CommandWrapPolicy.defaultMinLines,
            reversibleStoreMinBytes: reversibleStoreMinBytes ?? CommandWrapPolicy.reversibleStoreFloorBytes
        ).decision(
            toolName: toolName,
            output: rawOutput,
            toolArgumentsSummary: argsSummary.isEmpty ? nil : argsSummary
        )
        guard decision.shouldCompress else {
            return emptyOK
        }

        let question = decision.contractQuestion
        // Cap raised from 12k→48k so large Read/Grep tool results can reach the
        // sidecar model stage (and ledger as command-output (model)), not only a
        // tiny deterministic head. Floor stays 512.
        let maxChars = max(512, min(rawOutput.count, 48_000))
        // Nested CLI reuses the same compress + recordSavings path (including Wave A).
        let nested = ManagedDistillCLI(
            arguments: [question],
            stdin: Data(rawOutput.utf8),
            state: state,
            provider: provider ?? "claude",
            recoveryContext: recoveryContext,
            invocationID: invocationID,
            maxOutputCharacters: maxChars,
            reversibleStoreMinBytes: decision.reversibleStoreMinBytes,
            distillAdmission: distillAdmission,
            transport: transport
        )
        // Use runResult (not run) so Wave A ledger POST stays deferred until after
        // the hook JSON is delivered to the Claude CLI.
        let nestedResult = await nested.runResult()
        guard nestedResult.exitCode == 0 else { return emptyOK }

        // A nested successful compression carries its own trailing receipt. Preserve it
        // in updatedToolOutput; fail-open returns the exact raw bytes with no receipt.
        let nestedInput = Data(rawOutput.utf8)
        let compressed = Self.stripTrailingNewlines(String(decoding: nestedResult.stdout, as: UTF8.self))
        guard !compressed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              nestedResult.stdout != nestedInput,
              DistillAppliedReceipt.containsMarker(compressed),
              compressed.utf8.count < rawOutput.utf8.count else {
            return emptyOK
        }

        let replaced = Self.replaceToolOutputText(envelope["tool_response"], with: compressed)
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PostToolUse",
                "updatedToolOutput": replaced,
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return emptyOK
        }
        return RunResult(
            stdout: data,
            exitCode: 0,
            deferredSideEffect: nestedResult.deferredSideEffect
        )
    }

    static func stripTrailingNewlines(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\n") || t.hasSuffix("\r") {
            t.removeLast()
        }
        return t
    }

    static func isBashTool(_ toolName: String) -> Bool {
        let normalized = toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        return normalized == "bash"
    }

    /// True when tool_response contains an image content block or image-like base64 blob.
    static func toolResponseContainsImage(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let s = value as? String {
            return ToolOutputMultimodalGuard.looksLikeImagePayload(s)
        }
        if let arr = value as? [Any] {
            return arr.contains { toolResponseContainsImage($0) }
        }
        guard let obj = value as? [String: Any] else { return false }
        if let type = obj["type"] as? String, type.lowercased() == "image" {
            return true
        }
        if let mime = obj["mimeType"] as? String, mime.lowercased().hasPrefix("image/") {
            return true
        }
        if let content = obj["content"] {
            return toolResponseContainsImage(content)
        }
        // Nested data field may be base64 image.
        if let data = obj["data"] as? String, ToolOutputMultimodalGuard.looksLikeImagePayload(data) {
            return true
        }
        return false
    }

    /// Mirrors ClaudeAgentSDKBridge.mjs `extractToolOutputText`.
    static func extractToolOutputText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if let arr = value as? [Any] {
            return arr.map { extractToolOutputText($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        guard let obj = value as? [String: Any] else {
            return String(describing: value)
        }
        if let content = obj["content"] {
            return extractToolOutputText(content)
        }
        for key in ["text", "output", "stdout", "stderr", "result"] {
            if let s = obj[key] as? String { return s }
        }
        return ""
    }

    /// Mirrors ClaudeAgentSDKBridge.mjs `replaceToolOutputText` so command hooks
    /// return the same response shape Claude validates for each built-in tool.
    static func replaceToolOutputText(_ value: Any?, with text: String) -> Any {
        if value is String { return text }
        if value is [Any] {
            return [["type": "text", "text": text]]
        }
        if var obj = value as? [String: Any] {
            if obj["content"] is [Any] {
                obj["content"] = [["type": "text", "text": text]]
                return obj
            }
            for key in ["text", "output", "stdout", "stderr", "result"] {
                if obj[key] is String {
                    obj[key] = text
                    return obj
                }
            }
        }
        return text
    }

    /// Conservative compress contract for the PostToolUse hook (provider-agnostic default).
    /// Prefer `ToolOutputCompressionPolicy.decision(...).contractQuestion` at call sites.
    static func hookContractQuestion(toolName: String, toolInput: Any?) -> String {
        let args = summarizeToolInput(toolInput)
        return ToolOutputCompressionPolicy().decision(
            toolName: toolName.isEmpty ? "Bash" : toolName,
            output: String(repeating: "x\n", count: 40),
            toolArgumentsSummary: args.isEmpty ? nil : args
        ).contractQuestion
    }

    static func summarizeToolInput(_ toolInput: Any?) -> String {
        guard let obj = toolInput as? [String: Any] else { return "" }
        var parts: [String] = []
        for key in ["command", "pattern", "path", "glob", "url"] {
            if let s = obj[key] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { parts.append("\(key)=\(t)") }
            }
        }
        let joined = parts.joined(separator: " | ")
        if joined.count <= 500 { return joined }
        return String(joined.prefix(500))
    }

    // MARK: - compress (fail-open)

    /// Appends the host receipt at the final emission boundary. Recovery markers are
    /// already part of `transformed`, so the byte comparison includes every protocol
    /// line the provider will see. Returning nil means exact fail-open to `original`.
    private static func receiptedCompression(original: Data, transformed: String) -> Data? {
        guard Data(transformed.utf8) != original else { return nil }
        let separator = transformed.hasSuffix("\n") ? "" : "\n"
        let emitted = Data((transformed + separator + DistillAppliedReceipt.makeMarker() + "\n").utf8)
        guard emitted.count < original.count else { return nil }
        return emitted
    }

    private func compress(prompt: String) async -> RunResult {
        // Fail-open: hand back exactly what was piped in. exit 0 so the agent never
        // sees an error in place of its tool output.
        func failOpen() -> RunResult { RunResult(stdout: stdin, exitCode: 0) }

        guard !stdin.isEmpty else { return RunResult(stdout: Data(), exitCode: 0) }
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
            guard let compressed = Self.receiptedCompression(
                original: stdin,
                transformed: pre.output
            ) else {
                return failOpen()
            }
            FileHandle.standardError.write(Data(
                "rc-wave-prepass wave=\(pre.waveID) trigger=\(pre.trigger) saved_bytes=\(pre.savedBytes) frac=\(String(format: "%.3f", pre.savedFraction))\n".utf8
            ))
            // Compressed bytes are ready now. Ledger write is a deferred side-effect
            // via the same /v1/distill recordSavings path the normal compress path
            // uses — never a gate. Exactly one POST; we do not fall through to
            // normal compress (no double-count).
            let recordOriginal = input
            let recordPrompt = prompt
            let recordPre = pre
            let recordSelf = self
            return RunResult(
                stdout: compressed,
                exitCode: 0,
                deferredSideEffect: {
                    await recordSelf.bestEffortRecordPrepassSavings(
                        original: recordOriginal,
                        prompt: recordPrompt,
                        pre: recordPre
                    )
                }
            )
        }

        if ManagedDistillCLI.exceedsStdinCap(byteCount: stdin.count, cap: ManagedDistillCLI.stdinCapBytes) {
            let (out, code) = await compressChunks(input: input, prompt: prompt)
            return RunResult(stdout: out, exitCode: code)
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
              let response = Self.decodeResponse(DistillResponse.self, from: data),
              !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failOpen()
        }
        guard response.routeStage != .verbatim else { return failOpen() }
        var out = response.output
        if let handle = response.originalHandle, !handle.isEmpty {
            out += "\n[[rc:\(handle)]]"
        }
        guard let emitted = Self.receiptedCompression(original: stdin, transformed: out) else {
            return failOpen()
        }
        return RunResult(stdout: emitted, exitCode: 0)
    }

    /// Fire one `/v1/distill` POST with `recordSavings: true` and client-supplied
    /// `precomputedOutput` so the sidecar records the honest original→`pre.output`
    /// delta via `DistillSavingsCalculator.record` without re-running compression.
    ///
    /// Response body is discarded — the caller already holds `pre.output`. One bounded
    /// retry covers a transient hiccup (e.g. the resident sidecar mid-restart); a final
    /// failure is logged to stderr (wave id + byte count only, never prompt/output
    /// content) so a dropped ledger write is observable instead of vanishing silently.
    /// Still never gates compressed delivery either way.
    private func bestEffortRecordPrepassSavings(
        original: String,
        prompt: String,
        pre: TokenSaverWaveLosslessPrepass.Result
    ) async {
        guard pre.savedBytes > 0 else { return }
        guard distillAdmission() else { return }
        guard let state, let url = URL(string: state.baseURL + "/v1/distill") else { return }

        let request = DistillRequest(
            mode: .commandOutput,
            priority: .agent,
            input: original,
            question: prompt.isEmpty ? nil : prompt,
            provider: provider,
            recordSavings: true,
            cacheState: "wave_prepass_\(pre.waveID)",
            maxOutputCharacters: maxOutputCharacters,
            reversibleStoreMinBytes: reversibleStoreMinBytes,
            precomputedOutput: pre.output
        )
        guard let body = Self.canonicalBody(request) else { return }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyRecoveryScope(to: &urlRequest)
        // Distinct invocation suffix so a later full-compress of the same bytes (if any)
        // cannot collide on idempotency with this savings-only prepass record.
        urlRequest.setValue("\(invocationID).wave-prepass", forHTTPHeaderField: "X-RemoteCode-Invocation-ID")
        urlRequest.setValue(
            Self.recoveryOperationID(kind: "distill", canonicalPayload: body),
            forHTTPHeaderField: "X-RemoteCode-Operation-ID"
        )
        urlRequest.httpBody = body

        // One bounded retry: a resident local sidecar occasionally misses the first
        // request during a restart window. Still never a gate — give up after the retry
        // and log so the drop is diagnosable rather than silent.
        for attempt in 0..<2 {
            if let (_, status) = await transport(urlRequest), status == 200 {
                return
            }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        FileHandle.standardError.write(Data(
            "rc-wave-prepass ledger-post-failed wave=\(pre.waveID) saved_bytes=\(pre.savedBytes)\n".utf8
        ))
    }

    /// Pure seam: the DistillSavingsRecord a Wave A/B prepass hit produces when the
    /// sidecar's precomputed-output path sees original→compressed (same construction
    /// as `DistillRequest.responseUsingPrecomputedOutput` + `DistillSavingsCalculator`).
    /// Used by tests and as the deterministic contract for the ledger delta.
    public static func prepassSavingsRecord(
        original: String,
        compressed: String,
        provider: String?,
        waveID: String
    ) -> DistillSavingsRecord? {
        let request = DistillRequest(
            mode: .commandOutput,
            priority: .agent,
            input: original,
            provider: provider,
            recordSavings: true,
            cacheState: "wave_prepass_\(waveID)",
            precomputedOutput: compressed
        )
        guard let response = request.responseUsingPrecomputedOutput() else { return nil }
        return DistillSavingsCalculator.record(for: request, response: response)
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
                  let response = Self.decodeResponse(DistillResponse.self, from: data),
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
        guard let output = Self.receiptedCompression(
            original: stdin,
            transformed: emitted.joined(separator: "\n\n")
        ) else {
            return failOpen()
        }
        return (output, 0)
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
            return (Self.retrieveMissingHandleBody, 1)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
        applyRecoveryScope(to: &urlRequest)
        urlRequest.setValue(Self.recoveryOperationID(kind: "retrieve", canonicalPayload: Data(handle.utf8)), forHTTPHeaderField: "X-RemoteCode-Operation-ID")
        guard let (data, status) = await transport(urlRequest), status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["found"] as? Bool) == true,
              let original = obj["original"] as? String else {
            return (Self.retrieveUnavailableBody, 1)
        }
        return (Data(original.utf8), 0)
    }

    private func stats() async -> (Data, Int32) {
        guard let state, let url = URL(string: state.baseURL + "/v1/stats") else {
            return (Self.statsServiceUnavailableBody, 1)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
        guard let (data, status) = await transport(urlRequest), status == 200,
              let snapshot = Self.decodeResponse(DistillStatsSnapshot.self, from: data) else {
            return (Self.statsUnavailableBody, 1)
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

    // PERF: every managed distill POST builds a sortedKeys body for the wire
    // payload and recovery operation IDs; responses decode DistillResponse /
    // stats on the same path. JSONEncoder/Decoder are not thread-safe —
    // serialize concurrent PATH-wrapper spawns under a short lock and reuse
    // one encoder (sortedKeys unchanged) + one decoder.
    private static let codecLock = NSLock()
    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let responseDecoder = JSONDecoder()

    private static func canonicalBody(_ request: DistillRequest) -> Data? {
        codecLock.lock()
        defer { codecLock.unlock() }
        return try? canonicalEncoder.encode(request)
    }

    private static func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        codecLock.lock()
        defer { codecLock.unlock() }
        return try? responseDecoder.decode(type, from: data)
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
