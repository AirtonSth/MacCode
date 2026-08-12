import Foundation
@testable import DistillCore

final class TestScopedRecoveryStore: TokenSaverScopedRecoveryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var originals: [String: Data] = [:]
    private var states: [String: TokenSaverScopedInvocationState] = [:]

    func lookupInvocation(context: TokenSaverRecoveryRequestContext) throws -> TokenSaverScopedInvocationState? {
        lock.withLock { states[context.invocationID] }
    }

    func prepareOriginal(
        _ data: Data,
        context: TokenSaverRecoveryRequestContext,
        lane: String
    ) throws -> TokenSaverScopedPreparation {
        let capability = UUID().uuidString.lowercased()
        lock.withLock {
            originals[capability] = data
            states[context.invocationID] = .init(state: .prepared, transportOutcome: .notSent)
        }
        return .init(capability: capability, idempotencyKey: context.operationID, readBackVerified: true)
    }

    func retrieveOriginal(
        capability: String,
        context: TokenSaverRecoveryRequestContext
    ) throws -> Data? {
        lock.withLock { originals[capability] }
    }

    func markDelivered(
        capability: String,
        idempotencyKey: String,
        context: TokenSaverRecoveryRequestContext,
        outcome: TokenSaverScopedDeliveryOutcome
    ) throws -> Bool {
        lock.withLock {
            guard originals[capability] != nil else { return false }
            states[context.invocationID] = .init(state: .delivered, transportOutcome: outcome)
            return true
        }
    }

    func ack(
        capability: String,
        idempotencyKey: String,
        context: TokenSaverRecoveryRequestContext
    ) throws -> Bool {
        lock.withLock {
            guard originals[capability] != nil else { return false }
            states[context.invocationID] = .init(state: .acked, transportOutcome: .acked)
            return true
        }
    }
}

func testRecoveryContext(invocationID: String = UUID().uuidString) -> TokenSaverRecoveryRequestContext {
    TokenSaverRecoveryRequestContext(
        workspaceID: "test-workspace",
        projectID: "test-project",
        threadID: "test-thread",
        provider: "codex",
        attemptID: "test-attempt",
        operationID: "test-operation-\(invocationID)",
        invocationID: invocationID
    )
}
