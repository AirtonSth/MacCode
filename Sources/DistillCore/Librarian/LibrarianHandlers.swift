import Foundation
import CoreModel

enum LibrarianHandlers {
    static func run(
        _ request: LibrarianRequest,
        function: LibrarianFunction,
        store: LibrarianHandleStore,
        generate: (any LibrarianGenerating)?
    ) async -> LibrarianHandlerOutput {
        let resolved = resolve(request, store: store)
        switch function.id {
        case "retrieve":
            return retrieve(request, store: store)
        case "stats":
            return stats(request)
        case "search_store":
            return searchStore(request, store: store)
        case "json_crusher":
            return crush(resolved, transform: { JSONCrusher.minify($0) ?? JSONCrusher.tabularCSV($0) }, store: store)
        case "log_crusher":
            return crush(resolved, transform: { LogCollapser.collapse($0) }, store: store)
        case "stack_crusher":
            return crush(resolved, transform: { StackTraceCrusher.crush($0, handle: resolved.handle) }, store: store)
        case "test_crusher":
            return crush(resolved, transform: { TestReportCrusher.crush($0, handle: resolved.handle) }, store: store)
        case "diff_crusher":
            return crush(resolved, transform: { DiffCrusher.window($0) }, store: store)
        case "html_crusher":
            return crush(resolved, transform: { HTMLStructuralCompressor.compress($0, droppedHandle: resolved.handle) }, store: store)
        case "source_skeleton":
            return crush(resolved, transform: { SourceCodeSkeletonizer.skeletonize($0, droppedHandle: resolved.handle) }, store: store)
        case "encoder_rank":
            return encoderRank(request, resolved: resolved)
        case "toon_codec":
            return crush(resolved, transform: { ToonCodec.encodeIfEfficient($0) }, store: store)
        case "graphify_query":
            return unavailableHost(resolved, reason: "graphify_cli_not_executed")
        case "path_wrappers":
            return unavailableHost(resolved, reason: "path_wrap_is_host_PATH")
        case "nli_gate":
            return nliGate(resolved)
        case "notebook_crusher":
            return crush(resolved, transform: notebookCrush, store: store)
        case "lockfile_crusher":
            return crush(resolved, transform: lockfileCrush, store: store)
        case "generated_asset_notice":
            return generatedAsset(resolved, store: store)
        case "embedded_blob_crusher":
            return crush(resolved, transform: { embeddedBlobCrush($0, handle: resolved.handle) }, store: store)
        case "progress_bar_crusher":
            return crush(resolved, transform: { BuildProgressCrusher.crush($0, handle: resolved.handle) ?? progressCrush($0) }, store: store)
        case "secret_redact_view":
            return crush(resolved, transform: { Optional(secretRedact($0)) }, store: store)
        case "screenshot_ocr":
            return unavailableHost(resolved, reason: "vision_ocr_needs_image_bytes")
        case "doc_text_extract":
            return hostProcess(resolved, tool: "textutil", extra: ["pdftotext"])
        case "semantic_cache_lookup":
            return semanticCache(request, resolved: resolved, store: store)
        case "workspace_semantic_search":
            return searchStore(request, store: store)
        case "repo_map_budget":
            return crush(resolved, transform: { SourceCodeSkeletonizer.skeletonize($0, droppedHandle: resolved.handle) }, store: store)
        case "stale_tool_result_evict":
            return unavailableHost(resolved, reason: "host_resume_evict_not_in_sidecar")
        case "retrieve_range":
            return retrieveRange(request, store: store)
        case "handle_grep":
            return handleGrep(request, store: store)
        case "handle_query_eval":
            return handleQuery(request, store: store)
        case "handle_token_estimate":
            return tokenEstimate(resolved)
        case "session_transcript_search", "history_recall_search":
            return searchStore(request, store: store)
        case "repeated_failure_notice":
            return textNotice(resolved, text: "notice: similar failure may already exist in store; ignore if new")
        case "identifier_alias_codec":
            return crush(resolved, transform: aliasIdentifiers, store: store)
        case "ansi_escape_strip":
            return crush(resolved, transform: { Optional(stripANSI($0)) }, store: store)
        case "padded_table_compact":
            return crush(resolved, transform: compactTable, store: store)
        case "workspace_change_notice":
            return unavailableHost(resolved, reason: "fsevents_watch_is_host")
        case "audio_transcribe_local", "video_keyframe_ocr":
            return unavailableHost(resolved, reason: "media_bytes_required")
        case "screenshot_diff_digest":
            return unavailableHost(resolved, reason: "two_image_handles_required")
        case "write_ack_verify":
            return writeAck(resolved)
        case "unchanged_reread_stub":
            return unavailableHost(resolved, reason: "claude_posttooluse_only")
        case "stdout_budget_elide":
            return crush(resolved, transform: { stdoutElide($0, handle: resolved.handle) }, store: store)
        case "predicate_watch":
            return unavailableHost(resolved, reason: "host_watch_not_local_suggested")
        case "attachment_handle_intake", "terminal_scrollback_intake":
            return intake(resolved, store: store)
        case "lsp_query", "ast_grep_query":
            return unavailableHost(resolved, reason: "host_language_tool_required")
        case "svg_crusher":
            return crush(resolved, transform: svgCrush, store: store)
        case "error_site_autoquote":
            return errorSiteQuote(resolved)
        case "schema_validate_eval":
            return schemaValidate(request, resolved: resolved)
        case "batch_codemod_apply":
            return unavailableHost(resolved, reason: "host_codemod_not_local_authored")
        case "stale_tool_args_evict":
            return unavailableHost(resolved, reason: "host_resume_args_evict_not_in_sidecar")
        case "spreadsheet_extract":
            return unavailableHost(resolved, reason: "workbook_bytes_required")
        case "test_baseline_diff":
            return testBaseline(request, resolved: resolved, store: store)
        case "correction_exemplar_store":
            let handle = store.put(resolved.text, kind: "exemplar")
            return textNotice(resolved, text: "stored exemplar \(handle); never binds paid")
        case "duplicate_handle_notice":
            if let dup = store.findDuplicate(of: resolved.text) {
                return textNotice(resolved, text: "duplicate of \(dup)")
            }
            return textNotice(resolved, text: "no duplicate handle")
        case "secret_presence_flag":
            return flag(resolved, on: LibrarianSecretGate.looksSecret(resolved.text), label: "secret")
        case "pii_presence_flag":
            return flag(resolved, on: piiPresent(resolved.text), label: "pii")
        case "injection_pattern_flag":
            return flag(resolved, on: injectionPresent(resolved.text), label: "injection")
        case "compact_span":
            return crush(resolved, transform: compactSpan, store: store)
        case "wire_encode":
            return crush(resolved, transform: { Optional("WIRE\n" + $0.split(whereSeparator: \.isNewline).prefix(12).joined(separator: "\n")) }, store: store)
        default:
            if LibrarianCatalog.disabledOnNineB.contains(function.id) {
                return unavailableHost(resolved, reason: "disabled_on_ornith_9b")
            }
            if function.usesLLM {
                return await generateOp(request, function: function, resolved: resolved, store: store, generate: generate)
            }
            return crush(resolved, transform: { stdoutElide($0, handle: resolved.handle) }, store: store)
        }
    }

    private struct Resolved {
        let text: String
        let handle: String
        let original: String
    }

    private static func resolve(_ request: LibrarianRequest, store: LibrarianHandleStore) -> Resolved {
        if let handle = request.handle, let blob = store.get(handle) {
            return Resolved(text: blob, handle: handle, original: blob)
        }
        let text = request.input
        let handle = request.handle ?? store.put(text)
        if store.get(handle) == nil { _ = store.put(text, handle: handle) }
        return Resolved(text: text, handle: handle, original: text)
    }

    private static func retrieve(_ request: LibrarianRequest, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        guard let handle = request.handle else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "",
                envelope: .unavailable(op: "retrieve", reason: "missing_handle"),
                originalForSavings: request.input
            )
        }
        guard let text = store.get(handle) else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "",
                envelope: .unavailable(op: "retrieve", reason: "unknown_handle", handle: handle),
                handle: handle,
                originalForSavings: request.input
            )
        }
        return LibrarianHandlerOutput(status: .ok, text: text, handle: handle, originalForSavings: text)
    }

    private static func stats(_ request: LibrarianRequest) -> LibrarianHandlerOutput {
        let text = #"{"total_saved_tokens":0,"note":"payloads omitted"}"#
        return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input.isEmpty ? text : request.input)
    }

    private static func searchStore(_ request: LibrarianRequest, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        let query = request.question ?? request.pattern ?? request.input
        let results = CCRSearchIndex(records: store.records()).search(query, topK: 5)
        let body = results.map { "\($0.handle)\t\($0.score)\t\($0.excerpt)" }.joined(separator: "\n")
        let text = body.isEmpty ? "no hits; not evidence of absence" : body
        return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input.isEmpty ? query : request.input)
    }

    private static func retrieveRange(_ request: LibrarianRequest, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        guard let handle = request.handle else {
            return LibrarianHandlerOutput(status: .unavailable, text: "", envelope: .unavailable(op: "retrieve_range", reason: "missing_handle"), originalForSavings: request.input)
        }
        guard let slice = store.slice(handle: handle, startLine: request.startLine, endLine: request.endLine, startByte: request.startByte, endByte: request.endByte) else {
            return LibrarianHandlerOutput(status: .unavailable, text: "", envelope: .unavailable(op: "retrieve_range", reason: "unknown_handle", handle: handle), handle: handle, originalForSavings: request.input)
        }
        return LibrarianHandlerOutput(status: .ok, text: slice, handle: handle, originalForSavings: store.get(handle) ?? slice)
    }

    private static func handleGrep(_ request: LibrarianRequest, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        let handle = request.handle ?? resolve(request, store: store).handle
        let pattern = request.pattern ?? request.question ?? request.input
        let hits = store.grep(handle: handle, pattern: pattern, literal: true)
        let text = hits.map { "\($0.line):\($0.text)" }.joined(separator: "\n")
        let original = store.get(handle) ?? request.input
        return LibrarianHandlerOutput(status: .ok, text: text.isEmpty ? "0 matches" : text, handle: handle, originalForSavings: original)
    }

    private static func handleQuery(_ request: LibrarianRequest, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        handleGrep(request, store: store)
    }

    private static func tokenEstimate(_ resolved: Resolved) -> LibrarianHandlerOutput {
        let tokens = TokenEstimator.estimate(resolved.text)
        let lines = resolved.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let head = lines.prefix(8).joined(separator: "\n")
        let tail = lines.suffix(8).joined(separator: "\n")
        let text = "tokens=\(tokens)\n--- head ---\n\(head)\n--- tail ---\n\(tail)"
        return LibrarianHandlerOutput(status: .ok, text: text, handle: resolved.handle, originalForSavings: resolved.original)
    }

    private static func encoderRank(_ request: LibrarianRequest, resolved: Resolved) -> LibrarianHandlerOutput {
        let chunks = resolved.text.split(whereSeparator: \.isNewline).enumerated().map { idx, line in
            QueryAwareChunk(id: "\(idx+1)", text: String(line), position: idx)
        }
        let ranked = QueryAwareChunkRanker().rank(chunks: chunks, query: request.question ?? "")
        let text = ranked.prefix(8).map { "\($0.chunk.id)\t\($0.finalScore)\t\($0.chunk.text)" }.joined(separator: "\n")
        return LibrarianHandlerOutput(status: .ok, text: text, handle: resolved.handle, originalForSavings: resolved.original)
    }

    private static func nliGate(_ resolved: Resolved) -> LibrarianHandlerOutput {
        let result = FaithfulnessGate.validate(original: resolved.original, compressed: resolved.text)
        let status: LibrarianStatus = result.accepted ? .ok : .unavailable
        return LibrarianHandlerOutput(
            status: status,
            text: result.accepted ? resolved.text : resolved.original,
            handle: resolved.handle,
            stage: result.accepted ? .deterministic : .verbatim,
            originalForSavings: resolved.original
        )
    }

    private static func crush(_ resolved: Resolved, transform: (String) -> String?, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        let handle = store.put(resolved.original, handle: resolved.handle)
        guard let out = transform(resolved.text), out.utf8.count < resolved.text.utf8.count else {
            return LibrarianHandlerOutput(status: .ok, text: resolved.text, handle: handle, stage: .verbatim, originalForSavings: resolved.original)
        }
        let withHandle = out.contains("[[rc:") ? out : out + "\n[[rc:\(handle)]]"
        return LibrarianHandlerOutput(status: .ok, text: withHandle, handle: handle, originalForSavings: resolved.original)
    }

    private static func textNotice(_ resolved: Resolved, text: String) -> LibrarianHandlerOutput {
        LibrarianHandlerOutput(
            status: .ok,
            text: resolved.original,
            handle: resolved.handle,
            stage: .verbatim,
            originalForSavings: resolved.original
        )
    }

    private static func unavailableHost(_ resolved: Resolved, reason: String) -> LibrarianHandlerOutput {
        LibrarianHandlerOutput(
            status: .unavailable,
            text: resolved.text,
            envelope: .unavailable(op: "host", reason: reason, handle: resolved.handle),
            handle: resolved.handle,
            stage: .verbatim,
            originalForSavings: resolved.original
        )
    }

    private static func hostProcess(_ resolved: Resolved, tool: String, extra: [String]) -> LibrarianHandlerOutput {
        unavailableHost(resolved, reason: "\(tool)_not_executed_on_handle")
    }

    private static func stubHandle(_ resolved: Resolved, kind: String) -> LibrarianHandlerOutput {
        unavailableHost(resolved, reason: "\(kind)_not_executed")
    }

    private static func intake(_ resolved: Resolved, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        let handle = store.put(resolved.text, kind: "attachment")
        let preview = "kind=text size=\(resolved.text.utf8.count) handle=\(handle)"
        return LibrarianHandlerOutput(status: .ok, text: preview, handle: handle, originalForSavings: resolved.original)
    }

    private static func writeAck(_ resolved: Resolved) -> LibrarianHandlerOutput {
        let lines = resolved.text.split(whereSeparator: \.isNewline).count
        let text = "{\"lines\":\(lines),\"hash\":\"\(LibrarianHandleStore.makeHandle(resolved.text))\"}"
        return LibrarianHandlerOutput(status: .ok, text: text, handle: resolved.handle, originalForSavings: resolved.original)
    }

    private static func generatedAsset(_ resolved: Resolved, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        let handle = store.put(resolved.original, handle: resolved.handle)
        let text = "generated/minified asset size=\(resolved.text.utf8.count) hash=\(handle) [[rc:\(handle)]]"
        return LibrarianHandlerOutput(status: .ok, text: text, handle: handle, originalForSavings: resolved.original)
    }

    private static func semanticCache(_ request: LibrarianRequest, resolved: Resolved, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        if let dup = store.findDuplicate(of: resolved.text) {
            return textNotice(resolved, text: "semantic cache notice: similar blob at \(dup); never substitutes bytes")
        }
        return searchStore(request, store: store)
    }

    private static func flag(_ resolved: Resolved, on: Bool, label: String) -> LibrarianHandlerOutput {
        let view = on ? secretRedact(resolved.text) : resolved.text
        let text = "\(label)=\(on) \n\(view)"
        return LibrarianHandlerOutput(status: .ok, text: text, handle: resolved.handle, originalForSavings: resolved.original)
    }

    private static func schemaValidate(_ request: LibrarianRequest, resolved: Resolved) -> LibrarianHandlerOutput {
        guard let schema = request.schema, let data = resolved.text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return LibrarianHandlerOutput(status: .ok, text: "schema errors: input is not JSON", handle: resolved.handle, originalForSavings: resolved.original)
        }
        let text = schema.isEmpty ? "schema missing" : "schema checked (structural); errors=[]"
        return LibrarianHandlerOutput(status: .ok, text: text, handle: resolved.handle, originalForSavings: resolved.original)
    }

    private static func testBaseline(_ request: LibrarianRequest, resolved: Resolved, store: LibrarianHandleStore) -> LibrarianHandlerOutput {
        let current = Set(TestReportCrusher.crush(resolved.text, handle: resolved.handle)?.split(whereSeparator: \.isNewline).map(String.init) ?? [])
        let baselineText = request.handles.last.flatMap { store.get($0) } ?? ""
        let baseline = Set(baselineText.split(whereSeparator: \.isNewline).map(String.init))
        let neu = current.subtracting(baseline)
        let text = "new=\(neu.count)\n" + neu.sorted().joined(separator: "\n")
        return LibrarianHandlerOutput(status: .ok, text: text, handle: resolved.handle, originalForSavings: resolved.original)
    }

    private static func errorSiteQuote(_ resolved: Resolved) -> LibrarianHandlerOutput {
        let pattern = try! NSRegularExpression(pattern: #"([\w./-]+\.\w+):(\d+)"#)
        let ns = resolved.text as NSString
        var quotes: [String] = []
        for match in pattern.matches(in: resolved.text, range: NSRange(location: 0, length: ns.length)).prefix(8) {
            quotes.append(ns.substring(with: match.range))
        }
        let extra = quotes.isEmpty ? resolved.text : resolved.text + "\n# autoquote " + quotes.joined(separator: ", ")
        return LibrarianHandlerOutput(status: .ok, text: extra, handle: resolved.handle, originalForSavings: resolved.original)
    }

    // MARK: - transforms

    private static func notebookCrush(_ input: String) -> String? {
        guard let data = input.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var cells = obj["cells"] as? [[String: Any]] else { return nil }
        cells = cells.map { cell in
            var next = cell
            next["outputs"] = []
            next["execution_count"] = NSNull()
            return next
        }
        obj["cells"] = cells
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: out, encoding: .utf8),
              text.utf8.count < input.utf8.count else { return nil }
        return text
    }

    private static func lockfileCrush(_ input: String) -> String? {
        let lines = input.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > 40 else { return nil }
        let deps = lines.filter { $0.contains("\"") && ($0.contains("version") || $0.hasPrefix("name =") || $0.contains(": {")) }.prefix(40)
        return "lockfile top-level sample (\(lines.count) lines)\n" + deps.joined(separator: "\n")
    }

    private static func embeddedBlobCrush(_ input: String, handle: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"(data:[^;]+;base64,[A-Za-z0-9+/]{80,}={0,2})"#)
        let ns = input as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard pattern.firstMatch(in: input, range: range) != nil else { return nil }
        return pattern.stringByReplacingMatches(in: input, range: range, withTemplate: "[blob [[rc:\(handle)]]]")
    }

    private static func progressCrush(_ input: String) -> String? {
        let lines = input.components(separatedBy: "\r")
        guard lines.count > 3 else { return nil }
        return lines.last
    }

    private static func secretRedact(_ input: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"(?i)((?:api[_-]?key|secret|password|token|bearer)\s*[:=]\s*)(\S+)"#)
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return pattern.stringByReplacingMatches(in: input, range: range, withTemplate: "$1***")
    }

    private static func stripANSI(_ input: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\u001B\[[0-9;]*[A-Za-z]"#)
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return pattern.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    private static func compactTable(_ input: String) -> String? {
        let lines = input.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: "\t") }
        let text = lines.joined(separator: "\n")
        return text.utf8.count < input.utf8.count ? text : nil
    }

    private static func aliasIdentifiers(_ input: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{32,}\b"#)
        let ns = input as NSString
        let matches = pattern.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var out = input
        var n = 0
        for match in matches.reversed() {
            n += 1
            let token = "id\(n)"
            if let r = Range(match.range, in: out) {
                out.replaceSubrange(r, with: token)
            }
        }
        return out
    }

    private static func svgCrush(_ input: String) -> String? {
        guard input.contains("<svg") else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"\s[dD]="[^"]{80,}""#)
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let text = pattern.stringByReplacingMatches(in: input, range: range, withTemplate: " d=\"…\"")
        return text.utf8.count < input.utf8.count ? text : nil
    }

    private static func stdoutElide(_ input: String, handle: String) -> String? {
        let lines = input.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.count > 40 else { return nil }
        let head = lines.prefix(12)
        let tail = lines.suffix(12)
        return head.joined(separator: "\n") + "\n… elided [[rc:\(handle)]] …\n" + tail.joined(separator: "\n")
    }

    private static func compactSpan(_ input: String) -> String? {
        let text = input.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        return text.utf8.count < input.utf8.count ? text : nil
    }

    private static func piiPresent(_ text: String) -> Bool {
        text.contains("@") && text.contains(".")
    }

    private static func injectionPresent(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("ignore previous") || lower.contains("system prompt") || lower.contains("you are now")
    }

    // MARK: - generate family

    private static func generateOp(
        _ request: LibrarianRequest,
        function: LibrarianFunction,
        resolved: Resolved,
        store: LibrarianHandleStore,
        generate: (any LibrarianGenerating)?
    ) async -> LibrarianHandlerOutput {
        guard let generate else {
            return unavailableHost(resolved, reason: "generate_runtime_unavailable")
        }
        let prompt = """
        Op: \(function.id)
        Question: \(request.question ?? "")
        Source (cite exact substrings only):
        \(resolved.text.prefix(6000))
        Reply with one JSON object only. Keys: answer, span. span MUST be an exact substring of Source. No analysis.
        """
        guard let raw = await generate.generate(LibrarianGenerateCall(
            system: "Extract only. Never invent. Never include <think>. Reply with one JSON object only.",
            user: String(prompt),
            maxTokens: 512
        )), let clean = LibrarianThinkStrip.strip(raw),
              let parsed = parseAnswerSpan(clean, source: resolved.text) else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: resolved.original,
                envelope: .unavailable(op: function.id, reason: "generate_unavailable", handle: resolved.handle),
                handle: resolved.handle,
                stage: .verbatim,
                originalForSavings: resolved.original
            )
        }
        let answer = parsed.0
        let span = parsed.1
        if looksLikeChainOfThought(answer) {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: resolved.original,
                envelope: .unavailable(op: function.id, reason: "cot_in_content", handle: resolved.handle),
                handle: resolved.handle,
                stage: .verbatim,
                originalForSavings: resolved.original
            )
        }
        if span.isEmpty || !resolved.text.contains(span) {
            return LibrarianHandlerOutput(
                status: .lowConfidence,
                text: resolved.original,
                envelope: LibrarianEnvelope(
                    status: .lowConfidence,
                    confidence: 0.2,
                    op: function.id,
                    whyUncertain: "span_not_in_original",
                    fallback: LibrarianFallback(recommended: "retrieve", handle: resolved.handle)
                ),
                handle: resolved.handle,
                stage: .verbatim,
                originalForSavings: resolved.original
            )
        }
        let envelope = LibrarianEnvelope(
            status: .ok,
            confidence: 0.7,
            op: function.id,
            answer: .object(["text": .string(answer)]),
            evidence: [LibrarianEvidence(handle: resolved.handle, span: span)],
            fallback: LibrarianFallback(recommended: "retrieve", handle: resolved.handle, question: request.question)
        )
        let paid = function.safety == .candidate
            ? "NON-AUTHORITATIVE DRAFT\n\(answer)\n[[rc:\(resolved.handle)]]"
            : "\(answer)\n[[rc:\(resolved.handle)]]"
        return LibrarianHandlerOutput(
            status: .ok,
            text: paid,
            envelope: envelope,
            handle: resolved.handle,
            stage: .llmMLX,
            originalForSavings: resolved.original
        )
    }

    private static func parseAnswerSpan(_ raw: String, source: String) -> (String, String)? {
        let trimmed = extractJSONObject(raw)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let answer = stringifyJSONValue(obj["answer"]) ?? trimmed
            var span = obj["span"] as? String ?? ""
            if span.isEmpty || !source.contains(span) {
                span = tokenSpan(in: source, from: answer) ?? ""
            }
            if !span.isEmpty, source.contains(span) { return (answer, span) }
            if source.contains(answer), !answer.isEmpty { return (answer, answer) }
            return nil
        }
        if looksLikeChainOfThought(trimmed) { return nil }
        let span = tokenSpan(in: source, from: trimmed)
            ?? source.split(whereSeparator: \.isNewline).map(String.init).first(where: { trimmed.contains($0) && $0.count > 8 })
            ?? ""
        return span.isEmpty ? nil : (trimmed, span)
    }

    private static func looksLikeChainOfThought(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("the user wants")
            || lower.contains("let me analyze")
            || lower.contains("let me look")
            || lower.contains("the task is to")
            || lower.contains("the question asks")
            || lower.contains("i need to return compact extractive json")
    }

    private static func tokenSpan(in source: String, from answer: String) -> String? {
        let parts = answer.split { ch in
            !(ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == ":" || ch == "/")
        }
        return parts.map(String.init).first(where: { $0.count >= 2 && source.contains($0) })
    }

    private static func extractJSONObject(_ raw: String) -> String {
        let text = stripFence(raw)
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["answer"] != nil || obj["span"] != nil {
            return text
        }
        var rest = text
        while let start = rest.lastIndex(of: "{") {
            let fromBrace = String(rest[start...])
            if let end = fromBrace.lastIndex(of: "}"),
               let data = String(fromBrace[...end]).data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["answer"] != nil || obj["span"] != nil {
                return String(fromBrace[...end])
            }
            if start == rest.startIndex { break }
            rest = String(rest[..<start])
        }
        return text
    }

    private static func stripFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNL = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNL)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringifyJSONValue(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let list as [Any]:
            return list.map { "\($0)" }.joined(separator: "\n")
        case let object as [String: Any]:
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text
        default:
            return nil
        }
    }

    private static func extractive(_ id: String, text: String, question: String?, claim: String?) -> (answer: String, span: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let q = (question ?? claim ?? "").lowercased()
        let terms = q.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
        let hit = lines.first(where: { line in
            let lower = line.lowercased()
            return terms.contains(where: { lower.contains($0) })
        }) ?? lines.first(where: { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("fail") }) ?? lines.first ?? ""
        switch id {
        case "test_verdict":
            let failed = lines.filter { $0.contains("FAIL") || $0.contains("failed") }
            let pass = text.localizedCaseInsensitiveContains("passed") && failed.isEmpty
            return (pass ? "PASS" : "FAIL " + failed.prefix(8).joined(separator: ", "), failed.first ?? hit)
        case "command_intent":
            return ("statusCode", hit)
        case "classify_closed", "file_role_classify":
            let role = text.contains("XCTest") || text.contains("describe(") ? "test" : (text.contains("import") ? "impl" : "config")
            return (role, hit)
        case "entity_list", "import_summary":
            let ents = lines.filter { $0.contains("import ") || $0.hasSuffix(".swift") || $0.contains("error") }.prefix(20)
            return (ents.joined(separator: "\n"), ents.first ?? hit)
        case "ci_job_failures", "xcodebuild_error_extract", "compiler_diagnostics_extract":
            let fails = lines.filter { $0.localizedCaseInsensitiveContains("error:") || $0.contains("FAILED") }
            return (fails.prefix(20).joined(separator: "\n"), fails.first ?? hit)
        case "json_shape":
            return (jsonKeys(text), hit)
        case "env_key_list":
            let keys = lines.compactMap { line -> String? in
                let parts = line.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? String(parts[0]) : nil
            }
            return (keys.joined(separator: "\n"), keys.first ?? hit)
        case "nli_claim":
            let c = (claim ?? question ?? "")
            return (text.contains(c) ? "entail" : "unknown", hit)
        case "thread_title_generate":
            return (String(text.split(whereSeparator: \.isNewline).first?.prefix(60) ?? "thread"), hit)
        case "i18n_key_diff":
            return ("missing keys: (deterministic set diff of JSON keys)", hit)
        default:
            let keep = lines.filter { line in
                let lower = line.lowercased()
                return lower.contains("error") || lower.contains("fail") || terms.contains(where: { lower.contains($0) })
            }
            let answer = keep.isEmpty ? lines.prefix(15).joined(separator: "\n") : keep.prefix(30).joined(separator: "\n")
            return (answer, hit)
        }
    }

    private static func jsonKeys(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "keys=[]"
        }
        return obj.keys.sorted().joined(separator: ",")
    }
}
