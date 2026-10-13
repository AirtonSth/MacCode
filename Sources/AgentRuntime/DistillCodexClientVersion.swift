import Foundation

/// The Codex client version Distill names when it asks the ChatGPT backend
/// for its models (`GET <codex base>/models?client_version=V`), resolved the
/// way the Mac's Distill resolves it. The backend lists newer models only to
/// newer clients, and the bot's Linux guest has no `codex` to read a version
/// from, so without this the guest asks as Distill's built-in default and can
/// miss a model the Mac lists (and the model picker offers).
public enum DistillCodexClientVersion {
    public static let environmentKey = "DISTILL_CODEX_CLIENT_VERSION"
    static let legacyEnvironmentKey = "REMOTE_CODE_CODEX_CLIENT_VERSION"
    /// `codex --version` answers in milliseconds; a hung one must not hold a run.
    public static let probeTimeout: TimeInterval = 3

    /// The output of `codex --version` for the `codex` an environment's PATH
    /// finds; nil when there is none, it fails or it does not answer in time.
    public typealias Probe = @Sendable (_ environment: [String: String]) async -> String?

    /// The version a Distill started with `environment` would use, or nil when
    /// it would fall back to its built-in default (the guest then does too).
    /// An override that is set but not acceptable also gives nil: the Mac's
    /// Distill uses that override and never looks at `codex`, so no other
    /// value would be the Mac's.
    public static func resolve(
        environment: [String: String],
        probe: Probe = { await installedCodexVersionOutput(environment: $0) }
    ) async -> String? {
        // distill-shell/src/codex_auth.rs:1472-1486 codex_client_version: the first non-blank override, then the installed CLI.
        let override = [environmentKey, legacyEnvironmentKey].lazy
            .compactMap { environment[$0] }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let override { return isAcceptable(override) ? override : nil }
        guard let output = await probe(environment), let version = parse(output) else { return nil }
        return isAcceptable(version) ? version : nil
    }

    /// distill-shell/src/codex_auth.rs:1464-1470 parse_codex_cli_version: `codex-cli <version>`, trimmed.
    static func parse(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("codex-cli ") else { return nil }
        let version = String(trimmed.dropFirst("codex-cli ".count))
        return version.isEmpty ? nil : version
    }

    /// 1 to 64 ASCII characters, the first a digit, the rest digits, letters,
    /// `.`, `-` or `+` (`0.162.1`, `0.163.0-alpha.3`, `1.0.0+build.5`). Nothing
    /// else reaches the guest's env file: no space, line break, quote or `=`.
    public static func isAcceptable(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        return (1...64).contains(bytes.count) && bytes.first.map(digit) == true
            && bytes.allSatisfy {
                digit($0) || (97...122).contains($0) || (65...90).contains($0) || $0 == 46 || $0 == 45 || $0 == 43
            }
    }

    /// Runs `codex --version` on a dedicated thread. `ProcessLocator` searches
    /// the PATH every provider process is started with and skips the app's
    /// `codex` proxy in `~/.remote-code/bin`, which runs that same real CLI.
    public static func installedCodexVersionOutput(
        environment: [String: String], timeout: TimeInterval = probeTimeout
    ) async -> String? {
        await ProviderCLIProbe.runOffCooperativePool {
            // distill-shell/src/codex_auth.rs:1453-1462 installed_codex_version: stdout of a successful `codex --version`.
            let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
            // Of the run's environment only PATH goes to the child (`codex` can
            // be a node script): `ProviderCLIProbe.run` lays it over the app's
            // own support-process environment, never the run's secrets.
            guard let codex = ProcessLocator.resolve("codex", environmentPath: environment["PATH"], homeDirectory: home),
                  let result = ProviderCLIProbe.run(
                      binaryPath: codex, arguments: ["--version"],
                      environment: environment["PATH"].map { ["PATH": $0] } ?? [:], timeoutSeconds: timeout
                  ), result.status == 0 else { return nil }
            return result.stdout
        }
    }
}
