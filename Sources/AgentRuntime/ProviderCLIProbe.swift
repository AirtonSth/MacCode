import Foundation
import CoreModel

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

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
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
        let arguments: [String]
        switch provider {
        case .codex:
            arguments = ["login", "status"]
        case .claude:
            arguments = ["auth", "status"]
        }
        guard let result = run(binaryPath: binaryPath, arguments: arguments, environment: environment, timeoutSeconds: timeoutSeconds) else {
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

    public static func slashCommands(provider: AgentProvider, binaryPath: String, environment: [String: String] = [:], timeoutSeconds: TimeInterval = 2.0) -> [String] {
        guard let result = run(binaryPath: binaryPath, arguments: ["--help"], environment: environment, timeoutSeconds: timeoutSeconds),
              result.status == 0 else { return [] }
        return parseCommands(from: result.stdout)
    }

    public static func update(provider: AgentProvider, binaryPath: String, environment: [String: String] = [:], timeoutSeconds: TimeInterval = 120.0) -> UpdateResult {
        let arguments: [String]
        switch provider {
        case .codex, .claude:
            arguments = ["update"]
        }
        guard let result = run(binaryPath: binaryPath, arguments: arguments, environment: environment, timeoutSeconds: timeoutSeconds) else {
            return UpdateResult(ok: false, status: -1, stdout: "", stderr: "provider update command failed to start or timed out")
        }
        return UpdateResult(ok: result.status == 0, status: result.status, stdout: result.stdout, stderr: result.stderr)
    }

    private static func run(binaryPath: String, arguments: [String], environment: [String: String], timeoutSeconds: TimeInterval) -> CommandResult? {
        let trimmed = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.isExecutableFile(atPath: trimmed) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: trimmed)
        proc.arguments = arguments
        proc.environment = CodexRunner.processEnvironment(overrides: environment)
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

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
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: proc.terminationStatus, stdout: stdout, stderr: stderr)
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

    private static func accountLabel(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let label = accountLabel(from: object) {
            return label
        }

        let patterns = [
            #"(?i)logged in as\s+([^\s<>()]+@[^\s<>()]+)"#,
            #"(?i)authenticated as\s+([^\s<>()]+@[^\s<>()]+)"#,
            #"(?i)"email"\s*:\s*"([^"]+)""#
        ]
        for pattern in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(text[match])
            if let email = matched.range(of: #"[^\s<>()"]+@[^\s<>()"]+"#, options: .regularExpression) {
                return String(matched[email])
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

    private static func accountAuthMethod(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let method = accountAuthMethod(from: object) {
            return method
        }

        let patterns = [
            #"(?i)logged in using\s+([A-Za-z0-9_. -]+)"#,
            #"(?i)authenticated using\s+([A-Za-z0-9_. -]+)"#,
            #"(?i)"authMethod"\s*:\s*"([^"]+)""#
        ]
        for pattern in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(text[match])
            if let quoted = matched.range(of: #"(?<=")[^"]+(?="$)"#, options: .regularExpression) {
                return String(matched[quoted]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let cleaned = matched
                .replacingOccurrences(of: #"(?i)logged in using"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)authenticated using"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func parseCommands(from helpText: String) -> [String] {
        var commands: [String] = []
        var inCommands = false
        for rawLine in helpText.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "Commands:" {
                inCommands = true
                continue
            }
            guard inCommands else { continue }
            if line.isEmpty { break }
            guard let token = line.split(whereSeparator: \.isWhitespace).first else { continue }
            let primary = String(token).split(separator: "|").first.map(String.init) ?? String(token)
            guard primary.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil,
                  primary != "help" else { continue }
            commands.append("/" + primary)
        }
        return unique(commands)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
