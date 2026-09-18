import XCTest
@testable import DistillCore
import CoreModel

final class LibrarianCatalogTests: XCTestCase {
    func test_catalogHas188UniqueIDs() {
        XCTAssertEqual(LibrarianCatalog.all.count, 195)
        XCTAssertEqual(Set(LibrarianCatalog.ids).count, 195)
        XCTAssertEqual(LibrarianCatalog.forbiddenIDs.count, 19)
    }

    func test_exposedCatalogHasOnlyEnabledNonForbiddenFunctionsInStableOrder() {
        // WHY: rc_ask no longer pays to advertise every id in tools/list. The
        // on-demand catalog must still make every callable operation reachable,
        // while forbidden and runtime-disabled operations remain undiscoverable.
        XCTAssertEqual(LibrarianCatalog.implementedIDs.count, 175)
        XCTAssertEqual(Set(LibrarianCatalog.implementedIDs).count, 175)
        XCTAssertEqual(
            LibrarianCatalog.implementedIDs,
            LibrarianCatalog.all.filter {
                $0.safety != .forbidden && !LibrarianCatalog.disabledOnNineB.contains($0.id)
            }.map(\.id)
        )
        XCTAssertTrue(Set(LibrarianCatalog.implementedIDs).isDisjoint(with: LibrarianCatalog.forbiddenIDs))
        XCTAssertTrue(Set(LibrarianCatalog.implementedIDs).isDisjoint(with: LibrarianCatalog.disabledOnNineB))
    }

    func test_catalogPageSupportsExactAndSummarySearchWithOpaqueBoundCursor() throws {
        let exact = try LibrarianCatalog.page(query: "test_verdict", cursor: nil, limit: 20)
        XCTAssertEqual(exact.items.first?.id, "test_verdict")

        let summary = try LibrarianCatalog.page(query: "Ledger stats", cursor: nil, limit: 20)
        XCTAssertTrue(summary.items.contains { $0.id == "stats" })

        let first = try LibrarianCatalog.page(query: nil, cursor: nil, limit: 7)
        let cursor = try XCTUnwrap(first.nextCursor)
        XCTAssertNil(Int(cursor), "cursor is an opaque continuation, not a public offset")
        XCTAssertThrowsError(try LibrarianCatalog.page(query: "different", cursor: cursor, limit: 7))
        XCTAssertThrowsError(try LibrarianCatalog.page(query: nil, cursor: "not-a-cursor", limit: 7))
    }

    func test_persistCallback_emitsLibrarianModeRow() async {
        var persisted: [DistillSavingsRecord] = []
        let dispatcher = LibrarianDispatcher(persist: { persisted.append($0) })
        let original = String(repeating: "ERROR payment failed\n", count: 40)
        let handle = dispatcher.store.put(original)
        _ = await dispatcher.dispatch(LibrarianRequest(
            id: "log_crusher",
            input: original,
            handle: handle,
            provider: "grok"
        ))
        XCTAssertEqual(persisted.count, 1)
        XCTAssertTrue(persisted[0].mode.contains("librarian.log_crusher"))
        XCTAssertGreaterThan(persisted[0].savedTokens, 0)
        XCTAssertTrue(persisted[0].delivered)
    }

    func test_retrieve_roundTrip_recordsMeasuredSavingsOnlyWhenReplaced() async {
        let dispatcher = LibrarianDispatcher()
        let original = String(repeating: "ERROR payment failed\n", count: 40)
        let handle = dispatcher.store.put(original)
        let retrieved = await dispatcher.dispatch(LibrarianRequest(id: "retrieve", handle: handle, provider: "grok"))
        XCTAssertEqual(retrieved.status, .ok)
        XCTAssertEqual(retrieved.text, original)
        XCTAssertEqual(retrieved.analytics.savedTokens, 0, "byte-exact retrieve does not invent savings")

        let crushed = await dispatcher.dispatch(LibrarianRequest(
            id: "log_crusher",
            input: original,
            handle: handle,
            provider: "grok"
        ))
        XCTAssertEqual(crushed.status, .ok)
        XCTAssertTrue(crushed.analytics.mode.contains("librarian.log_crusher"))
        XCTAssertGreaterThan(crushed.analytics.savedTokens, 0)
        XCTAssertTrue(crushed.analytics.delivered)
        let expected = max(
            TokenEstimator.estimate(original) - TokenEstimator.estimate(crushed.text),
            0
        )
        XCTAssertEqual(crushed.analytics.savedTokens, expected)
        XCTAssertNotNil(crushed.analytics.record)
    }

    func test_tokenSaverOff_skipsAndSavesZero() async {
        let dispatcher = LibrarianDispatcher()
        var request = LibrarianRequest(id: "json_crusher", input: #"{"a":1}"#, provider: "codex")
        request.admitted = false
        let result = await dispatcher.dispatch(request)
        XCTAssertEqual(result.status, LibrarianStatus.refused)
        XCTAssertEqual(result.analytics.savedTokens, 0)
        XCTAssertFalse(result.analytics.delivered)
    }

    func test_forbidden_refusesAndNeverSaves() async {
        let dispatcher = LibrarianDispatcher()
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "apply_patch",
            input: "diff --git a/x b/x\n",
            provider: "claude"
        ))
        XCTAssertEqual(result.status, LibrarianStatus.refused)
        XCTAssertEqual(result.analytics.savedTokens, 0)
        XCTAssertEqual(result.envelope?.status, .refused)
    }

    func test_exactOutputRgIsNotDistilled() async {
        let dispatcher = LibrarianDispatcher()
        var request = LibrarianRequest(
            id: "distill_command_output",
            input: "match.swift:1:foo\nmatch.swift:2:bar\n",
            provider: "grok"
        )
        request.command = "rg foo"
        let result = await dispatcher.dispatch(request)
        XCTAssertEqual(result.status, LibrarianStatus.refused)
        XCTAssertEqual(result.analytics.savedTokens, 0)
    }

    func test_thinkStrip_dropsThinkAndReasoning() {
        let stripped = LibrarianThinkStrip.strip("<think>secret</think>{\"answer\":\"ok\",\"reasoning_content\":\"nope\"}")
        XCTAssertEqual(stripped, "{\"answer\":\"ok\"}")
        XCTAssertNil(LibrarianThinkStrip.paidFacingText("<think>unterminated"))
        XCTAssertEqual(LibrarianThinkStrip.strip("keep trailing\n"), "keep trailing\n")
    }

    func test_retrieveRangeAndHandleGrep() async {
        let dispatcher = LibrarianDispatcher()
        let blob = "one\nERROR two\nthree\n"
        let handle = dispatcher.store.put(blob)
        var rangeReq = LibrarianRequest(id: "retrieve_range", handle: handle, provider: "grok")
        rangeReq.startLine = 2
        rangeReq.endLine = 2
        let range = await dispatcher.dispatch(rangeReq)
        XCTAssertEqual(range.status, LibrarianStatus.ok)
        XCTAssertEqual(range.text, "ERROR two")

        var grepReq = LibrarianRequest(id: "handle_grep", handle: handle, provider: "grok")
        grepReq.pattern = "ERROR"
        let grep = await dispatcher.dispatch(grepReq)
        XCTAssertEqual(grep.status, LibrarianStatus.ok)
        XCTAssertTrue(grep.text.contains("2:ERROR two"))
    }

    func test_askHandle_liveOMLX() async throws {
        guard let runtime = LibrarianOpenAICompatibleRuntime(
            environment: ProcessInfo.processInfo.environment.merging([
                "RC_LIBRARIAN_GENERATE_BASE_URL": ProcessInfo.processInfo.environment["RC_LIBRARIAN_GENERATE_BASE_URL"] ?? "",
                "RC_LIBRARIAN_GENERATE_MODEL": ProcessInfo.processInfo.environment["RC_LIBRARIAN_GENERATE_MODEL"] ?? "Ornith-1.5-9B-MLX-4bit",
            ], uniquingKeysWith: { _, new in new })
        ) else {
            throw XCTSkip("RC_LIBRARIAN_GENERATE_BASE_URL not set")
        }
        let dispatcher = LibrarianDispatcher(generate: runtime)
        let original = "ERROR payment failed at Sources/Billing.swift:12\nretry ignored\n"
        let handle = dispatcher.store.put(original)
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "ask_handle",
            question: "what failed?",
            handle: handle,
            provider: "grok"
        ))
        XCTAssertTrue([LibrarianStatus.ok, LibrarianStatus.lowConfidence, LibrarianStatus.unavailable].contains(result.status))
        XCTAssertFalse(result.text.contains("<think>"))
        XCTAssertFalse(result.text.contains("reasoning_content"))
        if result.status == .ok {
            let span = result.envelope?.evidence.first?.span ?? ""
            if !span.isEmpty {
                XCTAssertTrue(original.contains(span))
            }
        }
        if let out = ProcessInfo.processInfo.environment["LIBRARIAN_OMLX_OUT"], !out.isEmpty {
            let payload: [String: Any] = [
                "status": result.status.rawValue,
                "text": result.text,
                "envelope": result.envelope?.jsonString() ?? "",
                "saved_tokens": result.analytics.savedTokens,
                "model": "Ornith-1.5-9B-MLX-4bit",
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: out), options: .atomic)
        }
    }

    func test_askHandle_withoutGenerateRuntimeIsUnavailable() async {
        let dispatcher = LibrarianDispatcher()
        let original = "ERROR payment failed at Sources/Billing.swift:12\n"
        let handle = dispatcher.store.put(original)
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "ask_handle",
            question: "what failed?",
            handle: handle,
            provider: "grok"
        ))
        XCTAssertEqual(result.status, LibrarianStatus.unavailable)
        XCTAssertEqual(result.analytics.savedTokens, 0)
        XCTAssertFalse(result.analytics.delivered)
    }

    func test_askHandle_stripsThinkAndReasoningContent() async {
        let dispatcher = LibrarianDispatcher(generate: LibrarianThinkWrappedGenerate())
        let original = "ERROR payment failed at Sources/Billing.swift:12\nretry ignored\n"
        let handle = dispatcher.store.put(original)
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "ask_handle",
            question: "what failed?",
            handle: handle,
            provider: "grok"
        ))
        XCTAssertEqual(result.status, .ok)
        XCTAssertFalse(result.text.contains("<think>"), "paid-facing text leaked think block")
        XCTAssertFalse(result.text.contains("reasoning_content"))
        XCTAssertFalse(result.text.contains("secret chain"))
        let envelope = result.envelope?.jsonString() ?? ""
        XCTAssertFalse(envelope.contains("<think>"))
        XCTAssertFalse(envelope.contains("reasoning_content"))
        XCTAssertGreaterThanOrEqual(result.analytics.savedTokens, 0)
        XCTAssertNotNil(result.analytics.record)
        XCTAssertNotNil(result.envelope)
        let span = result.envelope?.evidence.first?.span ?? ""
        XCTAssertFalse(span.isEmpty)
        XCTAssertTrue(original.contains(span))
    }

    func test_jsonShape_arrayAnswerStillClosesEnvelope() async {
        struct ArrayAnswerGenerate: LibrarianGenerating {
            func generate(_ call: LibrarianGenerateCall) async -> String? {
                #"{"answer":["title","labels","items"],"span":"title"}"#
            }
        }
        let dispatcher = LibrarianDispatcher(generate: ArrayAnswerGenerate())
        let original = #"{"title":"Fix billing","labels":["bug"],"items":[{"id":1}]}"#
        let handle = dispatcher.store.put(original)
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "json_shape",
            question: "List the top-level JSON keys.",
            handle: handle,
            provider: "grok"
        ))
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("title"))
        let span = result.envelope?.evidence.first?.span ?? ""
        XCTAssertTrue(original.contains(span), "span must be a substring")
        XCTAssertFalse(result.text.contains("<think>"))
    }

    func test_disabledNineBOps_doNotCallGenerate() async {
        let instrumented = LibrarianInstrumentedGenerate(LibrarianScriptedGenerate())
        let dispatcher = LibrarianDispatcher(generate: instrumented)
        XCTAssertEqual(LibrarianCatalog.disabledOnNineB, ["i18n_translation_draft"])
        for id in LibrarianCatalog.disabledOnNineB {
            let handle = dispatcher.store.put("source")
            let result = await dispatcher.dispatch(LibrarianRequest(id: id, handle: handle, provider: "grok"))
            XCTAssertEqual(result.status, .unavailable, id)
            XCTAssertTrue(result.envelope?.jsonString().contains("disabled_on_ornith_9b") == true, id)
        }
        XCTAssertEqual(instrumented.callCount, 0)
    }

    func test_cotPreambleThenJSON_closesEnvelope() async {
        struct MixedGenerate: LibrarianGenerating {
            func generate(_ call: LibrarianGenerateCall) async -> String? {
                """
                The user wants me to extract unresolved review threads from the source.
                Let me analyze.
                {"answer":"Please add a nil check","span":"Please add a nil check"}
                """
            }
        }
        let dispatcher = LibrarianDispatcher(generate: MixedGenerate())
        let original = #"{"reviews":[{"state":"CHANGES_REQUESTED","body":"Please add a nil check","path":"Sources/Billing.swift","line":12}]}"#
        let handle = dispatcher.store.put(original)
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "pr_thread_digest",
            question: "Extract unresolved review threads.",
            handle: handle,
            provider: "grok"
        ))
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Please add a nil check"))
        XCTAssertFalse(result.text.contains("The user wants"))
        let span = result.envelope?.evidence.first?.span ?? ""
        XCTAssertTrue(original.contains(span))
    }

    func test_chainOfThoughtContent_isUnavailable() async {
        struct CoTGenerate: LibrarianGenerating {
            func generate(_ call: LibrarianGenerateCall) async -> String? {
                "The user wants me to extract unresolved review threads from the source.\nPlease add a nil check"
            }
        }
        let dispatcher = LibrarianDispatcher(generate: CoTGenerate())
        let original = #"{"reviews":[{"body":"Please add a nil check"}]}"#
        let handle = dispatcher.store.put(original)
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "entity_list",
            question: "extract",
            handle: handle,
            provider: "grok"
        ))
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.text, original)
        XCTAssertEqual(result.analytics.savedTokens, 0)
    }

    func test_forbidden_doesNotCallGenerate() async {
        let instrumented = LibrarianInstrumentedGenerate(LibrarianThinkWrappedGenerate())
        let dispatcher = LibrarianDispatcher(generate: instrumented)
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "apply_patch",
            input: "diff --git a/x b/x\n",
            provider: "claude"
        ))
        XCTAssertEqual(result.status, LibrarianStatus.refused)
        XCTAssertEqual(instrumented.callCount, 0, "forbidden IDs must not call generate")
        XCTAssertEqual(result.analytics.savedTokens, 0)
    }

    func test_askHandle_envelopeSpanIsSubstring() async {
        let dispatcher = LibrarianDispatcher(generate: LibrarianScriptedGenerate())
        let original = "ERROR payment failed at Sources/Billing.swift:12\nretry ignored\n"
        let handle = dispatcher.store.put(original)
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "ask_handle",
            question: "what failed?",
            handle: handle,
            provider: "grok"
        ))
        XCTAssertEqual(result.status, .ok)
        let span = result.envelope?.evidence.first?.span ?? ""
        XCTAssertFalse(span.isEmpty)
        XCTAssertTrue(original.contains(span), "obligatory span must be a substring of the original")
        XCTAssertFalse(result.text.contains("<think>"))
        XCTAssertFalse(result.text.contains("reasoning_content"))
    }

    func test_askHandle_successEnvelopeDoesNotRepeatToolQuestion() async throws {
        let dispatcher = LibrarianDispatcher(generate: LibrarianScriptedGenerate())
        let original = "ERROR payment failed at Sources/Billing.swift:12\nretry ignored\n"
        let handle = dispatcher.store.put(original)
        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "ask_handle",
            question: "what failed?",
            handle: handle,
            provider: "grok"
        ))

        let envelope = try XCTUnwrap(result.envelope)
        XCTAssertEqual(envelope.status, .ok)
        XCTAssertEqual(envelope.op, "ask_handle")
        XCTAssertEqual(envelope.fallback.recommended, "retrieve")
        XCTAssertEqual(envelope.fallback.handle, handle)
        XCTAssertNil(
            envelope.fallback.question,
            "the tool input already carries the question; repeating it in the paid tool result wastes context"
        )
        XCTAssertTrue(original.contains(try XCTUnwrap(envelope.evidence.first?.span)))

        let encoded = envelope.jsonString()
        let decoded = try JSONDecoder().decode(LibrarianEnvelope.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded, envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        let fallback = try XCTUnwrap(object["fallback"] as? [String: Any])
        XCTAssertNil(fallback["question"], "the optional duplicate must be absent from the shipping JSON")
    }

    func test_librarianEnvelopeShippingJSONDoesNotEscapeSlashes() throws {
        let envelope = LibrarianEnvelope(
            status: .ok,
            confidence: 1,
            op: "ask_handle",
            answer: .object(["text": .string("Sources/App.swift")]),
            evidence: [LibrarianEvidence(handle: "rcv1.test", span: "Sources/App.swift")],
            fallback: LibrarianFallback(recommended: "retrieve", handle: "rcv1.test")
        )

        let encoded = envelope.jsonString()

        XCTAssertTrue(encoded.contains(#""text":"Sources/App.swift""#))
        XCTAssertTrue(encoded.contains(#""span":"Sources/App.swift""#))
        XCTAssertFalse(encoded.contains(#"\/"#))
        XCTAssertEqual(
            try JSONDecoder().decode(LibrarianEnvelope.self, from: Data(encoded.utf8)),
            envelope
        )
    }

    func test_notebookCrusher_stripsOutputs() async {
        let dispatcher = LibrarianDispatcher()
        let notebook = #"{"cells":[{"cell_type":"code","source":["print(1)"],"outputs":[{"data":{"image/png":"aaaa"}}],"execution_count":3}]}"#
        let result = await dispatcher.dispatch(LibrarianRequest(id: "notebook_crusher", input: notebook, provider: "claude"))
        XCTAssertEqual(result.status, .ok)
        XCTAssertFalse(result.text.contains("image/png"))
        XCTAssertTrue(result.analytics.mode.contains("librarian.notebook_crusher"))
    }

    func test_probeAllCatalogIDs() async throws {
        let dispatcher = LibrarianDispatcher(generate: LibrarianScriptedGenerate())
        let rows = await LibrarianProbe.runAll(dispatcher: dispatcher)
        XCTAssertEqual(rows.count, 195)
        XCTAssertEqual(Set(rows.map(\.id)).count, 195)
        let forbidden = rows.filter { $0.safety == "forbidden" }
        XCTAssertEqual(forbidden.count, 19)
        XCTAssertTrue(forbidden.allSatisfy { $0.status == "refused" || $0.status == "unavailable" })
        XCTAssertTrue(forbidden.allSatisfy { $0.mark == "bloqueado" })
        let disabled = rows.filter { $0.mark == "desabilitado" }
        XCTAssertEqual(Set(disabled.map(\.id)), LibrarianCatalog.disabledOnNineB)
        XCTAssertTrue(disabled.allSatisfy { $0.status == "unavailable" && !$0.generateCalled })
        let pendingGenerate = rows.filter { $0.mark == "pendente" && LibrarianCatalog.function(id: $0.id)?.usesLLM == true }
        XCTAssertTrue(pendingGenerate.isEmpty, "generate IDs not proven via generate path: \(pendingGenerate.map(\.id))")
        let fakeSavings = rows.filter {
            $0.delivered && $0.savedTokens > 0 && [
                "graphify_query", "path_wrappers", "doc_text_extract",
                "stale_tool_result_evict", "stale_tool_args_evict"
            ].contains($0.id)
        }
        XCTAssertTrue(fakeSavings.isEmpty, "host-tool stubs must not record savings: \(fakeSavings.map(\.id))")
        if let out = ProcessInfo.processInfo.environment["LIBRARIAN_PROBE_OUT"], !out.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rows)
            try data.write(to: URL(fileURLWithPath: out), options: .atomic)
        }
    }

    func test_retrieveDownDisablesLossy() async {
        let dispatcher = LibrarianDispatcher()
        var request = LibrarianRequest(
            id: "log_crusher",
            input: String(repeating: "x\n", count: 20),
            provider: "grok"
        )
        request.retrieveAvailable = false
        let result = await dispatcher.dispatch(request)
        XCTAssertEqual(result.status, LibrarianStatus.unavailable)
        XCTAssertEqual(result.analytics.savedTokens, 0)
    }

    // WHY: a duplicate notice replaces paid-facing bytes, so it is safe only when
    // the host has already recovered the same scoped capability byte-for-byte.
    func test_duplicateHandleNotice_compactsOnlyVerifiedExactRecoverableHandle() async {
        let dispatcher = LibrarianDispatcher()
        let original = String(repeating: "build step completed with identical output\n", count: 40)
        let handle = "scope-owned-capability"
        _ = dispatcher.store.put(original, handle: handle)
        let request = LibrarianRequest(
            id: "duplicate_handle_notice",
            input: original,
            handle: handle,
            provider: "codex",
            retrieveAvailable: true,
            verifiedRecoveryHandle: handle
        )

        let result = await dispatcher.dispatch(request)

        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.text, "duplicate [[rc:\(handle)]]")
        XCTAssertLessThan(result.text.utf8.count, original.utf8.count)
        XCTAssertGreaterThan(result.analytics.savedTokens, 0)

        let retrieved = await dispatcher.dispatch(LibrarianRequest(
            id: "retrieve",
            handle: handle,
            provider: "codex"
        ))
        XCTAssertEqual(retrieved.status, .ok)
        XCTAssertEqual(retrieved.text, original)
    }

    // WHY: resolve used to insert raw input before duplicate lookup, making every
    // first-seen blob a false self-duplicate. Raw input must remain byte-identical.
    func test_duplicateHandleNotice_rawInputDoesNotSelfDuplicate() async {
        let dispatcher = LibrarianDispatcher()
        let original = String(repeating: "first seen output\n", count: 20)

        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "duplicate_handle_notice",
            input: original,
            provider: "claude"
        ))

        XCTAssertEqual(result.text, original)
        XCTAssertEqual(result.analytics.savedTokens, 0)
    }

    // WHY: caller-provided handles, mismatched stores, unavailable recovery, and
    // notices that are not actually smaller must all fail open without savings.
    func test_duplicateHandleNotice_untrustedMismatchUnavailableAndShortFailOpen() async {
        let original = String(repeating: "trusted original payload\n", count: 20)

        let fabricated = LibrarianDispatcher()
        let fabricatedResult = await fabricated.dispatch(LibrarianRequest(
            id: "duplicate_handle_notice",
            input: original,
            handle: "fabricated",
            provider: "grok",
            retrieveAvailable: true,
            verifiedRecoveryHandle: "fabricated"
        ))
        XCTAssertEqual(fabricatedResult.text, original)
        XCTAssertEqual(fabricatedResult.analytics.savedTokens, 0)

        let mismatched = LibrarianDispatcher()
        _ = mismatched.store.put("different bytes", handle: "mismatch")
        let mismatchResult = await mismatched.dispatch(LibrarianRequest(
            id: "duplicate_handle_notice",
            input: original,
            handle: "mismatch",
            provider: "grok",
            retrieveAvailable: true,
            verifiedRecoveryHandle: "mismatch"
        ))
        XCTAssertEqual(mismatchResult.text, original)
        XCTAssertEqual(mismatchResult.analytics.savedTokens, 0)

        let unavailable = LibrarianDispatcher()
        _ = unavailable.store.put(original, handle: "unavailable")
        let unavailableResult = await unavailable.dispatch(LibrarianRequest(
            id: "duplicate_handle_notice",
            input: original,
            handle: "unavailable",
            provider: "grok",
            retrieveAvailable: false,
            verifiedRecoveryHandle: "unavailable"
        ))
        XCTAssertEqual(unavailableResult.text, original)
        XCTAssertEqual(unavailableResult.analytics.savedTokens, 0)

        let short = LibrarianDispatcher()
        _ = short.store.put("tiny", handle: "short-capability")
        let shortResult = await short.dispatch(LibrarianRequest(
            id: "duplicate_handle_notice",
            input: "tiny",
            handle: "short-capability",
            provider: "grok",
            retrieveAvailable: true,
            verifiedRecoveryHandle: "short-capability"
        ))
        XCTAssertEqual(shortResult.text, "tiny")
        XCTAssertEqual(shortResult.analytics.savedTokens, 0)
    }

    // WHY: an unknown op must stop at catalog admission and never reach the local
    // model, even when a generate runtime is installed.
    func test_unknownLibrarianOperationNeverCallsGenerate() async {
        let generate = LibrarianInstrumentedGenerate(LibrarianScriptedGenerate())
        let dispatcher = LibrarianDispatcher(generate: generate)

        let result = await dispatcher.dispatch(LibrarianRequest(
            id: "not-a-real-operation",
            input: "do not send this to the model",
            provider: "codex"
        ))

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(generate.callCount, 0)
        XCTAssertEqual(result.analytics.savedTokens, 0)
    }
}
