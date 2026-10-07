import Foundation
import CoreModel
import Darwin

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

    /// Peak retained stdout/stderr per probe. Matches account usage /usage PTY
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
    private final class PipeDrainControl: @unchecked Sendable {
        private let lock = NSLock()
        private var deadline: Date?

        func finishRoot() {
            lock.lock()
            deadline = Date().addingTimeInterval(BoundedPipeDrain.defaultTimeout)
            lock.unlock()
        }

        var shouldStop: Bool {
            lock.lock()
            defer { lock.unlock() }
            return deadline.map { Date() >= $0 } ?? false
        }
    }

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

    /// Runs blocking probe work on a dedicated thread so a caller never parks a
    /// Swift cooperative-pool thread on child-process I/O.
    public static func runOffCooperativePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: body()) }
        }
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
    /// macOS account, run through the same installed helper path execution
    /// uses (non-interactive). A HOME-only probe as the app owner
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
        case .distill:
            let processEnvironment = ProcessInfo.processInfo.environment
            // Foreign users use their own home; only the app owner inherits process DISTILL_HOME.
            var distillEnvironment = environment
            if runAsUser == nil, distillEnvironment["DISTILL_HOME"] == nil {
                distillEnvironment["DISTILL_HOME"] = processEnvironment["DISTILL_HOME"]
            }
            let home = DistillProvisioner.homeURL(
                environment: distillEnvironment,
                userHome: runAsUser?.homePath ?? FileManager.default.homeDirectoryForCurrentUser.path
            )
            if let runAsUser, !runAsUser.isCurrentAccount,
               !FileManager.default.isReadableFile(atPath: home.path) {
                return AuthStatus(authenticated: nil, accountLabel: nil, accountAuthMethod: nil)
            }
            let connected = DistillAccounts.connectedAccounts(home: home).filter(\.connected)
            let first = connected.first
            return AuthStatus(
                authenticated: first != nil,
                accountLabel: first.map { $0.email ?? $0.provider.displayName },
                accountAuthMethod: nil
            )
        }
        guard let result = run(
            binaryPath: binaryPath,
            arguments: arguments,
            environment: environment,
            runAsUser: runAsUser,
            timeoutSeconds: timeoutSeconds
        ) else {
            // A missing helper may fail closed — unknown, not "logged out".
            // Auto may still admit; the real spawn performs one-time install.
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
        case .codex, .claude, .grok, .distill:
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
        retention: PipeAccumulator.Retention = .prefix,
        currentDirectory: String? = nil
    ) -> CommandResult? {
        let trimmed = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.isExecutableFile(atPath: trimmed) else { return nil }

        let baseEnv = CodexRunner.processEnvironment(overrides: environment, purpose: .supportProcess)
        let launchPlan: RunAsUserProcessBootstrap.LaunchPlan
        do {
            // Probes stay non-interactive: the installed helper must already
            // exist, otherwise capability detection fails closed.
            launchPlan = try RunAsUserProcessBootstrap.plan(
                executablePath: trimmed,
                arguments: arguments,
                environment: baseEnv,
                currentDirectory: currentDirectory ?? FileManager.default.currentDirectoryPath,
                runAsUser: runAsUser
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
        let drainControl = PipeDrainControl()
        var stdoutTruncated = false
        var stderrTruncated = false
        var renderedStdout = ""
        var renderedStderr = ""

        drainDone.enter()
        Thread.detachNewThread {
            let drained = Self.drainCappedResult(
                from: out.fileHandleForReading,
                maxBytes: outputByteLimit,
                retention: retention,
                control: drainControl
            )
            resultLock.lock(); stdoutData = drained.data; stdoutTruncated = drained.truncated; renderedStdout = drained.renderedString; resultLock.unlock()
            drainDone.leave()
        }

        drainDone.enter()
        Thread.detachNewThread {
            let drained = Self.drainCappedResult(
                from: err.fileHandleForReading,
                maxBytes: outputByteLimit,
                retention: retention,
                control: drainControl
            )
            resultLock.lock(); stderrData = drained.data; stderrTruncated = drained.truncated; renderedStderr = drained.renderedString; resultLock.unlock()
            drainDone.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }

        do {
            try proc.run()
            // The child inherited duplicate write descriptors. Close only the
            // parent's copies so ordinary probes deliver EOF immediately;
            // a descendant that inherited a child copy remains bounded by the
            // post-root drain deadline below.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            drainControl.finishRoot()
            drainDone.wait()
            return nil
        }

        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            let foreignUserUID: uid_t? = {
                guard let uid = runAsUser?.uid, uid != getuid() else { return nil }
                return uid
            }()
            ProcessTerminator.terminateTreeImmediately(proc, foreignUserUID: foreignUserUID)
            _ = finished.wait(timeout: .now() + 0.2)
            drainControl.finishRoot()
            drainDone.wait()
            return nil
        }

        // A provider wrapper may exit after spawning a descendant that retains
        // stdout/stderr. Give already-buffered bytes a short drain window, but
        // never wait forever for EOF from a process the probe does not own.
        drainControl.finishRoot()
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

    private static func drainCappedResult(
        from handle: FileHandle,
        maxBytes: Int,
        retention: PipeAccumulator.Retention,
        control: PipeDrainControl? = nil
    ) -> DrainedOutput {
        let descriptor = handle.fileDescriptor
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags != -1,
              fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) != -1 else {
            try? handle.close()
            return DrainedOutput(data: Data(), truncated: false, renderedString: "")
        }
        defer { try? handle.close() }

        var acc = PipeAccumulator(maxBytes: maxBytes, retention: retention)
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            if control?.shouldStop == true { break }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                acc.append(Data(buffer.prefix(count)))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { break }

            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pollDescriptor, 1, 25)
            if pollResult < 0, errno != EINTR { break }
            if pollDescriptor.revents & Int16(POLLNVAL) != 0 { break }
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
        for rawLine in text.split(whereSeparator: \.isNewline).lazy {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.range(of: "update available", options: .caseInsensitive) != nil
                    || line.range(of: "new version available", options: .caseInsensitive) != nil
                    || line.range(of: "newer version", options: .caseInsensitive) != nil
                    || line.range(of: "outdated", options: .caseInsensitive) != nil else { continue }
            return line.isEmpty ? nil : line
        }
        return nil
    }

}
