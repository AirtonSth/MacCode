import Foundation
import Darwin
import os

private let lifecycleRecorderLog = Logger(subsystem: "io.remotecode.app", category: "lifecycle")

/// Records app start/stop and termination signals to a persistent on-disk log so
/// that a silent disappearance (SIGTERM from a relaunch, SIGKILL from the OS, an
/// abrupt exit) leaves a forensic trail even when the app was launched from a
/// terminal and is therefore invisible to the unified logging system.
///
/// It also keeps a "run marker" file: written at launch, removed only on a clean
/// `applicationWillTerminate`. If the marker survives into the next launch, the
/// previous run ended without a clean shutdown (killed or crashed before the
/// terminate hook ran) — which is exactly the signature of the reported
/// "the app just vanished" incident with no crash report.
public final class AppLifecycleRecorder {
    private let directory: URL
    private let logURL: URL
    private let markerURL: URL
    private var signalSources: [DispatchSourceSignal] = []

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

    // MARK: Signals

    /// A GUI app launched via LaunchServices has no controlling terminal, but a
    /// dev build run from a shell does — a terminal/session hangup (SIGHUP) would
    /// then silently kill it. SIGHUP must never take the app down. SIGTERM/SIGINT
    /// are intentional (e.g. a relaunch's `pkill`), so we honor them — but
    /// cleanly and logged, not as an unobserved abrupt exit.
    public static func shouldTerminate(onSignal signo: Int32) -> Bool {
        switch signo {
        case SIGTERM, SIGINT: return true
        case SIGHUP: return false
        default: return false
        }
    }

    /// Records the signal and, when it is a terminating signal, invokes
    /// `terminate`. Pure decision logic, exercised directly by tests; the live
    /// dispatch sources call through here.
    public func handleSignal(_ signo: Int32, terminate: () -> Void) {
        record("signal=\(Self.signalName(signo)) terminating=\(Self.shouldTerminate(onSignal: signo))")
        if Self.shouldTerminate(onSignal: signo) {
            terminate()
        }
    }

    /// Installs observers for SIGHUP, SIGTERM and SIGINT. The default disposition
    /// is set to ignore so the kernel does not kill the process before the
    /// dispatch handler can record (and decide) — then GCD delivers the signal on
    /// the main queue where `onTerminate` can safely drive an AppKit shutdown.
    public func installSignalHandlers(onTerminate: @escaping () -> Void) {
        for signo in [SIGHUP, SIGTERM, SIGINT] {
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            source.setEventHandler { [weak self] in
                self?.handleSignal(signo, terminate: onTerminate)
            }
            source.resume()
            signalSources.append(source)
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

    private static func signalName(_ signo: Int32) -> String {
        switch signo {
        case SIGHUP: return "SIGHUP"
        case SIGTERM: return "SIGTERM"
        case SIGINT: return "SIGINT"
        case SIGKILL: return "SIGKILL"
        default: return "SIG#\(signo)"
        }
    }
}
