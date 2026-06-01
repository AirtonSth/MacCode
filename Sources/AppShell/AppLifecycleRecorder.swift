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

private func lifecycleSignalHandler(_ signo: Int32) {
    let message: StaticString
    switch signo {
    case SIGTERM: message = "signal=SIGTERM terminating\n"
    case SIGINT: message = "signal=SIGINT terminating\n"
    default: message = "signal=other terminating\n"
    }
    if lifecycleSignalLogFD >= 0 {
        message.withUTF8Buffer { buf in
            _ = write(lifecycleSignalLogFD, buf.baseAddress, buf.count)
        }
    }
    if let path = lifecycleSignalMarkerPath {
        unlink(path)
    }
    signal(signo, SIG_DFL)
    raise(signo)
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
public final class AppLifecycleRecorder {
    private let directory: URL
    private let logURL: URL
    private let markerURL: URL
    private var heartbeatSeq = 0

    public init(directory: URL) {
        self.directory = directory
        self.logURL = directory.appendingPathComponent("lifecycle.log")
        self.markerURL = directory.appendingPathComponent("running.marker")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Recording

    public func record(_ event: String) {
        let line = "\(Self.timestamp()) pid=\(ProcessInfo.processInfo.processIdentifier) \(event)\n"
        append(line)
        lifecycleRecorderLog.info("app.lifecycle \(event, privacy: .public)")
    }

    /// Mark the process as running. Call as early as possible after bootstrap.
    public func beginRun() {
        let marker = "pid=\(ProcessInfo.processInfo.processIdentifier) startedAt=\(Self.timestamp())"
        try? Data(marker.utf8).write(to: markerURL)
        record("launch \(marker)")
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
    public func recordHeartbeat(reason: String) {
        heartbeatSeq += 1
        record("heartbeat seq=\(heartbeatSeq) reason=\(reason) rssKB=\(Self.footprintKB())")
    }

    /// If a run marker from a previous launch is still present, the previous run
    /// did not shut down cleanly. Returns the stale marker's contents (and
    /// removes it) so the caller can log it; returns nil on a clean prior run.
    @discardableResult
    public func consumeStaleRunMarker() -> String? {
        guard let data = try? Data(contentsOf: markerURL),
              let contents = String(data: data, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: markerURL)
        return contents
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

    private func append(_ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
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
