import Foundation

/// Per-technique Token Saver analytics. Every librarian call emits a
/// `DistillSavingsRecord` whose `mode` is `librarian.<id>` so the existing
/// Token Saver popover breakdown (`TokenSaverModeSavings`) shows savings per
/// catalog function. Saved tokens are measured with `TokenEstimator` on the
/// original vs delivered text. Skip / refuse / unavailable never increment saved.
public struct LibrarianAnalyticsEvent: Sendable, Equatable {
    public let op: String
    public let status: LibrarianStatus
    public let inputTokens: Int
    public let outputTokens: Int
    public let savedTokens: Int
    public let delivered: Bool
    public let provider: String
    public let modelID: String?
    public let record: DistillSavingsRecord?

    public var mode: String { record?.mode ?? "librarian.\(op)" }
}

public final class LibrarianAnalyticsLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LibrarianAnalyticsEvent] = []

    public init() {}

    public func record(_ event: LibrarianAnalyticsEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    public func snapshot() -> [LibrarianAnalyticsEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    public func savedTokens(op: String) -> Int {
        snapshot().filter { $0.op == op }.reduce(0) { $0 + $1.savedTokens }
    }

    public func totalSavedTokens() -> Int {
        snapshot().reduce(0) { $0 + $1.savedTokens }
    }

    public func modeBreakdown() -> [DistillStatsModeSavings] {
        var byKey: [String: (saved: Int, runs: Int, provider: String)] = [:]
        for event in snapshot() {
            let key = "\(event.provider)\u{1f}\(event.mode)"
            var row = byKey[key] ?? (0, 0, event.provider)
            row.saved += event.savedTokens
            row.runs += 1
            byKey[key] = row
        }
        return byKey.keys.sorted().compactMap { key in
            guard let row = byKey[key] else { return nil }
            return DistillStatsModeSavings(
                provider: row.provider,
                mode: String(key.split(separator: "\u{1f}").last ?? ""),
                savedTokens: row.saved,
                runs: row.runs
            )
        }
    }
}

public enum LibrarianAnalytics {
    public static func measure(
        op: String,
        status: LibrarianStatus,
        original: String,
        deliveredText: String?,
        provider: String,
        modelID: String?,
        threadID: String,
        stage: TokenSaverRouteStage
    ) -> LibrarianAnalyticsEvent {
        let inputTokens = TokenEstimator.estimate(original)
        let outputText = deliveredText ?? original
        let outputTokens = TokenEstimator.estimate(outputText)
        let replaced = status == .ok
            && deliveredText != nil
            && deliveredText != original
        let saved = replaced ? max(inputTokens - outputTokens, 0) : 0
        let record: DistillSavingsRecord?
        if shouldPersist(status: status) {
            record = DistillSavingsRecord(
                provider: provider.isEmpty ? "unknown" : provider,
                mode: TokenSaverEngineLabel.mode(base: "librarian.\(op)", stage: stage),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                savedTokens: saved,
                cacheState: "tool_output_oneshot",
                routeStage: stage,
                attributability: "not_prompt_bound",
                delivered: replaced && saved > 0,
                threadID: threadID
            )
        } else {
            record = DistillSavingsRecord(
                provider: provider.isEmpty ? "unknown" : provider,
                mode: TokenSaverEngineLabel.mode(base: "librarian.\(op)", stage: stage),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                savedTokens: 0,
                cacheState: "tool_output_oneshot",
                routeStage: stage,
                attributability: "not_prompt_bound",
                delivered: false,
                threadID: threadID
            )
        }
        return LibrarianAnalyticsEvent(
            op: op,
            status: status,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            savedTokens: saved,
            delivered: replaced && saved > 0,
            provider: provider.isEmpty ? "unknown" : provider,
            modelID: modelID,
            record: record
        )
    }

    /// Persist-shaped row always exists so skips are visible as kept-originals,
    /// but saved tokens stay zero unless bytes were actually replaced.
    private static func shouldPersist(status: LibrarianStatus) -> Bool {
        switch status {
        case .ok, .lowConfidence: return true
        case .unavailable, .refused, .skippedNetNegative: return true
        }
    }
}

public typealias LibrarianSavingsPersist = @Sendable (DistillSavingsRecord) -> Void
