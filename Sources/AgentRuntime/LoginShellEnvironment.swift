import Foundation

/// Captures the user's LOGIN-SHELL exported environment once per app run so that
/// agent-turn spawns receive the same secrets/PATH an interactive terminal would.
///
/// WHY: a Finder/Dock/launchd-launched GUI app inherits only the minimal launchd
/// environment — it does NOT source `~/.zprofile`/`~/.zshrc`, so anything the user
/// exports there (e.g. `RUNPOD_API_KEY`, custom `PATH`, tokens an MCP server needs)
/// is invisible to agents, even though the embedded terminal has them (it spawns a
/// real login+interactive shell on a PTY). This type closes that asymmetry.
///
/// Design constraints (from the sam-council review):
/// - PURE, fixture-testable parser decoupled from the live shell spawn.
/// - Non-blocking: `current()` never blocks a caller/main thread; it kicks a
///   single-flight async capture and returns the cached result once ready, else nil
///   (callers fail-open to the GUI env for that turn).
/// - Bounded retry + negative caching: a shell that keeps timing out is attempted at
///   most `maxAttempts` times, then a terminal "gave up" state is cached so turns do
///   not re-pay the cost (no per-turn thrash).
/// - Fail-LOUD, never silent: capture failure logs a NON-SECRET diagnostic so a
///   missing-secret run is explainable instead of mysterious.
/// - Never logs variable names or values.
///
/// This type only CAPTURES + PARSES the raw shell env. All policy (delta-over-GUI
/// merge, auth/loader stripping, PATH composition) lives in `CodexRunner`.
public enum LoginShellEnvironment {
    /// Marker printed to stdout BEFORE `env -0` so the parser can discard any shell
    /// startup noise (prompts, plugin banners) that precedes it.
    public static let sentinel = "__RC_LOGIN_ENV_V1__"

    private static let maxAttempts = 2
    private static let captureTimeout: TimeInterval = 6
    private static let outputCap = 4 * 1024 * 1024

    private static let lock = NSLock()
    private static var attempts = 0
    private static var finished = false
    private static var captured: [String: String]?
    private static var inFlight = false

    // MARK: Pure parser (fixture-testable)

    /// Parses NUL-delimited `KEY=VALUE` records that appear AFTER the sentinel.
    ///
    /// - Splits each record on the FIRST `=` only; values may legitimately contain
    ///   `=` (e.g. `LS_COLORS`, connection strings, base64/JWT tokens) and are never
    ///   rejected.
    /// - Returns nil when the sentinel is absent (capture produced only noise /
    ///   failed) so the caller fail-opens instead of trusting a partial dictionary.
    public static func parse(_ bytes: Data, sentinel: String = sentinel) -> [String: String]? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        guard let markerRange = text.range(of: "\u{0}" + sentinel + "\u{0}") else { return nil }
        let payload = text[markerRange.upperBound...]
        var out: [String: String] = [:]
        for record in payload.split(separator: "\u{0}", omittingEmptySubsequences: true) {
            guard let eq = record.firstIndex(of: "=") else { continue }
            let key = String(record[record.startIndex..<eq])
            guard !key.isEmpty else { continue }
            out[key] = String(record[record.index(after: eq)...])
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Non-blocking accessor

    /// The captured login-shell env if ready, else nil. NEVER blocks. First call
    /// kicks a single-flight async capture; subsequent turns get the cached result.
    public static func current(
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String]? {
        lock.lock()
        if finished {
            let value = captured
            lock.unlock()
            return value
        }
        let start = !inFlight && attempts < maxAttempts
        if start { inFlight = true; attempts += 1 }
        let attemptNo = attempts
        lock.unlock()

        if start {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = captureOnce(parentEnvironment: parentEnvironment)
                lock.lock()
                inFlight = false
                if let result {
                    captured = result
                    finished = true
                } else if attemptNo >= maxAttempts {
                    captured = nil
                    finished = true
                    lock.unlock()
                    FileHandle.standardError.write(Data(
                        "[RemoteCode] login-shell env capture failed after \(maxAttempts) attempts; agents run with the GUI environment (secrets exported only in your shell profile will be missing). Set RC_LOGIN_SHELL_ENV_IMPORT=0 to disable this feature.\n".utf8))
                    return
                }
                lock.unlock()
            }
        }
        return nil
    }

    /// Kick the capture at app launch so the cache is usually hot before turn 1.
    public static func prewarm(
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        _ = current(parentEnvironment: parentEnvironment)
    }

    /// Test-only reset of the memoized state.
    static func resetForTesting() {
        lock.lock()
        attempts = 0; finished = false; captured = nil; inFlight = false
        lock.unlock()
    }

    /// Test-only: pin a terminal captured result so `current()` returns it
    /// synchronously without spawning a shell (nil = pin a terminal capture failure).
    static func setForTesting(_ env: [String: String]?) {
        lock.lock()
        captured = env; finished = true; inFlight = false; attempts = maxAttempts
        lock.unlock()
    }

    // MARK: Capture (injectable spawn)

    typealias Spawn = (_ shell: String, _ args: [String], _ env: [String: String], _ timeout: TimeInterval) -> Data?

    /// One capture attempt. `spawn` is injectable so tests exercise parsing / policy
    /// against fixtures without a real shell.
    static func captureOnce(
        parentEnvironment: [String: String],
        shellPath: String? = nil,
        spawn: Spawn? = nil
    ) -> [String: String]? {
        let shell = (shellPath ?? parentEnvironment["SHELL"]).flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // Print the sentinel, then exec real /usr/bin/env (never a user PATH / alias /
        // managed-wrapper `env`). `-l -i` matches the terminal's login+interactive
        // shell so profile-only (`~/.zshrc`) exports are captured.
        let command = "/usr/bin/printf '\\000%s\\000' '\(sentinel)'; exec /usr/bin/env -0"
        let args = ["-l", "-i", "-c", command]
        // Match the embedded terminal's TERM so $TERM/tty-gated profile branches
        // behave closer to a real terminal. (True tty-only `[ -t 1 ]` exports remain
        // unreachable without a PTY — a documented limitation.)
        var captureEnv = parentEnvironment
        if (captureEnv["TERM"] ?? "").isEmpty { captureEnv["TERM"] = "xterm-256color" }
        let runner = spawn ?? defaultSpawn
        guard let data = runner(shell, args, captureEnv, captureTimeout) else { return nil }
        return parse(data)
    }

    /// Default spawn: own stdin from /dev/null, discard stderr (so a flooding rc
    /// cannot deadlock the stdout pipe), read stdout up to a cap on a background
    /// queue, and hard-timeout by terminating then SIGKILLing the shell.
    ///
    /// NOTE: uses `Process` (SIGTERM/SIGKILL to the shell). A daemon the rc detaches
    /// with `setsid`/`disown` can outlive the shell; this is a documented residual —
    /// the capture runs at most `maxAttempts` times per app run, so any such side
    /// effect fires at most twice, matching what opening a terminal would do anyway.
    private static func defaultSpawn(
        shell: String, args: [String], env: [String: String], timeout: TimeInterval
    ) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = args
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        let handle = outPipe.fileHandleForReading

        var out = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while out.count < outputCap {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                out.append(chunk)
            }
            readDone.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do {
            try proc.run()
        } catch {
            return nil
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        _ = readDone.wait(timeout: .now() + 2)
        try? handle.close()
        return out.isEmpty ? nil : out
    }
}
