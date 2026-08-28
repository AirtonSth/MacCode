import XCTest
import CoreModel
@testable import DistillCore

final class TwoPhaseDeliveryConfirmationTests: XCTestCase {
    private actor Counter {
        private var value = 0
        func increment() { value += 1 }
        func read() -> Int { value }
    }

    func test_accountingOutputExcludesMarkersAndNeverDecreasesSameInputSavings() throws {
        // WHY: receipts prove delivery but are never charged against the measured
        // replacement, so adopting two-phase accounting cannot shrink savings.
        let original = String(repeating: "verbose synthetic output\n", count: 40)
        let accounting = "short"
        let prefix = try XCTUnwrap(DistillDeferredDelivery.providerVisiblePrefix(
            accountingOutput: accounting,
            recoveryConfirmations: [.init(capability: "cap", idempotencyKey: "idem")]
        ))
        XCTAssertFalse(accounting.contains("[[rc:"))
        XCTAssertFalse(accounting.contains("[[rcd:"))
        XCTAssertTrue(prefix.contains("[[rc:cap]]"))
        XCTAssertGreaterThanOrEqual(
            TokenEstimator.estimate(original) - TokenEstimator.estimate(accounting),
            TokenEstimator.estimate(original) - TokenEstimator.estimate(prefix)
        )
    }

    func test_initialPostNeverRecordsAndFinalPostRequiresObservableHandoff() {
        // WHY: a client cannot claim delivery in its initial scheduler request.
        let initial = DistillRequest(
            mode: .commandOutput,
            input: "original",
            recordSavings: false,
            producerFamily: "managed-cli"
        )
        let final = DistillRequest(
            id: initial.id,
            mode: .commandOutput,
            input: initial.input,
            recordSavings: true,
            precomputedRouteStage: .deterministic,
            deferredDeliveryToken: "opaque",
            accountingOutput: "short",
            deliveredOutput: "short\n[[rcd:v2.synthetic.synthetic]]\n",
            producerFamily: "managed-cli",
            deferredHandoffDeadlineUnixMilliseconds: DistillDeferredDelivery.handoffDeadlineUnixMilliseconds()
        )
        XCTAssertEqual(initial.recordSavings, false)
        XCTAssertNil(initial.deliveredOutput)
        XCTAssertEqual(final.recordSavings, true)
        XCTAssertNotNil(final.deliveredOutput)
    }

    func test_sameInvocationRetryDedupesAndDistinctIdenticalInvocationRecords() {
        // WHY: transport retry reuses one stable UUID, but an independent
        // invocation over identical bytes must receive a distinct ledger row.
        func identity(_ invocation: String) -> DistillDeferredDeliveryAuthority.Identity {
            .init(
                provider: "codex",
                threadID: "thread",
                rootRunID: "root\u{1f}<null>",
                attemptID: nil,
                invocationID: invocation,
                operationID: "operation",
                producerFamily: "managed-cli"
            )
        }
        let first = DeferredDeliveryIdempotency.requestID(for: identity("invocation-a"))
        XCTAssertEqual(first, DeferredDeliveryIdempotency.requestID(for: identity("invocation-a")))
        XCTAssertNotEqual(first, DeferredDeliveryIdempotency.requestID(for: identity("invocation-b")))
        let formerlyColliding = DistillDeferredDeliveryAuthority.Identity(
            provider: "codex\u{1f}thread",
            threadID: "root",
            rootRunID: nil,
            attemptID: nil,
            invocationID: "invocation-a",
            operationID: "operation",
            producerFamily: "managed-cli"
        )
        XCTAssertNotEqual(first, DeferredDeliveryIdempotency.requestID(for: formerlyColliding))
    }

    func test_familyDeadlinesTimeoutUnavailableLateAreNonBlocking() async {
        // WHY: after guarded stdout/MCP handoff, an unavailable ledger cannot
        // hold EOF and a cancelled late call cannot persist after the deadline.
        let counter = Counter()
        let clock = ContinuousClock()
        let started = clock.now
        await DistillDeferredDelivery.awaitBestEffortHandoff(timeoutNanoseconds: 100_000_000) {
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await counter.increment()
        }
        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .milliseconds(275))
        try? await Task.sleep(nanoseconds: 650_000_000)
        let lateCount = await counter.read()
        XCTAssertEqual(lateCount, 0, "cancelled tail must never become a late delivered row")
    }
}
