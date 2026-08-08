import Foundation

// MARK: - Data

/// Captured usage data for one palette command ID.
/// Pure value type — no AppKit dependency, fully testable off main-thread.
public struct PaletteFrecencyEntry: Codable, Equatable, Sendable {
    public var id: String
    public var useCount: Int
    public var lastUsedAt: Date

    public init(id: String, useCount: Int = 0, lastUsedAt: Date = .distantPast) {
        self.id = id
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }
}

// MARK: - Pure scorer

/// Frecency score: combines recency (exponential decay) with use count.
/// Higher score = more relevant.
///
/// WHY this formula:
///   - recency decays with a half-life of ~7 days so a command used once last
///     week competes fairly with one used twice today.
///   - use count adds a floor so a highly-used command never drops to zero even
///     if old.
///   - Both axes are independent so the unit tests can verify each in isolation.
public enum PaletteFrecencyScorer {
    /// Half-life in seconds (7 days). Named constant so tests can reason about it.
    public static let halfLifeSeconds: Double = 7 * 24 * 3600

    /// Returns a non-negative frecency score.
    /// - Parameters:
    ///   - uses: total invocation count (>= 0)
    ///   - lastUsedAt: wall-clock timestamp of most recent use
    ///   - now: current time (injectable for deterministic tests)
    public static func score(uses: Int, lastUsedAt: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(lastUsedAt))
        let decayFactor = pow(0.5, age / halfLifeSeconds)
        // count + 1 so an item used once scores strictly above an item never used.
        // For very old (e.g. .distantPast) timestamps the decay underflows to
        // exactly 0.0; floor to the smallest positive Double so an unused command
        // keeps a strictly positive score and is never completely buried.
        return max(.leastNonzeroMagnitude, Double(uses + 1) * decayFactor)
    }
}

// MARK: - In-memory merge helper

/// Merges frecency data into a ranked command-ID list.
/// Pure function — no I/O, no AppKit. Used by CommandPalette and by tests.
///
/// Rules:
///   - Commands that appear in `entries` are sorted by descending frecency score
///     (ties break by original `candidateIDs` order).
///   - Commands not in `entries` keep their original order after the scored ones.
///   - `jumpIDs` (dynamic per-launch IDs) are never floated (they change per
///     catalog rebuild, so persisting them has no value).
public enum PaletteFrecencyMerger {
    public static func ranked(
        candidateIDs: [String],
        entries: [PaletteFrecencyEntry],
        now: Date
    ) -> [String] {
        let entryMap = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var scored: [(id: String, score: Double, originalIndex: Int)] = []
        var unscored: [(id: String, originalIndex: Int)] = []

        for (idx, id) in candidateIDs.enumerated() {
            if let e = entryMap[id] {
                let s = PaletteFrecencyScorer.score(uses: e.useCount, lastUsedAt: e.lastUsedAt, now: now)
                scored.append((id: id, score: s, originalIndex: idx))
            } else {
                unscored.append((id: id, originalIndex: idx))
            }
        }

        scored.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.originalIndex < $1.originalIndex
        }

        return scored.map(\.id) + unscored.map(\.id)
    }
}

// MARK: - Persistence protocol + store

/// Thin protocol over the raw kv get/set so tests inject an in-memory double.
public protocol PaletteFrecencyRepository {
    func get(_ key: String) throws -> String?
    func set(_ key: String, _ value: String) throws
}

/// Persists a capped list of `PaletteFrecencyEntry` values as JSON in the kv
/// settings table under the key `palette.frecency`.
public final class PaletteFrecencyStore {
    private let repo: any PaletteFrecencyRepository
    private let key = "palette.frecency"
    /// Hard cap: keep only the N most-recently-updated entries to avoid unbounded growth.
    private let cap: Int
    // PERF: load/persist allocated JSONDecoder/JSONEncoder per call (and
    // recordUse does both). Reuse one pair under a short lock.
    private let codecLock = NSLock()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(repo: any PaletteFrecencyRepository, cap: Int = 50) {
        self.repo = repo
        self.cap = cap
    }

    // MARK: Load

    public func load() -> [PaletteFrecencyEntry] {
        guard let raw = try? repo.get(key),
              let data = raw.data(using: .utf8) else {
            return []
        }
        codecLock.lock()
        let entries = try? decoder.decode([PaletteFrecencyEntry].self, from: data)
        codecLock.unlock()
        return entries ?? []
    }

    // MARK: Record a use

    /// Upsert an entry for `id`: increment use count, stamp `lastUsedAt`, persist.
    public func recordUse(id: String, at date: Date = .init()) {
        var entries = load()
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].useCount += 1
            entries[idx].lastUsedAt = date
        } else {
            entries.append(PaletteFrecencyEntry(id: id, useCount: 1, lastUsedAt: date))
        }
        // Trim to cap, keeping the most-recently-used.
        if entries.count > cap {
            entries.sort { $0.lastUsedAt > $1.lastUsedAt }
            entries = Array(entries.prefix(cap))
        }
        persist(entries)
    }

    // MARK: Private

    private func persist(_ entries: [PaletteFrecencyEntry]) {
        codecLock.lock()
        let data = try? encoder.encode(entries)
        codecLock.unlock()
        guard let data,
              let json = String(data: data, encoding: .utf8) else { return }
        try? repo.set(key, json)
    }
}
