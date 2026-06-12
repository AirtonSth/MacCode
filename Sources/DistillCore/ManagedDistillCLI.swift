import Foundation

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

    /// Hard cap on stdin bytes. Inputs above this are rejected with a non-zero exit so a
    /// runaway pipe cannot buffer an arbitrarily large blob into memory.
    /// 512 KB is well above any realistic single distill request (token-output blobs,
    /// large git diffs, verbose test logs). Raise only if legitimate inputs are measured
    /// to exceed this value.
    public static let stdinCapBytes: Int = 512 * 1_024

    /// Pure seam: returns true when `byteCount` exceeds `cap`. Extracted so tests can
    /// verify cap logic without constructing a full CLI instance or any I/O.
    public static func exceedsStdinCap(byteCount: Int, cap: Int) -> Bool {
        byteCount > cap
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
    public let maxOutputCharacters: Int
    public let transport: Transport

    public init(
        arguments: [String],
        stdin: Data,
        state: State?,
        provider: String? = nil,
        maxOutputCharacters: Int = 4_000,
        transport: @escaping Transport
    ) {
        self.arguments = arguments
        self.stdin = stdin
        self.state = state
        self.provider = provider
        self.maxOutputCharacters = max(128, maxOutputCharacters)
        self.transport = transport
    }

    public func run() async -> (stdout: Data, exitCode: Int32) {
        if arguments.first == "retrieve" {
            return await retrieve(handle: arguments.dropFirst().first ?? "")
        }
        let prompt = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return await compress(prompt: prompt)
    }

    // MARK: - compress (fail-open)

    private func compress(prompt: String) async -> (Data, Int32) {
        // Fail-open: hand back exactly what was piped in. exit 0 so the agent never
        // sees an error in place of its tool output.
        func failOpen() -> (Data, Int32) { (stdin, 0) }

        // Reject oversized stdin before any allocation. A blob this large would almost
        // certainly time out or be refused by the service anyway; rejecting early prevents
        // OOM and gives the caller an actionable error.
        if ManagedDistillCLI.exceedsStdinCap(byteCount: stdin.count, cap: ManagedDistillCLI.stdinCapBytes) {
            let msg = "distill: stdin exceeds \(ManagedDistillCLI.stdinCapBytes / 1_024) KB cap (\(stdin.count) bytes); truncate input before piping\n"
            return (Data(msg.utf8), 1)
        }

        let input = String(decoding: stdin, as: UTF8.self)
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (Data(), 0) // nothing piped → nothing to compress or lose
        }
        guard let state, let url = URL(string: state.baseURL + "/v1/distill") else { return failOpen() }

        let request = DistillRequest(
            mode: .commandOutput,
            priority: .agent,
            input: input,
            question: prompt.isEmpty ? nil : prompt,
            provider: provider,
            recordSavings: true,
            maxOutputCharacters: maxOutputCharacters
        )
        guard let body = try? JSONEncoder().encode(request) else { return failOpen() }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        guard let (data, status) = await transport(urlRequest), status == 200,
              let response = try? JSONDecoder().decode(DistillResponse.self, from: data),
              !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failOpen()
        }
        var out = response.output
        if let handle = response.originalHandle, !handle.isEmpty {
            out += "\n[[rc:\(handle)]]"
        }
        return (Data((out + "\n").utf8), 0)
    }

    // MARK: - retrieve (no stdin to preserve → exit 1 on miss)

    private func retrieve(handle: String) async -> (Data, Int32) {
        guard !handle.isEmpty, let state, let url = URL(string: state.baseURL + "/v1/retrieve/\(handle)") else {
            return (Data("distill retrieve: missing handle or service\n".utf8), 1)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(state.authToken)", forHTTPHeaderField: "Authorization")
        guard let (data, status) = await transport(urlRequest), status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["found"] as? Bool) == true,
              let original = obj["original"] as? String else {
            return (Data("distill retrieve: original unavailable\n".utf8), 1)
        }
        return (Data(original.utf8), 0)
    }
}
