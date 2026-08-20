import Foundation

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
        graphifyEnabled: Bool = false,
        command: String? = nil,
        schema: String? = nil,
        op: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        startByte: Int? = nil,
        endByte: Int? = nil,
        pattern: String? = nil,
        claim: String? = nil
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
