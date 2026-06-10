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
        let t = title.lowercased()
        if t == token { return 100 }
        if t.hasPrefix(token) { return 80 }
        if t.contains(token) { return 60 }
        if subtitle.lowercased().contains(token) { return 40 }
        if keywords.contains(where: { $0.lowercased().contains(token) }) { return 20 }
        // IMP-004: subsequence tier — "ntm" matches "New Terminal Surface".
        // Ranked below all substring tiers so exact/prefix/contains always win.
        if isSubsequence(token, of: t) { return 10 }
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

    /// Rank `items` against `query`, dropping non-matches. Ties keep the
    /// original (insertion) order so the palette is deterministic.
    public static func rank<T>(_ items: [T], query: String,
                               _ fields: (T) -> (title: String, subtitle: String, keywords: [String])) -> [T] {
        items.enumerated().compactMap { idx, item -> (T, Int, Int)? in
            let f = fields(item)
            guard let s = score(query: query, title: f.title, subtitle: f.subtitle, keywords: f.keywords) else { return nil }
            return (item, s, idx)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        .map(\.0)
    }
}
