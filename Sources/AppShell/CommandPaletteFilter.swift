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
        return nil
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
