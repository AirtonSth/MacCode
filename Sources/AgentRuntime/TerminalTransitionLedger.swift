import Foundation
import Darwin
import CoreModel

/// Closed reason class for terminal run transitions (plan-final T1–T3 / W0–W1).
/// Local causes never masquerade as provider completion.
public enum TerminalTransitionReason: String, Sendable, Codable, Equatable, CaseIterable {
    case providerCompleted
    case providerFailed
    case providerStartFailure
    case providerCancelled
    case userStop
    case processDeath
    case relaunchReconcile
    case lockSaturation
    case rpcTimeout
    case appTermination
    case unknown

    /// Status that may be stored on the durable run row for this reason.
    public var durableStatus: AgentRunStatus {
        switch self {
        case .providerCompleted:
            return .completed
        case .providerFailed, .providerStartFailure, .lockSaturation, .rpcTimeout, .processDeath:
            return .failed
        case .providerCancelled, .userStop:
            return .cancelled
        case .relaunchReconcile, .appTermination:
            return .interrupted
        case .unknown:
            return .failed
        }
    }

    /// Human-readable message for `agent_runs.error_message` (nil when silent is correct).
    public var durableErrorMessage: String? {
        switch self {
        case .providerCompleted, .userStop, .providerCancelled:
            return nil
        case .providerFailed:
            return "Provider reported failure."
        case .providerStartFailure:
            return "Provider start did not complete durably."
        case .processDeath:
            return "Provider process exited without an authoritative completion event."
        case .relaunchReconcile:
            return "Interrupted by app restart."
        case .lockSaturation:
            return "Stream persistence saturated under lock contention; run left recoverable."
        case .rpcTimeout:
            return "Provider RPC timed out; peer kept alive for other threads."
        case .appTermination:
            return "App terminated while run was active."
        case .unknown:
            return "Run ended without an authoritative terminal reason."
        }
    }

    /// Whether this reason may ever be presented as a normal provider completion.
    public var mayRenderAsProviderCompleted: Bool {
        self == .providerCompleted
    }

    /// Pure mapping from a requested durable status + initiator into a reason class.
    public static func classify(
        requestedStatus: AgentRunStatus,
        initiator: TerminalTransitionInitiator
    ) -> TerminalTransitionReason {
        switch initiator {
        case .providerTerminal:
            switch requestedStatus {
            case .completed: return .providerCompleted
            case .failed: return .providerFailed
            case .cancelled: return .providerCancelled
            case .interrupted: return .processDeath
            default: return .unknown
            }
        case .providerStartFailure:
            return .providerStartFailure
        case .userStop:
            return .userStop
        case .processDeath:
            return .processDeath
        case .relaunchReconcile:
            return .relaunchReconcile
        case .lockSaturation:
            return .lockSaturation
        case .rpcTimeout:
            return .rpcTimeout
        case .appTermination:
            return .appTermination
        case .unknown:
            return .unknown
        }
    }
}

public enum TerminalTransitionInitiator: String, Sendable, Codable, Equatable {
    case providerTerminal
    case providerStartFailure
    case userStop
    case processDeath
    case relaunchReconcile
    case lockSaturation
    case rpcTimeout
    case appTermination
    case unknown
}

public struct TerminalTransitionRecord: Sendable, Codable, Equatable {
    public var runId: String
    public var threadId: String
    public var reason: TerminalTransitionReason
    public var initiator: TerminalTransitionInitiator
    public var requestedStatus: String
    public var providerPid: Int32?
    public var exitStatus: Int32?
    public var eventSequence: Int64?
    public var bootId: String
    public var eventTime: Date
    public var commitTime: Date?
    public var presentTime: Date?

    public init(
        runId: String,
        threadId: String,
        reason: TerminalTransitionReason,
        initiator: TerminalTransitionInitiator,
        requestedStatus: AgentRunStatus,
        providerPid: Int32? = nil,
        exitStatus: Int32? = nil,
        eventSequence: Int64? = nil,
        bootId: String = "",
        eventTime: Date = Date(),
        commitTime: Date? = nil,
        presentTime: Date? = nil
    ) {
        self.runId = runId
        self.threadId = threadId
        self.reason = reason
        self.initiator = initiator
        self.requestedStatus = requestedStatus.rawValue
        self.providerPid = providerPid
        self.exitStatus = exitStatus
        self.eventSequence = eventSequence
        self.bootId = bootId
        self.eventTime = eventTime
        self.commitTime = commitTime
        self.presentTime = presentTime
    }
}

/// Pure policy: false completed detection for presentation.
public enum TerminalTransitionPolicy {
    /// Returns false when UI must not show `completed` for this record.
    public static func allowsCompletedPresentation(_ record: TerminalTransitionRecord) -> Bool {
        record.reason.mayRenderAsProviderCompleted
            && record.requestedStatus == AgentRunStatus.completed.rawValue
    }

    /// Prefer ledger reason over a bare status when they disagree.
    public static func reconciledStatus(
        requested: AgentRunStatus,
        reason: TerminalTransitionReason
    ) -> AgentRunStatus {
        if requested == .completed && !reason.mayRenderAsProviderCompleted {
            return reason.durableStatus
        }
        if reason == .relaunchReconcile || reason == .appTermination {
            return .interrupted
        }
        if reason == .lockSaturation || reason == .rpcTimeout {
            // Keep run alive semantically as failed/recoverable — never completed.
            return reason.durableStatus
        }
        return requested
    }
}

/// Durable append-only terminal transition ledger (write-before-UI).
/// Separate TTL from stream/provider log prune.
public final class TerminalTransitionLedger: @unchecked Sendable {
    public static let defaultMaxRows = 5_000
    public static let defaultTTL: TimeInterval = 30 * 24 * 60 * 60

    /// Best-effort boot session UUID (empty when unavailable).
    public static func currentBootId() -> String {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        guard size > 1 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        let rc = sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0)
        guard rc == 0 else { return "" }
        return String(cString: buffer)
    }

    private let fileURL: URL
    private let maxRows: Int
    private let ttl: TimeInterval
    private let queue = DispatchQueue(label: "io.remotecode.terminal-ledger")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(
        directory: URL,
        maxRows: Int = TerminalTransitionLedger.defaultMaxRows,
        ttl: TimeInterval = TerminalTransitionLedger.defaultTTL
    ) {
        self.fileURL = directory.appendingPathComponent("terminal-transitions.jsonl")
        self.maxRows = max(1, maxRows)
        self.ttl = max(60, ttl)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Append after durable run commit path; returns the committed record.
    @discardableResult
    public func append(_ record: TerminalTransitionRecord) throws -> TerminalTransitionRecord {
        var committed = record
        committed.commitTime = committed.commitTime ?? Date()
        try queue.sync {
            try appendLocked(committed)
            // Prune only when over soft budget — avoid O(n) rewrite every terminal.
            let count = try rowCountLocked()
            if count > maxRows {
                try pruneLocked(now: committed.commitTime ?? Date())
            }
        }
        return committed
    }

    private func rowCountLocked() throws -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    public func allRecords() throws -> [TerminalTransitionRecord] {
        try queue.sync {
            try loadLocked()
        }
    }

    public func records(forRunId runId: String) throws -> [TerminalTransitionRecord] {
        try allRecords().filter { $0.runId == runId }
    }

    private func appendLocked(_ record: TerminalTransitionRecord) throws {
        let data = try encoder.encode(record)
        var line = data
        line.append(contentsOf: "\n".utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL)
        }
    }

    private func loadLocked() throws -> [TerminalTransitionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(TerminalTransitionRecord.self, from: data)
        }
    }

    private func pruneLocked(now: Date) throws {
        var rows = try loadLocked()
        let cutoff = now.addingTimeInterval(-ttl)
        rows = rows.filter { $0.eventTime >= cutoff }
        if rows.count > maxRows {
            rows = Array(rows.suffix(maxRows))
        }
        let body = try rows.map { row -> Data in
            var data = try encoder.encode(row)
            data.append(contentsOf: "\n".utf8)
            return data
        }.reduce(into: Data()) { $0.append($1) }
        try body.write(to: fileURL, options: .atomic)
    }
}
