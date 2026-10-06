import Foundation
import Darwin

/// Copies GhosttyKit's crash evidence into RemoteCode's diagnostics folder.
///
/// GhosttyKit's embedded Sentry/Breakpad writes a minidump into its Sentry
/// database (`<Caches>/com.mitchellh.ghostty/sentry/<run>.run/`) and, on the
/// next start, hands the envelope to Ghostty's transport, which saves a
/// `.ghosttycrash` file under `$XDG_STATE_HOME/ghostty/crash`. The next
/// `ghostty_init` cleans the run folders up, so this must run at launch,
/// before anything can start Ghostty. Sources are only read, never changed;
/// the Ghostty folders are shared with Ghostty.app.
public enum GhosttyCrashHarvester {
    public static let fileExtensions: Set<String> = ["dmp", "envelope", "ghosttycrash"]
    /// Oldest copies beyond this count are deleted from the destination.
    public static let maxRetainedFiles = 20

    public static func defaultSourceDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        var sources: [URL] = []
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            sources.append(caches.appendingPathComponent("com.mitchellh.ghostty/sentry", isDirectory: true))
        }
        let stateHome = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".local/state", isDirectory: true)
        sources.append(stateHome.appendingPathComponent("ghostty/crash", isDirectory: true))
        return sources
    }

    /// Copies every crash file not copied before; returns the new copies.
    @discardableResult
    public static func harvest(
        from sources: [URL],
        into destination: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        var copied: [URL] = []
        for source in sources {
            guard let enumerator = fileManager.enumerator(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else { continue }
            let rootComponents = source.standardizedFileURL.pathComponents
            for case let file as URL in enumerator {
                guard fileExtensions.contains(file.pathExtension.lowercased()),
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                // Flatten the path below the source so files from different run
                // folders cannot collide.
                let relative = file.standardizedFileURL.pathComponents.dropFirst(rootComponents.count)
                let target = destination.appendingPathComponent(relative.joined(separator: "--"), isDirectory: false)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                if (try? fileManager.copyItem(at: file, to: target)) != nil {
                    copied.append(target)
                }
            }
        }
        if !copied.isEmpty {
            pruneOldest(in: destination, keeping: maxRetainedFiles, fileManager: fileManager)
        }
        return copied
    }

    static func pruneOldest(in directory: URL, keeping limit: Int, fileManager: FileManager) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), files.count > limit else { return }
        let newestFirst = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for file in newestFirst.dropFirst(limit) {
            try? fileManager.removeItem(at: file)
        }
    }
}

/// Recovers how a previous run that left a stale marker actually ended, from
/// launchd's unified-log line (e.g. `exited due to exit(1), ran for 35005804ms`
/// or `exited due to SIGKILL | sent by ...`). A run launched outside launchd
/// (from a terminal) has no such line and is reported as unknown.
public enum PreviousRunExitStatus {
    /// Runs `/usr/bin/log` with the given arguments; returns stdout, or nil on
    /// failure or timeout.
    public typealias LogRunner = (_ arguments: [String], _ timeout: TimeInterval) -> String?

    /// Searches from just before the last sign of life to a few hours later:
    /// heartbeats stop during a main-thread hang, so death can come much later.
    static let windowBefore: TimeInterval = 5
    static let windowAfter: TimeInterval = 3 * 60 * 60
    static let timeout: TimeInterval = 30

    /// The lifecycle.log line for the previous run's exit.
    public static func lifecycleLine(
        pid: pid_t,
        lastAlive: Date?,
        now: Date = Date(),
        runLog: LogRunner = runLogShow
    ) -> String {
        guard let lastAlive,
              let output = runLog(logShowArguments(pid: pid, lastAlive: lastAlive, now: now), timeout),
              let reason = launchdExitReason(inLogOutput: output, pid: pid) else {
            return "previous_run_exit pid=\(pid) launchd=unknown"
        }
        return "previous_run_exit pid=\(pid) launchd=\"\(reason)\""
    }

    static func logShowArguments(pid: pid_t, lastAlive: Date, now: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let end = min(now, lastAlive.addingTimeInterval(windowAfter))
        return [
            "show", "--style", "compact",
            "--start", formatter.string(from: lastAlive.addingTimeInterval(-windowBefore)),
            "--end", formatter.string(from: end),
            "--predicate",
            "process == \"launchd\" AND subsystem ENDSWITH \"[\(pid)]\" AND eventMessage BEGINSWITH \"exited\""
        ]
    }

    /// The `exited ...` text of launchd's line for `pid`, or nil when absent.
    /// Compact lines look like
    /// `... launchd[1:1bf2efa] [gui/501/<label> [15080]:] exited due to exit(1), ran for 75ms`.
    public static func launchdExitReason(inLogOutput output: String, pid: pid_t) -> String? {
        let tag = " [\(pid)]:] "
        for line in output.split(separator: "\n") {
            guard let tagRange = line.range(of: tag) else { continue }
            let reason = line[tagRange.upperBound...].trimmingCharacters(in: .whitespaces)
            if reason.hasPrefix("exited") {
                return reason.replacingOccurrences(of: "\"", with: "'")
            }
        }
        return nil
    }

    public static func runLogShow(arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
