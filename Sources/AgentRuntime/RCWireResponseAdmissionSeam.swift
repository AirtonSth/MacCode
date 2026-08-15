import CoreModel

/// Pure RCW1 A response gate. Persistence and UI consumers are intentionally
/// outside this seam so admission can be proven before either is wired.
public enum RCWireResponseAdmissionSeam {
    public enum CountQuality: Sendable, Equatable {
        case exactLexical
        case estimated
        case unknown
    }

    public struct PairCountRequest: Sendable, Equatable {
        public let provider: AgentProvider
        public let resolvedModel: String
        public let projection: RCWireResponseProjection
    }

    public struct PairCountReceipt: Sendable, Equatable {
        public let counterID: String
        public let quality: CountQuality
        public let provider: AgentProvider
        public let resolvedModel: String
        public let rawWireLexicalCount: Int
        public let deterministicHumanLexicalCount: Int

        public init(
            counterID: String,
            quality: CountQuality,
            provider: AgentProvider,
            resolvedModel: String,
            rawWireLexicalCount: Int,
            deterministicHumanLexicalCount: Int
        ) {
            self.counterID = counterID
            self.quality = quality
            self.provider = provider
            self.resolvedModel = resolvedModel
            self.rawWireLexicalCount = rawWireLexicalCount
            self.deterministicHumanLexicalCount = deterministicHumanLexicalCount
        }
    }

    public protocol PairCounting: Sendable {
        func countPair(_ request: PairCountRequest) async throws -> PairCountReceipt?
    }

    public struct Admission: Sendable, Equatable {
        public let projection: RCWireResponseProjection
        public let counterID: String
        public let provider: AgentProvider
        public let resolvedModel: String
        public let rawWireLexicalCount: Int
        public let deterministicHumanLexicalCount: Int
    }

    public enum Rejection: Sendable, Equatable {
        case invalidResponse
        case invalidResolvedModel
        case pairCounterUnavailable
        case pairCountUnavailable
        case pairCounterFailed
        case countQualityNotExactLexical(CountQuality)
        case counterBindingMismatch
        case invalidCounterID
        case invalidLexicalCount
        case tokenRatioOverflow
        case aboveMaximumTokenRatio
    }

    public enum Decision: Sendable, Equatable {
        case admitted(Admission)
        case rejected(Rejection)
    }

    public static func evaluate(
        rawResponse: String,
        provider: AgentProvider,
        resolvedModel: String,
        pairCounter: (any PairCounting)? = nil
    ) async -> Decision {
        guard let projection = RCWireProtocol.strictResponseProjection(raw: rawResponse) else {
            return .rejected(.invalidResponse)
        }
        guard !resolvedModel.allSatisfy(\.isWhitespace) else {
            return .rejected(.invalidResolvedModel)
        }
        guard let pairCounter else {
            return .rejected(.pairCounterUnavailable)
        }

        let request = PairCountRequest(
            provider: provider,
            resolvedModel: resolvedModel,
            projection: projection
        )
        let receipt: PairCountReceipt
        do {
            guard let measured = try await pairCounter.countPair(request) else {
                return .rejected(.pairCountUnavailable)
            }
            receipt = measured
        } catch {
            return .rejected(.pairCounterFailed)
        }

        guard receipt.quality == .exactLexical else {
            return .rejected(.countQualityNotExactLexical(receipt.quality))
        }
        guard receipt.provider == provider,
              receipt.resolvedModel == resolvedModel else {
            return .rejected(.counterBindingMismatch)
        }
        guard !receipt.counterID.allSatisfy(\.isWhitespace) else {
            return .rejected(.invalidCounterID)
        }
        guard receipt.rawWireLexicalCount > 0,
              receipt.deterministicHumanLexicalCount > 0 else {
            return .rejected(.invalidLexicalCount)
        }

        let (weightedRawWire, rawWireOverflow) = receipt.rawWireLexicalCount
            .multipliedReportingOverflow(by: 100)
        let (weightedHuman, humanOverflow) = receipt.deterministicHumanLexicalCount
            .multipliedReportingOverflow(by: 45)
        guard !rawWireOverflow, !humanOverflow else {
            return .rejected(.tokenRatioOverflow)
        }
        guard weightedRawWire <= weightedHuman else {
            return .rejected(.aboveMaximumTokenRatio)
        }

        return .admitted(Admission(
            projection: projection,
            counterID: receipt.counterID,
            provider: provider,
            resolvedModel: resolvedModel,
            rawWireLexicalCount: receipt.rawWireLexicalCount,
            deterministicHumanLexicalCount: receipt.deterministicHumanLexicalCount
        ))
    }
}
