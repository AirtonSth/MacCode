import Foundation

public struct LibrarianHTTPBody: Codable, Sendable {
    public var id: String
    public var input: String?
    public var question: String?
    public var handle: String?
    public var handles: [String]?
    public var provider: String?
    public var threadID: String?
    public var command: String?
    public var op: String?
    public var pattern: String?
    public var startLine: Int?
    public var endLine: Int?
    public var root: String?
    public var paths: [String]?
    public var symbol: String?
    public var fileName: String?
    public var baseRef: String?
    public var since: String?
    public var locale: String?
    public var payload: String?
    public var navigation: String?
    public var arguments: [String]?
    public var topK: Int?
    public var budgetTokens: Int?
    public var scopeToThread: Bool?
    public var watchIntervalSeconds: Double?
    public var watchTimeoutSeconds: Int?

    public enum CodingKeys: String, CodingKey {
        case id, input, question, handle, handles, provider, command, op, pattern
        case root, paths, symbol, locale, payload, navigation, arguments
        case threadID = "thread_id"
        case startLine = "start_line"
        case endLine = "end_line"
        case fileName = "file_name"
        case baseRef = "base_ref"
        case since
        case topK = "top_k"
        case budgetTokens = "budget_tokens"
        case scopeToThread = "scope_to_thread"
        case watchIntervalSeconds = "watch_interval_seconds"
        case watchTimeoutSeconds = "watch_timeout_seconds"
    }
}

public struct LibrarianRequest: Sendable {
    public var id: String
    public var input: String
    public var question: String?
    public var handle: String?
    public var handles: [String]
    public var provider: String
    public var threadID: String
    public var admitted: Bool
    public var retrieveAvailable: Bool
    /// Capability proven by the host through a scoped, byte-exact recovery
    /// readback. Caller-supplied HTTP fields never populate this directly.
    public var verifiedRecoveryHandle: String?
    public var graphifyEnabled: Bool
    public var command: String?
    public var schema: String?
    public var op: String?
    public var startLine: Int?
    public var endLine: Int?
    public var startByte: Int?
    public var endByte: Int?
    public var pattern: String?
    public var claim: String?
    /// Workspace root for the workspace / navigation / analysis ops.
    public var root: String?
    public var paths: [String]
    public var symbol: String?
    public var fileName: String?
    public var baseRef: String?
    public var since: String?
    public var locale: String?
    /// Structured op payload (JSON string) for batch_codemod_apply and friends.
    public var payload: String?
    /// LSP operation or graphify subcommand: documentSymbol|definition|references|hover, query|path|explain.
    public var navigationOperation: String?
    /// Already-approved argv for predicate_watch; RemoteCode never invents it.
    public var arguments: [String]
    public var topK: Int?
    public var budgetTokens: Int?
    public var scopeToThread: Bool
    public var watchIntervalSeconds: Double?
    public var watchTimeoutSeconds: Int?

    public init(
        id: String,
        input: String = "",
        question: String? = nil,
        handle: String? = nil,
        handles: [String] = [],
        provider: String = "unknown",
        threadID: String = "",
        admitted: Bool = true,
        retrieveAvailable: Bool = true,
        verifiedRecoveryHandle: String? = nil,
        graphifyEnabled: Bool = false,
        command: String? = nil,
        schema: String? = nil,
        op: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        startByte: Int? = nil,
        endByte: Int? = nil,
        pattern: String? = nil,
        claim: String? = nil,
        root: String? = nil,
        paths: [String] = [],
        symbol: String? = nil,
        fileName: String? = nil,
        baseRef: String? = nil,
        since: String? = nil,
        locale: String? = nil,
        payload: String? = nil,
        navigationOperation: String? = nil,
        arguments: [String] = [],
        topK: Int? = nil,
        budgetTokens: Int? = nil,
        scopeToThread: Bool = false,
        watchIntervalSeconds: Double? = nil,
        watchTimeoutSeconds: Int? = nil
    ) {
        self.id = id
        self.input = input
        self.question = question
        self.handle = handle
        self.handles = handles
        self.provider = provider
        self.threadID = threadID
        self.admitted = admitted
        self.retrieveAvailable = retrieveAvailable
        self.verifiedRecoveryHandle = verifiedRecoveryHandle
        self.graphifyEnabled = graphifyEnabled
        self.command = command
        self.schema = schema
        self.op = op
        self.startLine = startLine
        self.endLine = endLine
        self.startByte = startByte
        self.endByte = endByte
        self.pattern = pattern
        self.claim = claim
        self.root = root
        self.paths = paths
        self.symbol = symbol
        self.fileName = fileName
        self.baseRef = baseRef
        self.since = since
        self.locale = locale
        self.payload = payload
        self.navigationOperation = navigationOperation
        self.arguments = arguments
        self.topK = topK
        self.budgetTokens = budgetTokens
        self.scopeToThread = scopeToThread
        self.watchIntervalSeconds = watchIntervalSeconds
        self.watchTimeoutSeconds = watchTimeoutSeconds
    }
}

/// Input resolved for an op: the handle's blob when a handle was supplied,
/// otherwise the request's inline input (stored so recovery stays possible).
public struct ResolvedBox: Sendable {
    public let text: String
    public let handle: String
    public let original: String

    public init(text: String, handle: String, original: String) {
        self.text = text
        self.handle = handle
        self.original = original
    }
}

public struct LibrarianResult: Sendable {
    public let status: LibrarianStatus
    public let text: String
    public let envelope: LibrarianEnvelope?
    public let handle: String?
    public let analytics: LibrarianAnalyticsEvent

    public var paidFacingText: String { text }
}

public struct LibrarianHandlerOutput: Sendable {
    public let status: LibrarianStatus
    public let text: String
    public let envelope: LibrarianEnvelope?
    public let handle: String?
    public let stage: TokenSaverRouteStage
    public let originalForSavings: String

    public init(
        status: LibrarianStatus,
        text: String,
        envelope: LibrarianEnvelope? = nil,
        handle: String? = nil,
        stage: TokenSaverRouteStage = .deterministic,
        originalForSavings: String
    ) {
        self.status = status
        self.text = text
        self.envelope = envelope
        self.handle = handle
        self.stage = stage
        self.originalForSavings = originalForSavings
    }
}
