import XCTest
@testable import DistillCore
import CoreModel

final class LibrarianCatalogTests: XCTestCase {
    func test_catalogHas188UniqueIDs() {
        XCTAssertEqual(LibrarianCatalog.all.count, 188)
        XCTAssertEqual(Set(LibrarianCatalog.ids).count, 188)
        XCTAssertEqual(LibrarianCatalog.forbiddenIDs.count, 19)
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
        XCTAssertEqual(rows.count, 188)
        XCTAssertEqual(Set(rows.map(\.id)).count, 188)
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
}
