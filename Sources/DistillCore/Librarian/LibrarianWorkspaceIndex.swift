import Foundation

/// Embedding service used by the workspace ops. `embed` returns nil when the
/// encoder lane is unavailable, so every caller can fail open to lexical
/// ranking and disclose the mode instead of inventing vectors.
public struct LibrarianEmbeddingProvider: Sendable {
    public var model: String
    public var embed: @Sendable (_ texts: [String]) async -> [[Double]]?

    public init(model: String, embed: @escaping @Sendable ([String]) async -> [[Double]]?) {
        self.model = model
        self.embed = embed
    }

    /// HTTP provider against the running Distill sidecar's `/v1/embed`.
    public static func http(
        baseURL: String,
        authToken: String,
        model: String,
        session: URLSession = .shared
    ) -> LibrarianEmbeddingProvider {
        LibrarianEmbeddingProvider(model: model) { texts in
            guard !texts.isEmpty, let url = URL(string: baseURL + "/v1/embed") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["inputs": texts])
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["available"] as? Bool == true,
                  let rows = object["embeddings"] as? [[Double]],
                  rows.count == texts.count else {
                return nil
            }
            return rows
        }
    }
}

public struct LibrarianWorkspaceHit: Sendable, Equatable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let score: Double

    public init(path: String, startLine: Int, endLine: Int, score: Double) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.score = score
    }
}

public struct LibrarianRepoMapEntry: Sendable, Equatable {
    public let path: String
    public let score: Double
    public let symbols: [String]
    public let lines: Int
}

public struct LibrarianWorkspaceIndexStats: Sendable, Equatable {
    public let root: String
    public let files: Int
    public let chunks: Int
    public let embeddedChunks: Int
    public let truncated: Bool
}

/// One workspace index shared by semantic search, the repo map, encoder ranking
/// and the analysis ops. Files are enumerated once, chunked by line windows and
/// (when the encoder lane is up) embedded in one batch; queries fall back to the
/// deterministic lexical ranker when embeddings are unavailable.
public actor LibrarianWorkspaceIndex {
    /// A whole-repo index stays bounded: enough for real answers, never an
    /// unbounded walk over a monorepo on every op.
    public static let defaultMaxFiles = 800

    public nonisolated let root: String
    private let host: LibrarianHostIO
    private let embedder: LibrarianEmbeddingProvider?
    private let maxFiles: Int
    /// Bounded text cache: the analysis ops read each workspace file once.
    private var texts: [String: String] = [:]
    private var cachedBytes = 0
    static let textCacheByteBudget = 32 * 1024 * 1024
    private var chunks: [LibrarianTextChunk] = []
    private var vectors: [[Double]] = []
    private var fileSymbols: [String: [String]] = [:]
    private var built = false
    private var truncatedFlag = false
    private var embeddedCount = 0

    public init(
        root: String,
        host: LibrarianHostIO = .live,
        embedder: LibrarianEmbeddingProvider? = nil,
        maxFiles: Int = LibrarianWorkspaceIndex.defaultMaxFiles
    ) {
        self.root = root
        self.host = host
        self.embedder = embedder
        self.maxFiles = maxFiles
    }

    public func stats() async -> LibrarianWorkspaceIndexStats {
        await ensureBuilt()
        return LibrarianWorkspaceIndexStats(
            root: root,
            files: fileSymbols.count,
            chunks: chunks.count,
            embeddedChunks: embeddedCount,
            truncated: truncatedFlag
        )
    }

    public func ensureBuilt() async {
        guard !built else { return }
        built = true
        let files = host.listFiles(root, maxFiles)
        truncatedFlag = files.count >= maxFiles
        var collected: [LibrarianTextChunk] = []
        for path in files {
            guard let text = host.readText(path, LibrarianWorkspaceFiles.maxFileBytes) else { continue }
            if LibrarianWorkspaceFiles.isBinaryPath(path) { continue }
            fileSymbols[path] = LibrarianSymbolExtractor.symbols(in: text)
            collected.append(contentsOf: LibrarianChunker.chunks(path: path, text: text))
            if cachedBytes + text.utf8.count <= Self.textCacheByteBudget {
                texts[path] = text
                cachedBytes += text.utf8.count
            }
        }
        chunks = collected
        guard let embedder, !chunks.isEmpty else { return }
        // Bounded batch: one embed call per 32 chunks keeps a repo-wide index from
        // becoming a single unbounded model call.
        var produced: [[Double]] = []
        var batch: [LibrarianTextChunk] = []
        func flush() async {
            guard !batch.isEmpty else { return }
            if let rows = await embedder.embed(batch.map(\.text)), rows.count == batch.count {
                produced.append(contentsOf: rows)
            } else {
                produced.append(contentsOf: batch.map { _ in [] })
            }
            batch.removeAll(keepingCapacity: true)
        }
        for chunk in chunks {
            batch.append(chunk)
            if batch.count >= 32 { await flush() }
        }
        await flush()
        vectors = produced
        embeddedCount = vectors.filter { !$0.isEmpty }.count
    }

    public func search(query: String, topK: Int = 8) async -> (hits: [LibrarianWorkspaceHit], mode: String) {
        await ensureBuilt()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chunks.isEmpty else { return ([], modeName) }
        if let embedder, embeddedCount == chunks.count, let queryVector = await embedder.embed([trimmed])?.first {
            let scored = zip(chunks, vectors).map { chunk, vector in
                LibrarianWorkspaceHit(
                    path: chunk.path,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine,
                    score: LibrarianLexicalRanker.cosine(queryVector, vector)
                )
            }
            return (top(scored, limit: topK), "embedding")
        }
        let scored = chunks.map { chunk in
            LibrarianWorkspaceHit(
                path: chunk.path,
                startLine: chunk.startLine,
                endLine: chunk.endLine,
                score: LibrarianLexicalRanker.score(query: trimmed, text: chunk.text)
            )
        }
        return (top(scored, limit: topK), "lexical")
    }

    public func rank(chunks candidates: [LibrarianTextChunk], query: String, topK: Int) async -> (ranked: [LibrarianWorkspaceHit], mode: String) {
        guard !candidates.isEmpty else { return ([], "lexical") }
        if let embedder, let rows = await embedder.embed([query] + candidates.map(\.text)),
           rows.count == candidates.count + 1 {
            let queryVector = rows[0]
            let scored = zip(candidates, rows.dropFirst()).map { chunk, vector in
                LibrarianWorkspaceHit(
                    path: chunk.path,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine,
                    score: LibrarianLexicalRanker.cosine(queryVector, vector)
                )
            }
            return (top(scored, limit: topK), "embedding")
        }
        let scored = candidates.map { chunk in
            LibrarianWorkspaceHit(
                path: chunk.path,
                startLine: chunk.startLine,
                endLine: chunk.endLine,
                score: LibrarianLexicalRanker.score(query: query, text: chunk.text)
            )
        }
        return (top(scored, limit: topK), "lexical")
    }

    /// Ranked repo map: file → best matching chunks, symbols and size, fitted to a
    /// caller-supplied token budget. Real workspace paths only.
    public func repoMap(query: String, budgetTokens: Int, maxEntries: Int = 60) async -> (entries: [LibrarianRepoMapEntry], mode: String) {
        await ensureBuilt()
        let (hits, mode) = await search(query: query, topK: max(1, maxEntries * 3))
        var bestByPath: [String: LibrarianWorkspaceHit] = [:]
        for hit in hits where bestByPath[hit.path] == nil {
            bestByPath[hit.path] = hit
        }
        var entries: [LibrarianRepoMapEntry] = []
        var used = 0
        for hit in hits {
            guard bestByPath[hit.path]?.startLine == hit.startLine else { continue }
            let symbols = fileSymbols[hit.path] ?? []
            let cost = TokenEstimator.estimate(hit.path) + TokenEstimator.estimate(symbols.joined(separator: " "))
            if used + cost > budgetTokens && !entries.isEmpty { break }
            used += cost
            entries.append(LibrarianRepoMapEntry(
                path: hit.path,
                score: hit.score,
                symbols: Array(symbols.prefix(6)),
                lines: chunkLineCount(for: hit.path)
            ))
            if entries.count >= maxEntries { break }
        }
        return (entries, mode)
    }

    /// Workspace file text, read once. Falls back to a single host read when the
    /// cache budget was exhausted.
    public func text(for path: String) async -> String? {
        await ensureBuilt()
        if let cached = texts[path] { return cached }
        return host.readText(path, LibrarianWorkspaceFiles.maxFileBytes)
    }

    public func symbols(in path: String) async -> [String] {
        await ensureBuilt()
        return fileSymbols[path] ?? []
    }

    public func allPaths() async -> [String] {
        await ensureBuilt()
        return fileSymbols.keys.sorted()
    }

    public func chunkLineCounts() async -> [String: Int] {
        await ensureBuilt()
        var counts: [String: Int] = [:]
        for chunk in chunks {
            counts[chunk.path] = max(counts[chunk.path] ?? 0, chunk.endLine)
        }
        return counts
    }

    private func chunkLineCount(for path: String) -> Int {
        chunks.filter { $0.path == path }.map(\.endLine).max() ?? 0
    }

    private var modeName: String { embeddedCount == chunks.count && embeddedCount > 0 ? "embedding" : "lexical" }

    private func top(_ hits: [LibrarianWorkspaceHit], limit: Int) -> [LibrarianWorkspaceHit] {
        hits
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.path < rhs.path : lhs.score > rhs.score
            }
            .prefix(max(1, limit))
            .map { $0 }
    }
}

/// Shared per-process index cache: the semantic search, the repo map and the
/// analysis ops must not re-read the workspace per call.
public actor LibrarianWorkspaceIndexCache {
    public static let shared = LibrarianWorkspaceIndexCache()
    /// Each index can hold tens of MiB of text; keep only the most recently used roots.
    public static let defaultMaxRoots = 4
    private let maxRoots: Int
    private var indexes: [String: LibrarianWorkspaceIndex] = [:]
    private var recentRoots: [String] = []

    public init(maxRoots: Int = LibrarianWorkspaceIndexCache.defaultMaxRoots) {
        self.maxRoots = max(1, maxRoots)
    }

    public func index(
        for root: String,
        host: LibrarianHostIO,
        embedder: LibrarianEmbeddingProvider?
    ) -> LibrarianWorkspaceIndex {
        recentRoots.removeAll { $0 == root }
        recentRoots.append(root)
        if let existing = indexes[root] { return existing }
        let created = LibrarianWorkspaceIndex(root: root, host: host, embedder: embedder)
        indexes[root] = created
        while recentRoots.count > maxRoots {
            indexes.removeValue(forKey: recentRoots.removeFirst())
        }
        return created
    }

    public var cachedRootCount: Int { indexes.count }

    public func reset() {
        indexes.removeAll()
        recentRoots.removeAll()
    }
}

/// Language-agnostic declaration extraction for the repo map and analysis ops.
/// Deliberately lexical: it reports what it can see and never claims compiler
/// accuracy, which keeps a native matcher honest without an AST dependency.
public enum LibrarianSymbolExtractor {
    private static let patterns: [NSRegularExpression] = [
        #"(?m)^\s*(?:public |private |internal |fileprivate |open |final |static |export |async )*(?:func|def|function|fn)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
        #"(?m)^\s*(?:public |private |internal |final |open |export |abstract )*(?:class|struct|enum|protocol|interface|type|trait|record)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
        #"(?m)^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*[:=]"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func symbols(in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for pattern in patterns {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
                let name = ns.substring(with: match.range(at: 1))
                if seen.insert(name).inserted { out.append(name) }
                if out.count >= 400 { return out }
            }
        }
        return out
    }
}
