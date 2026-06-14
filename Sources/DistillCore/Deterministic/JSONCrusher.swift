import Foundation

public struct JSONSmartCrusherStats: Sendable, Equatable {
    public let itemCount: Int
    public let estimatedTokens: Int
    public let lengthVariance: Double
    public let uniquenessRatio: Double
    public let schemaSimilarity: Double

    public var activatesStatisticalWindow: Bool {
        itemCount >= 5 &&
            estimatedTokens >= 200 &&
            lengthVariance > 2.0 &&
            uniquenessRatio < 0.10 &&
            schemaSimilarity > 0.80
    }
}

/// Deterministic, lossless structural compression for JSON payloads (headroom's
/// SmartCrusher, ported native). `.minify` re-serializes parsed JSON with all
/// insignificant whitespace removed; the result is *semantically identical* to
/// the input — a re-parse is deep-equal — so it needs no reversible handle.
/// Pretty-printed tool output (2-space indent, newlines) shrinks substantially
/// with zero information loss. This runs on the CPU with no model and no I/O.
public enum JSONCrusher {
    public static let tabularCSVFormat = "json_tabular_csv_v1"

    /// Returns a minified rendering of `input` when (a) it parses as a JSON
    /// object/array and (b) the minified form is strictly smaller. Returns nil
    /// otherwise so the caller falls through unchanged (never inflate).
    ///
    /// `.sortedKeys` makes the output deterministic regardless of the parser's
    /// hash-ordered dictionary iteration; `.withoutEscapingSlashes` avoids
    /// inflating "/" into "\/". Both options are semantics-preserving, so two
    /// payloads with identical structure always crush to identical bytes — which
    /// is exactly what cross-turn dedup (P4) and the prompt cache reward.
    public static func minify(_ input: String) -> String? {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        // Only top-level array/dict are valid for re-serialization; fragments
        // (bare scalars) are not worth crushing and would throw.
        guard object is [Any] || object is [String: Any] else { return nil }
        guard let out = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: out, encoding: .utf8),
              text.count < input.count else {
            return nil
        }
        return text
    }

    /// True when `text` parses as a top-level JSON object or array. Cheap structural
    /// probe used by the router's classifier; tolerant of leading/trailing whitespace.
    public static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return object is [Any] || object is [String: Any]
    }

    /// Lossless SmartCrusher path for homogeneous, flat JSON arrays. The output is
    /// a JSON envelope containing schema + CSV rows whose cells are JSON literals,
    /// so `expandTabularCSV` can reconstruct a semantically identical JSON array.
    public static func tabularCSV(_ input: String, minSavingsRatio: Double = 0.30) -> String? {
        guard let rows = parseObjectArray(input),
              rows.count >= 2,
              let columns = commonColumns(for: rows),
              !columns.isEmpty else {
            return nil
        }

        var csvRows: [String] = []
        csvRows.reserveCapacity(rows.count)
        for row in rows {
            var encodedCells: [String] = []
            encodedCells.reserveCapacity(columns.count)
            for column in columns {
                guard let value = row[column],
                      isFlatJSONValue(value),
                      let literal = jsonLiteral(value) else {
                    return nil
                }
                encodedCells.append(encodeCSVCell(literal))
            }
            csvRows.append(encodedCells.joined(separator: ","))
        }

        let envelope: [String: Any] = [
            "_distill_format": tabularCSVFormat,
            "columns": columns,
            "rows": csvRows.joined(separator: "\n")
        ]
        guard let output = serialize(envelope),
              output.count < input.count else {
            return nil
        }
        let savings = 1.0 - (Double(output.count) / Double(input.count))
        return savings >= minSavingsRatio ? output : nil
    }

    public static func expandTabularCSV(_ input: String) -> String? {
        guard let data = input.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              envelope["_distill_format"] as? String == tabularCSVFormat,
              let columns = envelope["columns"] as? [String],
              let rowsText = envelope["rows"] as? String,
              let csvRows = parseCSVRows(rowsText) else {
            return nil
        }

        var rows: [[String: Any]] = []
        rows.reserveCapacity(csvRows.count)
        for csvRow in csvRows {
            guard csvRow.count == columns.count else { return nil }
            var row: [String: Any] = [:]
            row.reserveCapacity(columns.count)
            for (index, column) in columns.enumerated() {
                guard let value = parseJSONLiteral(csvRow[index]) else { return nil }
                row[column] = value
            }
            rows.append(row)
        }
        return serialize(rows)
    }

    public static func activationStats(_ input: String) -> JSONSmartCrusherStats? {
        guard let rows = parseObjectArray(input), rows.count >= 1 else { return nil }
        let itemStrings = rows.compactMap(serialize)
        guard itemStrings.count == rows.count else { return nil }
        let lengths = itemStrings.map(\.count)
        let mean = Double(lengths.reduce(0, +)) / Double(lengths.count)
        let variance = lengths.reduce(0.0) { partial, length in
            let delta = Double(length) - mean
            return partial + (delta * delta)
        } / Double(lengths.count)

        let uniqueRatio = Double(Set(itemStrings).count) / Double(itemStrings.count)
        var commonKeys = Set(rows[0].keys)
        var unionKeys = Set(rows[0].keys)
        for row in rows.dropFirst() {
            commonKeys.formIntersection(row.keys)
            unionKeys.formUnion(row.keys)
        }
        let schemaSimilarity = unionKeys.isEmpty ? 0.0 : Double(commonKeys.count) / Double(unionKeys.count)

        return JSONSmartCrusherStats(
            itemCount: rows.count,
            estimatedTokens: max(1, input.count / 4),
            lengthVariance: variance,
            uniquenessRatio: uniqueRatio,
            schemaSimilarity: schemaSimilarity
        )
    }

    /// Store-backed lossy SmartCrusher window for eligible JSON arrays. The caller
    /// must store `input` first and pass the retrieve handle; otherwise this API is
    /// not safe to use. Default routing does not call this path.
    public static func windowArray(
        _ input: String,
        droppedHandle: String,
        maxItems: Int = 15
    ) -> String? {
        guard maxItems >= 3,
              let stats = activationStats(input),
              stats.activatesStatisticalWindow,
              let rows = parseObjectArray(input),
              rows.count > maxItems else {
            return nil
        }

        var selected = Set<Int>()
        let firstCount = min(Int(ceil(Double(rows.count) * 0.30)), maxItems)
        for index in 0..<firstCount {
            selected.insert(index)
        }
        let lastBudget = maxItems - selected.count
        if lastBudget > 0 {
            let lastCount = min(Int(ceil(Double(rows.count) * 0.15)), lastBudget)
            for index in rows.count - lastCount..<rows.count {
                selected.insert(index)
            }
        }

        let lengths = rows.compactMap(serialize).map(\.count)
        for index in changePointIndices(lengths: lengths) where selected.count < maxItems {
            selected.insert(index)
        }

        guard selected.count < rows.count else { return nil }
        let sortedSelected = selected.sorted()
        let handle = normalizeRetrieveHandle(droppedHandle)
        guard !handle.isEmpty else { return nil }

        var output: [Any] = []
        var cursor = 0
        for index in sortedSelected {
            if cursor < index {
                output.append(dropSentinel(handle: handle, start: cursor, count: index - cursor))
            }
            output.append(rows[index])
            cursor = index + 1
        }
        if cursor < rows.count {
            output.append(dropSentinel(handle: handle, start: cursor, count: rows.count - cursor))
        }

        guard let text = serialize(output), text.count < input.count else { return nil }
        return text
    }

    private static func parseObjectArray(_ input: String) -> [[String: Any]]? {
        guard let data = input.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
            return nil
        }
        return array
    }

    private static func commonColumns(for rows: [[String: Any]]) -> [String]? {
        guard let first = rows.first else { return nil }
        let columns = first.keys.sorted()
        guard !columns.isEmpty else { return nil }
        for row in rows {
            guard row.keys.sorted() == columns else { return nil }
        }
        return columns
    }

    private static func isFlatJSONValue(_ value: Any) -> Bool {
        value is String || value is NSNumber || value is NSNull
    }

    private static func jsonLiteral(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value],
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
              let wrapped = String(data: data, encoding: .utf8),
              wrapped.count >= 2 else {
            return nil
        }
        return String(wrapped.dropFirst().dropLast())
    }

    private static func parseJSONLiteral(_ literal: String) -> Any? {
        guard let data = "[\(literal)]".data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data, options: []) as? [Any],
              values.count == 1 else {
            return nil
        }
        return values[0]
    }

    private static func serialize(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeCSVCell(_ cell: String) -> String {
        guard cell.contains(",") || cell.contains("\"") || cell.contains("\n") else {
            return cell
        }
        return "\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func parseCSVRows(_ input: String) -> [[String]]? {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false
        var index = input.startIndex

        while index < input.endIndex {
            let char = input[index]
            if char == "\"" {
                let next = input.index(after: index)
                if inQuotes, next < input.endIndex, input[next] == "\"" {
                    cell.append("\"")
                    index = input.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if char == ",", !inQuotes {
                row.append(cell)
                cell.removeAll(keepingCapacity: true)
            } else if char == "\n", !inQuotes {
                row.append(cell)
                rows.append(row)
                row.removeAll(keepingCapacity: true)
                cell.removeAll(keepingCapacity: true)
            } else {
                cell.append(char)
            }
            index = input.index(after: index)
        }
        guard !inQuotes else { return nil }
        row.append(cell)
        rows.append(row)
        return rows
    }

    private static func changePointIndices(lengths: [Int]) -> [Int] {
        guard lengths.count > 2 else { return [] }
        let mean = Double(lengths.reduce(0, +)) / Double(lengths.count)
        let variance = lengths.reduce(0.0) { partial, length in
            let delta = Double(length) - mean
            return partial + (delta * delta)
        } / Double(lengths.count)
        let threshold = max(16, Int(sqrt(variance) * 2.0))
        var indices: [Int] = []
        for index in 1..<lengths.count {
            if abs(lengths[index] - lengths[index - 1]) >= threshold {
                indices.append(index)
            }
        }
        return indices
    }

    private static func normalizeRetrieveHandle(_ handle: String) -> String {
        var normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = normalized.range(of: "rc:") {
            normalized = String(normalized[range.upperBound...])
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[]{}() \t\n"))
        return normalized
    }

    private static func dropSentinel(handle: String, start: Int, count: Int) -> [String: String] {
        [
            "_ccr_dropped": "[[rc:\(handle)]] \(count)_rows_offloaded offset=\(start)"
        ]
    }
}
