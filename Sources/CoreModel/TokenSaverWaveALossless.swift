import Foundation
import CoreFoundation

/// Wave A lossless triggers default-off / shadow (task-12).
public enum TokenSaverWaveALossless {
    public static let taskID = "task-12"
    public static let minJSONGainFraction: Double = 0.30

    public enum Trigger: String, CaseIterable, Sendable {
        case repeatedLog = "repeated_log"
        case structuredJSON = "structured_json"
        case exactToolReplay = "exact_tool_replay"
        case unchangedFileReread = "unchanged_file_reread"
    }

    public enum Mode: String, Sendable { case off, shadow, active }

    /// Defaults: shadow only — never active promotion.
    public static var defaults: [Trigger: Mode] {
        Dictionary(uniqueKeysWithValues: Trigger.allCases.map { ($0, .shadow) })
    }

    public static let promotionDefaultOff = true

    // MARK: - Scorecard (content-free)

    public struct Scorecard: Sendable, Equatable {
        public var eligible: Int = 0
        public var attempted: Int = 0
        public var accepted: Int = 0
        public var fallback: Int = 0
        public init() {}
    }

    public struct ScoreKey: Hashable, Sendable {
        public let bindingDigest: String
        public let trigger: Trigger
        public init(bindingDigest: String = "", trigger: Trigger) {
            self.bindingDigest = bindingDigest
            self.trigger = trigger
        }
    }

    public final class Scoreboard: @unchecked Sendable {
        private let lock = NSLock()
        private var byKey: [ScoreKey: Scorecard] = [:]
        private let maxEntries: Int

        public init(maxEntries: Int = 4_096) {
            self.maxEntries = max(1, maxEntries)
        }

        public func snapshot(bindingDigest: String = "", trigger: Trigger) -> Scorecard {
            lock.lock(); defer { lock.unlock() }
            return byKey[ScoreKey(bindingDigest: bindingDigest, trigger: trigger)] ?? Scorecard()
        }

        public func record(
            bindingDigest: String = "",
            trigger: Trigger,
            eligible: Bool,
            attempted: Bool,
            accepted: Bool
        ) {
            lock.lock(); defer { lock.unlock() }
            let key = ScoreKey(bindingDigest: bindingDigest, trigger: trigger)
            if byKey[key] == nil && byKey.count >= maxEntries { return }
            var s = byKey[key] ?? Scorecard()
            if eligible && s.eligible < .max { s.eligible += 1 }
            if attempted && s.attempted < .max { s.attempted += 1 }
            if accepted && s.accepted < .max { s.accepted += 1 }
            if attempted && !accepted && s.fallback < .max { s.fallback += 1 }
            byKey[key] = s
        }
    }

    public static let sharedScoreboard = Scoreboard()

    /// Shadow observation: never mutates provider payload; only updates scorecard.
    @discardableResult
    public static func observeShadow(
        trigger: Trigger,
        eligible: Bool,
        wouldAccept: Bool,
        bindingDigest: String = "",
        scoreboard: Scoreboard = sharedScoreboard
    ) -> Mode {
        let mode = defaults[trigger] ?? .off
        guard mode != .off else { return mode }
        // Always count an observation as attempted; eligible is independent.
        scoreboard.record(
            bindingDigest: bindingDigest,
            trigger: trigger,
            eligible: eligible,
            attempted: true,
            accepted: eligible && wouldAccept
        )
        return mode
    }

    // MARK: - Repeated log collapse

    /// Collapse consecutive duplicate lines; preserve trailing exit/status lines.
    public static func collapseRepeatedLogLines(_ text: String) -> (collapsed: String, exitPreserved: Bool) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var prev: String?
        var streak = 0
        for line in lines {
            if line == prev {
                streak += 1
                if streak == 1 {
                    out.append("… repeated ×\(streak + 1)")
                } else if let last = out.indices.last, out[last].hasPrefix("… repeated") {
                    out[last] = "… repeated ×\(streak + 1)"
                }
            } else {
                out.append(line)
                prev = line
                streak = 0
            }
        }
        let collapsed = out.joined(separator: "\n")
        let exitPreserved = preservesExitMarkers(original: text, collapsed: collapsed)
        return (collapsed, exitPreserved)
    }

    public static func preservesExitMarkers(original: String, collapsed: String) -> Bool {
        let markers = ["exit code", "exit_code", "EXIT:", "Process exited", "stderr"]
        for m in markers {
            if original.localizedCaseInsensitiveContains(m) {
                if !collapsed.localizedCaseInsensitiveContains(m) { return false }
            }
        }
        // Also preserve last non-empty line if it looks like status
        let lastOrig = original.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        if lastOrig.range(of: #"\b(exit|status|code)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return collapsed.contains(lastOrig)
        }
        return true
    }

    /// Storeless RLE markers (must match DistillCore.LogCollapser for expand compatibility).
    public static let rleMarkerPrefix = "⟦×"
    public static let rleMarkerSuffix = "⟧"

    /// Storeless collapse of consecutive identical lines (minRun=3). Inverse is expandStorelessLog.
    public static func collapseStorelessLog(_ input: String, minRun: Int = 3) -> String? {
        let lines = input.components(separatedBy: "\n")
        guard lines.count >= minRun else { return nil }
        var out: [String] = []
        var i = 0
        var didCollapse = false
        while i < lines.count {
            var j = i + 1
            while j < lines.count && lines[j] == lines[i] { j += 1 }
            let run = j - i
            let isMarker = lines[i].hasPrefix(rleMarkerPrefix) && lines[i].hasSuffix(rleMarkerSuffix)
            if run >= minRun && !isMarker {
                out.append(lines[i])
                out.append("\(rleMarkerPrefix)\(run)\(rleMarkerSuffix)")
                didCollapse = true
            } else {
                for k in i..<j { out.append(lines[k]) }
            }
            i = j
        }
        guard didCollapse else { return nil }
        let text = out.joined(separator: "\n")
        return text.count < input.count ? text : nil
    }

    public static func expandStorelessLog(_ input: String) -> String {
        let lines = input.components(separatedBy: "\n")
        var out: [String] = []
        for line in lines {
            if line.hasPrefix(rleMarkerPrefix), line.hasSuffix(rleMarkerSuffix) {
                let inner = line.dropFirst(rleMarkerPrefix.count).dropLast(rleMarkerSuffix.count)
                if let count = Int(inner), count >= 1, let last = out.last {
                    for _ in 1..<count { out.append(last) }
                    continue
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Allow when storeless collapse shrinks, exit preserved, and expand(collapse(x)) == x.
    public static func repeatedLogAllows(original: String) -> Bool {
        guard let collapsed = collapseStorelessLog(original) else { return false }
        guard preservesExitMarkers(original: original, collapsed: collapsed) else { return false }
        return expandStorelessLog(collapsed) == original
    }

    public static func repeatedLogInvertible(original: String) -> Bool {
        guard let collapsed = collapseStorelessLog(original) else { return false }
        return expandStorelessLog(collapsed) == original
    }

    // MARK: - Storeless invertibility (base64)

    public static func collapse(_ raw: Data) -> Data {
        Data(raw.base64EncodedString().utf8)
    }

    public static func expand(_ collapsed: Data) -> Data? {
        guard let s = String(data: collapsed, encoding: .utf8) else { return nil }
        return Data(base64Encoded: s)
    }

    public static func expandCollapseRoundTrip(_ raw: Data) -> Bool {
        guard let out = expand(collapse(raw)) else { return false }
        return out == raw
    }

    // MARK: - Structured JSON

    public static func isHomogeneousJSON(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return false
        }
        return isHomogeneousValue(obj as Any)
    }

    private static func isHomogeneousValue(_ value: Any) -> Bool {
        switch classify(value) {
        case .scalar:
            return true
        case .array(let items):
            guard !items.isEmpty else { return true }
            let kinds = items.map { classify($0).kindTag }
            guard let first = kinds.first, kinds.allSatisfy({ $0 == first }) else { return false }
            if first == "object" {
                let schemas: [ObjectSchema] = items.compactMap { objectSchema($0) }
                guard schemas.count == items.count, let head = schemas.first else { return false }
                guard schemas.allSatisfy({ $0 == head }) else { return false }
            }
            return items.allSatisfy { isHomogeneousValue($0) }
        case .object(let values):
            return values.allSatisfy { isHomogeneousValue($0) }
        case .unknown:
            return false
        }
    }

    /// Key set + per-key scalar kind (or nested tag) for object rows.
    private struct ObjectSchema: Equatable {
        let keys: [String]
        let kinds: [String]
    }

    private static func objectSchema(_ value: Any) -> ObjectSchema? {
        guard let dict = asStringKeyedDict(value) else { return nil }
        let keys = dict.keys.sorted()
        let kinds = keys.map { classify(dict[$0]!).kindTag }
        return ObjectSchema(keys: keys, kinds: kinds)
    }

    private static func asStringKeyedDict(_ value: Any) -> [String: Any]? {
        if let d = value as? [String: Any] { return d }
        if let d = value as? NSDictionary {
            var out: [String: Any] = [:]
            for (k, v) in d {
                guard let ks = k as? String else { return nil }
                out[ks] = v
            }
            return out
        }
        return nil
    }

    private enum Classified {
        case scalar(String)
        case array([Any])
        case object([Any])
        case unknown
        var kindTag: String {
            switch self {
            case .scalar(let t): return t
            case .array: return "array"
            case .object: return "object"
            case .unknown: return "unknown"
            }
        }
    }

    private static func classify(_ value: Any) -> Classified {
        if value is NSNull { return .scalar("null") }
        if value is String { return .scalar("string") }
        if let n = value as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                return .scalar("bool")
            }
            return .scalar("number")
        }
        if let a = value as? [Any] { return .array(a) }
        if let a = value as? NSArray {
            return .array((0..<a.count).map { a.object(at: $0) as Any })
        }
        if let d = value as? [String: Any] { return .object(Array(d.values)) }
        if let d = value as? NSDictionary { return .object(d.allValues.map { $0 as Any }) }
        return .unknown
    }

    public static func jsonDeepEqual(_ a: String, _ b: String) -> Bool {
        guard let da = a.data(using: .utf8), let db = b.data(using: .utf8),
              let oa = try? JSONSerialization.jsonObject(with: da),
              let ob = try? JSONSerialization.jsonObject(with: db),
              let ra = try? JSONSerialization.data(withJSONObject: oa, options: [.sortedKeys]),
              let rb = try? JSONSerialization.data(withJSONObject: ob, options: [.sortedKeys]) else {
            return false
        }
        return ra == rb
    }

    public static func gainFraction(originalBytes: Int, collapsedBytes: Int) -> Double {
        guard originalBytes > 0 else { return 0 }
        return Double(originalBytes - collapsedBytes) / Double(originalBytes)
    }

    /// Structured JSON collapse only when both parse, deep-equal, homogeneous, and ≥30% gain.
    public static func structuredJSONAllows(original: String, collapsed: String) -> Bool {
        guard isHomogeneousJSON(original) else { return false }
        guard let od = original.data(using: .utf8),
              let cd = collapsed.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: od),
              let c = try? JSONSerialization.jsonObject(with: cd),
              let ro = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let rc = try? JSONSerialization.data(withJSONObject: c, options: [.sortedKeys]),
              ro == rc else {
            return false
        }
        let gain = gainFraction(originalBytes: original.utf8.count, collapsedBytes: collapsed.utf8.count)
        return gain >= minJSONGainFraction
    }

    // MARK: - Exact tool replay

    public static func exactReplayAllows(first: Data, second: Data, isMostRecent: Bool, pointerCount: Int) -> Bool {
        first == second && !isMostRecent && pointerCount <= 8
    }

    // MARK: - Unchanged file reread

    public static func unchangedRereadAllows(
        samePath: Bool,
        sameHash: Bool,
        sameRange: Bool,
        handlePresent: Bool,
        retrievalActive: Bool
    ) -> Bool {
        samePath && sameHash && sameRange && handlePresent && retrievalActive
    }
}
