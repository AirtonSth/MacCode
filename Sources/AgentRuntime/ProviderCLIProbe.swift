import Foundation
import CoreModel

/// Accumulates pipe chunks drained concurrently and decodes to a UTF-8 String.
/// Pure value helper — no actor state, safe to use on any thread.
///
/// PERF: version/auth probes use a prefix cap so a misbehaving CLI cannot pin
/// multi-MB Data. User-triggered updates use the same bound as a suffix so their
/// terminal diagnostics survive; truncation is surfaced by `update`.
struct PipeAccumulator: Sendable {
    enum Retention: Sendable {
        case prefix
        case suffix
    }

    /// Peak retained stdout/stderr per probe. Matches Token Saver /usage PTY
    /// and Claude SDK npm install tails in order of magnitude; far above any
    /// legitimate `--version` / auth JSON payload. Was unbounded, then 256 KiB.
    static let defaultMaxBytes = 128 * 1_024

    private(set) var data: Data = Data()
    private let maxBytes: Int
    private let retention: Retention
    private(set) var truncated = false

    init(maxBytes: Int = defaultMaxBytes, retention: Retention = .prefix) {
        self.maxBytes = max(1, maxBytes)
        self.retention = retention
    }

    var isFull: Bool { data.count >= maxBytes }

    mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        if retention == .suffix {
            data.append(chunk)
            if data.count > maxBytes {
                data.removeFirst(data.count - maxBytes)
                truncated = true
            }
            return
        }
        let room = maxBytes - data.count
        if room <= 0 {
            truncated = true
            return
        }
        if chunk.count <= room {
            data.append(chunk)
        } else {
            data.append(chunk.prefix(room))
            truncated = true
        }
    }

    var string: String {
        String(decoding: data, as: UTF8.self)
    }

    static let truncationNotice = "[RemoteCode] provider update output truncated; showing the final diagnostic tail.\n"

    /// User-facing update output makes bounded suffix retention explicit.
    var renderedString: String {
        guard truncated, retention == .suffix else { return string }
        return "\(Self.truncationNotice)\(string)"
    }

    /// Pure prefix retention decision for unit tests (mirrors append policy).
    static func retainedPrefix(_ data: Data, maxBytes: Int = defaultMaxBytes) -> Data {
        let limit = max(1, maxBytes)
        if data.count <= limit { return data }
        return data.prefix(limit)
    }
}

public enum ProviderCLIProbe {
    public struct AuthStatus: Equatable, Sendable {
        public let authenticated: Bool?
        public let accountLabel: String?
        public let accountAuthMethod: String?

        public init(authenticated: Bool?, accountLabel: String?, accountAuthMethod: String? = nil) {
            self.authenticated = authenticated
            self.accountLabel = accountLabel
            self.accountAuthMethod = accountAuthMethod
        }
    }

    public struct VersionStatus: Equatable, Sendable {
        public let version: String?
        public let updateState: String?
        public let advisory: String?

        public init(version: String?, updateState: String?, advisory: String?) {
            self.version = version
            self.updateState = updateState
            self.advisory = advisory
        }
    }

    public struct UpdateResult: Equatable, Sendable {
        public let ok: Bool
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
        let renderedStdout: String
        let renderedStderr: String
    }

    public static func version(binaryPath: String, environment: [String: String] = [:], timeoutSeconds: TimeInterval = 2.0) -> String? {
        versionStatus(binaryPath: binaryPath, environment: environment, timeoutSeconds: timeoutSeconds).version
    }

    public static func versionStatus(binaryPath: String, environment: [String: String] = [:], timeoutSeconds: TimeInterval = 2.0) -> VersionStatus {
        guard let result = run(binaryPath: binaryPath, arguments: ["--version"], environment: environment, timeoutSeconds: timeoutSeconds),
              result.status == 0 else { return VersionStatus(version: nil, updateState: nil, advisory: nil) }
        let text = result.stdout
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let advisory = updateAdvisory(from: combined)
        return VersionStatus(
            version: text?.isEmpty == false ? text : nil,
            updateState: advisory == nil ? "current" : "update_available",
            advisory: advisory
        )
    }

    public static func authenticated(provider: AgentProvider, binaryPath: String, environment: [String: String] = [:], timeoutSeconds: TimeInterval = 4.0) -> Bool? {
        authStatus(provider: provider, binaryPath: binaryPath, environment: environment, timeoutSeconds: timeoutSeconds).authenticated
    }

    public static func authStatus(provider: AgentProvider, binaryPath: String, environment: [String: String] = [:], timeoutSeconds: TimeInterval = 4.0) -> AuthStatus {
        authStatus(
            provider: provider,
            binaryPath: binaryPath,
            environment: environment,
            runAsUser: nil,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Auth probe aligned with provider spawn. When `runAsUser` is a foreign
    /// macOS account, run the same `sudo -n -u <user> -H -- <binary> …` path
    /// execution uses (non-interactive). A HOME-only probe as the app owner
    /// false-negatives Claude OAuth for the selected user and blocks Auto.
    public static func authStatus(
        provider: AgentProvider,
        binaryPath: String,
        environment: [String: String] = [:],
        runAsUser: AgentRunAsUser?,
        timeoutSeconds: TimeInterval = 4.0
    ) -> AuthStatus {
        let arguments: [String]
        switch provider {
        case .codex:
            arguments = ["login", "status"]
        case .claude:
            arguments = ["auth", "status"]
        case .grok:
            // Grok has no dedicated auth-status subcommand; `models` prints
            // "You are logged in with …" when authenticated.
            arguments = ["models"]
        }
        guard let result = run(
            binaryPath: binaryPath,
            arguments: arguments,
            environment: environment,
            runAsUser: runAsUser,
            timeoutSeconds: timeoutSeconds
        ) else {
            // Foreign sudo -n may fail without a cached credential — unknown,
            // not "logged out". Auto may still admit; spawn uses sudo -A.
            return AuthStatus(authenticated: nil, accountLabel: nil, accountAuthMethod: nil)
        }

        let combined = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accountLabel = accountLabel(from: combined)
        let accountAuthMethod = accountAuthMethod(from: combined)
        if let bool = authBoolean(from: combined) {
            return AuthStatus(authenticated: bool, accountLabel: accountLabel, accountAuthMethod: accountAuthMethod)
        }
        let lower = combined.lowercased()
        if lower.contains("not logged in")
            || lower.contains("not authenticated")
            || lower.contains("unauthenticated")
            || lower.contains("authentication required")
            || lower.contains("login required") {
            return AuthStatus(authenticated: false, accountLabel: accountLabel, accountAuthMethod: accountAuthMethod)
        }
        if result.status == 0,
           lower.contains("logged in") || lower.contains("authenticated") {
            return AuthStatus(authenticated: true, accountLabel: accountLabel, accountAuthMethod: accountAuthMethod)
        }
        return AuthStatus(authenticated: nil, accountLabel: accountLabel, accountAuthMethod: accountAuthMethod)
    }

    /// Interactive slash-command discovery. `<binary> --help` is NOT a valid
    /// source: its "Commands:" section lists CLI *subcommands* (exec, install,
    /// setup-token, ...) plus wrapped description fragments, none of which are
    /// interactive slash commands — probing it filled the composer autocomplete
    /// with bogus entries on both providers. Return nothing so the curated
    /// per-provider defaults stay the only slash-command source.
    public static func slashCommands(provider: AgentProvider, binaryPath: String, environment: [String: String] = [:], timeoutSeconds: TimeInterval = 2.0) -> [String] {
        []
    }

    public static func update(provider: AgentProvider, binaryPath: String, environment: [String: String] = [:], timeoutSeconds: TimeInterval = 120.0) -> UpdateResult {
        let arguments: [String]
        switch provider {
        case .codex, .claude, .grok:
            arguments = ["update"]
        }
        guard let result = run(binaryPath: binaryPath, arguments: arguments, environment: environment, timeoutSeconds: timeoutSeconds, retention: .suffix) else {
            return UpdateResult(ok: false, status: -1, stdout: "", stderr: "provider update command failed to start or timed out")
        }
        return UpdateResult(ok: result.status == 0, status: result.status, stdout: result.renderedStdout, stderr: result.renderedStderr)
    }

    static func run(
        binaryPath: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: TimeInterval,
        retention: PipeAccumulator.Retention = .prefix
    ) -> CommandResult? {
        run(
            binaryPath: binaryPath,
            arguments: arguments,
            environment: environment,
            runAsUser: nil,
            timeoutSeconds: timeoutSeconds,
            retention: retention
        )
    }

    static func run(
        binaryPath: String,
        arguments: [String],
        environment: [String: String],
        runAsUser: AgentRunAsUser?,
        timeoutSeconds: TimeInterval,
        retention: PipeAccumulator.Retention = .prefix
    ) -> CommandResult? {
        let trimmed = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.isExecutableFile(atPath: trimmed) else { return nil }

        let baseEnv = CodexRunner.processEnvironment(overrides: environment, purpose: .supportProcess)
        let transport = ProviderSubprocessLauncher.transportCommand(
            provider: .codex,
            executablePath: trimmed,
            arguments: arguments,
            environment: baseEnv
        )
        let launchPlan: RunAsUserProcessBootstrap.LaunchPlan
        do {
            // Match ClaudeStreamingCLIAdapter: foreign user → sudo -n -u -H
            // (no askpass during probe — password UI only at real spawn).
            launchPlan = try RunAsUserProcessBootstrap.plan(
                executablePath: transport.executablePath,
                arguments: transport.arguments,
                environment: baseEnv,
                currentDirectory: FileManager.default.currentDirectoryPath,
                runAsUser: runAsUser,
                askpassPath: nil
            )
        } catch {
            return nil
        }

        let proc = Process()
        RunAsUserProcessBootstrap.apply(launchPlan, to: proc)
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        // Drain both pipes on background threads concurrently with process
        // execution. Reading must start BEFORE proc.run() returns so that a
        // child emitting >64 KB does not fill the OS pipe buffer (~64 KB on
        // macOS), stall, and prevent the process from exiting — which would
        // burn the full timeout before SIGTERM.
        //
        // Chunked drain keeps at most PipeAccumulator.defaultMaxBytes according
        // to the probe's retention mode while still reading to EOF, so multi-MB
        // floods cannot pin process memory and the pipe never back-pressures the
        // child. Version/auth use the prefix; updates use the diagnostic suffix.
        let drainDone = DispatchGroup()
        let resultLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        let outputByteLimit = PipeAccumulator.defaultMaxBytes
        var stdoutTruncated = false
        var stderrTruncated = false
        var renderedStdout = ""
        var renderedStderr = ""

        drainDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let drained = Self.drainCappedResult(
                from: out.fileHandleForReading,
                maxBytes: outputByteLimit,
                retention: retention
            )
            resultLock.lock(); stdoutData = drained.data; stdoutTruncated = drained.truncated; renderedStdout = drained.renderedString; resultLock.unlock()
            drainDone.leave()
        }

        drainDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let drained = Self.drainCappedResult(
                from: err.fileHandleForReading,
                maxBytes: outputByteLimit,
                retention: retention
            )
            resultLock.lock(); stderrData = drained.data; stderrTruncated = drained.truncated; renderedStderr = drained.renderedString; resultLock.unlock()
            drainDone.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }

        do {
            try proc.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            proc.terminate()
            _ = finished.wait(timeout: .now() + 0.2)
            return nil
        }

        // Child has exited; pipe write-ends are now closed; drain tasks will
        // finish reading to EOF imminently. Wait for them before reading.
        drainDone.wait()

        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        return CommandResult(
            status: proc.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated,
            renderedStdout: renderedStdout,
            renderedStderr: renderedStderr
        )
    }

    /// Drain a pipe handle to EOF, retaining a bounded prefix or suffix.
    /// Continues reading after the cap so the child cannot block on a full pipe.
    struct DrainedOutput {
        let data: Data
        let truncated: Bool
        let renderedString: String
    }

    static func drainCapped(from handle: FileHandle, maxBytes: Int) -> Data {
        drainCappedResult(from: handle, maxBytes: maxBytes, retention: .prefix).data
    }

    static func drainCappedResult(
        from handle: FileHandle,
        maxBytes: Int,
        retention: PipeAccumulator.Retention
    ) -> DrainedOutput {
        var acc = PipeAccumulator(maxBytes: maxBytes, retention: retention)
        let chunkSize = 16 * 1_024
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            acc.append(chunk)
        }
        return DrainedOutput(data: acc.data, truncated: acc.truncated, renderedString: acc.renderedString)
    }

    private static func authBoolean(from text: String) -> Bool? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return authBoolean(from: object)
    }

    private static func authBoolean(from value: Any) -> Bool? {
        if let array = value as? [Any] {
            for entry in array {
                if let nested = authBoolean(from: entry) { return nested }
            }
            return nil
        }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["authenticated", "isAuthenticated", "loggedIn", "isLoggedIn"] {
            if let bool = object[key] as? Bool { return bool }
        }
        for key in ["auth", "status", "session", "account"] {
            if let nested = object[key], let bool = authBoolean(from: nested) {
                return bool
            }
        }
        return nil
    }

    // PERF: auth text fallbacks recompiled these patterns via
    // range(of:options:.regularExpression) on every provider snapshot /
    // scheduled-task preflight. Compile once; match semantics unchanged.
    private static let accountLabelPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"logged in as\s+([^\s<>()]+@[^\s<>()]+)"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"authenticated as\s+([^\s<>()]+@[^\s<>()]+)"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #""email"\s*:\s*"([^"]+)""#, options: [.caseInsensitive]),
    ]
    private static let emailInMatchRegex = try! NSRegularExpression(pattern: #"[^\s<>()"]+@[^\s<>()"]+"#)

    private static func accountLabel(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let label = accountLabel(from: object) {
            return label
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in accountLabelPatterns {
            guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
                  let matchedRange = Range(match.range, in: text) else { continue }
            let matched = String(text[matchedRange])
            let emailNSRange = NSRange(matched.startIndex..<matched.endIndex, in: matched)
            if let emailMatch = emailInMatchRegex.firstMatch(in: matched, options: [], range: emailNSRange),
               let emailRange = Range(emailMatch.range, in: matched) {
                return String(matched[emailRange])
            }
        }
        return nil
    }

    private static func accountLabel(from value: Any) -> String? {
        if let array = value as? [Any] {
            for entry in array {
                if let nested = accountLabel(from: entry) { return nested }
            }
            return nil
        }
        if let string = value as? String, string.contains("@") {
            return string
        }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["email", "accountEmail", "username", "login", "displayName"] {
            if let label = object[key] as? String,
               !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return label
            }
        }
        for key in ["account", "user", "profile", "session", "auth"] {
            if let nested = object[key], let label = accountLabel(from: nested) {
                return label
            }
        }
        return nil
    }

    // PERF: same compile-once contract as accountLabel for "Logged in using …"
    // and authMethod JSON text fallbacks on every auth probe.
    private static let accountAuthMethodPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"logged in using\s+([A-Za-z0-9_. -]+)"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"authenticated using\s+([A-Za-z0-9_. -]+)"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #""authMethod"\s*:\s*"([^"]+)""#, options: [.caseInsensitive]),
    ]
    private static let quotedValueAtEndRegex = try! NSRegularExpression(pattern: #"(?<=")[^"]+(?="$)"#)
    private static let stripLoggedInUsingRegex = try! NSRegularExpression(
        pattern: #"logged in using"#,
        options: [.caseInsensitive]
    )
    private static let stripAuthenticatedUsingRegex = try! NSRegularExpression(
        pattern: #"authenticated using"#,
        options: [.caseInsensitive]
    )

    private static func accountAuthMethod(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let method = accountAuthMethod(from: object) {
            return method
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in accountAuthMethodPatterns {
            guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
                  let matchedRange = Range(match.range, in: text) else { continue }
            let matched = String(text[matchedRange])
            let matchedNSRange = NSRange(matched.startIndex..<matched.endIndex, in: matched)
            if let quotedMatch = quotedValueAtEndRegex.firstMatch(in: matched, options: [], range: matchedNSRange),
               let quotedRange = Range(quotedMatch.range, in: matched) {
                return String(matched[quotedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var cleaned = matched
            cleaned = stripLoggedInUsingRegex.stringByReplacingMatches(
                in: cleaned, options: [], range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned), withTemplate: ""
            )
            cleaned = stripAuthenticatedUsingRegex.stringByReplacingMatches(
                in: cleaned, options: [], range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned), withTemplate: ""
            )
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    private static func accountAuthMethod(from value: Any) -> String? {
        if let array = value as? [Any] {
            for entry in array {
                if let nested = accountAuthMethod(from: entry) { return nested }
            }
            return nil
        }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["authMethod", "authenticationMethod", "loginMethod", "method", "type"] {
            if let method = object[key] as? String,
               !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return method
            }
        }
        for key in ["account", "user", "profile", "session", "auth"] {
            if let nested = object[key], let method = accountAuthMethod(from: nested) {
                return method
            }
        }
        return nil
    }

    private static func updateAdvisory(from text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            guard lower.contains("update available")
                    || lower.contains("new version available")
                    || lower.contains("newer version")
                    || lower.contains("outdated") else { continue }
            return line.isEmpty ? nil : line
        }
        return nil
    }

}
