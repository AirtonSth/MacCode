import Foundation
import Darwin

/// Captures a main-thread stack while a hang is in progress (S-F5).
///
/// `HangWatchdog` reports the current gap on every tick. Once per hang episode
/// (one episode = one unacknowledged main ping), at `sampleThreshold` this runs
/// `/usr/bin/sample <pid> <n> -mayDie -file <dir>/hang-<ts>.txt`. At
/// `spindumpThreshold` it escalates to `spindump`, but only when that can run
/// without asking for privileges (it needs root to sample the live system);
/// otherwise it logs the skip. Tools run on a private serial queue, never on
/// main and never on the watchdog queue. At most `maxFiles` hang files are kept.
public final class HangStackCapture: @unchecked Sendable {
    public typealias ProcessRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> Int32
    public typealias Logger = @Sendable (String) -> Void

    public static let sampleExecutable = "/usr/bin/sample"
    public static let spindumpExecutable = "/usr/sbin/spindump"
    static let filePrefix = "hang-"
    static let fileSuffix = ".txt"

    private let directory: URL
    private let pid: Int32
    private let sampleThreshold: TimeInterval
    private let spindumpThreshold: TimeInterval
    private let captureDurationSeconds: Int
    private let maxFiles: Int
    private let spindumpAvailable: @Sendable () -> Bool
    private let runner: ProcessRunner
    private let log: Logger
    private let captureQueue = DispatchQueue(label: "io.remotecode.hang-stack-capture", qos: .utility)

    private let lock = NSLock()
    private var episodeStart: Date?
    private var sampled = false
    private var spindumpHandled = false

    public init(
        directory: URL,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        sampleThreshold: TimeInterval = 5,
        spindumpThreshold: TimeInterval = 60,
        captureDurationSeconds: Int = 3,
        maxFiles: Int = 10,
        spindumpAvailable: @escaping @Sendable () -> Bool = HangStackCapture.spindumpRunsWithoutPrivileges,
        runner: @escaping ProcessRunner = HangStackCapture.runProcess,
        log: @escaping Logger
    ) {
        self.directory = directory
        self.pid = pid
        self.sampleThreshold = sampleThreshold
        self.spindumpThreshold = spindumpThreshold
        self.captureDurationSeconds = max(1, captureDurationSeconds)
        self.maxFiles = max(1, maxFiles)
        self.spindumpAvailable = spindumpAvailable
        self.runner = runner
        self.log = log
    }

    /// Called on every watchdog tick. `episodeStart` is the last main
    /// acknowledgement: it stays fixed for the whole hang and changes once main
    /// answers again, which starts a new episode.
    public func observe(gapSeconds: TimeInterval, kind: HangWatchdogGapKind, episodeStart: Date, now: Date = Date()) {
        guard kind == .hangLikely else { return }
        var runSample = false
        var runSpindump = false
        var skipSpindump = false
        lock.lock()
        if self.episodeStart != episodeStart {
            self.episodeStart = episodeStart
            sampled = false
            spindumpHandled = false
        }
        if gapSeconds >= sampleThreshold, !sampled {
            sampled = true
            runSample = true
        }
        if gapSeconds >= spindumpThreshold, !spindumpHandled {
            spindumpHandled = true
            if spindumpAvailable() { runSpindump = true } else { skipSpindump = true }
        }
        lock.unlock()

        let gap = Int(gapSeconds)
        let stamp = Self.fileStamp(now)
        if runSample {
            let name = "\(Self.filePrefix)\(stamp)\(Self.fileSuffix)"
            capture(tool: "sample", executable: Self.sampleExecutable,
                    arguments: ["\(pid)", "\(captureDurationSeconds)", "-mayDie"], fileName: name, gap: gap)
        }
        if skipSpindump {
            log("hang_spindump_skipped reason=requires_privileges gapSec=\(gap)")
        }
        if runSpindump {
            let name = "\(Self.filePrefix)\(stamp)-spindump\(Self.fileSuffix)"
            capture(tool: "spindump", executable: Self.spindumpExecutable,
                    arguments: ["\(pid)", "\(captureDurationSeconds)"], fileName: name, gap: gap)
        }
    }

    /// Test seam: blocks until queued captures finish.
    public func waitUntilIdleForTests() {
        captureQueue.sync {}
    }

    private func capture(tool: String, executable: String, arguments: [String], fileName: String, gap: Int) {
        captureQueue.async { [self] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            pruneHangFiles(keeping: maxFiles - 1)
            let url = directory.appendingPathComponent(fileName)
            do {
                let status = try runner(executable, arguments + ["-file", url.path])
                let written = FileManager.default.fileExists(atPath: url.path)
                log("hang_stack_captured tool=\(tool) status=\(status) written=\(written ? 1 : 0) file=\(fileName) gapSec=\(gap)")
            } catch {
                log("hang_stack_failed tool=\(tool) gapSec=\(gap) error=\(type(of: error))")
            }
        }
    }

    private func pruneHangFiles(keeping keep: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let hangFiles = names
            .filter { $0.hasPrefix(Self.filePrefix) && $0.hasSuffix(Self.fileSuffix) }
            .sorted() // UTC timestamp names sort chronologically.
        guard hangFiles.count > keep else { return }
        for name in hangFiles.prefix(hangFiles.count - keep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    /// `spindump` refuses to sample the live system unless it runs as root, and
    /// the app must not prompt for privileges just to collect diagnostics.
    public static let spindumpRunsWithoutPrivileges: @Sendable () -> Bool = {
        geteuid() == 0 && FileManager.default.isExecutableFile(atPath: spindumpExecutable)
    }

    public static let runProcess: ProcessRunner = { executable, arguments in
        dispatchPrecondition(condition: .notOnQueue(.main))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
