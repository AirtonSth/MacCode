import Foundation

/// Pure, testable command-palette matching. Mirrors t3code's
/// `CommandPalette.logic` split — ranking lives here, the NSPanel only
/// renders. Higher score = better match; `nil` = no match.
public struct CommandPaletteFilter {
    public static func score(query: String, title: String,
                             subtitle: String = "", keywords: [String] = []) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return 0 }
        let t = title.lowercased()
        if t == q { return 100 }
        if t.hasPrefix(q) { return 80 }
        if t.contains(q) { return 60 }
        if subtitle.lowercased().contains(q) { return 40 }
        if keywords.contains(where: { $0.lowercased().contains(q) }) { return 20 }
        // IMP-004: subsequence tier — "ntm" matches "New Terminal Surface".
        // Ranked below all substring tiers so exact/prefix/contains always win.
        if isSubsequence(q, of: t) { return 10 }
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
