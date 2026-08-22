import Foundation
import CoreModel

public final class LibrarianDispatcher: @unchecked Sendable {
    public let store: LibrarianHandleStore
    public let analytics: LibrarianAnalyticsLedger
    public var generate: (any LibrarianGenerating)?
    public var persist: LibrarianSavingsPersist?

    public init(
        store: LibrarianHandleStore = LibrarianHandleStore(),
        analytics: LibrarianAnalyticsLedger = LibrarianAnalyticsLedger(),
        generate: (any LibrarianGenerating)? = nil,
        persist: LibrarianSavingsPersist? = nil
    ) {
        self.store = store
        self.analytics = analytics
        self.generate = generate
        self.persist = persist
    }

    public func dispatch(_ request: LibrarianRequest) async -> LibrarianResult {
        let output = await handle(request)
        let strippedText: String
        if let clean = LibrarianThinkStrip.paidFacingText(output.text) {
            strippedText = clean
        } else {
            let refused = LibrarianHandlerOutput(
                status: .unavailable,
                text: "",
                envelope: .unavailable(op: request.id, reason: "think_strip_failed", handle: request.handle),
                handle: request.handle,
                stage: .verbatim,
                originalForSavings: output.originalForSavings
            )
            return finish(request: request, output: refused)
        }
        var adjusted = output
        if strippedText != output.text {
            adjusted = LibrarianHandlerOutput(
                status: output.status,
                text: strippedText,
                envelope: output.envelope,
                handle: output.handle,
                stage: output.stage,
                originalForSavings: output.originalForSavings
            )
        }
        return finish(request: request, output: adjusted)
    }

    private func finish(request: LibrarianRequest, output: LibrarianHandlerOutput) -> LibrarianResult {
        let event = LibrarianAnalytics.measure(
            op: request.id,
            status: output.status,
            original: output.originalForSavings,
            deliveredText: output.status == .ok ? output.text : nil,
            provider: request.provider,
            modelID: nil,
            threadID: request.threadID,
            stage: output.stage
        )
        analytics.record(event)
        if let record = event.record {
            persist?(record)
        }
        return LibrarianResult(
            status: output.status,
            text: output.text,
            envelope: output.envelope,
            handle: output.handle,
            analytics: event
        )
    }

    private func handle(_ request: LibrarianRequest) async -> LibrarianHandlerOutput {
        guard let fn = LibrarianCatalog.function(id: request.id) else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "",
                envelope: .unavailable(op: request.id, reason: "unknown_handle_or_op"),
                originalForSavings: request.input
            )
        }
        if !request.admitted {
            return LibrarianHandlerOutput(
                status: .refused,
                text: "",
                envelope: .refused(op: fn.id, reason: "token_saver_inactive"),
                originalForSavings: request.input
            )
        }
        if fn.id == "stats" {
            return statsOutput()
        }
        if fn.safety == .forbidden {
            return LibrarianForbidden.handle(request, function: fn)
        }
        if LibrarianExactOutputPolicy.shouldRefuseAutoDistill(id: fn.id, command: request.command) {
            return LibrarianForbidden.exactOutputRefuse(request)
        }
        if !request.retrieveAvailable, LibrarianExactOutputPolicy.isLossy(fn) {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: request.input,
                envelope: .unavailable(op: fn.id, reason: "retrieve_down_lossy_disabled", handle: request.handle),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        if (fn.id == "graphify_query" || fn.id == "graph_ask"), !request.graphifyEnabled {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: request.input,
                envelope: .unavailable(op: fn.id, reason: "graphify_inactive"),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        if LibrarianSecretGate.looksSecret(request.input), fn.usesLLM {
            return LibrarianHandlerOutput(
                status: .refused,
                text: "",
                envelope: .refused(op: fn.id, reason: "secret_pre_gate", handle: request.handle),
                originalForSavings: request.input
            )
        }
        return await LibrarianHandlers.run(request, function: fn, store: store, generate: generate)
    }

    // PERF: JSONEncoder sortedKeys is ICU-heavy. Share one behind lock.
    private static let statsEncoderLock = NSLock()
    private static let statsEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private func statsOutput() -> LibrarianHandlerOutput {
        let modes = analytics.modeBreakdown()
        let total = analytics.totalSavedTokens()
        Self.statsEncoderLock.lock()
        let modesJSON = (try? Self.statsEncoder.encode(modes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        Self.statsEncoderLock.unlock()
        let text = "{\"total_saved_tokens\":\(total),\"modes\":\(modesJSON)}"
        return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: text)
    }
}

public enum LibrarianExactOutputPolicy {
    public static func shouldRefuseAutoDistill(id: String, command: String?) -> Bool {
        if id == "distill_exact_rg" { return true }
        guard let command, !command.isEmpty else { return false }
        let last = command.split(separator: "|").last.map { String($0) } ?? command
        if last.trimmingCharacters(in: .whitespaces).hasPrefix("distill") {
            return false
        }
        let primary = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
        return WrappedCommandCatalog.isExactOutputCommand(primary)
            && (id.hasPrefix("distill_") || id.hasSuffix("_digest") || id.contains("crusher"))
    }

    public static func isLossy(_ fn: LibrarianFunction) -> Bool {
        fn.safety == .safe || fn.safety == .candidate || fn.id.contains("crusher") || fn.id.contains("elide")
    }
}

public enum LibrarianSecretGate {
    private static let regex = try! NSRegularExpression(
        pattern: #"(?i)(api[_-]?key|secret|password|token|bearer)\s*[:=]\s*\S{8,}"#
    )

    public static func looksSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
