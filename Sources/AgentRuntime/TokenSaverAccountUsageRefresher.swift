import Foundation
import Darwin
import CoreModel
import RemoteCodeCSystem

public struct TokenSaverAccountUsageRefreshRequest: Sendable, Equatable {
    public let codexBinary: String
    public let claudeBinary: String
    public let grokBinary: String
    /// Override for tests; default is `~/.grok/logs/unified.jsonl`.
    public let grokBillingLogURL: URL?
    public let cwd: String
    public let environment: [String: String]

    public init(
        codexBinary: String = "codex",
        claudeBinary: String = "claude",
        grokBinary: String = "grok",
        grokBillingLogURL: URL? = nil,
        cwd: String = NSHomeDirectory(),
        environment: [String: String] = [:]
    ) {
        self.codexBinary = codexBinary
        self.claudeBinary = claudeBinary
        self.grokBinary = grokBinary
        self.grokBillingLogURL = grokBillingLogURL
        self.cwd = cwd
        self.environment = environment
    }
}

public protocol TokenSaverAccountUsageRefreshing: Sendable {
    func refreshAccountUsage(_ request: TokenSaverAccountUsageRefreshRequest) async -> [AssistantAccountUsage]
}

public enum AssistantAccountUsageParser {
    public static func codex(from payload: [String: Any]) -> AssistantAccountUsage? {
        let rateLimitsByLimitId = payload["rateLimitsByLimitId"] as? [String: Any]
            ?? payload["rate_limits_by_limit_id"] as? [String: Any]
        let rateLimits = rateLimitsByLimitId?["codex"] as? [String: Any]
            ?? payload["rateLimits"] as? [String: Any]
            ?? payload["rate_limits"] as? [String: Any]
            ?? payload
        let snapshot = weeklySnapshot(from: rateLimits)
        guard let usedPercent = double(snapshot["usedPercent"]) ?? double(snapshot["used_percent"]) else {
            return nil
        }
        return AssistantAccountUsage(
            provider: .codex,
            weeklyUsedPercent: usedPercent,
            weeklyWindowDurationMinutes: windowMinutes(from: snapshot),
            weeklyResetsAtMs: resetMilliseconds(from: snapshot["resetsAt"] ?? snapshot["resets_at"]),
            currentSessionUsedPercent: currentSessionUsedPercent(from: rateLimits),
            currentSessionResetsAtMs: currentSessionResetsAtMilliseconds(from: rateLimits)
        )
    }

    public static func claude(from payload: [String: Any]) -> AssistantAccountUsage? {
        let info = payload["rate_limit_info"] as? [String: Any]
            ?? payload["rateLimitInfo"] as? [String: Any]
            ?? payload["rateLimits"] as? [String: Any]
            ?? payload
        let snapshot = info["primary"] as? [String: Any]
            ?? info["weekly"] as? [String: Any]
            ?? info["allModels"] as? [String: Any]
            ?? info["all_models"] as? [String: Any]
            ?? info
        guard let usedPercent = double(snapshot["usedPercent"]) ?? double(snapshot["used_percent"]) else {
            return nil
        }
        return AssistantAccountUsage(
            provider: .claude,
            weeklyUsedPercent: usedPercent,
            weeklyWindowDurationMinutes: int(snapshot["windowDurationMins"]) ?? int(snapshot["window_duration_mins"]),
            weeklyResetsAtMs: resetMilliseconds(from: snapshot["resetsAt"] ?? snapshot["resets_at"] ?? payload["reset_at"] ?? payload["resetAt"]),
            currentSessionUsedPercent: currentSessionUsedPercent(from: info),
            currentSessionResetsAtMs: currentSessionResetsAtMilliseconds(from: info)
        )
    }

    public static func claudeUsageText(_ text: String) -> AssistantAccountUsage? {
        // Prefer the structured screen parser first: modern Claude Code headless
        // `/usage` prints one-line "Current week (all models): 54% used" which the
        // legacy weekly|subscription patterns miss, leaving Claude stuck at 0%.
        // NEVER recurse into claudeUsageScreen → claudeUsageText: empty/partial
        // probes would stack-overflow the detached refresh task.
        if let fromScreen = claudeUsageScreen(text) {
            return fromScreen
        }
        return claudeUsageLoosePatterns(text)
    }

    /// Non-recursive pattern pass used by both headless and screen parsers.
    /// WHY separate: `claudeUsageScreen` used to fall back into `claudeUsageText`,
    /// and after screen was preferred from text that became infinite recursion
    /// (signal 10 crash on empty / partial / remaining-only strings).
    private static func claudeUsageLoosePatterns(_ text: String) -> AssistantAccountUsage? {
        let patterns = [
            // Modern one-line: "Current week (all models): 54% used · resets ..."
            #"(?i)current\s*week\s*\(\s*all\s*models\s*\)[^\n\r%]{0,40}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)"#,
            #"(?i)(?:weekly|subscription|usage)[^\n\r%]{0,80}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)"#,
            #"(?i)([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)[^\n\r]{0,80}(?:weekly|subscription|usage|week)"#,
            #"(?i)(?:weekly|subscription|usage)[^\n\r%]{0,80}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:remaining|left)"#
        ]
        for pattern in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(text[match])
            guard let numberRange = matched.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
                  let percent = Double(matched[numberRange]) else { continue }
            let lower = matched.lowercased()
            let used = (lower.contains("remaining") || lower.contains("left")) ? max(0, 100 - percent) : percent
            // Also pick up session % when the modern one-liner is present.
            let session = firstPercent(in: text, patterns: [
                #"(?i)current\s*session[^\n\r%]{0,40}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)"#
            ])
            return AssistantAccountUsage(
                provider: .claude,
                weeklyUsedPercent: used,
                weeklyWindowDurationMinutes: 10_080,
                currentSessionUsedPercent: session
            )
        }
        return nil
    }

    /// Parses Grok shell billing log lines (`billing: fetched credits config`).
    ///
    /// Observed shape in `~/.grok/logs/unified.jsonl`:
    /// ```json
    /// {"msg":"billing: fetched credits config","ctx":{"config":{
    ///   "creditUsagePercent":29.0,
    ///   "billingPeriodEnd":"2026-07-15T20:46:41.975270+00:00",
    ///   "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",...}
    /// }}}
    /// ```
    public static func grokBillingLogLine(_ line: String) -> AssistantAccountUsage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return grokBillingJSON(obj)
    }

    public static func grokBillingJSON(_ obj: [String: Any]) -> AssistantAccountUsage? {
        let msg = (obj["msg"] as? String) ?? (obj["message"] as? String) ?? ""
        let ctx = obj["ctx"] as? [String: Any] ?? obj["context"] as? [String: Any] ?? obj
        let config = ctx["config"] as? [String: Any] ?? obj["config"] as? [String: Any]
        guard let config else { return nil }
        // Prefer billing log lines; also accept bare credit-config objects that
        // carry creditUsagePercent (unit tests / future cache files).
        let looksLikeBilling = msg.contains("billing") || msg.contains("credits")
            || config["creditUsagePercent"] != nil || config["credit_usage_percent"] != nil
        guard looksLikeBilling else { return nil }
        let percent = double(config["creditUsagePercent"])
            ?? double(config["credit_usage_percent"])
            ?? double(config["usedPercent"])
            ?? double(config["used_percent"])
        guard let percent else { return nil }
        let periodEnd = config["billingPeriodEnd"] as? String
            ?? config["billing_period_end"] as? String
            ?? (config["currentPeriod"] as? [String: Any])?["end"] as? String
            ?? (config["current_period"] as? [String: Any])?["end"] as? String
        let resetsAtMs = parseISO8601Milliseconds(periodEnd)
        return AssistantAccountUsage(
            provider: .grok,
            weeklyUsedPercent: percent,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAtMs: resetsAtMs
        )
    }

    /// Scans a Grok unified log file (newest first within the last `maxBytes`) for
    /// the freshest `billing: fetched credits config` entry.
    ///
    /// WHY maxBytes defaults to 4 MiB: real `unified.jsonl` files routinely put
    /// more than 512 KiB of non-billing traffic between credit snapshots (observed
    /// gaps > 800 KiB). A too-small window returns nil, the partial account-usage
    /// refresh treats Grok as missing, and Token Saver falsely paints Grok at 0%.
    public static func grokFromBillingLogFile(
        at url: URL,
        maxBytes: Int = 4 * 1024 * 1024
    ) -> AssistantAccountUsage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size: UInt64
        do {
            size = try handle.seekToEnd()
        } catch {
            return nil
        }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // Drop partial first line when we mid-started the file.
        var text = String(data: data, encoding: .utf8) ?? ""
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        // Newest last in the log — walk reverse.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if let usage = grokBillingLogLine(String(line)) {
                return usage
            }
        }
        return nil
    }

    private static func parseISO8601Milliseconds(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    public static func claudeUsageScreen(_ text: String) -> AssistantAccountUsage? {
        let normalized = terminalPlainText(text)
        let compacted = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
        let weeklyPatterns = [
            #"(?is)Current\s*week\s*\(\s*all\s*models\s*\).*?([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#,
            #"(?is)Weekly\s*limits?.*?all\s*models.*?([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#,
            #"(?is)(?:weekly|subscription|usage)[^\n\r%]{0,120}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)"#
        ]
        let compactedWeeklyPatterns = [
            #"(?is)Currentweek\(allmodels\).*?([0-9]+(?:\.[0-9]+)?)%used"#,
            #"(?is)Weeklylimits?.*?allmodels.*?([0-9]+(?:\.[0-9]+)?)%used"#
        ]
        guard let weeklyUsed = firstPercent(in: normalized, patterns: weeklyPatterns)
            ?? firstPercent(in: compacted, patterns: compactedWeeklyPatterns) else {
            // Loose patterns only — never claudeUsageText (would re-enter this path).
            return claudeUsageLoosePatterns(normalized)
        }
        let currentSessionUsed = firstPercent(in: normalized, patterns: [
            #"(?is)Current\s*session.*?([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
        ]) ?? firstPercent(in: compacted, patterns: [
            #"(?is)Curre(?:n)?tsession.*?([0-9]+(?:\.[0-9]+)?)%used"#
        ])
        return AssistantAccountUsage(
            provider: .claude,
            weeklyUsedPercent: weeklyUsed,
            weeklyWindowDurationMinutes: 10_080,
            currentSessionUsedPercent: currentSessionUsed
        )
    }

    private static func weeklySnapshot(from rateLimits: [String: Any]) -> [String: Any] {
        if let weekly = rateLimits["weekly"] as? [String: Any] {
            return weekly
        }
        let candidates = ["secondary", "primary"].compactMap { rateLimits[$0] as? [String: Any] }
        if let weekly = candidates.first(where: { (windowMinutes(from: $0) ?? 0) >= 10_080 }) {
            return weekly
        }
        if let largest = candidates.max(by: { (windowMinutes(from: $0) ?? 0) < (windowMinutes(from: $1) ?? 0) }) {
            return largest
        }
        return rateLimits
    }

    private static func currentSessionUsedPercent(from rateLimits: [String: Any]) -> Double? {
        let current = rateLimits["currentSession"] as? [String: Any]
            ?? rateLimits["current_session"] as? [String: Any]
            ?? rateLimits["primary"] as? [String: Any]
        guard let window = current,
              (windowMinutes(from: window) ?? 0) < 10_080 else {
            return nil
        }
        return double(window["usedPercent"])
            ?? double(window["used_percent"])
            ?? double(window["usedPercentage"])
            ?? double(window["used_percentage"])
    }

    private static func currentSessionResetsAtMilliseconds(from rateLimits: [String: Any]) -> Int64? {
        let current = rateLimits["currentSession"] as? [String: Any]
            ?? rateLimits["current_session"] as? [String: Any]
            ?? rateLimits["primary"] as? [String: Any]
        guard let window = current,
              (windowMinutes(from: window) ?? 0) < 10_080 else {
            return nil
        }
        return resetMilliseconds(from: window["resetsAt"] ?? window["resets_at"])
    }

    private static func firstPercent(in text: String, patterns: [String]) -> Double? {
        for pattern in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(text[match])
            guard let numberRange = matched.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) else {
                continue
            }
            return Double(matched[numberRange])
        }
        return nil
    }

    private static func terminalPlainText(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "\r", with: "\n")
        result = result.replacingOccurrences(
            of: "[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}\u{007F}]",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return result
    }

    private static func resetMilliseconds(from value: Any?) -> Int64? {
        if let int = int(value) {
            return int < 10_000_000_000 ? Int64(int) * 1000 : Int64(int)
        }
        guard let string = value as? String else { return nil }
        if let int = Int64(string) {
            return int < 10_000_000_000 ? int * 1000 : int
        }
        return ISO8601DateFormatter().date(from: string).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    private static func windowMinutes(from snapshot: [String: Any]) -> Int? {
        int(snapshot["windowDurationMins"])
            ?? int(snapshot["window_duration_mins"])
            ?? int(snapshot["windowMinutes"])
            ?? int(snapshot["window_minutes"])
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

public final class TokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing, @unchecked Sendable {
    private struct CommandResult {
        let status: Int32
        let stdout: String
    }

    private let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 18.0) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func refreshAccountUsage(_ request: TokenSaverAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
        async let codex = withProviderTimeout { await self.fetchCodexUsage(request) }
        async let claude = withProviderTimeout { await self.fetchClaudeUsage(request) }
        async let grok = withProviderTimeout { await self.fetchGrokUsage(request) }
        return await [codex, claude, grok]
            .compactMap { $0 }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    private func withProviderTimeout(
        _ operation: @escaping @Sendable () async -> AssistantAccountUsage?
    ) async -> AssistantAccountUsage? {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func resume(_ usage: AssistantAccountUsage?) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: usage)
            }
            let providerTimeout = UInt64(max(30, timeoutSeconds * 2 + 8) * 1_000_000_000)

            let work = Task.detached {
                let usage = await operation()
                resume(usage)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: providerTimeout)
                work.cancel()
                resume(nil)
            }
        }
    }

    private func fetchCodexUsage(_ request: TokenSaverAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        do {
            let client = try CodexAppServerClient(
                binary: request.codexBinary,
                arguments: ["app-server"],
                cwd: request.cwd,
                environment: request.environment
            )
            defer { client.stop() }
            _ = try await client.initialize(
                clientName: "remotecode",
                clientTitle: "RemoteCode",
                clientVersion: "0.0.0"
            )
            let response = try await client.requestJSONObject(method: "account/rateLimits/read")
            return AssistantAccountUsageParser.codex(from: response)
        } catch {
            return nil
        }
    }

    private func fetchClaudeUsage(_ request: TokenSaverAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        // Prefer the Process path (waitUntilExit) first — it never leaves PTY zombies.
        // Screen-capture PTY is fallback only when text /usage fails (plan-final W1).
        // Parse with claudeUsageText (which prefers claudeUsageScreen patterns) so
        // modern "Current week (all models): N% used" headless output is accepted
        // without spawning an interactive PTY.
        if let result = run(
            binary: request.claudeBinary,
            arguments: [
                "-p",
                "--output-format", "text",
                "--no-session-persistence",
                "--max-budget-usd", "0.01",
                "/usage"
            ],
            cwd: request.cwd,
            environment: request.environment
        ), result.status == 0 || !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let usage = AssistantAccountUsageParser.claudeUsageText(result.stdout) {
            return usage
        }
        if let usage = await runClaudeUsageScreen(request) {
            return usage
        }
        return nil
    }

    /// Grok weekly credit usage is written by the shell to
    /// `~/.grok/logs/unified.jsonl` (`billing: fetched credits config`).
    /// Headless `/usage` does not return a machine-readable account probe, so
    /// we read the freshest local billing snapshot (same source the TUI uses).
    private func fetchGrokUsage(_ request: TokenSaverAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        let url = request.grokBillingLogURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/logs/unified.jsonl")
        return AssistantAccountUsageParser.grokFromBillingLogFile(at: url)
    }

    private func runClaudeUsageScreen(_ request: TokenSaverAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        guard let path = ProcessLocator.resolve(request.claudeBinary) else {
            return nil
        }

        var environment = CodexRunner.processEnvironment(overrides: request.environment, purpose: .supportProcess)
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "C.UTF-8"
        environment["LC_ALL"] = environment["LC_ALL"] ?? "C.UTF-8"
        environment.removeValue(forKey: "NO_COLOR")
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        var envp = environment.sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }

        var masterFD: Int32 = -1
        let pid = request.cwd.withCString { cwdPointer in
            path.withCString { executablePointer in
                argv.withUnsafeMutableBufferPointer { argvPointer in
                    envp.withUnsafeMutableBufferPointer { envpPointer in
                        rc2_spawnpty_exec(
                            &masterFD,
                            cwdPointer,
                            executablePointer,
                            argvPointer.baseAddress,
                            envpPointer.baseAddress
                        )
                    }
                }
            }
        }
        guard pid > 0 else { return nil }

        defer { close(masterFD) }
        _ = rc2_set_winsize(masterFD, 40, 120)
        let flags = fcntl(masterFD, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK) }

        var output = Data()
        let readyDeadline = Date().addingTimeInterval(min(10, max(2, timeoutSeconds / 2)))
        while Date() < readyDeadline {
            if Task.isCancelled {
                terminatePTYChild(pid)
                return nil
            }
            _ = readAvailablePTY(masterFD, into: &output)
            let text = String(decoding: output.suffix(64_000), as: UTF8.self)
            if text.contains("❯") {
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        writePTY(masterFD, Data("/usage\r".utf8))
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Task.isCancelled {
                terminatePTYChild(pid)
                return nil
            }
            let childOpen = readAvailablePTY(masterFD, into: &output)
            let text = String(decoding: output.suffix(256_000), as: UTF8.self)
            if let usage = AssistantAccountUsageParser.claudeUsageScreen(text) {
                terminatePTYChild(pid)
                return usage
            }
            if !childOpen && !isChildRunning(pid) { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        writePTY(masterFD, Data("\u{1B}/exit\r".utf8))
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = readAvailablePTY(masterFD, into: &output)
        terminatePTYChild(pid)
        let text = String(decoding: output.suffix(256_000), as: UTF8.self)
        return AssistantAccountUsageParser.claudeUsageScreen(text)
    }

    private func readAvailablePTY(_ fd: Int32, into output: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer[0..<Int(count)])
                continue
            }
            if count == 0 { return false }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return true }
            return false
        }
    }

    private func writePTY(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func isChildRunning(_ pid: Int32) -> Bool {
        OwnedChildReaper.poll(pid: pid) == nil
    }

    private func terminatePTYChild(_ pid: Int32) {
        // Always terminate with a final waitpid so the child cannot remain <defunct>
        // (plan-final W1: 0.4s WNOHANG-only window left permanent zombies).
        _ = OwnedChildReaper.terminateAndReap(pid: pid)
    }

    private func terminateScriptProcess(_ proc: Process) {
        guard proc.isRunning else { return }
        signalChildren(of: proc.processIdentifier, signal: "TERM")
        proc.terminate()
        let limit = Date().addingTimeInterval(0.8)
        while Date() < limit, proc.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard proc.isRunning else { return }
        signalChildren(of: proc.processIdentifier, signal: "KILL")
        kill(proc.processIdentifier, SIGKILL)
        proc.waitUntilExit()
    }

    private func signalChildren(of pid: Int32, signal: String) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pkill") else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-\(signal)", "-P", "\(pid)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {}
    }

    private func run(
        binary: String,
        arguments: [String],
        cwd: String,
        environment: [String: String]
    ) -> CommandResult? {
        guard let path = ProcessLocator.resolve(binary) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = CodexRunner.processEnvironment(overrides: environment, purpose: .supportProcess)
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice

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
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: proc.terminationStatus, stdout: stdout)
    }
}
