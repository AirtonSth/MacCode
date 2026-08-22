import Foundation

/// Native TOON (Token-Oriented Object Notation) codec for JSON-shaped tool output.
///
/// Spec: https://github.com/toon-format/spec v4.1 — encoder emits the forms we
/// actually produce (objects, inline primitive arrays, tabular object arrays,
/// keyed tabular objects, list fallback). Decode exists so adopt is proven
/// lossless (JSON-model equality), not claimed.
///
/// Host policy: object keys are sorted (same determinism as `JSONCrusher.minify`
/// `.sortedKeys`). No new packages. Encoders never emit comment lines.
public enum ToonCodec: Sendable {
    public static let minInputBytes = 64

    /// Encode parsed JSON text to TOON. Nil when input is not a top-level object/array.
    public static func encode(_ jsonText: String) -> String? {
        guard let value = parseJSON(jsonText) else { return nil }
        let lines = encodeRoot(value)
        return lines.joined(separator: "\n")
    }

    /// Decode TOON we emit back to minified JSON text. Nil on structural failure.
    public static func decodeToJSON(_ toon: String) -> String? {
        guard let value = decodeValue(toon) else { return nil }
        return serializeJSON(value)
    }

    /// Adopt TOON only when it is smaller than minify on TokenEstimator and
    /// decode(encode) equals the JSON model. Never inflates versus the original.
    public static func encodeIfEfficient(_ jsonText: String) -> String? {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= minInputBytes else { return nil }
        guard JSONCrusher.looksLikeJSON(trimmed) else { return nil }
        guard let toon = encode(trimmed), !toon.isEmpty else { return nil }
        guard let roundTrip = decodeToJSON(toon), jsonModelEqual(trimmed, roundTrip) else {
            return nil
        }
        let baseline = JSONCrusher.minify(trimmed) ?? trimmed
        guard TokenEstimator.estimate(toon) < TokenEstimator.estimate(baseline) else {
            return nil
        }
        guard toon.utf8.count < trimmed.utf8.count else { return nil }
        return toon
    }

    /// Whole-word `json` in the distill question means the agent asked for JSON.
    public static func shouldSkipForQuestion(_ question: String?) -> Bool {
        guard let question, !question.isEmpty else { return false }
        return question.range(
            of: "\\bjson\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public static func jsonModelEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = parseJSON(lhs), let b = parseJSON(rhs) else { return false }
        return serializeJSON(a) == serializeJSON(b)
    }

    // MARK: - Parse / serialize JSON

    static func parseJSON(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        if object is [Any] || object is [String: Any] { return object }
        return nil
    }

    static func serializeJSON(_ value: Any) -> String? {
        let boxed: Any
        if JSONSerialization.isValidJSONObject(value) {
            boxed = value
        } else {
            return nil
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: boxed,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Encode

    private static func encodeRoot(_ value: Any) -> [String] {
        if let array = value as? [Any] {
            return encodeArray(array, key: nil, depth: 0)
        }
        if let object = value as? [String: Any] {
            if object.isEmpty { return [] }
            if let keyed = encodeKeyedTabular(object, key: nil, depth: 0) {
                return keyed
            }
            return encodeObjectFields(object, depth: 0)
        }
        return [encodePrimitive(value)]
    }

    private static func encodeObjectFields(_ object: [String: Any], depth: Int) -> [String] {
        var lines: [String] = []
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            lines.append(contentsOf: encodeField(key: key, value: value, depth: depth))
        }
        return lines
    }

    private static func encodeField(key: String, value: Any, depth: Int) -> [String] {
        let indent = String(repeating: " ", count: depth * 2)
        let encodedKey = encodeKey(key)
        if isPrimitiveValue(value) {
            return ["\(indent)\(encodedKey): \(encodePrimitive(value))"]
        }
        if let array = value as? [Any] {
            return encodeArray(array, key: encodedKey, depth: depth)
        }
        if let child = value as? [String: Any] {
            if child.isEmpty {
                return ["\(indent)\(encodedKey):"]
            }
            if let keyed = encodeKeyedTabular(child, key: encodedKey, depth: depth) {
                return keyed
            }
            var lines = ["\(indent)\(encodedKey):"]
            lines.append(contentsOf: encodeObjectFields(child, depth: depth + 1))
            return lines
        }
        return ["\(indent)\(encodedKey): \(encodePrimitive(value))"]
    }

    private static func encodeArray(_ array: [Any], key: String?, depth: Int) -> [String] {
        let indent = String(repeating: " ", count: depth * 2)
        let prefix = key.map { "\($0)" } ?? ""
        if array.isEmpty {
            if let key {
                return ["\(indent)\(key): []"]
            }
            return ["[]"]
        }
        if array.allSatisfy(isPrimitiveValue) {
            let header = "\(indent)\(prefix)[\(array.count)]:"
            let values = array.map(encodePrimitive).joined(separator: ",")
            return ["\(header) \(values)"]
        }
        if let tabular = encodeTabular(array, key: prefix, depth: depth) {
            return tabular
        }
        var lines = ["\(indent)\(prefix)[\(array.count)]:"]
        let itemIndent = String(repeating: " ", count: (depth + 1) * 2)
        for element in array {
            if isPrimitiveValue(element) {
                lines.append("\(itemIndent)- \(encodePrimitive(element))")
            } else if let childArray = element as? [Any] {
                let nested = encodeArray(childArray, key: nil, depth: 0)
                if let first = nested.first {
                    lines.append("\(itemIndent)- \(first)")
                    for extra in nested.dropFirst() {
                        lines.append("\(itemIndent)  \(extra)")
                    }
                }
            } else if let child = element as? [String: Any] {
                if child.isEmpty {
                    lines.append("\(itemIndent)-")
                } else {
                    let fields = encodeObjectFields(child, depth: 0)
                    if let first = fields.first {
                        lines.append("\(itemIndent)- \(first)")
                        for extra in fields.dropFirst() {
                            lines.append("\(itemIndent)  \(extra)")
                        }
                    }
                }
            }
        }
        return lines
    }

    private static func encodeTabular(_ array: [Any], key: String, depth: Int) -> [String]? {
        guard let shape = tabularShape(array) else { return nil }
        let indent = String(repeating: " ", count: depth * 2)
        let headerFields = fieldList(shape)
        let header = "\(indent)\(key)[\(array.count)]{\(headerFields)}:"
        var lines = [header]
        let rowIndent = String(repeating: " ", count: (depth + 1) * 2)
        for element in array {
            guard let row = element as? [String: Any] else { return nil }
            lines.append(rowIndent + rowCells(row, shape: shape).joined(separator: ","))
        }
        return lines
    }

    private static func encodeKeyedTabular(
        _ object: [String: Any],
        key: String?,
        depth: Int
    ) -> [String]? {
        guard object.count >= 2 else { return nil }
        var values: [[String: Any]] = []
        values.reserveCapacity(object.count)
        for entryKey in object.keys.sorted() {
            guard let child = object[entryKey] as? [String: Any], !child.isEmpty else {
                return nil
            }
            values.append(child)
        }
        guard let shape = tabularShape(values) else { return nil }
        let indent = String(repeating: " ", count: depth * 2)
        let prefix = key ?? ""
        let header = "\(indent)\(prefix)[\(object.count):]{\(fieldList(shape))}:"
        var lines = [header]
        let rowIndent = String(repeating: " ", count: (depth + 1) * 2)
        for entryKey in object.keys.sorted() {
            guard let row = object[entryKey] as? [String: Any] else { return nil }
            let cells = rowCells(row, shape: shape).joined(separator: ",")
            lines.append("\(rowIndent)\(encodeKey(entryKey)): \(cells)")
        }
        return lines
    }

    private struct TabularShape {
        let keys: [String]
        let nested: [String: [String]]
    }

    private static func tabularShape(_ array: [Any]) -> TabularShape? {
        guard array.count >= 1 else { return nil }
        var objects: [[String: Any]] = []
        for element in array {
            guard let object = element as? [String: Any], !object.isEmpty else { return nil }
            objects.append(object)
        }
        let keys = objects[0].keys.sorted()
        guard !keys.isEmpty else { return nil }
        for object in objects where object.keys.sorted() != keys {
            return nil
        }
        var nested: [String: [String]] = [:]
        for key in keys {
            let column = objects.map { $0[key] as Any }
            if column.allSatisfy(isPrimitiveValue) { continue }
            var children: [[String: Any]] = []
            for value in column {
                guard let child = value as? [String: Any], !child.isEmpty else { return nil }
                children.append(child)
            }
            let subkeys = children[0].keys.sorted()
            guard children.allSatisfy({
                $0.keys.sorted() == subkeys && $0.values.allSatisfy(isPrimitiveValue)
            }) else { return nil }
            nested[key] = subkeys
        }
        return TabularShape(keys: keys, nested: nested)
    }

    private static func fieldList(_ shape: TabularShape) -> String {
        shape.keys.map { key in
            if let nested = shape.nested[key] {
                return "\(encodeKey(key)){\(nested.map(encodeKey).joined(separator: ","))}"
            }
            return encodeKey(key)
        }.joined(separator: ",")
    }

    private static func rowCells(_ row: [String: Any], shape: TabularShape) -> [String] {
        var cells: [String] = []
        for key in shape.keys {
            if let nested = shape.nested[key], let child = row[key] as? [String: Any] {
                for sub in nested {
                    cells.append(encodePrimitive(child[sub] as Any))
                }
            } else {
                cells.append(encodePrimitive(row[key] as Any))
            }
        }
        return cells
    }

    // MARK: - Primitives

    static func isPrimitiveValue(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if value is String { return true }
        if value is Bool { return true }
        if value is NSNumber { return true }
        return false
    }

    static func encodePrimitive(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let flag = booleanValue(value) { return flag ? "true" : "false" }
        if let number = value as? NSNumber {
            return encodeNumber(number)
        }
        if let string = value as? String {
            return encodeString(string)
        }
        return encodeString(String(describing: value))
    }

    private static func booleanValue(_ value: Any) -> Bool? {
        // `as? Bool` is true for NSNumber(1). Only CFBoolean is a JSON bool.
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func encodeNumber(_ number: NSNumber) -> String {
        let doubleValue = number.doubleValue
        if doubleValue.isNaN || doubleValue.isInfinite { return "null" }
        if doubleValue == 0 { return "0" }
        let magnitude = abs(doubleValue)
        if magnitude >= 1e-6 && magnitude < 1e21 {
            if doubleValue == floor(doubleValue),
               let intValue = Int64(exactly: doubleValue) {
                return String(intValue)
            }
            var text = String(doubleValue)
            if text.contains("e") || text.contains("E") {
                text = NSDecimalNumber(value: doubleValue).stringValue
            }
            if text.contains(".") {
                while text.last == "0" { text.removeLast() }
                if text.last == "." { text.removeLast() }
            }
            return text
        }
        return String(format: "%g", doubleValue)
    }

    static func encodeString(_ string: String) -> String {
        if needsQuotes(string) {
            return "\"" + escape(string) + "\""
        }
        return string
    }

    static func encodeKey(_ key: String) -> String {
        let unquoted = try? NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_.]*$")
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        if unquoted?.firstMatch(in: key, range: range) != nil {
            return key
        }
        return "\"" + escape(key) + "\""
    }

    private static func needsQuotes(_ string: String) -> Bool {
        if string.isEmpty { return true }
        if string != string.trimmingCharacters(in: .whitespaces) { return true }
        if string == "true" || string == "false" || string == "null" { return true }
        if string.contains(":") || string.contains("\"") || string.contains("\\") { return true }
        if string.contains("[") || string.contains("]") || string.contains("{") || string.contains("}") {
            return true
        }
        if string.contains(",") { return true }
        if string.hasPrefix("-") || string.hasPrefix("#") { return true }
        if string.unicodeScalars.contains(where: { $0.value < 0x20 }) { return true }
        if string.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)
    private static func escape(_ string: String) -> String {
        var out = ""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x5C: out += "\\\\"
            case 0x22: out += "\\\""
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1F:
                // PERF: nibble table avoids String(format:) per control scalar (Toon escape hot for tool outputs).
                let v = scalar.value
                var hex: [UInt8] = [92, 117, 48, 48, 48, 48] // \u0000
                hex[2] = hexAlphabet[Int((v >> 12) & 0xf)]
                hex[3] = hexAlphabet[Int((v >> 8) & 0xf)]
                hex[4] = hexAlphabet[Int((v >> 4) & 0xf)]
                hex[5] = hexAlphabet[Int(v & 0xf)]
                out += String(bytes: hex, encoding: .utf8) ?? String(format: "\\u%04x", v)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Decode

    static func decodeValue(_ toon: String) -> Any? {
        let content = normalizedLines(from: toon)
        if content.isEmpty { return [String: Any]() }
        let first = content[0].text
        if first == "[]" { return [Any]() }
        if let parsed = parseHeader(first), parsed.key == nil {
            if let fields = parsed.fields {
                if parsed.keyed {
                    return decodeKeyed(lines: content, start: 0, header: parsed)
                }
                return decodeTabular(lines: content, start: 0, header: parsed, fields: fields).value
            }
            if parsed.length == 0 { return [Any]() }
            if let inline = parsed.inline, !inline.isEmpty || parsed.length == 0 {
                let cells = splitDelimited(inline)
                return cells.map(decodeToken)
            }
            return decodeList(lines: content, start: 0, header: parsed).value
        }
        return decodeObject(lines: content, start: 0, depth: 0).value
    }

    private struct Line {
        let depth: Int
        let text: String
    }

    private static func normalizedLines(from toon: String) -> [Line] {
        var result: [Line] = []
        for raw in toon.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var spaces = 0
            for ch in line.unicodeScalars {
                if ch == " " { spaces += 1 } else { break }
            }
            let text = String(line.dropFirst(spaces))
            result.append(Line(depth: spaces / 2, text: text))
        }
        return result
    }

    private struct Header {
        let key: String?
        let length: Int
        let keyed: Bool
        let fields: [Field]?
        let inline: String?
    }

    private struct Field {
        let name: String
        let nested: [String]
    }

    private static func parseHeader(_ text: String) -> Header? {
        guard let bracket = text.firstIndex(of: "["),
              let close = text.firstIndex(of: "]") else { return nil }
        let keyPart = String(text[..<bracket])
        let key = keyPart.isEmpty ? nil : unquoteToken(keyPart)
        let inside = String(text[text.index(after: bracket)..<close])
        let keyed = inside.contains(":")
        let lengthText = inside.split(separator: ":").first.map(String.init) ?? inside
        guard let length = Int(lengthText) else { return nil }
        let after = String(text[text.index(after: close)...])
        if after.hasPrefix("{") {
            guard let endBrace = matchingBrace(after) else { return nil }
            let fieldsText = String(after.dropFirst().prefix(endBrace - 2))
            let fields = parseFieldList(fieldsText)
            return Header(key: key, length: length, keyed: keyed, fields: fields, inline: nil)
        }
        var rest = after
        if rest.hasPrefix(":") { rest.removeFirst() }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return Header(key: key, length: length, keyed: keyed, fields: nil, inline: rest)
    }

    private static func matchingBrace(_ text: String) -> Int? {
        var depth = 0
        var index = 0
        var inQuote = false
        var escape = false
        for ch in text {
            if escape { escape = false; index += 1; continue }
            if ch == "\\" && inQuote { escape = true; index += 1; continue }
            if ch == "\"" { inQuote.toggle(); index += 1; continue }
            if !inQuote {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { return index + 1 }
                }
            }
            index += 1
        }
        return nil
    }

    private static func parseFieldList(_ text: String) -> [Field] {
        var fields: [Field] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i] == "," || text[i] == " " { i = text.index(after: i) }
            guard i < text.endIndex else { break }
            let name: String
            if text[i] == "\"" {
                let parsed = readQuoted(text, from: i)
                name = parsed.value
                i = parsed.next
            } else {
                let start = i
                while i < text.endIndex, text[i] != "," && text[i] != "{" {
                    i = text.index(after: i)
                }
                name = String(text[start..<i]).trimmingCharacters(in: .whitespaces)
            }
            var nested: [String] = []
            if i < text.endIndex, text[i] == "{" {
                i = text.index(after: i)
                let innerStart = i
                var depth = 1
                while i < text.endIndex, depth > 0 {
                    if text[i] == "{" { depth += 1 }
                    if text[i] == "}" { depth -= 1 }
                    if depth > 0 { i = text.index(after: i) }
                }
                let inner = String(text[innerStart..<i])
                nested = inner.split(separator: ",").map { unquoteToken($0.trimmingCharacters(in: .whitespaces)) }
                if i < text.endIndex, text[i] == "}" { i = text.index(after: i) }
            }
            if !name.isEmpty {
                fields.append(Field(name: name, nested: nested.filter { !$0.isEmpty }))
            }
            if i < text.endIndex, text[i] == "," { i = text.index(after: i) }
        }
        return fields
    }

    private static func readQuoted(_ text: String, from start: String.Index) -> (value: String, next: String.Index) {
        var i = text.index(after: start)
        var out = ""
        var escape = false
        while i < text.endIndex {
            let ch = text[i]
            if escape {
                switch ch {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(ch)
                }
                escape = false
            } else if ch == "\\" {
                escape = true
            } else if ch == "\"" {
                return (out, text.index(after: i))
            } else {
                out.append(ch)
            }
            i = text.index(after: i)
        }
        return (out, i)
    }

    private static func decodeTabular(
        lines: [Line],
        start: Int,
        header: Header,
        fields: [Field]
    ) -> (value: [Any], next: Int) {
        let resolved = fields.isEmpty ? (header.fields ?? []) : fields
        var rows: [Any] = []
        var index = start + 1
        let rowDepth = lines[start].depth + 1
        while index < lines.count, lines[index].depth == rowDepth, !lines[index].text.hasPrefix("- ") {
            let text = lines[index].text
            if text.contains(":"), firstUnquoted(text, ":") != nil,
               firstUnquoted(text, ",") == nil || (firstUnquoted(text, ":")! < (firstUnquoted(text, ",") ?? text.endIndex)) {
                if !text.contains(",") { break }
            }
            let cells = splitDelimited(text)
            rows.append(objectFromCells(cells, fields: resolved))
            index += 1
            if rows.count == header.length { break }
        }
        return (rows, index)
    }

    private static func decodeKeyed(lines: [Line], start: Int, header: Header) -> [String: Any]? {
        guard let fields = header.fields else { return nil }
        var object: [String: Any] = [:]
        var index = start + 1
        let rowDepth = lines[start].depth + 1
        while index < lines.count, lines[index].depth == rowDepth {
            let text = lines[index].text
            guard let colon = firstUnquoted(text, ":") else { break }
            let key = unquoteToken(String(text[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            object[key] = objectFromCells(splitDelimited(rest), fields: fields)
            index += 1
        }
        return object
    }

    private static func decodeList(lines: [Line], start: Int, header: Header) -> (value: [Any], next: Int) {
        var items: [Any] = []
        var index = start + 1
        let itemDepth = lines[start].depth + 1
        while index < lines.count, lines[index].depth >= itemDepth {
            let line = lines[index]
            if line.depth != itemDepth || !(line.text == "-" || line.text.hasPrefix("- ")) {
                break
            }
            let body = line.text == "-" ? "" : String(line.text.dropFirst(2))
            if body.isEmpty {
                items.append([String: Any]())
                index += 1
                continue
            }
            if let childHeader = parseHeader(body), childHeader.key == nil {
                if let fields = childHeader.fields {
                    let nested = decodeTabular(
                        lines: remapped(lines, index: index, body: body, header: childHeader),
                        start: 0,
                        header: childHeader,
                        fields: fields
                    )
                    items.append(nested.value)
                    index += 1
                    continue
                }
            }
            if let childHeader = parseHeader(body), childHeader.fields == nil, let inline = childHeader.inline, !inline.isEmpty {
                items.append(splitDelimited(inline).map(decodeToken))
                index += 1
                continue
            }
            if body.contains(":") {
                var objectLines = [Line(depth: 0, text: body)]
                index += 1
                while index < lines.count, lines[index].depth > itemDepth {
                    objectLines.append(Line(depth: lines[index].depth - itemDepth - 0, text: lines[index].text))
                    // sibling fields of list-item object are depth itemDepth+1 but encoded as extra indent 2 from hyphen line
                    index += 1
                }
                // Fix depths: first field on hyphen is depth 0; following lines used itemDepth+1 in encoder as "  key"
                if let obj = decodeObject(lines: redepth(objectLines), start: 0, depth: 0).value as? [String: Any] {
                    items.append(obj)
                }
                continue
            }
            items.append(decodeToken(body))
            index += 1
        }
        return (items, index)
    }

    private static func remapped(
        _ lines: [Line],
        index: Int,
        body: String,
        header: Header
    ) -> [Line] {
        [Line(depth: 0, text: body)]
    }

    private static func redepth(_ lines: [Line]) -> [Line] {
        lines
    }

    private static func decodeObject(lines: [Line], start: Int, depth: Int) -> (value: Any, next: Int) {
        var object: [String: Any] = [:]
        var index = start
        while index < lines.count {
            let line = lines[index]
            if line.depth < depth { break }
            if line.depth > depth { break }
            if let header = parseHeader(line.text), let key = header.key {
                if let fields = header.fields {
                    if header.keyed {
                        if let keyed = decodeKeyed(lines: lines, start: index, header: header) {
                            object[key] = keyed
                        }
                        index += 1
                        while index < lines.count, lines[index].depth > line.depth { index += 1 }
                        continue
                    }
                    let decoded = decodeTabular(lines: lines, start: index, header: header, fields: fields)
                    object[key] = decoded.value
                    index = decoded.next
                    continue
                }
                if let inline = header.inline, !inline.isEmpty {
                    object[key] = splitDelimited(inline).map(decodeToken)
                    index += 1
                    continue
                }
                if header.length == 0 {
                    object[key] = [Any]()
                    index += 1
                    continue
                }
                let decoded = decodeList(lines: lines, start: index, header: header)
                object[key] = decoded.value
                index = decoded.next
                continue
            }
            guard let colon = firstUnquoted(line.text, ":") else { break }
            let key = unquoteToken(String(line.text[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = String(line.text[line.text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if rest == "[]" {
                object[key] = [Any]()
                index += 1
                continue
            }
            if rest.isEmpty {
                var childLines: [Line] = []
                index += 1
                while index < lines.count, lines[index].depth > depth {
                    childLines.append(lines[index])
                    index += 1
                }
                if childLines.isEmpty {
                    object[key] = [String: Any]()
                } else {
                    let shifted = childLines.map { Line(depth: $0.depth, text: $0.text) }
                    object[key] = decodeObject(lines: shifted, start: 0, depth: depth + 1).value
                }
                continue
            }
            object[key] = decodeToken(rest)
            index += 1
        }
        return (object, index)
    }

    private static func objectFromCells(_ cells: [String], fields: [Field]) -> [String: Any] {
        var object: [String: Any] = [:]
        var cursor = 0
        for field in fields {
            if field.nested.isEmpty {
                if cursor < cells.count {
                    object[field.name] = decodeToken(cells[cursor])
                    cursor += 1
                }
            } else {
                var child: [String: Any] = [:]
                for sub in field.nested {
                    if cursor < cells.count {
                        child[sub] = decodeToken(cells[cursor])
                        cursor += 1
                    }
                }
                object[field.name] = child
            }
        }
        return object
    }

    private static func splitDelimited(_ text: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inQuote = false
        var escape = false
        for ch in text {
            if escape {
                current.append("\\")
                current.append(ch)
                escape = false
                continue
            }
            if ch == "\\" && inQuote {
                escape = true
                continue
            }
            if ch == "\"" {
                inQuote.toggle()
                current.append(ch)
                continue
            }
            if ch == ",", !inQuote {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func decodeToken(_ token: String) -> Any {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed == "null" { return NSNull() }
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return unescape(String(trimmed.dropFirst().dropLast()))
        }
        if let intValue = Int64(trimmed) { return NSNumber(value: intValue) }
        if let doubleValue = Double(trimmed),
           trimmed.range(of: #"^-?[0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return NSNumber(value: doubleValue)
        }
        return unquoteToken(trimmed)
    }

    private static func unquoteToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return unescape(String(trimmed.dropFirst().dropLast()))
        }
        return trimmed
    }

    private static func unescape(_ string: String) -> String {
        var out = ""
        let chars = Array(string)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": out.append("\n"); i += 2; continue
                case "r": out.append("\r"); i += 2; continue
                case "t": out.append("\t"); i += 2; continue
                case "\"": out.append("\""); i += 2; continue
                case "\\": out.append("\\"); i += 2; continue
                case "u" where i + 5 < chars.count:
                    let hex = String(chars[(i + 2)...(i + 5)])
                    if let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
                        out.append(Character(scalar))
                        i += 6
                        continue
                    }
                default:
                    break
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func firstUnquoted(_ text: String, _ needle: Character) -> String.Index? {
        var inQuote = false
        var escape = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if escape { escape = false; i = text.index(after: i); continue }
            if ch == "\\" && inQuote { escape = true; i = text.index(after: i); continue }
            if ch == "\"" { inQuote.toggle(); i = text.index(after: i); continue }
            if ch == needle, !inQuote { return i }
            i = text.index(after: i)
        }
        return nil
    }
}
