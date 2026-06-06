import Foundation
import Darwin
import CoreModel
import RemoteCodeCSystem

public struct TokenSaverAccountUsageRefreshRequest: Sendable, Equatable {
    public let codexBinary: String
    public let claudeBinary: String
    public let cwd: String
    public let environment: [String: String]

    public init(
        codexBinary: String = "codex",
        claudeBinary: String = "claude",
        cwd: String = NSHomeDirectory(),
        environment: [String: String] = [:]
    ) {
        self.codexBinary = codexBinary
        self.claudeBinary = claudeBinary
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
        let patterns = [
            #"(?i)(?:weekly|subscription|usage)[^\n\r%]{0,80}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)"#,
            #"(?i)([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:used|utilized)[^\n\r]{0,80}(?:weekly|subscription|usage)"#,
            #"(?i)(?:weekly|subscription|usage)[^\n\r%]{0,80}([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:remaining|left)"#
        ]
        for pattern in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(text[match])
            guard let numberRange = matched.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
                  let percent = Double(matched[numberRange]) else { continue }
            let lower = matched.lowercased()
            let used = (lower.contains("remaining") || lower.contains("left")) ? max(0, 100 - percent) : percent
            return AssistantAccountUsage(provider: .claude, weeklyUsedPercent: used, weeklyWindowDurationMinutes: 10_080)
        }
        return nil
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
            return claudeUsageText(normalized)
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
        return await [codex, claude]
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
        if let usage = runClaudeUsageScreen(request) {
            return usage
        }
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
        ), result.status == 0,
           let usage = AssistantAccountUsageParser.claudeUsageText(result.stdout) {
            return usage
        }
        return nil
    }

    private func runClaudeUsageScreen(_ request: TokenSaverAccountUsageRefreshRequest) -> AssistantAccountUsage? {
        guard let path = ProcessLocator.resolve(request.claudeBinary) else {
            return nil
        }

        var environment = CodexRunner.processEnvironment(overrides: request.environment)
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "C.UTF-8"
        environment["LC_ALL"] = environment["LC_ALL"] ?? "C.UTF-8"
        environment.removeValue(forKey: "NO_COLOR")
        let environmentPairs = environment.map { ($0.key, $0.value) }

        var masterFD: Int32 = -1
        let pid = rc2_forkpty(&masterFD)
        if pid < 0 { return nil }
        if pid == 0 {
            _ = chdir(request.cwd)
            for (key, value) in environmentPairs {
                key.withCString { keyPtr in
                    value.withCString { valuePtr in
                        _ = setenv(keyPtr, valuePtr, 1)
                    }
                }
            }
            path.withCString { executablePath in
                let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executablePath), nil]
                argv.withUnsafeBufferPointer { pointer in
                    _ = execv(executablePath, pointer.baseAddress)
                }
            }
            _exit(127)
        }

        defer { close(masterFD) }
        _ = rc2_set_winsize(masterFD, 40, 120)
        let flags = fcntl(masterFD, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK) }

        var output = Data()
        let readyDeadline = Date().addingTimeInterval(min(10, max(2, timeoutSeconds / 2)))
        while Date() < readyDeadline {
            _ = readAvailablePTY(masterFD, into: &output)
            let text = String(decoding: output.suffix(64_000), as: UTF8.self)
            if text.contains("❯") {
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        Thread.sleep(forTimeInterval: 0.25)

        writePTY(masterFD, Data("/usage\r".utf8))
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let childOpen = readAvailablePTY(masterFD, into: &output)
            let text = String(decoding: output.suffix(256_000), as: UTF8.self)
            if let usage = AssistantAccountUsageParser.claudeUsageScreen(text) {
                terminatePTYChild(pid)
                return usage
            }
            if !childOpen && !isChildRunning(pid) { break }
            Thread.sleep(forTimeInterval: 0.15)
        }

        writePTY(masterFD, Data("\u{1B}/exit\r".utf8))
        Thread.sleep(forTimeInterval: 0.2)
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
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == 0
    }

    private func terminatePTYChild(_ pid: Int32) {
        if !isChildRunning(pid) { return }
        Darwin.kill(pid, SIGTERM)
        let limit = Date().addingTimeInterval(0.8)
        while Date() < limit {
            if !isChildRunning(pid) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Darwin.kill(pid, SIGKILL)
        let killLimit = Date().addingTimeInterval(0.4)
        while Date() < killLimit {
            if !isChildRunning(pid) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
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
        proc.environment = CodexRunner.processEnvironment(overrides: environment)
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
