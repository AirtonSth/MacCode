import Foundation
import Darwin
import CoreModel

public enum TerminalInputStatus: String, Sendable, Equatable {
    case accepted
    case queueFull = "queue_full"
    case processExited = "process_exited"
    case surfaceNotFound = "surface_not_found"
    case writeFailed = "write_failed"
}

public struct TerminalRuntimeHealth: Sendable, Equatable {
    public var processAlive: Bool
    public var childPID: Int32?
    public var exitStatus: Int32?
    public var terminationSignal: Int32?
    public var ptyOpen: Bool
    public var inputAccepting: Bool
    public var terminalDeadReason: String?
    public var lastOutputAt: Date?
    public var outputPartial: Bool
    public var outputPendingBytes: Int
    public var historyWriteFailures: Int
    public var droppedOutputBytes: Int = 0
    public var rows: Int
    public var cols: Int
    public var renderDiagnostics: TerminalRenderDiagnostics? = nil

    public var alive: Bool {
        processAlive && ptyOpen && terminalDeadReason == nil
    }
}

public struct TerminalTextSnapshot: Sendable, Equatable {
    public var text: String
    public var ansiText: String? = nil
    /// Resolved 16-entry ANSI palette (indices 0-15) as `#rrggbb` hex strings,
    /// populated ONLY when the active Ghostty theme differs from the built-in
    /// default palette. `nil` means "default palette" -- iOS renders with its
    /// own hardcoded default, so a nil here is byte-identical to before this
    /// field existed (back-compat). Serialized as `ansi_palette` only when set.
    public var ansiPalette: [String]? = nil
    public var complete: Bool
    public var source: String
    public var timestamp: Date
    public var partialReason: String?
    public var pendingBytes: Int
    public var rows: Int
    public var cols: Int
    public var renderDiagnostics: TerminalRenderDiagnostics? = nil
}

public struct TerminalRenderDiagnostics: Sendable, Equatable {
    public var logicalVisible: Bool
    public var registryVisible: Bool
    public var drainingHiddenBacklog: Bool
    public var windowAttached: Bool
    public var parked: Bool
    public var hasUsableBounds: Bool
    public var hiddenAncestor: Bool
    public var blockedReason: String?

    public var canRender: Bool {
        logicalVisible &&
        registryVisible &&
        !drainingHiddenBacklog &&
        windowAttached &&
        !parked &&
        hasUsableBounds &&
        !hiddenAncestor
    }

    public init(
        logicalVisible: Bool,
        registryVisible: Bool,
        drainingHiddenBacklog: Bool,
        windowAttached: Bool,
        parked: Bool,
        hasUsableBounds: Bool,
        hiddenAncestor: Bool
    ) {
        self.logicalVisible = logicalVisible
        self.registryVisible = registryVisible
        self.drainingHiddenBacklog = drainingHiddenBacklog
        self.windowAttached = windowAttached
        self.parked = parked
        self.hasUsableBounds = hasUsableBounds
        self.hiddenAncestor = hiddenAncestor
        self.blockedReason = Self.firstBlockedReason(
            logicalVisible: logicalVisible,
            registryVisible: registryVisible,
            drainingHiddenBacklog: drainingHiddenBacklog,
            windowAttached: windowAttached,
            parked: parked,
            hasUsableBounds: hasUsableBounds,
            hiddenAncestor: hiddenAncestor
        )
    }

    static func firstBlockedReason(
        logicalVisible: Bool,
        registryVisible: Bool,
        drainingHiddenBacklog: Bool,
        windowAttached: Bool,
        parked: Bool,
        hasUsableBounds: Bool,
        hiddenAncestor: Bool
    ) -> String? {
        if !logicalVisible { return "logical_hidden" }
        if !registryVisible { return "registry_hidden" }
        if drainingHiddenBacklog { return "hidden_backlog_draining" }
        if !windowAttached { return "window_detached" }
        if parked { return "parking_window" }
        if !hasUsableBounds { return "invalid_bounds" }
        if hiddenAncestor { return "hidden_ancestor" }
        return nil
    }
}

struct TerminalStartupEnvironment: Equatable {
    static let managedTerminalType = "xterm-256color"
    static let managedColorTerm = "truecolor"
    static let managedTerminalProgram = "ghostty"

    private static let blankedInheritedAgentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX"
    ]

    var assignments: [String: String]
    var removals: Set<String>

    init(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID
    ) {
        var assignments: [String: String] = [
            "TERM": Self.managedTerminalType,
            "COLORTERM": Self.managedColorTerm,
            "CLICOLOR": "1",
            "TERM_PROGRAM": Self.managedTerminalProgram,
            "RC2_WORKSPACE_ID": workspaceID.value.uuidString,
            "RC2_SURFACE_ID": surfaceID.value.uuidString
        ]

        if parent["LANG"] == nil {
            assignments["LANG"] = "en_US.UTF-8"
        }

        for key in Self.blankedInheritedAgentKeys where parent[key] != nil {
            assignments[key] = ""
        }

        self.assignments = assignments
        self.removals = ["NO_COLOR"]
    }

    func applyToCurrentProcess() {
        for key in removals {
            unsetenv(key)
        }
        for (key, value) in assignments where !key.isEmpty {
            setenv(key, value, 1)
        }
    }

    static func shellPath(from parent: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let value = parent["SHELL"] ?? "/bin/zsh"
        return value.isEmpty ? "/bin/zsh" : value
    }
}

public final class SurfaceRuntimeBus: @unchecked Sendable {
    public static let shared = SurfaceRuntimeBus()

    // Lock-guarded storage instead of a serial dispatch queue (F12): the previous
    // `queue.async` emit delivered health transitions LATE (the new state sat in a
    // background FIFO before the sink ran), and the `queue.sync` getter could block
    // — or deadlock if ever read from the bus queue. The sink is set once at startup
    // and itself hops to @MainActor where it needs to, so reading it under a lock
    // and invoking it synchronously on the emitting thread is both safe and makes
    // health publication deterministic (no transition is dropped or reordered).
    private let lock = NSLock()
    private var sinkStorage: (@Sendable (_ surfaceId: SurfaceID, _ health: TerminalRuntimeHealth) -> Void)?

    public var sink: (@Sendable (_ surfaceId: SurfaceID, _ health: TerminalRuntimeHealth) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return sinkStorage }
        set { lock.lock(); sinkStorage = newValue; lock.unlock() }
    }

    public func emit(_ surfaceId: SurfaceID, _ health: TerminalRuntimeHealth) {
        lock.lock()
        let sink = sinkStorage
        lock.unlock()
        sink?(surfaceId, health)
    }
}

enum TerminalWriteResult: Equatable {
    case wrote(Int)
    case wouldBlock
    case interrupted
    case failed(Int32)
}

final class TerminalTickCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false

    func trySchedule() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func complete() {
        lock.lock()
        scheduled = false
        lock.unlock()
    }
}

enum TerminalFileDescriptorFlags {
    @discardableResult
    static func enableNonBlocking(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        guard flags & O_NONBLOCK == 0 else { return true }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }
}

final class TerminalInputPump: @unchecked Sendable {
    typealias Writer = @Sendable (_ data: Data, _ offset: Int) -> TerminalWriteResult

    private let queue: DispatchQueue
    private let maxQueuedBytes: Int
    private let retryDelay: useconds_t
    private let maxWouldBlockWaitMicros: UInt64
    private let writer: Writer
    private let lock = NSLock()
    private var queuedBytes = 0
    private var accepting = true
    private var lastFailure: TerminalInputStatus?
    var onTerminalFailure: (@Sendable (TerminalInputStatus) -> Void)?
    /// Fired (off the pump's queue) when a single write blocks past the retry
    /// budget because the child stopped draining its stdin. RECOVERABLE — the pump
    /// keeps accepting input; this only surfaces "input is blocked" so the UI can
    /// say so instead of the terminal looking silently dead. `unwrittenBytes` is how
    /// much of the stalled chunk was abandoned.
    var onInputStalled: (@Sendable (_ unwrittenBytes: Int) -> Void)?

    init(
        label: String = "rc2.terminal.input-pump",
        maxQueuedBytes: Int = 1024 * 1024,
        retryDelay: useconds_t = 2_000,
        maxWouldBlockWaitMicros: UInt64 = 5_000_000,
        writer: @escaping Writer
    ) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxQueuedBytes = max(1, maxQueuedBytes)
        self.retryDelay = retryDelay
        self.maxWouldBlockWaitMicros = maxWouldBlockWaitMicros
        self.writer = writer
    }

    /// Pure decision seam for the `.wouldBlock` retry budget. Returns true once the
    /// cumulative time spent waiting on a non-draining PTY reaches the budget, so the
    /// drain loop stops spinning instead of head-of-line-blocking the serial queue
    /// (and every later keystroke) forever. `nonisolated static` so the budget logic
    /// is unit-testable without a live pump, queue, or PTY.
    static func shouldAbortWouldBlock(waitedMicros: UInt64, budgetMicros: UInt64) -> Bool {
        budgetMicros > 0 && waitedMicros >= budgetMicros
    }

    var queuedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedBytes
    }

    var inputAccepting: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting && queuedBytes < maxQueuedBytes
    }

    func enqueue(_ data: Data) -> TerminalInputStatus {
        guard !data.isEmpty else { return .accepted }
        lock.lock()
        if !accepting {
            let failure = lastFailure ?? .processExited
            lock.unlock()
            return failure
        }
        guard queuedBytes + data.count <= maxQueuedBytes else {
            lock.unlock()
            return .queueFull
        }
        queuedBytes += data.count
        lock.unlock()

        queue.async { [weak self] in
            self?.drain(data)
        }
        return .accepted
    }

    func stop(reason: TerminalInputStatus = .processExited) {
        lock.lock()
        accepting = false
        lastFailure = reason
        lock.unlock()
    }

    func drain() {
        queue.sync {}
    }

    private func drain(_ data: Data) {
        defer {
            lock.lock()
            queuedBytes = max(0, queuedBytes - data.count)
            lock.unlock()
        }

        var offset = 0
        var wouldBlockWaitMicros: UInt64 = 0
        while offset < data.count {
            switch writer(data, offset) {
            case .wrote(let count) where count > 0:
                offset += count
                wouldBlockWaitMicros = 0   // forward progress resets the stall budget
            case .wrote:
                fail(.writeFailed)
                return
            case .interrupted:
                continue
            case .wouldBlock:
                // The child stopped reading its stdin (slave tty input buffer full).
                // Bound the retry: an open-ended `usleep`+continue spins a CPU core
                // forever AND head-of-line-blocks every later keystroke queued behind
                // this chunk on the serial queue — the "terminal alive but typing
                // dead" freeze. This is RECOVERABLE backpressure, not process death,
                // so do NOT latch accepting=false (fail()); stop waiting on this chunk
                // and surface the stall. Subsequent input is no longer blocked.
                if Self.shouldAbortWouldBlock(waitedMicros: wouldBlockWaitMicros,
                                              budgetMicros: maxWouldBlockWaitMicros) {
                    onInputStalled?(data.count - offset)
                    return
                }
                usleep(retryDelay)
                wouldBlockWaitMicros &+= UInt64(retryDelay)
                continue
            case .failed:
                fail(.writeFailed)
                return
            }
        }
    }

    private func fail(_ status: TerminalInputStatus) {
        lock.lock()
        accepting = false
        lastFailure = status
        lock.unlock()
        onTerminalFailure?(status)
    }
}
