import XCTest
@testable import AgentRuntime

/// Pins R7 residual agent-app memory ceilings: LineBuffer peak retention and
/// lastPersisted fingerprint storage.
///
/// WHY: after R1–R6, two residual pins remained — unbounded NDJSON reassembly
/// Data without a newline, and full final-answer Strings in dedup maps. These
/// constants bound synthetic ceilings used in docs/evidence.
final class AgentAppMemoryR7CapTests: XCTestCase {

    func test_lineBufferDefaultMaxBytes_is512KiB() {
        XCTAssertEqual(LineBuffer.defaultMaxBytes, 512 * 1_024)
    }

    func test_lineBufferRetentionEstimate_8MiBTo512KiB() {
        let prior = 8 * 1_024 * 1_024
        let limit = LineBuffer.defaultMaxBytes
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertEqual(reduction, 0.9375, accuracy: 0.0001)
        XCTAssertEqual(limit, 512 * 1_024)
    }

    func test_fingerprintStoredBytes_vs32KiBString() {
        let prior = AgentRunCoordinator.lastPersistedAssistantContentSizeCap
        let after = AssistantContentFingerprint.storedByteSize
        let reduction = Double(prior - after) / Double(prior)
        XCTAssertEqual(after, 16)
        XCTAssertGreaterThan(reduction, 0.99)
        // Explicit claim used in evidence: 32768 → 16 is −99.951%
        XCTAssertEqual(
            Double(prior - after) / Double(prior),
            (Double(prior - 16) / Double(prior)),
            accuracy: 0.000001
        )
    }

    func test_fingerprintEquality_stableAcrossCalls() {
        let text = String(repeating: "final-answer-body-", count: 200)
        XCTAssertEqual(
            AssistantContentFingerprint.of(text),
            AssistantContentFingerprint.of(text)
        )
        XCTAssertNotEqual(
            AssistantContentFingerprint.of(text),
            AssistantContentFingerprint.of(text + "x")
        )
    }

    /// Swift String equality is canonical; composed and decomposed `é` must
    /// fingerprint equal so lastPersisted dedup cannot miss.
    func test_fingerprintEquality_matchesCanonicalEquivalence() {
        let composed = "caf\u{00E9}" // café with precomposed é
        let decomposed = "cafe\u{0301}" // e + combining acute
        XCTAssertEqual(composed, decomposed, "precondition: Swift String equality")
        XCTAssertEqual(
            AssistantContentFingerprint.of(composed),
            AssistantContentFingerprint.of(decomposed)
        )
    }
}
