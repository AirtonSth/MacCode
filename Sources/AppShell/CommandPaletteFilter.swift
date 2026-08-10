import Foundation

/// Pure, testable command-palette matching. Mirrors t3code's
/// `CommandPalette.logic` split — ranking lives here, the NSPanel only
/// renders. Higher score = better match; `nil` = no match.
public struct CommandPaletteFilter {
    public static func score(query: String, title: String,
                             subtitle: String = "", keywords: [String] = []) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return 0 }

        // Multi-word AND matching: every token must match some field.
        // Single-token path preserves existing tier semantics exactly.
        let tokens = q.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if tokens.count > 1 {
            var minScore = Int.max
            for token in tokens {
                guard let s = scoreToken(token, title: title, subtitle: subtitle, keywords: keywords) else {
                    return nil // any unmatched token -> exclude
                }
                if s < minScore { minScore = s }
            }
            return minScore == Int.max ? nil : minScore
        }

        return scoreToken(q, title: title, subtitle: subtitle, keywords: keywords)
    }

    /// Score a single, already-lowercased token against the item fields.
    private static func scoreToken(_ token: String, title: String,
                                   subtitle: String, keywords: [String]) -> Int? {
        if title.compare(token, options: .caseInsensitive) == .orderedSame { return 100 }
        if title.range(of: token, options: [.caseInsensitive, .anchored]) != nil { return 80 }
        if title.range(of: token, options: .caseInsensitive) != nil { return 60 }
        if subtitle.range(of: token, options: .caseInsensitive) != nil { return 40 }
        if keywords.contains(where: { $0.range(of: token, options: .caseInsensitive) != nil }) { return 20 }
        // IMP-004: subsequence tier — "ntm" matches "New Terminal Surface".
        // Ranked below all substring tiers so exact/prefix/contains always win.
        // Avoid per-entry lowercased alloc — use caseInsensitive subsequence.
        if isSubsequenceCaseInsensitive(token, haystack: title) { return 10 }
        return nil
    }

    /// IMP-004: true when every character of `needle` appears in `haystack`
    /// in order (not necessarily contiguous). Both are assumed lowercased.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var matched = false
            while let h = it.next() {
                if h == ch { matched = true; break }
            }
            if !matched { return false }
        }
        return true
    }

    /// PERF: case-insensitive subsequence without allocating `haystack.lowercased()` per entry.
    /// `needle` is already lowercased; scans `haystack` with caseInsensitive per-char range.
    static func isSubsequenceCaseInsensitive(_ needle: String, haystack: String) -> Bool {
        var searchFrom = haystack.startIndex
        for ch in needle {
            guard let r = haystack.range(of: String(ch), options: .caseInsensitive, range: searchFrom..<haystack.endIndex) else {
                return false
            }
            searchFrom = r.upperBound
        }
        return true
    }

    /// P3: pure helper - given a display `title` and a search `query`, return
    /// the `String.Index` ranges inside `title` that should be bolded.
    ///
    /// Strategy (mirrors the filter tier order so highlighted chars always
    /// correspond to the reason the row was included):
    ///   1. Empty query or no-match -> []
    ///   2. Prefix match  -> one range covering the prefix
    ///   3. Substring match -> one range covering the first occurrence
    ///   4. Subsequence match -> one range per query character (greedy-first)
    ///
    /// The helper is `nonisolated static` so tests can call it without
    /// @MainActor and without instantiating any AppKit objects.
    public nonisolated static func matchedRanges(title: String, query: String) -> [Range<String.Index>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // Prefix / substring: one contiguous range (case-insensitive, locale-safe).
        if let range = title.range(of: q, options: .caseInsensitive) {
            return [range]
        }

        // Subsequence: one range per query character (greedy-first, case-insensitive).
        var result: [Range<String.Index>] = []
        var searchFrom = title.startIndex
        for qChar in q {
            guard searchFrom < title.endIndex else { return [] }
            guard let found = title.range(of: String(qChar),
                                          options: .caseInsensitive,
                                          range: searchFrom..<title.endIndex) else {
                return []
            }
            result.append(found)
            searchFrom = found.upperBound
        }
        return result
    }

    /// Rank `items` against `query`, dropping non-matches. Ties keep the
    /// original (insertion) order so the palette is deterministic.
    public static func rank<T>(_ items: [T], query: String,
                               _ fields: (T) -> (title: String, subtitle: String, keywords: [String])) -> [T] {
        // PERF: palette filters on every keystroke; query and field lowercasing
        // was repeated per-item via score(). Hoist query normalization and avoid
        // re-lowercasing query inside the per-item loop.
        let qLow = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if qLow.isEmpty {
            // score() returns 0 for empty query -> keep all, sorted by insertion order.
            return items
        }
        let tokens: [String]
        if qLow.contains(" ") {
            tokens = qLow.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if tokens.isEmpty { return items }
        } else {
            tokens = [qLow]
        }
        // Single-token vs multi-token scoring without re-lowercasing query and
        // without per-item field lowercasing (allocation-free haystack via case-insensitive range).
        return items.enumerated().compactMap { idx, item -> (T, Int, Int)? in
            let f = fields(item)
            let score: Int?
            if tokens.count > 1 {
                var minScore = Int.max
                var ok = true
                for token in tokens {
                    guard let s = scoreTokenCaseInsensitive(token: token, title: f.title, subtitle: f.subtitle, keywords: f.keywords) else {
                        ok = false; break
                    }
                    if s < minScore { minScore = s }
                }
                score = ok ? (minScore == Int.max ? nil : minScore) : nil
            } else {
                score = scoreTokenCaseInsensitive(token: tokens[0], title: f.title, subtitle: f.subtitle, keywords: f.keywords)
            }
            guard let s = score else { return nil }
            return (item, s, idx)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        .map(\.0)
    }

    // PERF: case-insensitive scoring without per-item lowercased() allocs on every keystroke.
    // Used by rank() hot path; token is already lowercased.
    private static func scoreTokenCaseInsensitive(token: String, title: String, subtitle: String, keywords: [String]) -> Int? {
        if title.compare(token, options: .caseInsensitive) == .orderedSame { return 100 }
        if title.range(of: token, options: [.caseInsensitive, .anchored]) != nil { return 80 }
        if title.range(of: token, options: .caseInsensitive) != nil { return 60 }
        if subtitle.range(of: token, options: .caseInsensitive) != nil { return 40 }
        if keywords.contains(where: { $0.range(of: token, options: .caseInsensitive) != nil }) { return 20 }
        if isSubsequenceCaseInsensitive(token, haystack: title) { return 10 }
        return nil
    }
}
