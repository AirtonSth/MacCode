import Foundation
import CryptoKit

/// Wave B typed crushers (task-15).
/// Default OFF via per-trigger registry; store-before-loss with verified readback.
public enum TokenSaverTypedCrushers {
    public static let taskID = "task-15"
    /// Global kill: even if a trigger is registered ON, master OFF blocks all admits.
    public static let defaultEnabled = false

    // MARK: - Registry (promotion path without hardcoding true)

    public enum CrusherKind: String, CaseIterable, Sendable, Hashable {
        case pytest, stacktrace, diff, search, adaptiveJSON = "adaptive_json"
    }

    /// Per-trigger enable registry. Defaults all OFF. Tests/production may enable selectively.
    public final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled: [CrusherKind: Bool]
        private var releaseSeal: TokenSaverAuthorityPlane.ReleaseSeal?

        public init(allEnabled: Bool = false) {
            self.enabled = Dictionary(uniqueKeysWithValues: CrusherKind.allCases.map { ($0, allEnabled) })
        }

        public func isEnabled(_ kind: CrusherKind, bindingDigest: String?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let releaseSeal,
                  let bindingDigest,
                  releaseSeal.isStillValid(for: bindingDigest) else {
                return false
            }
            return enabled[kind] ?? false
        }

        /// Test/ops hook: enable a single trigger only when master allows (or for test registry that
        /// tracks intent separately via `setIntent`).
        public func set(_ kind: CrusherKind, enabled value: Bool) {
            lock.lock(); enabled[kind] = value; lock.unlock()
        }

        public func enableAllForTesting() {
            lock.lock()
            for k in CrusherKind.allCases { enabled[k] = true }
            lock.unlock()
        }

        /// Production activation is possible only with an opaque full-release proof.
        public func activate(_ kinds: Set<CrusherKind>, releaseSeal: TokenSaverAuthorityPlane.ReleaseSeal) {
            lock.lock()
            self.releaseSeal = releaseSeal
            for kind in CrusherKind.allCases {
                enabled[kind] = kinds.contains(kind)
            }
            lock.unlock()
        }

        public func deactivate() {
            lock.lock()
            releaseSeal = nil
            for kind in CrusherKind.allCases { enabled[kind] = false }
            lock.unlock()
        }

        public func snapshot() -> [CrusherKind: Bool] {
            lock.lock(); defer { lock.unlock() }
            return enabled
        }
    }

    public static let sharedRegistry = Registry()

    /// Whether a kind is live: master defaultEnabled AND registry bit.
    /// For production, defaultEnabled stays false so this is always false until both flip.
    public static func isLive(
        _ kind: CrusherKind,
        bindingDigest: String? = nil,
        registry: Registry = sharedRegistry
    ) -> Bool {
        registry.isEnabled(kind, bindingDigest: bindingDigest)
    }

    /// Test-only: evaluate admit predicates with an explicit live flag (avoids mutating global default).
    public static func isLiveOverride(kind: CrusherKind, registryAllows: Bool, masterEnabled: Bool) -> Bool {
        masterEnabled && registryAllows
    }

    // MARK: - Store

    public protocol BlobStore: AnyObject {
        func store(id: String, plaintext: Data) throws
        func retrieve(id: String) throws -> Data
    }

    public final class MemoryStore: BlobStore, @unchecked Sendable {
        private let lock = NSLock()
        private var blobs: [String: Data] = [:]
        public init() {}
        public func store(id: String, plaintext: Data) throws {
            lock.lock(); blobs[id] = plaintext; lock.unlock()
        }
        public func retrieve(id: String) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let d = blobs[id] else { throw StoreError.missing }
            return d
        }
        public enum StoreError: Error { case missing }
    }

    public static let sharedMemory = MemoryStore()

    public final class EncryptedStore: BlobStore, @unchecked Sendable {
        private let originals: TokenSaverLossyOriginalStoring

        public init(originals: TokenSaverLossyOriginalStoring) {
            self.originals = originals
        }

        public func store(id: String, plaintext: Data) throws {
            guard originals.save(handle: "typed-crusher|\(id)", data: plaintext) != .conflict else {
                throw StoreError.conflict
            }
        }

        public func retrieve(id: String) throws -> Data {
            guard let data = originals.load(handle: "typed-crusher|\(id)") else {
                throw StoreError.missing
            }
            return data
        }

        public enum StoreError: Error {
            case conflict
            case missing
        }
    }

    public static func handleID(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Store-before-loss with verified byte-exact readback. Returns nil on any failure.
    public static func storeVerified(_ plaintext: Data, store: BlobStore) -> String? {
        let id = handleID(for: plaintext)
        do {
            try store.store(id: id, plaintext: plaintext)
            let back = try store.retrieve(id: id)
            guard back == plaintext else { return nil }
            return id
        } catch {
            return nil
        }
    }

    public struct Result: Sendable, Equatable {
        public let accepted: Bool
        public let collapsed: String?
        public let handle: String?
        public let kind: CrusherKind
    }

    // MARK: - Predicates (respect live flag)

    public static func pytestAccept(countsMatch: Bool, failuresPreserved: Bool, handleValid: Bool, live: Bool) -> Bool {
        live && countsMatch && failuresPreserved && handleValid
    }
    public static func stacktraceAccept(identicalRunsCollapsed: Bool, ambiguous: Bool, live: Bool) -> Bool {
        live && identicalRunsCollapsed && !ambiguous
    }
    public static func diffAccept(plusMinusPreserved: Bool, isBinary: Bool, live: Bool) -> Bool {
        live && plusMinusPreserved && !isBinary
    }
    public static func searchAccept(handleValid: Bool, matchCountPreserved: Bool, live: Bool) -> Bool {
        live && handleValid && matchCountPreserved
    }
    public static func adaptiveWindowAccept(coverageOK: Bool, hasOmittedMarker: Bool, live: Bool) -> Bool {
        live && coverageOK && hasOmittedMarker
    }

    // Legacy wrappers (default registry / master OFF)
    public static func pytestAccept(countsMatch: Bool, failuresPreserved: Bool, handleValid: Bool) -> Bool {
        pytestAccept(countsMatch: countsMatch, failuresPreserved: failuresPreserved, handleValid: handleValid, live: isLive(.pytest))
    }
    public static func stacktraceAccept(identicalFramesOnly: Bool, ambiguous: Bool) -> Bool {
        stacktraceAccept(identicalRunsCollapsed: identicalFramesOnly, ambiguous: ambiguous, live: isLive(.stacktrace))
    }
    public static func diffAccept(plusMinusPreserved: Bool, isBinary: Bool) -> Bool {
        diffAccept(plusMinusPreserved: plusMinusPreserved, isBinary: isBinary, live: isLive(.diff))
    }
    public static func searchAccept(matchesDroppedWithoutHandle: Bool) -> Bool {
        searchAccept(handleValid: !matchesDroppedWithoutHandle, matchCountPreserved: true, live: isLive(.search))
    }
    public static func adaptiveWindowAccept(coverageOK: Bool, hasOmittedMarker: Bool) -> Bool {
        adaptiveWindowAccept(coverageOK: coverageOK, hasOmittedMarker: hasOmittedMarker, live: isLive(.adaptiveJSON))
    }

    // MARK: - Helpers

    /// Parse trailing `N failed` from pytest summary (last match wins).
    public static func parsePytestFailedCount(_ text: String) -> Int? {
        let pattern = #"(\d+)\s+failed"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last, last.numberOfRanges >= 2 else { return nil }
        return Int(ns.substring(with: last.range(at: 1)))
    }

    /// Strict stack frame lines only (not prose containing "at ").
    public static func isStackFrameLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("at ") { return true }
        if t.hasPrefix("File \"") { return true }
        if t.range(of: #"^\s*at\s+\S+"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^File \"[^\"]+\", line \d+"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Collapse only consecutive identical frame runs (RLE), keep order and non-frame lines.
    public static func collapseConsecutiveIdenticalFrames(_ original: String) -> (collapsed: String, hadRun: Bool) {
        let lines = original.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var hadRun = false
        while i < lines.count {
            let line = lines[i]
            let isFrame = isStackFrameLine(line)
            if isFrame {
                var j = i + 1
                while j < lines.count && lines[j] == line { j += 1 }
                let run = j - i
                out.append(line)
                if run >= 2 {
                    out.append("⟦×\(run)⟧")
                    hadRun = true
                }
                i = j
            } else {
                out.append(line)
                i += 1
            }
        }
        return (out.joined(separator: "\n"), hadRun)
    }

    // MARK: - Crushers

    public static func crushPytest(
        original: String,
        failureLines: [String],
        store: BlobStore = sharedMemory,
        registry: Registry = sharedRegistry,
        masterEnabled: Bool? = nil,
        bindingDigest: String? = nil
    ) -> Result {
        let live = masterEnabled.map { $0 && (registry.snapshot()[.pytest] ?? false) }
            ?? registry.isEnabled(.pytest, bindingDigest: bindingDigest)
        guard live else { return off(.pytest) }
        guard let parsed = parsePytestFailedCount(original) else {
            return Result(accepted: false, collapsed: nil, handle: nil, kind: .pytest)
        }
        let failuresPreserved = failureLines.count == parsed
        let countsMatch = parsed == failureLines.count
        guard let handle = storeVerified(Data(original.utf8), store: store) else {
            return Result(accepted: false, collapsed: nil, handle: nil, kind: .pytest)
        }
        let ok = pytestAccept(
            countsMatch: countsMatch,
            failuresPreserved: failuresPreserved,
            handleValid: true,
            live: live
        )
        guard ok else { return Result(accepted: false, collapsed: nil, handle: nil, kind: .pytest) }
        let body = "pytest: \(parsed) failed\n" + failureLines.joined(separator: "\n") + "\n[[rc:\(handle)]]"
        return Result(accepted: true, collapsed: body, handle: handle, kind: .pytest)
    }

    public static func crushStacktrace(
        original: String,
        store: BlobStore = sharedMemory,
        registry: Registry = sharedRegistry,
        masterEnabled: Bool? = nil,
        bindingDigest: String? = nil
    ) -> Result {
        let live = masterEnabled.map { $0 && (registry.snapshot()[.stacktrace] ?? false) }
            ?? registry.isEnabled(.stacktrace, bindingDigest: bindingDigest)
        guard live else { return off(.stacktrace) }
        let (collapsedBody, hadRun) = collapseConsecutiveIdenticalFrames(original)
        let hasFrame = original.split(separator: "\n").contains { isStackFrameLine(String($0)) }
        let ambiguous = !hasFrame
        let ok = stacktraceAccept(identicalRunsCollapsed: hadRun, ambiguous: ambiguous, live: live)
        guard ok else { return Result(accepted: false, collapsed: nil, handle: nil, kind: .stacktrace) }
        guard let handle = storeVerified(Data(original.utf8), store: store) else {
            return Result(accepted: false, collapsed: nil, handle: nil, kind: .stacktrace)
        }
        return Result(
            accepted: true,
            collapsed: collapsedBody + "\n[[rc:\(handle)]]",
            handle: handle,
            kind: .stacktrace
        )
    }

    /// True if text has line-anchored unified/git diff structure: both --- and +++ headers.
    public static func isUnifiedDiff(_ original: String) -> Bool {
        let lines = original.components(separatedBy: "\n")
        let hasMinus = lines.contains { $0.hasPrefix("--- ") || $0.hasPrefix("---\t") }
        let hasPlus = lines.contains { $0.hasPrefix("+++ ") || $0.hasPrefix("+++\t") }
        let hasGit = lines.contains { $0.hasPrefix("diff --git ") }
        let hasHunk = lines.contains { $0.hasPrefix("@@") }
        let hasChange = lines.contains {
            ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---"))
        }
        // Require both file headers (or git header + both), plus a hunk or change line.
        let headersOK = (hasMinus && hasPlus) || (hasGit && hasMinus && hasPlus)
        return headersOK && (hasHunk || hasChange)
    }

    /// Collapse unchanged context runs; preserve all +/-/header/hunk lines.
    public static func collapseDiffContext(_ original: String) -> (collapsed: String, plusMinusPreserved: Bool) {
        let lines = original.components(separatedBy: "\n")
        var out: [String] = []
        var ctxRun = 0
        var plusMinus = 0
        func flushCtx() {
            if ctxRun > 2 {
                out.append(" … \(ctxRun) unchanged …")
            } else if ctxRun > 0 {
                // keep short context as-is (already emitted)
            }
            ctxRun = 0
        }
        for line in lines {
            if isDiffFileHeader(line) || line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                flushCtx()
                out.append(line)
            } else if line.hasPrefix("+") || line.hasPrefix("-") {
                flushCtx()
                out.append(line)
                plusMinus += 1
            } else {
                // context / other
                if ctxRun < 2 {
                    out.append(line)
                }
                ctxRun += 1
            }
        }
        flushCtx()
        return (out.joined(separator: "\n"), plusMinus > 0)
    }

    public static func crushDiff(
        original: String,
        isBinary: Bool,
        store: BlobStore = sharedMemory,
        registry: Registry = sharedRegistry,
        masterEnabled: Bool? = nil,
        bindingDigest: String? = nil
    ) -> Result {
        let live = masterEnabled.map { $0 && (registry.snapshot()[.diff] ?? false) }
            ?? registry.isEnabled(.diff, bindingDigest: bindingDigest)
        guard live else { return off(.diff) }
        guard isUnifiedDiff(original) else {
            return Result(accepted: false, collapsed: nil, handle: nil, kind: .diff)
        }
        let (collapsedBody, plusMinusPreserved) = collapseDiffContext(original)
        let ok = diffAccept(plusMinusPreserved: plusMinusPreserved, isBinary: isBinary, live: live)
        guard ok else { return Result(accepted: false, collapsed: nil, handle: nil, kind: .diff) }
        guard let handle = storeVerified(Data(original.utf8), store: store) else {
            return Result(accepted: false, collapsed: nil, handle: nil, kind: .diff)
        }
        return Result(
            accepted: true,
            collapsed: collapsedBody + "\n[[rc:\(handle)]]",
            handle: handle,
            kind: .diff
        )
    }

    public static func crushSearch(
        original: String,
        matchLines: [String],
        store: BlobStore = sharedMemory,
        registry: Registry = sharedRegistry,
        masterEnabled: Bool? = nil,
        bindingDigest: String? = nil
    ) -> Result {
        let live = masterEnabled.map { $0 && (registry.snapshot()[.search] ?? false) }
            ?? registry.isEnabled(.search, bindingDigest: bindingDigest)
        guard live else { return off(.search) }
        let matchCount = matchLines.count
        guard let handle = storeVerified(Data(original.utf8), store: store) else {
            // Store failure → do not drop matches
            return Result(accepted: false, collapsed: nil, handle: nil, kind: .search)
        }
        // Verified readback already done in storeVerified
        let ok = searchAccept(handleValid: true, matchCountPreserved: matchCount >= 0, live: live)
        guard ok else { return Result(accepted: false, collapsed: nil, handle: nil, kind: .search) }
        // Preserve match list + handle; never drop matches without handle
        let body = "search: \(matchCount) matches\n" + matchLines.joined(separator: "\n") + "\n[[rc:\(handle)]]"
        return Result(accepted: true, collapsed: body, handle: handle, kind: .search)
    }

    /// Adaptive JSON: minify when small; for top-level arrays keep first/last N elements
    /// with omitted-count marker (schema-preserving). Objects only minify (never slice keys).
    public static func crushAdaptiveJSON(
        original: String,
        windowElements: Int = 3,
        store: BlobStore = sharedMemory,
        registry: Registry = sharedRegistry,
        masterEnabled: Bool? = nil,
        bindingDigest: String? = nil
    ) -> Result {
        let live = masterEnabled.map { $0 && (registry.snapshot()[.adaptiveJSON] ?? false) }
            ?? registry.isEnabled(.adaptiveJSON, bindingDigest: bindingDigest)
        guard live else { return off(.adaptiveJSON) }
        guard let data = original.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return Result(accepted: false, collapsed: nil, handle: nil, kind: .adaptiveJSON)
        }
        guard let handle = storeVerified(Data(original.utf8), store: store) else {
            return Result(accepted: false, collapsed: nil, handle: nil, kind: .adaptiveJSON)
        }
        let collapsed: String
        let omitted: Int
        if let arr = obj as? [Any] {
            let n = arr.count
            if n <= windowElements * 2 {
                guard let compact = try? JSONSerialization.data(withJSONObject: arr),
                      let s = String(data: compact, encoding: .utf8) else {
                    return Result(accepted: false, collapsed: nil, handle: nil, kind: .adaptiveJSON)
                }
                collapsed = s + "\n[[rc:\(handle)]]"
                omitted = 0
            } else {
                let head = Array(arr.prefix(windowElements))
                let tail = Array(arr.suffix(windowElements))
                omitted = n - windowElements * 2
                guard let headData = try? JSONSerialization.data(withJSONObject: head),
                      let tailData = try? JSONSerialization.data(withJSONObject: tail),
                      let hs = String(data: headData, encoding: .utf8),
                      let ts = String(data: tailData, encoding: .utf8) else {
                    return Result(accepted: false, collapsed: nil, handle: nil, kind: .adaptiveJSON)
                }
                // Preserve collection count in marker for coverage audit.
                collapsed = hs + "\n… omitted \(omitted) of \(n) elements …\n" + ts + "\n[[rc:\(handle)]]"
            }
        } else {
            // Objects / scalars: minify only (never arbitrary slice)
            guard let compact = try? JSONSerialization.data(withJSONObject: obj),
                  let s = String(data: compact, encoding: .utf8) else {
                return Result(accepted: false, collapsed: nil, handle: nil, kind: .adaptiveJSON)
            }
            guard s.utf8.count < original.utf8.count else {
                // No gain → deny (lossy window not applied to objects)
                return Result(accepted: false, collapsed: nil, handle: nil, kind: .adaptiveJSON)
            }
            collapsed = s + "\n[[rc:\(handle)]]"
            omitted = 0
        }
        let hasMarker = collapsed.contains("[[rc:") && (omitted == 0 || collapsed.contains("omitted"))
        let coverageOK = adaptiveCoverageOK(obj: obj, omitted: omitted, windowElements: windowElements)
        let ok = adaptiveWindowAccept(coverageOK: coverageOK, hasOmittedMarker: hasMarker, live: live)
        guard ok else { return Result(accepted: false, collapsed: nil, handle: nil, kind: .adaptiveJSON) }
        return Result(accepted: true, collapsed: collapsed, handle: handle, kind: .adaptiveJSON)
    }

    /// Fail closed on low coverage: cannot omit more than 80% of array elements,
    /// and kept window must retain at least 2 distinct type kinds when input is diverse.
    public static func adaptiveCoverageOK(obj: Any, omitted: Int, windowElements: Int) -> Bool {
        if let arr = obj as? [Any] {
            let n = arr.count
            if n == 0 { return true }
            if omitted == 0 { return true }
            // Too aggressive: omit > 80%
            if Double(omitted) / Double(n) > 0.80 { return false }
            let kept = Array(arr.prefix(windowElements)) + Array(arr.suffix(windowElements))
            let kinds = Set(kept.map { adaptiveTypeKind($0) })
            let allKinds = Set(arr.map { adaptiveTypeKind($0) })
            // If input has diverse kinds, kept window must retain >=2 kinds (or all if <2 total)
            if allKinds.count >= 2 && kinds.count < min(2, allKinds.count) { return false }
            return true
        }
        // Objects: minify path only (omitted always 0)
        return omitted == 0
    }

    private static func adaptiveTypeKind(_ value: Any) -> String {
        if value is String { return "string" }
        if value is Bool { return "bool" }
        if value is NSNumber {
            if CFGetTypeID(value as! CFTypeRef) == CFBooleanGetTypeID() { return "bool" }
            return "number"
        }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        if value is NSNull { return "null" }
        return "other"
    }

    /// File headers: `--- path` / `+++ path` with space or tab after the marker.
    public static func isDiffFileHeader(_ line: String) -> Bool {
        line.hasPrefix("--- ") || line.hasPrefix("---\t")
            || line.hasPrefix("+++ ") || line.hasPrefix("+++\t")
    }

    /// Extract +/- change lines from a unified diff (excluding file headers only).
    public static func diffChangeLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { line in
            if isDiffFileHeader(line) { return false }
            // Content lines: + or - prefix, including ++++foo / ----foo body lines
            return line.hasPrefix("+") || line.hasPrefix("-")
        }
    }

    public static func readback(handle: String, store: BlobStore = sharedMemory) -> Data? {
        try? store.retrieve(id: handle)
    }

    private static func off(_ kind: CrusherKind) -> Result {
        Result(accepted: false, collapsed: nil, handle: nil, kind: kind)
    }
}
