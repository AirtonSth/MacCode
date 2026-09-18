import Foundation

/// Automatic hot-lane routing: a command/tool output whose shape matches a
/// catalog hot op is processed by that op without any model or user request, and
/// the invocation records its own `librarian.<op>` ledger row.
///
/// Only deterministic crushers are routed here. Exact-output tools (rg/grep/cat
/// and friends) are never routed: the catalog forbids auto-distilling the stdout
/// an agent must consume byte-exactly.
public enum LibrarianHotLane {
    /// Candidate op ids for a payload, best first. A build/lint report falls
    /// through to the log crusher when no progress bar exists, and the ledger row
    /// always names the op that actually produced the delivered text.
    public static func opIDs(
        for text: String,
        question: String? = nil,
        router: DistillContentRouter = DistillContentRouter()
    ) -> [String] {
        let type = router.classify(text)
        var ids = opIDs(for: type)
        // Exact-output shapes (search result dumps, rg/grep stdout) are never
        // auto-routed by a catalog op, even when they look like a big listing.
        if ids.isEmpty, type != .searchResults, looksLikeLargeListing(text) {
            ids = ["stdout_budget_elide"]
        }
        return ids
    }

    public static func opID(
        for text: String,
        question: String? = nil,
        router: DistillContentRouter = DistillContentRouter()
    ) -> String? {
        opIDs(for: text, question: question, router: router).first
    }

    public static func opIDs(for type: DistillContentType) -> [String] {
        switch type {
        case .json: return ["json_crusher", "toon_codec"]
        case .log: return ["log_crusher"]
        case .diff: return ["diff_crusher"]
        case .stackTrace: return ["stack_crusher"]
        case .testReport: return ["test_crusher"]
        case .buildOutput: return ["progress_bar_crusher", "log_crusher", "test_crusher"]
        case .html: return ["html_crusher"]
        case .searchResults, .sourceCode, .mixed, .prose: return []
        }
    }

    public static func opID(for type: DistillContentType) -> String? {
        opIDs(for: type).first
    }

    /// A large file listing: most non-empty lines start with a path-like token.
    public static func looksLikeLargeListing(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 40 else { return false }
        var pathLike = 0
        for line in lines.prefix(200) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { continue }
            if first == "/" || first == "." || first.isLetter {
                let head = trimmed.prefix(60)
                if head.contains("/") || head.hasSuffix("/") { pathLike += 1 }
            }
        }
        return pathLike * 2 >= min(lines.count, 200)
    }

    /// Route through the shipped dispatcher. The caller supplies the durable
    /// recovery handle so the op's marker points at retrievable bytes.
    public static func route(
        text: String,
        question: String?,
        handle: String?,
        dispatcher: LibrarianDispatcher
    ) async -> LibrarianResult? {
        for opID in opIDs(for: text, question: question) {
            let result = await dispatcher.dispatch(LibrarianRequest(
                id: opID,
                input: text,
                question: question,
                handle: handle,
                admitted: true,
                retrieveAvailable: handle != nil,
                verifiedRecoveryHandle: handle
            ))
            if result.status == .ok,
               result.text != text,
               result.text.utf8.count < text.utf8.count {
                return result
            }
        }
        return nil
    }
}
