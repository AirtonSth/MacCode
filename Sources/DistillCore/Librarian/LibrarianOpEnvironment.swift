import Foundation

/// Everything a librarian op needs from the host, injected so the shipped ops
/// can be driven from tests against a real temp workspace and from the sidecar
/// against the real filesystem, processes and services.
public struct LibrarianOpEnvironment: Sendable {
    public var host: LibrarianHostIO
    /// nil (or a provider whose embed call fails) fails open to lexical ranking.
    public var embedder: LibrarianEmbeddingProvider?
    /// Workspace root used when the request does not carry one.
    public var defaultRoot: String?
    /// Real persisted transcript/session store, read-only.
    public var transcript: LibrarianTranscriptStore?
    /// graphify CLI runner (real binary; nil disables the op honestly).
    public var graph: LibrarianGraphRunner?
    /// sourcekit-lsp client (real binary; nil disables the op honestly).
    public var lsp: LibrarianLSPClient?
    /// Speech transcription seam: TCC-gated live implementation, injectable in tests.
    public var speech: LibrarianSpeechTranscriber?
    public var processEnvironment: [String: String]

    public init(
        host: LibrarianHostIO = .live,
        embedder: LibrarianEmbeddingProvider? = nil,
        defaultRoot: String? = nil,
        transcript: LibrarianTranscriptStore? = nil,
        graph: LibrarianGraphRunner? = nil,
        lsp: LibrarianLSPClient? = nil,
        speech: LibrarianSpeechTranscriber? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.host = host
        self.embedder = embedder
        self.defaultRoot = defaultRoot
        self.transcript = transcript
        self.graph = graph
        self.lsp = lsp
        self.speech = speech
        self.processEnvironment = processEnvironment
    }

    /// Live environment: real filesystem, real processes, real Graphify/LSP when
    /// the binaries resolve, no embedder (the caller wires the sidecar's
    /// `/v1/embed`) and no transcript DB (the service wires its own).
    public static let live = LibrarianOpEnvironment(
        host: .live,
        embedder: nil,
        defaultRoot: ProcessInfo.processInfo.environment["RC_TOKEN_SAVER_WORKSPACE_ROOT"],
        transcript: nil,
        graph: LibrarianGraphRunner.live(),
        lsp: LibrarianLSPClient.live(),
        speech: LibrarianSpeechTranscriber.live()
    )

    /// Resolve the workspace root for a request: explicit request root, then the
    /// environment default, then the process working directory.
    public func root(for request: LibrarianRequest) -> String {
        if let root = request.root?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty, host.isDirectory(root) {
            return root
        }
        if let fallback = defaultRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty, host.isDirectory(fallback) {
            return fallback
        }
        let cwd = FileManager.default.currentDirectoryPath
        return host.isDirectory(cwd) ? cwd : "/"
    }

    public func index(for root: String) async -> LibrarianWorkspaceIndex {
        await LibrarianWorkspaceIndexCache.shared.index(for: root, host: host, embedder: embedder)
    }
}

public struct LibrarianTranscriptHit: Sendable, Equatable {
    public let threadID: String
    public let role: String
    public let createdAt: String
    public let snippet: String

    public init(threadID: String, role: String, createdAt: String, snippet: String) {
        self.threadID = threadID
        self.role = role
        self.createdAt = createdAt
        self.snippet = snippet
    }
}

/// Read-only search over the host's persisted transcript (`agent_messages`) so
/// `session_transcript_search` / `history_recall_search` return real turns
/// instead of living in the reversible-handle store.
public struct LibrarianTranscriptStore: Sendable {
    /// nil means the store itself is unavailable (open/prepare failure), which is
    /// a different state from "no hits" and must be reported as such.
    public var search: @Sendable (_ query: String, _ limit: Int, _ threadID: String?) -> [LibrarianTranscriptHit]?
    public var recent: @Sendable (_ limit: Int, _ threadID: String?) -> [LibrarianTranscriptHit]?

    public init(
        search: @escaping @Sendable (String, Int, String?) -> [LibrarianTranscriptHit]?,
        recent: @escaping @Sendable (Int, String?) -> [LibrarianTranscriptHit]?
    ) {
        self.search = search
        self.recent = recent
    }

    /// Real SQLite implementation over the RemoteCode database (read-only).
    public static func sqlite(dbPath: String) -> LibrarianTranscriptStore {
        LibrarianTranscriptSQLite(dbPath: dbPath).store
    }
}

/// Real graphify CLI runner.
public struct LibrarianGraphRunner: Sendable {
    public var executable: String
    public var timeout: TimeInterval
    public var run: @Sendable (_ arguments: [String], _ graphPath: String?) -> LibrarianProcessResult

    public init(
        executable: String,
        timeout: TimeInterval = 25,
        run: @escaping @Sendable ([String], String?) -> LibrarianProcessResult
    ) {
        self.executable = executable
        self.timeout = timeout
        self.run = run
    }

    public static func live(host: LibrarianHostIO = .live) -> LibrarianGraphRunner? {
        guard let binary = host.resolveTool("graphify") else { return nil }
        return LibrarianGraphRunner(executable: binary) { arguments, graphPath in
            var args = arguments
            if let graphPath, !graphPath.isEmpty { args += ["--graph", graphPath] }
            return host.runProcess(LibrarianProcessInvocation(
                executable: binary,
                arguments: args,
                cwd: graphPath.map { ($0 as NSString).deletingLastPathComponent },
                timeout: 25
            ))
        }
    }
}

/// Real sourcekit-lsp client (JSON-RPC over stdio, one short-lived session per
/// query). Kept minimal on purpose: initialize → didOpen → query → shutdown.
public struct LibrarianLSPClient: Sendable {
    public var executable: String
    public var timeout: TimeInterval

    public init(executable: String, timeout: TimeInterval = 20) {
        self.executable = executable
        self.timeout = timeout
    }

    public static func live(host: LibrarianHostIO = .live) -> LibrarianLSPClient? {
        if let resolved = host.resolveTool("sourcekit-lsp") {
            return LibrarianLSPClient(executable: resolved)
        }
        return nil
    }
}

/// Speech transcription seam. The live implementation is TCC-gated; tests inject
/// a real audio-file-backed stub so the op plumbing is exercised without a grant.
public struct LibrarianSpeechTranscriber: Sendable {
    public var authorization: LibrarianAuthorizationState
    public var transcribe: @Sendable (_ audioPath: String, _ locale: String) async -> String?

    public init(
        authorization: LibrarianAuthorizationState,
        transcribe: @escaping @Sendable (String, String) async -> String?
    ) {
        self.authorization = authorization
        self.transcribe = transcribe
    }

    public static func live() -> LibrarianSpeechTranscriber {
        let state = LibrarianHostPermissions.authorization(for: "speech")
        return LibrarianSpeechTranscriber(authorization: state) { path, locale in
            await LibrarianSpeechRecognition.transcribe(path: path, locale: locale)
        }
    }
}
