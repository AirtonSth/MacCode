import Foundation
import CoreModel

/// Production bridge for Wave B typed crushers (task-15).
/// Default registry/master OFF → crushers always deny; no provider payload mutation.
public enum TokenSaverTypedCrushersBridge {
    public static let taskID = "task-15"

    private final class ActivationState: @unchecked Sendable {
        private let lock = NSLock()
        private var bindingDigest: String?
        private var store: TokenSaverTypedCrushers.BlobStore?

        func activate(bindingDigest: String, store: TokenSaverTypedCrushers.BlobStore) {
            lock.lock()
            self.bindingDigest = bindingDigest
            self.store = store
            lock.unlock()
        }

        func deactivate() {
            lock.lock()
            bindingDigest = nil
            store = nil
            lock.unlock()
        }

        func store(for bindingDigest: String?) -> TokenSaverTypedCrushers.BlobStore? {
            lock.lock(); defer { lock.unlock() }
            guard self.bindingDigest == bindingDigest else { return nil }
            return store
        }
    }

    private static let activation = ActivationState()

    public static func activate(
        kinds: Set<TokenSaverTypedCrushers.CrusherKind>,
        bindingDigest: String,
        releaseSeal: TokenSaverAuthorityPlane.ReleaseSeal,
        encryptedStore: TokenSaverEncryptedStore,
        scope: TokenSaverEncryptedStore.Scope
    ) {
        TokenSaverTypedCrushers.sharedRegistry.activate(kinds, releaseSeal: releaseSeal)
        let originals = TokenSaverEncryptedOriginalStore(store: encryptedStore, scope: scope)
        activation.activate(
            bindingDigest: bindingDigest,
            store: TokenSaverTypedCrushers.EncryptedStore(originals: originals)
        )
    }

    public static func deactivate() {
        TokenSaverTypedCrushers.sharedRegistry.deactivate()
        activation.deactivate()
    }

    /// Extract pytest failure case lines (not the summary "N failed" line).
    public static func pytestFailureLines(from output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // Case result lines, not summary
            if t.range(of: #"^\d+\s+failed"#, options: .regularExpression) != nil { return false }
            if t.contains("=====") { return false }
            return t.contains(" FAILED") || t.hasSuffix(" FAILED") || t.hasPrefix("FAILED ")
        }
    }

    /// Extract `[[rc:…]]` handles (hex SHA or production `rcv1.*` scoped form).
    public static func extractRecoveryHandles(from output: String) -> [String] {
        let pattern = #"\[\[rc:([^\]]+)\]\]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = output as NSString
        return re.matches(in: output, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges >= 2 else { return nil }
            let h = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return h.isEmpty ? nil : h
        }
    }

    /// Probe crushers on tool output. Fail-open: never throws; never mutates `output`.
    /// `resultScopeDigest` is independent of query BindingID so cross-scope denial is real.
    public static func observeToolOutput(
        toolName: String,
        output: String,
        bindingDigest: String? = nil,
        resultScopeDigest: String? = nil
    ) {
        // A release-approved binding without its encrypted original store still fails open/raw.
        if let store = activation.store(for: bindingDigest) {
            if output.range(of: #"\d+\s+failed"#, options: .regularExpression) != nil
                || output.contains("pytest") {
                _ = TokenSaverTypedCrushers.crushPytest(
                    original: output,
                    failureLines: pytestFailureLines(from: output),
                    store: store,
                    bindingDigest: bindingDigest
                )
            }
            if output.contains("Traceback")
                || output.split(separator: "\n").contains(where: { TokenSaverTypedCrushers.isStackFrameLine(String($0)) }) {
                _ = TokenSaverTypedCrushers.crushStacktrace(
                    original: output,
                    store: store,
                    bindingDigest: bindingDigest
                )
            }
            if TokenSaverTypedCrushers.isUnifiedDiff(output) {
                _ = TokenSaverTypedCrushers.crushDiff(
                    original: output,
                    isBinary: false,
                    store: store,
                    bindingDigest: bindingDigest
                )
            }
            if toolName == "Grep" || toolName == "Glob" {
                let lines = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                _ = TokenSaverTypedCrushers.crushSearch(
                    original: output,
                    matchLines: lines,
                    store: store,
                    bindingDigest: bindingDigest
                )
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.first == "{" || trimmed.first == "[" {
                _ = TokenSaverTypedCrushers.crushAdaptiveJSON(
                    original: trimmed,
                    store: store,
                    bindingDigest: bindingDigest
                )
            }
        }
        // task-16 recovery probes (default OFF → deny)
        // PERF: materialize UTF-8 once only when handles exist; reuse for
        // bytes + original across every probe on the same tool output.
        let recoveryHandles = extractRecoveryHandles(from: output)
        if !recoveryHandles.isEmpty {
            let outputBytes = Data(output.utf8)
            for handle in recoveryHandles {
                _ = TokenSaverRecoveryBridge.observeRetrieve(
                    handle: handle,
                    bytes: outputBytes,
                    original: outputBytes,
                    revoked: false
                )
            }
        }
        if toolName == "Grep" || toolName == "Glob" {
            // Missing result scope must deny (empty), not self-match on query BindingID.
            let q = bindingDigest ?? ""
            let r = resultScopeDigest ?? ""
            _ = TokenSaverRecoveryBridge.observeSearch(queryScope: q, resultScope: r)
        }
    }
}
