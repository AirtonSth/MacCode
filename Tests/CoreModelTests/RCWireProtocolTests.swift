import XCTest
@testable import CoreModel

final class RCWireProtocolTests: XCTestCase {
    func test_requestRoundTripPreservesEscapedPayloadAndExactRecords() throws {
        let frame = RCWireFrame(
            direction: .request,
            sequence: 1,
            records: [
                .init(kind: .goal, value: "Fix the parser without changing output."),
                .init(kind: .constraint, value: "Keep path\t/Users/sam/App.swift and line one\nline two exact."),
                .init(kind: .exact, value: "git show abc123")
            ]
        )

        let encoded = try RCWireProtocol.serialize(frame)
        let decoded = try XCTUnwrap(RCWireProtocol.parse(encoded).first)

        XCTAssertEqual(decoded, frame,
                       "the wire transport must round-trip user meaning and byte-exact spans")
        XCTAssertTrue(encoded.hasPrefix("RCW1\tQ\t1\n"),
                      "byte zero must identify the protocol before any provider text can leak")
    }

    func test_longMultilingualRequestUsesSequentialFramesWithoutTruncation() throws {
        let original = String(
            repeating: "日本語の指示を保持 \\server\\path\n",
            count: 2_000
        )

        let encoded = try RCWireProtocol.serializeRequestText(original)
        let withRecovery = try RCWireProtocol.addingExactRecord("[[rc:long-prompt]]", to: encoded)
        let frames = try RCWireProtocol.parse(withRecovery)
        let recovered = frames
            .flatMap(\.records)
            .filter { $0.kind == .goal }
            .map(\.value)
            .joined()

        XCTAssertGreaterThan(frames.count, 1,
                             "the 8 KiB limit applies per frame, never to the whole user prompt")
        XCTAssertEqual(frames.map(\.sequence), Array(1...frames.count))
        XCTAssertEqual(Data(recovered.utf8), Data(original.utf8),
                       "multiframe RCW1 must preserve every original UTF-8 byte")
        XCTAssertEqual(frames.last?.records.last, .init(kind: .exact, value: "[[rc:long-prompt]]"))
    }

    func test_recoveryHandleIsAttachedAsAValidExactRecord() throws {
        let request = try RCWireProtocol.serialize(.init(
            direction: .request,
            sequence: 1,
            records: [.init(kind: .goal, value: "Inspect the failure.")]
        ))
        let recoverable = try RCWireProtocol.addingExactRecord("[[rc:abc123]]", to: request)
        let frame = try XCTUnwrap(RCWireProtocol.parse(recoverable).first)
        XCTAssertEqual(frame.records.last, .init(kind: .exact, value: "[[rc:abc123]]"),
                       "lossy wire must expose recovery without appending bytes outside the transport grammar")
    }

    func test_transportEnvelopeFindsProviderPreambleWithoutWeakeningStrictParser() throws {
        let wire = try RCWireProtocol.serialize(.init(
            direction: .response,
            sequence: 1,
            records: [.init(kind: .outcome, value: "The failure is diagnosed.")]
        ))
        let raw = "Response in the requested frame:\n\n" + wire
        let envelope = try XCTUnwrap(RCWireProtocol.transportEnvelope(in: raw))

        XCTAssertEqual(envelope.prefix, "Response in the requested frame:")
        XCTAssertEqual(envelope.payload, wire.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertThrowsError(try RCWireProtocol.parse(raw),
                             "the envelope detector prevents leakage but must not make the grammar permissive")
        XCTAssertEqual(try RCWireProtocol.parse(envelope.payload).first?.direction, .response)
    }

    func test_hostOwnedRequestRecordsAreFramedBySwiftWithoutChangingTheGoal() throws {
        let request = try RCWireProtocol.serialize(.init(
            direction: .request,
            sequence: 1,
            records: [.init(kind: .goal, value: "Fix the reliability issue.")]
        ))
        let composed = try RCWireProtocol.addingRequestRecords([
            .init(kind: .constraint, value: "Run $remote-code-orchestrate for active_host=codex.")
        ], to: request)
        let frame = try XCTUnwrap(RCWireProtocol.parse(composed).first)

        XCTAssertEqual(frame.records.first?.value, "Fix the reliability issue.",
                       "host composition must not rewrite the local model's semantic result")
        XCTAssertEqual(frame.records.last, .init(
            kind: .constraint,
            value: "Run $remote-code-orchestrate for active_host=codex."
        ), "host routing data must remain an exact typed record")
        XCTAssertTrue(composed.hasPrefix("RCW1\tQ\t1\n"),
                      "Auto composition must preserve byte-zero wire discrimination")
    }

    func test_responseRendererIsReadableWithoutLocalLLM() throws {
        let wire = """
        RCW1\tA\t1
        O\tBuild completed successfully.
        E\t143 tests passed.
        R\tDeployment was not performed.
        .
        """

        let frames = try RCWireProtocol.parse(wire)
        XCTAssertEqual(
            RCWireProtocol.renderEnglish(frames),
            "Build completed successfully.\n\nEvidence: 143 tests passed.\n\nRisk: Deployment was not performed.",
            "decoder failure must still leave a complete deterministic English answer"
        )
    }

    func test_parserRejectsUnknownVersionUnknownTagAndTruncation() {
        XCTAssertThrowsError(try RCWireProtocol.parse("RCW2\tA\t1\nO\tdone\n.\n"))
        XCTAssertThrowsError(try RCWireProtocol.parse("RCW1\tA\t1\nZ\tdone\n.\n"))
        XCTAssertThrowsError(try RCWireProtocol.parse("RCW1\tA\t1\nO\tdone"))
    }

    func test_parserToleratesProviderJSONEscapedQuotesWithoutAcceptingUnknownEscapes() throws {
        let grokStyle = "RCW1\tA\t1\nE\tAdd sample.status == \\\"ready\\\".\n.\n"
        let frame = try XCTUnwrap(RCWireProtocol.parse(grokStyle).first)

        XCTAssertEqual(frame.records.first?.value, "Add sample.status == \"ready\".",
                       "a provider's harmless JSON-style quote escape must not make an otherwise valid frame unreadable")
        XCTAssertThrowsError(try RCWireProtocol.parse("RCW1\tA\t1\nE\tunknown \\q escape\n.\n"),
                             "unknown escapes remain malformed instead of silently changing bytes")
    }

    func test_parserPreservesUntaggedProviderResponseFooterAsExactText() throws {
        let claudeStyle = """
        RCW1\tA\t1
        O\tConclusion unchanged.
        Certification id CLAUDE-RCW1-FOLLOWUP-1 acknowledged; no files modified.
        .
        """
        let frames = try RCWireProtocol.parse(claudeStyle)

        XCTAssertEqual(frames.first?.records.last, .init(
            kind: .exact,
            value: "Certification id CLAUDE-RCW1-FOLLOWUP-1 acknowledged; no files modified."
        ), "a provider footer must remain readable and byte-identical instead of blanking a valid answer")
        XCTAssertTrue(RCWireProtocol.renderEnglish(frames).contains("CLAUDE-RCW1-FOLLOWUP-1"))
        XCTAssertThrowsError(try RCWireProtocol.parse("RCW1\tA\t1\nZ\tunknown field\n.\n"),
                             "unknown tagged fields remain malformed")
        XCTAssertThrowsError(try RCWireProtocol.parse("RCW1\tQ\t1\nuntagged request\n.\n"),
                             "request encoding remains strict because RemoteCode owns it")
    }

    func test_parserAcceptsProgressiveResponseFramesInSequence() throws {
        let wire = """
        RCW1\tA\t1
        A\tInspecting the failing test.
        .
        RCW1\tA\t2
        O\tThe race was fixed.
        E\tFocused suite passed.
        .
        """

        let frames = try RCWireProtocol.parse(wire)
        XCTAssertEqual(frames.map(\.sequence), [1, 2])
        XCTAssertEqual(
            RCWireProtocol.renderEnglish(frames),
            "Action: Inspecting the failing test.\n\nThe race was fixed.\n\nEvidence: Focused suite passed."
        )
    }

    func test_nonResponseFrameCannotBeRenderedAsAssistantAnswer() throws {
        let request = RCWireFrame(direction: .request, sequence: 1, records: [
            .init(kind: .goal, value: "Delete nothing")
        ])

        XCTAssertEqual(RCWireProtocol.renderEnglish([request]), "")
    }

    func test_prefixDetectionWaitsForSplitSentinelAndReleasesPlainEnglish() {
        XCTAssertEqual(RCWireProtocol.prefixDisposition("R"), .undecided)
        XCTAssertEqual(RCWireProtocol.prefixDisposition("RCW"), .undecided)
        XCTAssertEqual(RCWireProtocol.prefixDisposition("RCW1\t"), .wire)
        XCTAssertEqual(RCWireProtocol.prefixDisposition("RCW2\tA\t1"), .wire)
        XCTAssertEqual(RCWireProtocol.prefixDisposition("Regular answer"), .plainText)
    }

    func test_semanticSafetyGatePinsNegationNumbersUnitsQuotesAndCode() throws {
        let original = "Do not delete 3 files. Keep 2.5 GB and run `git status`.\n```sh\nmake test\n```"
        let safe = try RCWireProtocol.serialize(.init(direction: .request, sequence: 1, records: [
            .init(kind: .goal, value: "Do not delete 3 files"),
            .init(kind: .constraint, value: "Keep 2.5 GB"),
            .init(kind: .exact, value: "`git status`\n```sh\nmake test\n```")
        ]))
        XCTAssertTrue(RCWireProtocol.preservesProtectedSemantics(original: original, wire: safe))
        XCTAssertFalse(
            RCWireProtocol.preservesProtectedSemantics(
                original: original,
                wire: safe.replacingOccurrences(of: "Do not", with: "Do")
            ),
            "dropping negation can reverse intent even when paths and IDs survive"
        )
        XCTAssertFalse(
            RCWireProtocol.preservesProtectedSemantics(
                original: original,
                wire: safe.replacingOccurrences(of: "2.5 GB", with: "2 GB")
            ),
            "small numbers and units are load-bearing too"
        )
    }

    func test_renderSafetyRejectsDroppedNegationNumberAndCommand() throws {
        let frame = RCWireFrame(direction: .response, sequence: 1, records: [
            .init(kind: .outcome, value: "Do not run `rm -rf /tmp/cache`; keep 42 MB free.")
        ])
        XCTAssertTrue(RCWireProtocol.renderedTextPreservesProtectedSemantics(
            "Do not run `rm -rf /tmp/cache`; keep 42 MB free.", frames: [frame]
        ))
        XCTAssertFalse(RCWireProtocol.renderedTextPreservesProtectedSemantics(
            "Run the cleanup and keep space free.", frames: [frame]
        ), "local polishing must never reverse negation or drop exact commands/numbers")
    }

    func test_renderSafetyRejectsNegationOnlyInversion() {
        let frame = RCWireFrame(direction: .response, sequence: 1, records: [
            .init(kind: .outcome, value: "The tests did not pass.")
        ])

        XCTAssertFalse(
            RCWireProtocol.renderedTextPreservesProtectedSemantics(
                "The tests passed.",
                frames: [frame]
            ),
            "local Human rendering must not erase the only negation in a response"
        )
    }

    func test_securityAndApprovalFramesRequireDeterministicRendering() {
        XCTAssertTrue(RCWireProtocol.requiresDeterministicRendering([
            .init(direction: .response, sequence: 1, records: [
                .init(kind: .question, value: "Approve `sudo rm -rf /tmp/cache`?")
            ])
        ]))
        XCTAssertFalse(RCWireProtocol.requiresDeterministicRendering([
            .init(direction: .response, sequence: 1, records: [
                .init(kind: .outcome, value: "Focused tests passed.")
            ])
        ]))
    }

    /// WHY: request-side `C Human repeated G...` is reconstructive, but RCW1 v1
    /// never assigned response-side semantics to C. Silently accepting the same
    /// spelling for A frames would invent an unversioned codec that existing
    /// consumers cannot reconstruct losslessly.
    func test_responseExactRepeatContextRequiresAVersionedCodec() {
        let candidate = "RCW1\tA\t1\nO\tOK\nC\tHuman repeated O verbatim 100 times.\n.\n"

        XCTAssertThrowsError(try RCWireProtocol.parse(candidate))
    }
}
