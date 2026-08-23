import XCTest
@testable import DistillCore

final class LibrarianEvidencePackIntegrationTests: XCTestCase {
    private actor CapturingGenerate: LibrarianGenerating {
        let reply: String
        private var captured: LibrarianGenerateCall?

        init(reply: String) {
            self.reply = reply
        }

        func generate(_ call: LibrarianGenerateCall) async -> String? {
            captured = call
            return reply
        }

        func lastCall() -> LibrarianGenerateCall? {
            captured
        }
    }

    func test_verifiedRecoveryFeedsRankedTailEvidenceToLocalGenerate() async throws {
        var lines = (0..<520).map { "routine-output-\($0)-nothing-actionable" }
        lines[410] = "TAIL_EVIDENCE_410 requires immediate retry"
        let original = lines.joined(separator: "\n")
        let generate = CapturingGenerate(
            reply: #"{"answer":"TAIL_EVIDENCE_410","span":"TAIL_EVIDENCE_410"}"#
        )
        let dispatcher = LibrarianDispatcher(generate: generate)
        let handle = dispatcher.store.put(original)

        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "entity_list",
            input: original,
            question: "Find TAIL_EVIDENCE_410",
            handle: handle,
            provider: "codex",
            retrieveAvailable: true,
            verifiedRecoveryHandle: handle
        ))
        let captured = await generate.lastCall()
        let call = try XCTUnwrap(captured)

        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(call.user.contains("TAIL_EVIDENCE_410"))
        XCTAssertTrue(call.user.contains("[bytes:"), "long verified input should use the ranked evidence view")
        XCTAssertEqual(result.envelope?.evidence.first?.span, "TAIL_EVIDENCE_410")
    }

    func test_unverifiedRecoveryKeepsLegacyPrefixAndRejectsUnshownTailSpan() async throws {
        var lines = (0..<520).map { "routine-output-\($0)-nothing-actionable" }
        lines[410] = "TAIL_EVIDENCE_410 requires immediate retry"
        let original = lines.joined(separator: "\n")
        let generate = CapturingGenerate(
            reply: #"{"answer":"TAIL_EVIDENCE_410","span":"TAIL_EVIDENCE_410"}"#
        )
        let dispatcher = LibrarianDispatcher(generate: generate)
        let handle = dispatcher.store.put(original)

        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "entity_list",
            input: original,
            question: "Find the requested late evidence",
            handle: handle,
            provider: "codex",
            retrieveAvailable: true
        ))
        let captured = await generate.lastCall()
        let call = try XCTUnwrap(captured)

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.text, original)
        XCTAssertFalse(call.user.contains("TAIL_EVIDENCE_410"))
        XCTAssertFalse(call.user.contains("[bytes:"), "unverified input must keep the legacy prefix path")
        XCTAssertEqual(result.analytics.savedTokens, 0)
    }

    func test_verifiedShortInputKeepsPromptSourceByteIdentical() async throws {
        let original = "ERROR payment failed at Sources/Billing.swift:12\nretry ignored\n"
        let generate = CapturingGenerate(
            reply: #"{"answer":"payment failed","span":"payment failed"}"#
        )
        let dispatcher = LibrarianDispatcher(generate: generate)
        let handle = dispatcher.store.put(original)

        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "entity_list",
            input: original,
            question: "what failed?",
            handle: handle,
            provider: "codex",
            retrieveAvailable: true,
            verifiedRecoveryHandle: handle
        ))
        let captured = await generate.lastCall()
        let call = try XCTUnwrap(captured)

        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(call.user.contains("Source (cite exact substrings only):\n\(original)"))
        XCTAssertFalse(call.user.contains("[bytes:"))
    }
}
