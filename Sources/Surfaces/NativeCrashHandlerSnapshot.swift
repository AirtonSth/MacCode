import Darwin
import os

private let crashHandlerLog = Logger(subsystem: "io.remotecode.surfaces", category: "crash-handlers")

/// The process's native crash handlers: the task-level Mach exception ports and
/// the dispositions of the crash signals.
///
/// GhosttyKit embeds sentry-native with the Breakpad backend. Initializing it
/// replaces the task exception ports and the SIGABRT handler; on a crash
/// Breakpad writes a minidump into Ghostty's cache and calls
/// `_exit(exception_type)`. macOS ReportCrash never sees the crash, so the app
/// "closes by itself" with no `.ips` report, no `will_terminate` and no
/// `atexit` line. Capturing before Ghostty initializes and restoring right after
/// hands crashes back to ReportCrash.
struct NativeCrashHandlerSnapshot: Equatable {
    struct ExceptionPort: Equatable {
        let mask: exception_mask_t
        let port: mach_port_t
        let behavior: exception_behavior_t
        let flavor: thread_state_flavor_t
    }

    struct SignalDisposition: Equatable {
        let signal: Int32
        let action: sigaction

        static func == (lhs: SignalDisposition, rhs: SignalDisposition) -> Bool {
            lhs.signal == rhs.signal
                && lhs.action.sa_flags == rhs.action.sa_flags
                && lhs.action.sa_mask == rhs.action.sa_mask
                && withUnsafeBytes(of: lhs.action.__sigaction_u, { Array($0) })
                    == withUnsafeBytes(of: rhs.action.__sigaction_u, { Array($0) })
        }
    }

    /// The exception types a crash reporter takes over (Breakpad's mask plus
    /// EXC_SOFTWARE).
    static let crashExceptionMask = exception_mask_t(
        EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC
            | EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE
    )
    static let crashSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    let exceptionPorts: [ExceptionPort]
    let signals: [SignalDisposition]

    static func capture() -> NativeCrashHandlerSnapshot {
        let capacity = 32
        var masks = [exception_mask_t](repeating: 0, count: capacity)
        var ports = [mach_port_t](repeating: 0, count: capacity)
        var behaviors = [exception_behavior_t](repeating: 0, count: capacity)
        var flavors = [thread_state_flavor_t](repeating: 0, count: capacity)
        var count = mach_msg_type_number_t(capacity)
        let result = task_get_exception_ports(
            mach_task_self_, crashExceptionMask, &masks, &count, &ports, &behaviors, &flavors
        )
        var exceptionPorts: [ExceptionPort] = []
        if result == KERN_SUCCESS {
            for index in 0..<Int(count) {
                // With no port there is no handler: behavior and flavor are
                // meaningless, and the kernel reports them inconsistently.
                let hasHandler = ports[index] != mach_port_t(MACH_PORT_NULL)
                exceptionPorts.append(ExceptionPort(
                    mask: masks[index],
                    port: ports[index],
                    behavior: hasHandler ? behaviors[index] : 0,
                    flavor: hasHandler ? flavors[index] : 0
                ))
            }
        }
        let signals = crashSignals.map { signo -> SignalDisposition in
            var action = sigaction()
            sigaction(signo, nil, &action)
            return SignalDisposition(signal: signo, action: action)
        }
        return NativeCrashHandlerSnapshot(exceptionPorts: exceptionPorts, signals: signals)
    }

    /// Puts the captured handlers back. Exception types the snapshot did not
    /// list are cleared first, so a handler installed afterwards cannot survive.
    func restore() {
        task_set_exception_ports(
            mach_task_self_, Self.crashExceptionMask, mach_port_t(MACH_PORT_NULL),
            EXCEPTION_DEFAULT, THREAD_STATE_NONE
        )
        for entry in exceptionPorts where entry.port != mach_port_t(MACH_PORT_NULL) {
            task_set_exception_ports(mach_task_self_, entry.mask, entry.port, entry.behavior, entry.flavor)
        }
        for disposition in signals {
            var action = disposition.action
            sigaction(disposition.signal, &action, nil)
        }
    }
}

/// Wraps GhosttyKit's one-time global initialization so its embedded crash
/// reporter cannot keep the host's crash handlers (see
/// `NativeCrashHandlerSnapshot`).
final class GhosttyCrashHandlerGuard {
    struct Report: Equatable {
        /// Ghostty replaced at least one crash handler while initializing.
        let changedDuringInit: Bool
        /// The handlers equal the pre-init snapshot after `end()`.
        let restored: Bool
    }

    private static let reportLock = OSAllocatedUnfairLock<Report?>(initialState: nil)

    /// The outcome of the most recent guarded initialization, or nil before one ran.
    static var lastReport: Report? { reportLock.withLock { $0 } }

    private let before: NativeCrashHandlerSnapshot

    private init(before: NativeCrashHandlerSnapshot) {
        self.before = before
    }

    static func begin() -> GhosttyCrashHandlerGuard {
        GhosttyCrashHandlerGuard(before: .capture())
    }

    func end() {
        let during = NativeCrashHandlerSnapshot.capture()
        before.restore()
        let report = Report(changedDuringInit: during != before, restored: NativeCrashHandlerSnapshot.capture() == before)
        Self.reportLock.withLock { $0 = report }
        if report.restored {
            crashHandlerLog.info("ghostty.crash_handlers_restored changed=\(report.changedDuringInit, privacy: .public)")
        } else {
            crashHandlerLog.fault("ghostty.crash_handlers_restore_failed changed=\(report.changedDuringInit, privacy: .public)")
        }
    }
}
