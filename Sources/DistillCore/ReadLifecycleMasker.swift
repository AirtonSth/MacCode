import Foundation

public struct ReadLifecycleObservation: Sendable, Equatable, Identifiable {
    public let id: String
    public let realpath: String
    public let startLine: Int
    public let endLine: Int
    public let contentHash: String
    public let byteCount: Int
    public let text: String
    public let retrieveHandle: String?
    public let turnIndex: Int
    public let hasError: Bool

    public init(
        id: String,
        realpath: String,
        startLine: Int,
        endLine: Int,
        contentHash: String,
        byteCount: Int,
        text: String,
        retrieveHandle: String?,
        turnIndex: Int,
        hasError: Bool = false
    ) {
        self.id = id
        self.realpath = realpath
        self.startLine = min(startLine, endLine)
        self.endLine = max(startLine, endLine)
        self.contentHash = contentHash
        self.byteCount = max(0, byteCount)
        self.text = text
        let normalizedHandle = retrieveHandle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.retrieveHandle = normalizedHandle.isEmpty ? nil : normalizedHandle
        self.turnIndex = turnIndex
        self.hasError = hasError
    }
}

public struct ReadLifecycleMaskResult: Sendable, Equatable {
    public let observation: ReadLifecycleObservation
    public let output: String
    public let masked: Bool
    public let reason: String?
}

public enum ReadLifecycleMasker {
    /// I5.1: default OFF. I5.9/K8: a live MCP `rc_retrieve` is a per-turn precondition —
    /// if it is unavailable, masked content could not be recovered, so we mask NOTHING.
    /// Both gates short-circuit to a fully-unmasked result (deterministic, byte-stable).
    public static func maskSupersededReads(
        _ observations: [ReadLifecycleObservation],
        keepLastTurns: Int = 2,
        enabled: Bool = false,
        mcpRetrieveAvailable: Bool = true
    ) -> [ReadLifecycleMaskResult] {
        guard enabled else {
            return observations.map { result($0, masked: false, reason: "masking_disabled") }
        }
        guard mcpRetrieveAvailable else {
            return observations.map { result($0, masked: false, reason: "mcp_retrieve_unavailable") }
        }
        let latestTurn = observations.map(\.turnIndex).max() ?? 0
        return observations.map { observation in
            guard observation.retrieveHandle != nil else {
                return result(observation, masked: false, reason: "missing_handle")
            }
            guard !observation.hasError else {
                return result(observation, masked: false, reason: "error_output")
            }
            guard latestTurn - observation.turnIndex >= keepLastTurns else {
                return result(observation, masked: false, reason: "recent_turn")
            }
            guard let newer = observations.first(where: { supersedes(candidate: $0, older: observation) }) else {
                return result(observation, masked: false, reason: "not_superseded")
            }
            return ReadLifecycleMaskResult(
                observation: observation,
                output: placeholder(for: observation, supersededBy: newer),
                masked: true,
                reason: "superseded_by:\(newer.id)"
            )
        }
    }

    public static func placeholder(
        for observation: ReadLifecycleObservation,
        supersededBy newer: ReadLifecycleObservation
    ) -> String {
        let handle = observation.retrieveHandle ?? ""
        let lines = observation.text.components(separatedBy: "\n")
        let firstRaw = lines.first ?? ""
        let lastRaw = lines.last ?? ""
        let first = firstRaw.isEmpty ? "" : firstRaw
        let last = lastRaw.isEmpty ? "" : lastRaw
        return """
        [stale read masked: \(observation.realpath):\(observation.startLine)-\(observation.endLine), \(observation.byteCount) bytes, hash \(observation.contentHash), superseded by \(newer.id)]
        first: \(first)
        last: \(last)
        retrieve: rc_retrieve(\(handle))
        """
    }

    /// I5.6: every handle whose observation was masked MUST be pinned in the reversible
    /// store (ref_count>0, exempt from pruneUnreferenced) for the resumable session
    /// lifetime — otherwise a later rc_retrieve of masked content could 404.
    public static func pinnedHandles(of results: [ReadLifecycleMaskResult]) -> [String] {
        results.compactMap { $0.masked ? $0.observation.retrieveHandle : nil }
    }

    private static func supersedes(candidate: ReadLifecycleObservation, older: ReadLifecycleObservation) -> Bool {
        guard candidate.id != older.id,
              candidate.turnIndex > older.turnIndex,
              candidate.realpath == older.realpath,
              candidate.contentHash == older.contentHash,
              candidate.startLine <= older.startLine,
              candidate.endLine >= older.endLine,
              candidate.retrieveHandle != nil,
              !candidate.hasError else {
            return false
        }
        return true
    }

    private static func result(
        _ observation: ReadLifecycleObservation,
        masked: Bool,
        reason: String
    ) -> ReadLifecycleMaskResult {
        ReadLifecycleMaskResult(
            observation: observation,
            output: observation.text,
            masked: masked,
            reason: reason
        )
    }
}
