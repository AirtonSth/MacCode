import DistillCore
import Foundation
import Persistence

/// The single production mapping from a delivered Distill response to durable savings.
/// Persistence is deliberately fail-open: provider output has already crossed its
/// observable handoff boundary before this callback runs.
public final class DeferredSavingsRecorder: @unchecked Sendable {
    private let repository: TokenSaverSavingsRepository
    private let eventSink: @Sendable (DistillSavingsRecord) -> Void
    private let errorSink: @Sendable (Error) -> Void

    public init(
        repository: TokenSaverSavingsRepository,
        eventSink: @escaping @Sendable (DistillSavingsRecord) -> Void = { _ in },
        errorSink: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.repository = repository
        self.eventSink = eventSink
        self.errorSink = errorSink
    }

    @discardableResult
    public func record(
        request: DistillRequest,
        response: DistillResponse,
        threadID: String
    ) -> DistillSavingsRecord? {
        guard let record = DistillSavingsCalculator.record(
            for: request,
            response: response,
            threadID: threadID
        ) else { return nil }
        do {
            let persistedSavedTokens = try repository.record(
                provider: record.provider,
                mode: record.mode,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                savedTokens: record.savedTokens,
                cacheState: record.cacheState,
                contentType: "unknown",
                engine: record.routeStage?.rawValue ?? "unknown",
                attributability: record.attributability,
                delivered: record.delivered,
                threadID: record.threadID,
                idempotencyKey: record.idempotencyKey
            )
            if persistedSavedTokens > 0 { eventSink(record) }
            return record
        } catch {
            errorSink(error)
            return nil
        }
    }

    public var successHandler: DistillHTTPServer.SuccessHandler {
        { [self] request, response, threadID in
            _ = record(request: request, response: response, threadID: threadID)
        }
    }
}
