import Dispatch
import Foundation

/// S-F4a: reacts to the OS memory-pressure notifications the app used to
/// ignore. On a warning or critical event it lowers the process-wide terminal
/// budget for one pass and reclaims hidden terminals only (priority 0): their
/// ANSI mirror is compacted and their native Ghostty surface, with its Metal
/// swapchain, is released until the tab is revealed. Visible and focused
/// terminals are left to the normal budget so what the user is looking at
/// never rebuilds under them. A terminal is compacted at most once: later
/// events skip it, so pressure never makes a tab dormant. A warning also
/// spares hidden terminals running a foreground program (TUIs, agent CLIs),
/// because a released surface answers no terminal queries; only a critical
/// event releases those.
///
/// NSCache-backed memos (markdown, diff, tool-input) are not touched here:
/// NSCache already evicts on system memory pressure by itself.
@MainActor
public final class MemoryPressureMonitor {
    public enum Level: String, Sendable {
        case warning
        case critical
    }

    struct Relief: Equatable {
        let ceiling: Int
        let maxPriority: Int
        let spareLiveForegroundJobs: Bool
    }

    /// Hidden terminals have reclaim priority 0 (see
    /// `TerminalSurface.terminalMemoryReclaimPriority`).
    static let hiddenTerminalPriority = 0

    static func relief(for level: Level, budget: Int) -> Relief {
        switch level {
        case .warning:
            Relief(ceiling: max(0, budget) / 2, maxPriority: hiddenTerminalPriority, spareLiveForegroundJobs: true)
        case .critical:
            Relief(ceiling: 0, maxPriority: hiddenTerminalPriority, spareLiveForegroundJobs: false)
        }
    }

    private let authority: TerminalMemoryBudgetAuthority
    private let log: (String) -> Void
    private var source: DispatchSourceMemoryPressure?

    public convenience init(log: @escaping (String) -> Void) {
        self.init(authority: .shared, log: log)
    }

    init(authority: TerminalMemoryBudgetAuthority, log: @escaping (String) -> Void) {
        self.authority = authority
        self.log = log
    }

    /// Idempotent. Events are delivered on the main queue, where the terminal
    /// budget lives.
    public func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            let level: Level
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                return
            }
            MainActor.assumeIsolated {
                self?.handle(level)
            }
        }
        source.activate()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    var isRunningForTesting: Bool { source != nil }

    func handle(_ level: Level) {
        let relief = Self.relief(for: level, budget: authority.maxRetainedBytes)
        let start = DispatchTime.now().uptimeNanoseconds
        let before = authority.retainedBytesForTesting
        let reclaimed = authority.relieveMemoryPressure(
            ceiling: relief.ceiling,
            maxPriority: relief.maxPriority,
            spareLiveForegroundJobs: relief.spareLiveForegroundJobs
        )
        let after = authority.retainedBytesForTesting
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        log(
            "memory_pressure level=\(level.rawValue) ceilingBytes=\(relief.ceiling) "
                + "terminalsReclaimed=\(reclaimed) terminalBytesBefore=\(before) terminalBytesAfter=\(after) "
                + "durationMs=\(String(format: "%.1f", durationMs))"
        )
    }
}
