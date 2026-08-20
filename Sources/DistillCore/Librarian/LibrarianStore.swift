import Foundation

/// In-process recovery-scope handle store. Sidecar never open(2)s a paid-invented path.
public final class LibrarianHandleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: String] = [:]
    private var kinds: [String: String] = [:]

    public init(records: [String: String] = [:]) {
        blobs = records
    }

    public func put(_ text: String, handle: String? = nil, kind: String = "text") -> String {
        let id = handle ?? Self.makeHandle(text)
        lock.lock()
        blobs[id] = text
        kinds[id] = kind
        lock.unlock()
        return id
    }

    public func get(_ handle: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return blobs[handle]
    }

    public func kind(of handle: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return kinds[handle]
    }

    public func allHandles() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(blobs.keys).sorted()
    }

    public func records() -> [CCRSearchRecord] {
        lock.lock(); defer { lock.unlock() }
        return blobs.map { CCRSearchRecord(handle: $0.key, text: $0.value) }
    }

    public func slice(handle: String, startLine: Int?, endLine: Int?, startByte: Int?, endByte: Int?) -> String? {
        guard let text = get(handle) else { return nil }
        if let startByte, let endByte, startByte >= 0, endByte >= startByte {
            let utf8 = Array(text.utf8)
            guard startByte < utf8.count else { return "" }
            let end = min(endByte, utf8.count)
            return String(decoding: utf8[startByte..<end], as: UTF8.self)
        }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let start = max(0, (startLine ?? 1) - 1)
        let end = min(lines.count, endLine ?? lines.count)
        guard start < end else { return "" }
        return lines[start..<end].joined(separator: "\n")
    }

    public func grep(handle: String, pattern: String, literal: Bool = true) -> [(line: Int, text: String)] {
        guard let text = get(handle) else { return [] }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var hits: [(Int, String)] = []
        if literal {
            for (idx, line) in lines.enumerated() where line.contains(pattern) {
                hits.append((idx + 1, line))
            }
            return hits
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for (idx, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex.firstMatch(in: line, range: range) != nil {
                hits.append((idx + 1, line))
            }
        }
        return hits
    }

    public func findDuplicate(of text: String) -> String? {
        let hash = Self.sha(text)
        lock.lock(); defer { lock.unlock() }
        for (handle, blob) in blobs where Self.sha(blob) == hash {
            return handle
        }
        return nil
    }

    public static func makeHandle(_ text: String) -> String {
        "rcv1." + String(sha(text).prefix(24))
    }

    private static func sha(_ text: String) -> String {
        DistillSHA256.hex(text)
    }
}
