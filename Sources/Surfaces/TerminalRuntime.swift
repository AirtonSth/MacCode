import Foundation
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

    private let queue = DispatchQueue(label: "RemoteCode.SurfaceRuntimeBus")
    private var sinkStorage: (@Sendable (_ surfaceId: SurfaceID, _ health: TerminalRuntimeHealth) -> Void)?

    public var sink: (@Sendable (_ surfaceId: SurfaceID, _ health: TerminalRuntimeHealth) -> Void)? {
        get { queue.sync { sinkStorage } }
        set {
            queue.async {
                self.sinkStorage = newValue
            }
        }
    }

    public func emit(_ surfaceId: SurfaceID, _ health: TerminalRuntimeHealth) {
        queue.async {
            self.sinkStorage?(surfaceId, health)
        }
    }
}

enum TerminalWriteResult: Equatable {
    case wrote(Int)
    case wouldBlock
    case interrupted
    case failed(Int32)
}

final class TerminalInputPump: @unchecked Sendable {
    typealias Writer = @Sendable (_ data: Data, _ offset: Int) -> TerminalWriteResult

    private let queue: DispatchQueue
    private let maxQueuedBytes: Int
    private let retryDelay: useconds_t
    private let writer: Writer
    private let lock = NSLock()
    private var queuedBytes = 0
    private var accepting = true
    private var lastFailure: TerminalInputStatus?
    var onTerminalFailure: (@Sendable (TerminalInputStatus) -> Void)?

    init(
        label: String = "rc2.terminal.input-pump",
        maxQueuedBytes: Int = 1024 * 1024,
        retryDelay: useconds_t = 2_000,
        writer: @escaping Writer
    ) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxQueuedBytes = max(1, maxQueuedBytes)
        self.retryDelay = retryDelay
        self.writer = writer
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
        while offset < data.count {
            switch writer(data, offset) {
            case .wrote(let count) where count > 0:
                offset += count
            case .wrote:
                fail(.writeFailed)
                return
            case .interrupted:
                continue
            case .wouldBlock:
                usleep(retryDelay)
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
