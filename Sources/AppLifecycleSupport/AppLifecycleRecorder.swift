import Foundation
import Darwin
import os

private let lifecycleRecorderLog = Logger(subsystem: "io.remotecode.app", category: "lifecycle")

// MARK: - Async-signal-safe signal handling
//
// These globals back a C signal handler. A signal handler may only call
// async-signal-safe functions, so it cannot touch Swift allocation, os_log,
// FileHandle, or Foundation. It writes a fixed message to a pre-opened fd,
// removes the run marker (so an intentional kill is not later misreported as a
// silent death), then restores the default disposition and re-raises so the
// process still terminates — letting a relaunch's `pkill` replace it.
private var lifecycleSignalLogFD: Int32 = -1
private var lifecycleSignalMarkerPath: UnsafeMutablePointer<CChar>?

/// The (async-signal-safe) log line written for a terminating signal. Pure;
/// extracted so the signal->message mapping is unit-testable (QA-mac:48).
func lifecycleSignalMessage(for signo: Int32) -> StaticString {
    switch signo {
    case SIGTERM: return "signal=SIGTERM terminating\n"
    case SIGINT: return "signal=SIGINT terminating\n"
    default: return "signal=other terminating\n"
    }
}

/// The signal handler's side effects: append the marker line to the open log fd
/// and unlink the run marker. Async-signal-safe (only write/unlink, no Swift
/// allocation). Extracted WITHOUT the re-raise so the write+unlink mechanics are
/// unit-testable in-process (QA-mac:48); the real handler below performs these
/// then re-raises with the default disposition so the signal still terminates.
func lifecycleSignalRecord(fd: Int32, markerPath: UnsafeMutablePointer<CChar>?, signo: Int32) {
    if fd >= 0 {
        lifecycleSignalMessage(for: signo).withUTF8Buffer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }
    if let path = markerPath {
        unlink(path)
    }
}

private func lifecycleSignalHandler(_ signo: Int32) {
    lifecycleSignalRecord(fd: lifecycleSignalLogFD, markerPath: lifecycleSignalMarkerPath, signo: signo)
    signal(signo, SIG_DFL)
    raise(signo)
}

// MARK: - Log rotation helpers (pure, no I/O - fully testable)

/// Returns true when the current log file should be rotated before the next
/// append. Rotation triggers when `size` exceeds `cap`. Both values must be
/// non-negative; a zero cap disables rotation (cap == 0 => never rotate).
public func shouldRotate(size: Int, cap: Int) -> Bool {
    guard cap > 0 else { return false }
    return size >= cap
}

/// Describes a pending rotation: the source file to rename and the destination
/// it should be moved to. The caller owns all I/O.
public struct LogRotationPlan: Equatable {
    /// The live log file that will become the backup.
    public let source: URL
    /// Where the backup copy will land (overwrites any existing .1 backup).
    public let backup: URL

    public init(source: URL, backup: URL) {
        self.source = source
        self.backup = backup
    }
}

/// Produces a rotation plan for `logURL` without touching the filesystem.
/// The backup file gets a `.1` suffix appended to the source URL's last path
/// component (e.g. `lifecycle.log` -> `lifecycle.log.1`).
public func rotationPlan(for logURL: URL) -> LogRotationPlan {
    let backupName = logURL.lastPathComponent + ".1"
    let backup = logURL.deletingLastPathComponent().appendingPathComponent(backupName)
    return LogRotationPlan(source: logURL, backup: backup)
}

/// Records app start/stop, periodic heartbeats and termination signals to a
/// persistent on-disk log so a silent disappearance leaves a forensic trail even
/// when the app was launched from a terminal (invisible to unified logging).
///
/// A "run marker" file is written at launch and removed only on a clean
/// `applicationWillTerminate` (or by the signal handler for an intentional
/// SIGTERM/SIGINT). If the marker survives into the next launch — with no
/// `signal=` line and no `atexit` line — the previous run was hard-killed
/// (SIGKILL/jetsam) with no chance to record anything. If an `atexit` line is
/// present but no `will_terminate`, the process exited via `exit()` outside the
/// AppKit terminate flow (e.g. a fatal `exit()` inside an embedded library).
///
/// Log rotation: before each append the file size is checked. When the file
/// exceeds `rotationCapBytes` (default 2 MB) the log is renamed to
/// `lifecycle.log.1` (overwriting any existing backup) and a fresh
/// `lifecycle.log` is started. Only one backup generation is kept to bound
/// disk usage.
public final class AppLifecycleRecorder {
    /// Default rotation cap: 2 MB.
    public static let defaultRotationCapBytes: Int = 2 * 1024 * 1024

    /// Shared ISO8601 formatter -- constructing one per call is ~200 us;
    /// reusing it makes timestamp() effectively free.
    /// ISO8601DateFormatter is not thread-safe; all calls must be serialized
    /// via `ioQueue` before use.
    private static let sharedFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private let directory: URL
    private let logURL: URL
    private let markerURL: URL
    private var heartbeatSeq = 0
    /// Persistent write handle; nil until first append, closed on rotation.
    private var logHandle: FileHandle?
    /// Serializes all I/O and formatter access (ISO8601DateFormatter is not
    /// thread-safe; FileHandle state is mutable). Matches the original
    /// per-call isolation without paying allocation costs on every append.
    private let ioQueue = DispatchQueue(label: "io.remotecode.lifecycle.io")
    /// Maximum lifecycle.log size before rotation. 0 = disabled.
    public let rotationCapBytes: Int

    public init(directory: URL, rotationCapBytes: Int = AppLifecycleRecorder.defaultRotationCapBytes) {
        self.directory = directory
        self.rotationCapBytes = rotationCapBytes
        self.logURL = directory.appendingPathComponent("lifecycle.log")
        // Per-pid marker: two processes on one App Support (e.g. an old build
        // without the instance lock) must not overwrite each other's evidence.
        self.markerURL = directory.appendingPathComponent("running.\(ProcessInfo.processInfo.processIdentifier).marker")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Recording

    public func record(_ event: String) {
        // Build the timestamp and append while holding ioQueue so the shared
        // formatter and logHandle are never accessed concurrently.
        let pid = ProcessInfo.processInfo.processIdentifier
        ioQueue.sync {
            let line = "\(Self.sharedFormatter.string(from: Date())) pid=\(pid) \(event)\n"
            appendOnQueue(line)
        }
        lifecycleRecorderLog.info("app.lifecycle \(event, privacy: .public)")
    }

    /// Mark the process as running. Call as early as possible after bootstrap.
    public func beginRun() {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Format timestamp outside ioQueue; record() will re-enter ioQueue for
        // the append. Using the shared formatter here is safe because beginRun
        // is called once at startup before concurrent callers exist.
        let ts = Self.sharedFormatter.string(from: Date())
        var marker = "pid=\(pid) startedAt=\(ts)"
        if let start = Self.processStartTime(pid: pid) {
            marker += " procStart=\(start)"
        }
        try? Data(marker.utf8).write(to: markerURL)
        record("launch \(marker)")
#if DEBUG
        // Debug builds run SwiftUI diffing / JSON decode 5-20x slower; one
        // boot line makes a debug-packaged app identifiable in perf triage
        // (perf audit X-00).
        record("build=debug")
#endif
    }

    /// Clear the run marker; call from `applicationWillTerminate` so the next
    /// launch can tell a clean shutdown apart from an abrupt death.
    public func endRunCleanly(reason: String) {
        record("will_terminate reason=\(reason)")
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Periodic liveness + memory sample, written to the FILE (not just unified
    /// logging, which drops `.info`). A gap between the last heartbeat and an
    /// unclean exit localizes a main-thread hang; a climbing rssKB localizes an
    /// out-of-memory kill.
    public func recordHeartbeat(
        reason: String,
        providerProcesses: Int? = nil,
        providerRSSKB: Int? = nil,
        orphanProviders: Int? = nil,
        sidecarProcesses: Int? = nil,
        sidecarRSSKB: Int? = nil,
        orphanSidecars: Int? = nil
    ) {
        heartbeatSeq += 1
        var fields = [
            "heartbeat seq=\(heartbeatSeq)",
            "reason=\(reason)",
            "rssKB=\(Self.footprintKB())"
        ]
        if let providerProcesses { fields.append("providerProcesses=\(providerProcesses)") }
        if let providerRSSKB { fields.append("providerRSSKB=\(providerRSSKB)") }
        if let orphanProviders { fields.append("orphanProviders=\(orphanProviders)") }
        if let sidecarProcesses { fields.append("sidecarProcesses=\(sidecarProcesses)") }
        if let sidecarRSSKB { fields.append("sidecarRSSKB=\(sidecarRSSKB)") }
        if let orphanSidecars { fields.append("orphanSidecars=\(orphanSidecars)") }
        record(fields.joined(separator: " "))
        // The marker's modification time is the run's last sign of life, so the
        // next launch knows where to look for how this run ended.
        _ = utimes(markerURL.path, nil)
    }

    /// Every run marker whose process is gone belongs to a run that did not
    /// shut down cleanly. Returns those markers' contents (and removes them) so
    /// the caller can log them; returns [] when every prior run was clean.
    /// A marker whose pid is still alive with the same start time belongs to a
    /// live run and is left in place, so its later death is still detected.
    /// The legacy `running.marker` from older builds is checked the same way.
    @discardableResult
    public func consumeStaleRunMarkers() -> [String] {
        consumeStaleRunMarkerRecords().map(\.contents)
    }

    /// A consumed marker of a run that did not shut down cleanly.
    public struct StaleRunMarker: Equatable {
        public let contents: String
        public let pid: pid_t?
        /// The marker's modification time: the run's last heartbeat, or its
        /// launch when it never reached one.
        public let lastAlive: Date?
    }

    /// `consumeStaleRunMarkers`, keeping each marker's pid and last sign of life.
    @discardableResult
    public func consumeStaleRunMarkerRecords() -> [StaleRunMarker] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var stale: [StaleRunMarker] = []
        for name in names.sorted() where name.hasPrefix("running.") && name.hasSuffix(".marker") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let contents = String(data: data, encoding: .utf8) else { continue }
            if Self.markerOwnerIsAlive(contents) { continue }
            let lastAlive = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            try? FileManager.default.removeItem(at: url)
            stale.append(StaleRunMarker(
                contents: contents,
                pid: Self.markerField("pid", in: contents).flatMap { pid_t($0) },
                lastAlive: lastAlive
            ))
        }
        return stale
    }

    /// True when the marker's pid is running and is the same process that
    /// wrote it. `kill(pid, 0)` alone is not enough because pids are reused:
    /// the start time must equal the recorded `procStart`, or, for legacy
    /// markers without it, must not be later than `startedAt`.
    static func markerOwnerIsAlive(_ contents: String) -> Bool {
        guard let pidText = markerField("pid", in: contents),
              let pid = pid_t(pidText), pid > 0 else { return false }
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let currentStart = processStartTime(pid: pid) else { return false }
        if let recorded = markerField("procStart", in: contents) {
            return recorded == currentStart
        }
        guard let startedAtText = markerField("startedAt", in: contents),
              let startedAt = ISO8601DateFormatter().date(from: startedAtText),
              let currentSeconds = Double(currentStart) else { return false }
        return currentSeconds <= startedAt.timeIntervalSince1970 + 1
    }

    private static func markerField(_ key: String, in contents: String) -> String? {
        for token in contents.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let parts = token.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == key { return String(parts[1]) }
        }
        return nil
    }

    /// The kernel's start time for `pid` as "seconds.microseconds", or nil
    /// when the process does not exist.
    static func processStartTime(pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return String(format: "%ld.%06d", start.tv_sec, start.tv_usec)
    }

    // MARK: Signals & exit

    /// Termination policy by signal. SIGHUP (controlling-terminal/session
    /// hangup) must never kill the GUI app — a dev build launched from a shell
    /// would otherwise vanish when that shell closes. SIGTERM/SIGINT are
    /// intentional (e.g. a relaunch's `pkill`) and must still terminate, but
    /// recorded rather than silent.
    public static func shouldTerminate(onSignal signo: Int32) -> Bool {
        switch signo {
        case SIGTERM, SIGINT: return true
        case SIGHUP: return false
        default: return false
        }
    }

    /// Installs signal handling via `sigaction` (reliable under NSApplication's
    /// run loop, unlike a GCD signal source which does not fire when the signal
    /// is set to SIG_IGN). SIGHUP is ignored so a terminal hangup cannot kill the
    /// app; SIGTERM/SIGINT are recorded then re-raised so they still terminate.
    public func installSignalHandlers() {
        lifecycleSignalLogFD = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        lifecycleSignalMarkerPath = strdup(markerURL.path)

        signal(SIGHUP, SIG_IGN)

        var action = sigaction()
        action.__sigaction_u.__sa_handler = lifecycleSignalHandler
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        for signo in [SIGTERM, SIGINT] where Self.shouldTerminate(onSignal: signo) {
            sigaction(signo, &action, nil)
        }
    }

    /// Logs when the process exits via `exit()` / normal return. Combined with
    /// the absence of a `will_terminate` line, an `atexit` line proves the
    /// process left through `exit()` outside the AppKit terminate flow.
    public func installExitHandler() {
        atexit_b { [weak self] in
            self?.record("atexit process_exiting")
        }
    }

    // MARK: Helpers

    /// Must be called with `ioQueue` already held (sync or async).
    private func appendOnQueue(_ text: String) {
        rotateIfNeeded()
        let data = Data(text.utf8)
        if logHandle == nil {
            if FileManager.default.fileExists(atPath: logURL.path) {
                logHandle = try? FileHandle(forWritingTo: logURL)
            } else {
                try? data.write(to: logURL)
                logHandle = try? FileHandle(forWritingTo: logURL)
                return
            }
        }
        guard let handle = logHandle else {
            try? data.write(to: logURL)
            return
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Rotates lifecycle.log -> lifecycle.log.1 when the current file size
    /// meets or exceeds `rotationCapBytes`. The backup overwrites any existing
    /// .1 file; only one backup generation is kept.
    private func rotateIfNeeded() {
        guard rotationCapBytes > 0 else { return }
        let currentSize = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        guard shouldRotate(size: currentSize, cap: rotationCapBytes) else { return }
        // Close the persistent handle before moving the file so the move
        // succeeds on all APFS/HFS volumes and the next append opens fresh.
        try? logHandle?.close()
        logHandle = nil
        let plan = rotationPlan(for: logURL)
        // Overwrite any existing backup, then remove the live log so the next
        // append creates a fresh file.
        try? FileManager.default.removeItem(at: plan.backup)
        try? FileManager.default.moveItem(at: plan.source, to: plan.backup)
    }

    /// Test-only helper: formats a fixed date so tests can pin the formatter
    /// output without depending on wall-clock time. Do not call from I/O paths;
    /// use `sharedFormatter` via `ioQueue` there.
    static func timestamp(from date: Date) -> String {
        sharedFormatter.string(from: date)
    }

    private static func footprintKB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1024)
    }
}
