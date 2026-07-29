import CoreModel
import Darwin
import Foundation

/// Pure policy for the RemoteCode nested-provider PATH controller.
///
/// The OS half (spawn, streams, receipts) lives in `RemoteCodeDistillService`;
/// everything here is deterministic and free of process I/O so unit tests cover
/// resolution, recursion avoidance, node ids, and status mapping without spawning.
///
/// Contract:
/// - Resolve the real provider executable outside the managed bin / self.
/// - Never parse prompts, transcripts, tool output, or secrets into node ids.
/// - Fail open: missing real binary or missing telemetry scope is a non-proxy path.
/// - Do not invent Token Saver admission; the parent environment is authoritative.
public enum ProviderProxyPolicy {
    public static var providerCommands: Set<String> { ProviderProxyCatalog.providerSet }

    public static func isProviderProxy(_ command: String) -> Bool {
        ProviderProxyCatalog.isProviderProxyCommand(command)
    }

    public static func commandBasename(_ command: String) -> String {
        ProviderProxyCatalog.commandBasename(command)
    }

    // MARK: - telemetry scope (content-free)

    /// Thread-scoped Subagents telemetry is present when the host injected the
    /// always-on scope keys. Token Saver lanes are orthogonal and not required.
    public static func hasTelemetryScope(environment: [String: String]) -> Bool {
        let thread = (environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"]
            ?? environment["RC_TOKEN_SAVER_THREAD_ID"]
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = (environment["REMOTE_CODE_AGENT_PROVIDER"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !thread.isEmpty && UUID(uuidString: thread) != nil && AgentProvider(rawValue: provider) != nil
    }

    // MARK: - node id (bounded, content-free)

    /// Stable bounded node id: provider + invocation metadata only.
    /// Never includes argv prompt text, file contents, or secrets.
    public static func makeNodeId(
        providerBasename: String,
        processIdentifier: Int32,
        monotonicNanos: UInt64
    ) -> String {
        let provider = sanitizeToken(commandBasename(providerBasename), fallback: "provider")
        let pid = max(0, processIdentifier)
        let hex = String(monotonicNanos, radix: 16)
        let raw = "nested.\(provider).\(pid).\(hex)"
        return String(raw.prefix(128))
    }

    private static func sanitizeToken(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return fallback }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
        return filtered.isEmpty ? fallback : filtered
    }

    // MARK: - exit status → AgentRunStatus

    /// Map a child process termination to Subagents receipt status.
    /// - exit 0 → completed
    /// - SIGINT / SIGTERM (uncaught signal) → cancelled
    /// - any other nonzero / signal → failed
    public static func runStatus(
        wasUncaughtSignal: Bool,
        terminationStatus: Int32,
        forwardedSignal: Int32? = nil
    ) -> AgentRunStatus {
        if let forwardedSignal, forwardedSignal == SIGINT || forwardedSignal == SIGTERM {
            return .cancelled
        }
        if wasUncaughtSignal {
            if terminationStatus == SIGINT || terminationStatus == SIGTERM {
                return .cancelled
            }
            return .failed
        }
        if terminationStatus == 0 {
            return .completed
        }
        return .failed
    }

    // MARK: - real-binary resolution (recursion guard)

    /// Resolve the real provider executable, skipping the managed bin and any
    /// candidate that resolves to this proxy binary itself.
    public static func resolveRealExecutable(
        command: String,
        pathEntries: [String],
        managedBinDirectory: String,
        isExecutableFile: (String) -> Bool,
        resolvesToSelf: (String) -> Bool
    ) -> String? {
        CommandWrapPolicy.resolveRealExecutable(
            command: command,
            pathEntries: pathEntries,
            managedBinDirectory: managedBinDirectory,
            isExecutableFile: isExecutableFile,
            resolvesToSelf: resolvesToSelf
        )
    }

    /// Whether a PATH candidate under the managed bin is a provider proxy shim
    /// that host launchers must skip so top-level turns use the real CLI.
    public static func isManagedProviderProxyPath(
        command: String,
        candidatePath: String,
        managedBinDirectory: String,
        symlinkDestination: (String) -> String?
    ) -> Bool {
        guard isProviderProxy(command) else { return false }
        let managed = normalizedDirectory(managedBinDirectory)
        let candidateDir = normalizedDirectory((candidatePath as NSString).deletingLastPathComponent)
        guard candidateDir == managed else { return false }
        // Symlink to our service (or any non-regular destination we own) counts.
        if let dest = symlinkDestination(candidatePath) {
            let base = (dest as NSString).lastPathComponent
            if base == "RemoteCodeDistillService" || dest.contains("RemoteCodeDistillService") {
                return true
            }
            // Any symlink we placed in managed bin for a provider basename is a proxy.
            return true
        }
        return false
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
