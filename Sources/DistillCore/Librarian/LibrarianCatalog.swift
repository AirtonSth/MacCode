import Foundation

public enum LibrarianSafety: String, Sendable, Equatable, Codable {
    case deterministic
    case safe
    case candidate
    case forbidden
}

public enum LibrarianRuntimeClass: String, Sendable, Equatable, Codable {
    case none
    case hot17bE4b = "hot-1.7b-e4b"
    case nineB = "9b"
    case thirtyFiveBOnly = "35b-only"
    case never
}

public struct LibrarianFunction: Sendable, Equatable, Codable {
    public let id: String
    public let safety: LibrarianSafety
    public let mcp: String
    public let lane: String
    public let usesLLM: Bool
    public let runtime: LibrarianRuntimeClass
    public let summary: String
    public let paidFallback: String
}

public struct LibrarianCatalogItem: Sendable, Equatable, Codable {
    public let id: String
    public let summary: String
}

public struct LibrarianCatalogPage: Sendable, Equatable, Codable {
    public let items: [LibrarianCatalogItem]
    public let nextCursor: String?
    public let total: Int
}

public enum LibrarianCatalogPageError: Error, Sendable, Equatable {
    case invalidLimit
    case invalidCursor
}

public enum LibrarianCatalog {
    public static let version = "rc-local-llm-function-catalog-v1"
    /// Ornith-1.5-9B spends the generate budget on chain-of-thought and never
    /// emits extractive JSON. Sidecar returns unavailable without calling generate.
    public static let disabledOnNineB: Set<String> = [
        "i18n_translation_draft",
    ]
    /// Eight common ids stay in the compact rc_ask schema as a routing hint.
    /// The complete callable surface is discovered on demand through rc_catalog.
    public static let hotHintIDs = [
        "test_verdict",
        "ci_job_failures",
        "handle_grep",
        "retrieve_range",
        "extract_schema",
        "pick_candidates",
        "cite_spans",
        "multi_handle_ask",
    ]
    public static let all: [LibrarianFunction] = [
        LibrarianFunction(id: "retrieve", safety: .deterministic, mcp: "rc_retrieve", lane: "any", usesLLM: false, runtime: .none, summary: "Byte-exact original behind [[rc:handle]]", paidFallback: "Agent-sandbox read_file of the path cited in fallback; Distill sidecar never open(2); circuit-breaker disables lossy if retrieve is down"),
        LibrarianFunction(id: "stats", safety: .deterministic, mcp: "rc_stats", lane: "any", usesLLM: false, runtime: .none, summary: "Ledger stats, no payloads", paidFallback: "Ignore; stats never required to continue a turn"),
        LibrarianFunction(id: "search_store", safety: .deterministic, mcp: "rc_search", lane: "on_demand", usesLLM: false, runtime: .none, summary: "CCR/reversible-store search by query", paidFallback: "rc_retrieve hits or native grep"),
        LibrarianFunction(id: "json_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Deterministic JSON/TOON crush", paidFallback: "Original stdin via fail-open"),
        LibrarianFunction(id: "log_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Collapse repeated log lines", paidFallback: "Original"),
        LibrarianFunction(id: "stack_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Keep frames, drop dumps", paidFallback: "Original"),
        LibrarianFunction(id: "test_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Keep fail names and assertion text", paidFallback: "Original"),
        LibrarianFunction(id: "diff_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Keep file headers and hunks, drop noise", paidFallback: "Original git diff"),
        LibrarianFunction(id: "html_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Strip chrome, keep text", paidFallback: "Original"),
        LibrarianFunction(id: "source_skeleton", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Signatures/line map without bodies", paidFallback: "Native read_file of needed range"),
        LibrarianFunction(id: "encoder_rank", safety: .deterministic, mcp: "rc_pick", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Embedding rank of chunks vs question", paidFallback: "Paid model picks from raw candidate list"),
        LibrarianFunction(id: "toon_codec", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Uniform JSON arrays as TOON", paidFallback: "Keep JSON if agent asked JSON-only"),
        LibrarianFunction(id: "graphify_query", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Existing graphify CLI query/path/explain", paidFallback: "Native grep/read after graph miss"),
        LibrarianFunction(id: "path_wrappers", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Host PATH wrap of noisy binaries", paidFallback: "Unwrapped command if wrap fails"),
        LibrarianFunction(id: "nli_gate", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Existing BERT NLI reject-only gate", paidFallback: "Fail-open accept then deterministic faithfulness"),
        LibrarianFunction(id: "notebook_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Strip .ipynb outputs/base64 images; keep code+markdown cells", paidFallback: "Original notebook JSON"),
        LibrarianFunction(id: "lockfile_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "package-lock/yarn.lock/Cargo.lock/Package.resolved → top-level deps + counts, never full graph", paidFallback: "Original lockfile via native read"),
        LibrarianFunction(id: "generated_asset_notice", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Binary/minified/generated mega-file → typed notice (size, kind, hash) + handle instead of bytes", paidFallback: "Paid forces native read_file or rc_retrieve"),
        LibrarianFunction(id: "embedded_blob_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "base64/data-URI/hexdump islands inside text → typed placeholder + sub-handle", paidFallback: "Original blob via rc_retrieve"),
        LibrarianFunction(id: "progress_bar_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Collapse carriage-return progress/spinner frames (npm, pip, docker pull) to final state per bar", paidFallback: "Original stream"),
        LibrarianFunction(id: "secret_redact_view", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Masked view of secret-bearing blob: keys kept, values masked; deterministic masker, fail-closed", paidFallback: "Paid uses secret stores; unredacted bytes never enter paid context"),
        LibrarianFunction(id: "screenshot_ocr", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "On-device Vision OCR of pasted image → text + boxes instead of vision tokens; secret pre-gate applies to OCR text", paidFallback: "Paid reads the original image natively"),
        LibrarianFunction(id: "doc_text_extract", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "pdftotext/textutil text layer of PDF/DOCX/RTF → handle; secret pre-gate applies", paidFallback: "Paid reads original document natively (vision)"),
        LibrarianFunction(id: "semantic_cache_lookup", safety: .deterministic, mcp: "rc_search", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Embedding lookup: similar question/blob already answered at handle X; notice-only, never substitutes bytes", paidFallback: "Ignore notice; paid re-derives"),
        LibrarianFunction(id: "workspace_semantic_search", safety: .deterministic, mcp: "rc_search", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Embedding search over host-indexed workspace chunks → ranked paths+ranges; host feeds chunks, sidecar never open(2)", paidFallback: "Native grep/graphify; index miss is not evidence of absence"),
        LibrarianFunction(id: "repo_map_budget", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Ranked repo map of signatures fitted to a token budget (aider-style) for session boot", paidFallback: "Paid reads real files for anything load-bearing"),
        LibrarianFunction(id: "stale_tool_result_evict", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Host-owned resume/replay context only: age/size policy swaps old tool results for [[rc:handle]] stubs; never rewrites a live provider session", paidFallback: "rc_retrieve or native re-read; circuit breaker disables evict if retrieve is down"),
        LibrarianFunction(id: "retrieve_range", safety: .deterministic, mcp: "rc_retrieve", lane: "any", usesLLM: false, runtime: .none, summary: "Byte-exact slice of a handle by line/byte range instead of the whole blob", paidFallback: "Full rc_retrieve"),
        LibrarianFunction(id: "handle_grep", safety: .deterministic, mcp: "rc_search", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Exact grep inside handle(s): verbatim match lines + line numbers", paidFallback: "Full rc_retrieve; native grep on the original path"),
        LibrarianFunction(id: "handle_query_eval", safety: .deterministic, mcp: "rc_ask", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Run a paid-supplied deterministic query (regex/jq/xpath/line-range) against a handle → counts + sample spans; no LLM involved", paidFallback: "rc_retrieve and paid evaluates natively"),
        LibrarianFunction(id: "handle_token_estimate", safety: .deterministic, mcp: "rc_stats", lane: "any", usesLLM: false, runtime: .none, summary: "Per-provider token estimate + head/tail preview of a handle, so paid can decide retrieve-or-not", paidFallback: "Paid retrieves blind"),
        LibrarianFunction(id: "session_transcript_search", safety: .deterministic, mcp: "rc_search", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Keyword/embedding search over the host-persisted session transcript → turn refs + spans; survives compaction", paidFallback: "Paid asks the user or re-derives from scratch"),
        LibrarianFunction(id: "repeated_failure_notice", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Embedding similarity: this error ≈ previous attempts at handles X,Y; notice-only loop detector", paidFallback: "Ignore notice"),
        LibrarianFunction(id: "identifier_alias_codec", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Reversible aliasing of long UUIDs/hashes/paths to short tokens; expansion table behind a handle", paidFallback: "Original identifiers via rc_retrieve"),
        LibrarianFunction(id: "ansi_escape_strip", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Strip ANSI color/cursor escape codes that inflate tokenization", paidFallback: "Original bytes"),
        LibrarianFunction(id: "padded_table_compact", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Collapse alignment whitespace in columnar CLI output; CSV/TOON re-emit", paidFallback: "Original table"),
        LibrarianFunction(id: "workspace_change_notice", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "FSEvents-based list of files changed since a given turn + per-handle staleness check; paid re-reads only those", paidFallback: "Paid re-reads/re-greps natively"),
        LibrarianFunction(id: "audio_transcribe_local", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "On-device ASR of audio (meetings, voice notes) → transcript + timestamps; secret/PII pre-gate applies", paidFallback: "Paid processes the original audio if the provider supports it"),
        LibrarianFunction(id: "video_keyframe_ocr", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Keyframes + OCR + scene timestamps from a video (demo-video validation) instead of paid vision", paidFallback: "Paid views original frames natively"),
        LibrarianFunction(id: "screenshot_diff_digest", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Pixel-diff two images → changed-region boxes, % changed, OCR of changed regions", paidFallback: "Paid views both originals"),
        LibrarianFunction(id: "write_ack_verify", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Successful write/edit tool results → terse ack {lines, hash, applied hunks} instead of full echo; kills the verify re-read", paidFallback: "Full write echo; paid may re-read the file natively to verify"),
        LibrarianFunction(id: "unchanged_reread_stub", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Re-read of a file unchanged since handle X → stub + delta ranges, via provider rewrite hook only (Claude PostToolUse); Grok/Codex native reads stay untouched", paidFallback: "Full read result; paid may always force rc_retrieve or native re-read"),
        LibrarianFunction(id: "stdout_budget_elide", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Generic byte budget on any stdout when no specific crusher matches: head+tail verbatim, middle elided to [[rc:handle]]", paidFallback: "Original via rc_retrieve; head+tail always verbatim"),
        LibrarianFunction(id: "predicate_watch", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Paid-initiated watch: host re-runs the same already-approved command until regex predicate matches or timeout; paid receives one final result instead of N polls", paidFallback: "Paid polls natively; never local-suggested execution"),
        LibrarianFunction(id: "attachment_handle_intake", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "User file attachments become handles + typed preview (kind, size, pages); paid pulls ranges/digests on demand instead of full inline. User prompt TEXT stays verbatim", paidFallback: "Paid inlines the original attachment (see distill_user_prompt for the text boundary)"),
        LibrarianFunction(id: "lsp_query", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "sourcekit-lsp/tsserver queries: definition, references, hover types, document symbols → exact locations + signatures instead of grep+read storms", paidFallback: "Native grep/read; graphify; LSP miss is not evidence of absence"),
        LibrarianFunction(id: "ast_grep_query", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Tree-sitter/ast-grep structural pattern queries over host-fed workspace files → match locations", paidFallback: "Native grep/read"),
        LibrarianFunction(id: "svg_crusher", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Strip SVG path-coordinate blobs → structure, text, viewBox; full behind handle", paidFallback: "Original SVG"),
        LibrarianFunction(id: "error_site_autoquote", safety: .deterministic, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Parse file:line refs in failing output; host appends the referenced source lines (±N) verbatim so paid skips the follow-up read", paidFallback: "Additive-only verbatim quotes; paid may still read files natively"),
        LibrarianFunction(id: "history_recall_search", safety: .deterministic, mcp: "rc_search", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Embedding search across past session stores/threads in the same workspace scope → prior fixes/decisions + handles; notice-only", paidFallback: "Ignore; paid re-derives. Results are notices with handles, never injected as authority"),
        LibrarianFunction(id: "terminal_scrollback_intake", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Ghostty scrollback the user attaches → scoped handle + crushers; paid gets digest + handle, not raw scrollback", paidFallback: "User pastes raw scrollback; paid reads the full handle via rc_retrieve"),
        LibrarianFunction(id: "schema_validate_eval", safety: .deterministic, mcp: "rc_ask", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Validate handle content against a paid-supplied JSON Schema/grammar → error list with paths; no LLM involved", paidFallback: "rc_retrieve and paid validates by inspection or its own tooling"),
        LibrarianFunction(id: "batch_codemod_apply", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Paid-authored deterministic rewrite rule (regex/ast-grep), host-executed across N files → per-file diff digest; local LLM never authors the rule; saves paid OUTPUT tokens on mass renames/import updates", paidFallback: "Paid edits file-by-file via native write/search_replace; full diff via git; revert always available"),
        LibrarianFunction(id: "stale_tool_args_evict", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Host-owned resume/replay context: old write/edit tool ARGUMENTS collapse to {path, hash, handle} stubs — the content is on disk and in store; never mid live provider session", paidFallback: "rc_retrieve of the stored argument blob or native read of the file on disk"),
        LibrarianFunction(id: "spreadsheet_extract", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "xlsx/numbers workbook → sheet list + tabular digest per sheet via host converter (paid can't read the binary at all); secret/PII gates apply", paidFallback: "Host converts to CSV and paid reads ranges natively"),
        LibrarianFunction(id: "test_baseline_diff", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Compare current test failures against a stored baseline handle → only NEW and newly-fixed failures; pre-existing flakes stop burning paid attention", paidFallback: "Full test output; baseline handle cited so paid can audit the subtraction"),
        LibrarianFunction(id: "correction_exemplar_store", safety: .deterministic, mcp: "none", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Store paid's correction of a local answer as a scoped few-shot exemplar for future local calls on similar blobs; exemplars never cross workspace scope", paidFallback: "Ignore; corrections only improve local quality, never bind paid"),
        LibrarianFunction(id: "distill_command_output", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Extractive compress of noisy stdout with question", paidFallback: "Fail-open original; or rc_retrieve handle; paid may re-run command without pipe"),
        LibrarianFunction(id: "distill_long_text", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Long prose/log extractive compress", paidFallback: "Original + handle"),
        LibrarianFunction(id: "watch_summary", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Existing watchSummary mode", paidFallback: "Original stream bytes"),
        LibrarianFunction(id: "ask_handle", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Extractive QA over a recovery-scope handle with obligatory spans", paidFallback: "If low_confidence or no span match: rc_retrieve; paid may read_file in the agent sandbox of cited path:line (not sidecar FS)"),
        LibrarianFunction(id: "extract_schema", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Fill closed JSON schema from handle", paidFallback: "Schema fail or extra keys → unavailable; paid reads original"),
        LibrarianFunction(id: "pick_candidates", safety: .safe, mcp: "rc_pick", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Top-k ids from path/symbol list for a question", paidFallback: "Paid scans full candidate list; never deletes unread files from disk"),
        LibrarianFunction(id: "nli_claim", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "entail/contradict/unknown of claim vs handle", paidFallback: "unknown → paid reads evidence handle"),
        LibrarianFunction(id: "classify_closed", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Closed enum: pass/fail, file role, error class", paidFallback: "Unknown label → paid inspects original"),
        LibrarianFunction(id: "cluster_lines", safety: .safe, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Group similar failures; 1 example per group", paidFallback: "Paid requests unclustered handle"),
        LibrarianFunction(id: "outline_structure", safety: .safe, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Headings/functions with line ranges", paidFallback: "Deterministic skeletonizer or native read"),
        LibrarianFunction(id: "delta_handles", safety: .safe, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "What changed between two handles", paidFallback: "Native diff of stored originals"),
        LibrarianFunction(id: "cite_spans", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Quotes that must be substrings of original", paidFallback: "If quote not in original, drop and retrieve"),
        LibrarianFunction(id: "entity_list", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Files, tests, error tokens mentioned in blob", paidFallback: "Paid greps original"),
        LibrarianFunction(id: "test_verdict", safety: .safe, mcp: "rc_extract", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "PASS/FAIL + failing names from test stdout", paidFallback: "Deterministic test crusher, then original"),
        LibrarianFunction(id: "command_intent", safety: .safe, mcp: "none", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Existing CommandOutputIntent classifier", paidFallback: "Keyword matcher; else full output"),
        LibrarianFunction(id: "filter_line_numbers", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Line numbers matching an NL predicate", paidFallback: "Paid reads those lines natively; if empty, grep original"),
        LibrarianFunction(id: "map_error_to_files", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Stack/error → likely paths", paidFallback: "Paid opens cited paths; miss → search"),
        LibrarianFunction(id: "json_shape", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Infer keys of a JSON blob without values if secret-like", paidFallback: "jq on original (exact-output; not distilled)"),
        LibrarianFunction(id: "semantic_dedup", safety: .safe, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Near-duplicate handles/chunks", paidFallback: "Keep all; paid ignores dedup"),
        LibrarianFunction(id: "log_records", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Log lines → {ts,level,msg,file}", paidFallback: "Original log"),
        LibrarianFunction(id: "git_theme_summary", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "git log/status noisy summary", paidFallback: "git log as exact if needed"),
        LibrarianFunction(id: "ci_job_failures", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "CI log → failed job names", paidFallback: "Original CI log handle"),
        LibrarianFunction(id: "lint_group", safety: .safe, mcp: "rc_digest", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Group linter hits by rule", paidFallback: "Full linter stdout"),
        LibrarianFunction(id: "coverage_summary", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Coverage % and uncovered files", paidFallback: "Original report"),
        LibrarianFunction(id: "docker_error_tail", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Last error in long docker/build log", paidFallback: "Original"),
        LibrarianFunction(id: "terraform_plan_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Add/change/destroy counts + names", paidFallback: "Full terraform plan (paid must confirm apply)"),
        LibrarianFunction(id: "kubectl_digest", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Wide kubectl get output", paidFallback: "Original"),
        LibrarianFunction(id: "gh_run_digest", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "gh run view / api noise", paidFallback: "Original gh json"),
        LibrarianFunction(id: "linear_issue_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Extract title/AC/labels from issue JSON, no invention", paidFallback: "Full issue JSON"),
        LibrarianFunction(id: "mcp_schema_trim", safety: .safe, mcp: "rc_pick", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Filter huge MCP tool catalogs to matching names", paidFallback: "Full search_tool dump"),
        LibrarianFunction(id: "patch_explain", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Describe a unified diff; never apply", paidFallback: "Paid reads the diff verbatim"),
        LibrarianFunction(id: "chunk_select", safety: .safe, mcp: "rc_pick", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Which line ranges of a file answer a question", paidFallback: "Native read of those ranges or whole file"),
        LibrarianFunction(id: "file_role_classify", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "test/impl/config/generated/skill", paidFallback: "Paid opens the file"),
        LibrarianFunction(id: "json_path_select", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Which JSON paths match a question", paidFallback: "jq/original JSON"),
        LibrarianFunction(id: "table_extract", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Markdown/HTML tables → JSON rows", paidFallback: "Original table text"),
        LibrarianFunction(id: "metric_extract", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Numbers from bench output", paidFallback: "Original bench log"),
        LibrarianFunction(id: "playwright_trace_digest", safety: .safe, mcp: "rc_compress", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Playwright log → failed spec + error", paidFallback: "Original playwright output"),
        LibrarianFunction(id: "xcodebuild_error_extract", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "xcodebuild/swift test errors", paidFallback: "Original"),
        LibrarianFunction(id: "subagent_brief_compact", safety: .safe, mcp: "rc_compress", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Compress explore subagent dump before parent context", paidFallback: "Parent reads full child output.json"),
        LibrarianFunction(id: "multi_handle_ask", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "One question over N handles", paidFallback: "Paid retrieves each handle"),
        LibrarianFunction(id: "constraint_extract", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Acceptance criteria from a ticket blob", paidFallback: "Full ticket JSON"),
        LibrarianFunction(id: "import_summary", safety: .safe, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Import/include list from a file", paidFallback: "Native read or AST skeleton"),
        LibrarianFunction(id: "log_timeline", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Timestamped event list", paidFallback: "Original log"),
        LibrarianFunction(id: "graphql_error_extract", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "GraphQL errors array digest", paidFallback: "Original JSON"),
        LibrarianFunction(id: "har_summary", safety: .safe, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "HAR/network log: status and URLs only", paidFallback: "Original HAR"),
        LibrarianFunction(id: "sql_explain_digest", safety: .safe, mcp: "rc_compress", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "EXPLAIN/analyze output", paidFallback: "Original"),
        LibrarianFunction(id: "profiler_hotspots", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Top stacks from profiler text", paidFallback: "Original profile"),
        LibrarianFunction(id: "flake_classify", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "flake vs consistent fail (classify only)", paidFallback: "Paid re-runs tests"),
        LibrarianFunction(id: "boilerplate_strip", safety: .safe, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Drop license headers/generated banners", paidFallback: "Full file"),
        LibrarianFunction(id: "graph_ask", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Prose wrapper over graphify query result", paidFallback: "Raw graphify CLI output, then native search"),
        LibrarianFunction(id: "skill_name_pick", safety: .safe, mcp: "rc_pick", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Pick relevant skill NAMES only; never distill SKILL.md bodies", paidFallback: "Paid reads full SKILL.md verbatim"),
        LibrarianFunction(id: "env_key_list", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Env key names, never values", paidFallback: "Paid inspects file with secret redaction"),
        LibrarianFunction(id: "duplicate_handle_notice", safety: .safe, mcp: "rc_search", lane: "on_demand", usesLLM: false, runtime: .none, summary: "This blob already stored as handle X", paidFallback: "Ignore notice"),
        LibrarianFunction(id: "secret_presence_flag", safety: .safe, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Regex/heuristic: blob looks secret-bearing; do not echo values", paidFallback: "Skip local model; keep original off paid context until redacted"),
        LibrarianFunction(id: "wire_encode", safety: .safe, mcp: "none", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Existing DistillMode.wireEncode", paidFallback: "Unencoded text"),
        LibrarianFunction(id: "compact_span", safety: .safe, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Existing compact span codec", paidFallback: "Decoded literals"),
        LibrarianFunction(id: "tree_listing_digest", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Huge find/ls -R listing → subtree summary relevant to question", paidFallback: "Original listing"),
        LibrarianFunction(id: "mcp_result_digest", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Compress verbose MCP tool results (question-aware) where the provider hook supports rewrite", paidFallback: "Original tool result; providers without the hook are never rewritten"),
        LibrarianFunction(id: "grep_hits_rank", safety: .safe, mcp: "rc_pick", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Rank/group hits of an already-stored grep dump handle; voluntary paid call only — never auto-distills rg/grep", paidFallback: "Full match lines verbatim via rc_retrieve"),
        LibrarianFunction(id: "context_pack", safety: .safe, mcp: "rc_pick", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Question → ranked reading list of handles, paths+ranges and skeletons; no prose claims", paidFallback: "Paid explores natively; the pack is a reading list, never a substitute for reading"),
        LibrarianFunction(id: "dependency_graph_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "npm ls / pip freeze / SwiftPM resolve output → direct deps, versions, conflicts", paidFallback: "Original resolver output"),
        LibrarianFunction(id: "crash_report_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "macOS .ips/crash log → exception type, faulting thread, top frames, relevant binary images", paidFallback: "Original crash report handle"),
        LibrarianFunction(id: "blame_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "git blame output → per-range author/commit/date relevant to question", paidFallback: "Original blame output"),
        LibrarianFunction(id: "merge_conflict_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Conflicted files + per-conflict ours/theirs summary; conflict markers quoted verbatim", paidFallback: "Native read of original conflict hunks"),
        LibrarianFunction(id: "pr_thread_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "gh pr review/comment JSON → unresolved threads {file, line, ask}", paidFallback: "Full gh JSON"),
        LibrarianFunction(id: "chat_thread_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Slack/comment thread JSON → participants, decisions, open questions with spans", paidFallback: "Full thread JSON"),
        LibrarianFunction(id: "help_flags_extract", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "--help/man output → flags and subcommands relevant to question", paidFallback: "Original help text"),
        LibrarianFunction(id: "openapi_digest", safety: .safe, mcp: "rc_pick", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "OpenAPI/GraphQL SDL spec → endpoints/types matching question", paidFallback: "Original spec via jq/native read"),
        LibrarianFunction(id: "db_schema_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "sqlite .schema / SHOW CREATE dump → relevant tables, columns, indexes", paidFallback: "Original schema dump"),
        LibrarianFunction(id: "tabular_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Big CSV/TSV → columns, row count, question-relevant sample rows", paidFallback: "Native read of original ranges"),
        LibrarianFunction(id: "metric_delta", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Two metric handles → per-metric delta table; numbers must be substrings of both sources", paidFallback: "Paid reads both originals"),
        LibrarianFunction(id: "impacted_test_pick", safety: .safe, mcp: "rc_pick", lane: "on_demand", usesLLM: true, runtime: .thirtyFiveBOnly, summary: "Diff handle + test inventory → likely-impacted test ids; never gates CI", paidFallback: "Paid may always run the full suite"),
        LibrarianFunction(id: "thread_title_generate", safety: .safe, mcp: "none", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Host-UI labels (thread titles, tab names) from first turns; UI-only, never injected into paid context", paidFallback: "Heuristic first-line truncation; paid never needed"),
        LibrarianFunction(id: "compiler_diagnostics_extract", safety: .safe, mcp: "rc_extract", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Any compiler/typechecker output (tsc, cargo, go, javac, swiftc) → {file, line, severity, message}", paidFallback: "Original build output"),
        LibrarianFunction(id: "bundler_build_digest", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "webpack/vite/next build output → errors, warnings, emitted sizes", paidFallback: "Original"),
        LibrarianFunction(id: "snapshot_diff_digest", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "Snapshot-test failure diffs → minimal changed-subtree summary", paidFallback: "Original snapshot diff"),
        LibrarianFunction(id: "pkg_install_digest", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "brew/apt/npm install and upgrade logs → installed versions + warnings/errors", paidFallback: "Original"),
        LibrarianFunction(id: "http_response_digest", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "curl/httpie output → status, key headers, body digest relevant to question", paidFallback: "Original response"),
        LibrarianFunction(id: "process_snapshot_digest", safety: .safe, mcp: "rc_compress", lane: "hot", usesLLM: true, runtime: .hot17bE4b, summary: "ps/lsof/netstat snapshots → entries matching question (orphans, sockets, ports)", paidFallback: "Original snapshot"),
        LibrarianFunction(id: "sanitizer_report_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "ASan/TSan/UBSan report → leak/race class + key frames", paidFallback: "Original report"),
        LibrarianFunction(id: "syscall_trace_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "strace/dtruss/fs_usage trace → files/sockets touched + error syscalls relevant to question", paidFallback: "Original trace handle"),
        LibrarianFunction(id: "debugger_output_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "lldb/gdb session output → relevant frames, variables, breakpoint hits", paidFallback: "Original debugger output"),
        LibrarianFunction(id: "memory_report_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "vmmap/leaks/footprint output → top regions and allocations relevant to question", paidFallback: "Original report"),
        LibrarianFunction(id: "binary_inspect_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "nm/otool/objdump/strings output → symbols and sections matching question", paidFallback: "Original dump"),
        LibrarianFunction(id: "lighthouse_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Lighthouse/axe JSON → scores + top violations grouped", paidFallback: "Original JSON"),
        LibrarianFunction(id: "vuln_scan_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "npm audit/trivy/grype JSON → {package, severity, fixedIn} grouped", paidFallback: "Original scan JSON"),
        LibrarianFunction(id: "pbxproj_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Xcode .pbxproj → targets, phases, build settings relevant to question", paidFallback: "Native read of original ranges"),
        LibrarianFunction(id: "codesign_notarize_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "codesign/notarytool/stapler output → identity, entitlements, errors", paidFallback: "Original output"),
        LibrarianFunction(id: "gitlab_api_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "glab/GitLab API JSON (MRs, pipelines, discussions) → unresolved threads + failed jobs", paidFallback: "Full GitLab JSON"),
        LibrarianFunction(id: "email_thread_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Email chains (.eml/mbox/M365 JSON) → participants, latest ask, decisions; quote-chain deduped", paidFallback: "Full thread"),
        LibrarianFunction(id: "meeting_transcript_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Meeting transcript → decisions, action items, owners, with spans", paidFallback: "Full transcript handle"),
        LibrarianFunction(id: "changelog_range_extract", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "CHANGELOG/release notes → entries between two versions", paidFallback: "Full changelog"),
        LibrarianFunction(id: "subagent_outcome_classify", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Subagent output → done/partial/failed/off-task with evidence spans", paidFallback: "Parent reads full child output"),
        LibrarianFunction(id: "pii_presence_flag", safety: .safe, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Heuristic PII detector (emails, names, document numbers) → flag + masked view; keeps customer data out of paid context", paidFallback: "Skip local; original reaches paid only per host masking policy"),
        LibrarianFunction(id: "cross_handle_contradiction_scan", safety: .safe, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .thirtyFiveBOnly, summary: "Find contradicting claims across N handles; both sides quoted as obligatory spans", paidFallback: "Paid reads all handles; unknown → no claim"),
        LibrarianFunction(id: "multi_log_timeline_merge", safety: .safe, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Merge timestamped events across N log handles into one ordered timeline with source tags", paidFallback: "Original logs; deterministic per-log timestamp sort"),
        LibrarianFunction(id: "ui_tree_digest", safety: .safe, mcp: "rc_extract", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Accessibility/DOM tree dumps (browser or computer-use) → elements matching question {role, label, coords}", paidFallback: "Full tree JSON"),
        LibrarianFunction(id: "injection_pattern_flag", safety: .safe, mcp: "none", lane: "hot", usesLLM: false, runtime: .none, summary: "Heuristic prompt-injection detector on fetched/untrusted content → flag + quarantine notice; content stays behind handle until paid opts in", paidFallback: "Paid reads the original knowingly via rc_retrieve; flag is advisory, never censorship"),
        LibrarianFunction(id: "provider_tier_suggest", safety: .safe, mcp: "none", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Suggest the cheapest adequate paid tier/model for a prompt (model-Auto input); UI-surfaced only", paidFallback: "User-selected model always wins; suggestions never silently applied"),
        LibrarianFunction(id: "commit_message_draft", safety: .candidate, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Draft commit message from diff handle", paidFallback: "Paid rewrites or ignores; never auto-git-commit from local text"),
        LibrarianFunction(id: "pr_description_draft", safety: .candidate, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Draft PR body from diff+tests", paidFallback: "Paid rewrites; videos/URLs must be paid-verified"),
        LibrarianFunction(id: "plan_candidate", safety: .candidate, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .thirtyFiveBOnly, summary: "5-step candidate plan, labeled non-authoritative", paidFallback: "Paid must rewrite before acting"),
        LibrarianFunction(id: "review_comment_draft", safety: .candidate, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .thirtyFiveBOnly, summary: "Draft review notes with required citations", paidFallback: "Paid confirms or discards; local is never merge authority"),
        LibrarianFunction(id: "refactor_suggestion_list", safety: .candidate, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .thirtyFiveBOnly, summary: "List possible refactors; do not apply", paidFallback: "Paid implements or ignores"),
        LibrarianFunction(id: "test_plan_draft", safety: .candidate, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .thirtyFiveBOnly, summary: "Suggested test names from a change", paidFallback: "Paid writes tests"),
        LibrarianFunction(id: "i18n_key_diff", safety: .candidate, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Missing translation keys", paidFallback: "Deterministic key set diff"),
        LibrarianFunction(id: "search_query_suggest", safety: .candidate, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Suggest rg/graphify queries for a question; paid chooses and executes", paidFallback: "Paid writes its own queries; suggestions never auto-run"),
        LibrarianFunction(id: "root_cause_hypothesis_draft", safety: .candidate, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .thirtyFiveBOnly, summary: "Ranked failure hypotheses from an error digest, labeled non-authoritative", paidFallback: "Paid diagnoses from originals; must verify before acting"),
        LibrarianFunction(id: "release_notes_draft", safety: .candidate, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Draft release notes from diff/log handles", paidFallback: "Paid rewrites from git log; never auto-publish"),
        LibrarianFunction(id: "i18n_translation_draft", safety: .candidate, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Draft translations for missing resource keys", paidFallback: "Paid reviews/rewrites; never ships unreviewed"),
        LibrarianFunction(id: "issue_triage_draft", safety: .candidate, mcp: "rc_digest", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "Suggest labels/duplicates/severity for a new issue from handles", paidFallback: "Paid confirms; local never writes to the tracker"),
        LibrarianFunction(id: "sql_query_draft", safety: .candidate, mcp: "rc_ask", lane: "on_demand", usesLLM: true, runtime: .nineB, summary: "NL → SQL draft against a schema digest (live-DB triage)", paidFallback: "Paid writes/validates its own SQL; drafts never auto-execute"),
        LibrarianFunction(id: "project_commands", safety: .deterministic, mcp: "rc_extract", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Build/test/run entry points detected in the workspace: SwiftPM, package.json scripts, Makefile targets, Xcode containers, README commands", paidFallback: "Paid inspects the manifests natively"),
        LibrarianFunction(id: "branch_files", safety: .deterministic, mcp: "rc_extract", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Files this branch touches versus a base ref (merge-base + name-status) plus uncommitted changes", paidFallback: "Paid runs git diff natively"),
        LibrarianFunction(id: "symbol_references", safety: .deterministic, mcp: "rc_search", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Workspace references to a symbol with per-file counts and sample lines", paidFallback: "Paid greps natively"),
        LibrarianFunction(id: "test_mapping", safety: .deterministic, mcp: "rc_extract", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Source↔test mapping from shared symbols across test paths", paidFallback: "Paid searches for the tests natively"),
        LibrarianFunction(id: "ownership_lookup", safety: .deterministic, mcp: "rc_extract", lane: "on_demand", usesLLM: false, runtime: .none, summary: "CODEOWNERS rule plus recent authors for a path, rule text quoted", paidFallback: "Paid reads CODEOWNERS and git log"),
        LibrarianFunction(id: "orphan_files", safety: .deterministic, mcp: "rc_digest", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Files no other workspace file references (entry points excluded); candidates only, never a delete list", paidFallback: "Paid audits references natively"),
        LibrarianFunction(id: "call_graph", safety: .deterministic, mcp: "rc_digest", lane: "on_demand", usesLLM: false, runtime: .none, summary: "Lexical callers/callees/definitions of a symbol with file:line evidence", paidFallback: "Paid greps or drives the LSP natively"),
        LibrarianFunction(id: "local_agent_with_tools", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Do not give Ornith shell/FS/web tools", paidFallback: "Paid remains the only agent with tools"),
        LibrarianFunction(id: "apply_patch", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Local model must not apply or emit authoritative patches", paidFallback: "Paid writes via search_replace/write"),
        LibrarianFunction(id: "generate_code_to_ship", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "No shipping code from 9B/35B", paidFallback: "Paid implements"),
        LibrarianFunction(id: "distill_skill_body", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "SKILL.md and skill tool output stay verbatim", paidFallback: "Full skill body"),
        LibrarianFunction(id: "distill_exact_rg", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Never auto-distill rg/grep/cat and listed exact-output tools", paidFallback: "Full match lines; voluntary | distill only when last command is distill"),
        LibrarianFunction(id: "rewrite_system_prompt", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Local must not mutate provider safety/system prompts", paidFallback: "Host-owned prompts"),
        LibrarianFunction(id: "extract_secret_values", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Never return token/password/key values", paidFallback: "Redact; paid uses secret stores"),
        LibrarianFunction(id: "authority_merge", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Local is never merge/review authority", paidFallback: "Paid + human"),
        LibrarianFunction(id: "forward_thinking_trace", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Never put Ornith <think>/reasoning_content into paid context", paidFallback: "Strip; if strip fails, unavailable"),
        LibrarianFunction(id: "web_or_computer_use", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "No network/computer-use from local specialist", paidFallback: "Paid MCP computer-use if admitted"),
        LibrarianFunction(id: "lie_tests_passed", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Must not claim PASS if original lacks it; NLI/faithfulness reject", paidFallback: "Original test output"),
        LibrarianFunction(id: "impersonate_agent_reply", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Local must never author user-facing agent chat replies; host-UI labels only", paidFallback: "Paid authors all replies"),
        LibrarianFunction(id: "auto_run_suggested_commands", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Commands/queries suggested by local text must never auto-execute", paidFallback: "Paid reviews and runs; host executes nothing from local output"),
        LibrarianFunction(id: "exfiltrate_store_content", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Sidecar/store payloads never leave the machine; ledger and telemetry carry counts only", paidFallback: "Store stays local; paid uses its own provider channel"),
        LibrarianFunction(id: "distill_permission_surface", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Permission prompts, approval dialogs and safety warnings are never distilled or rewritten", paidFallback: "Verbatim always"),
        LibrarianFunction(id: "distill_user_prompt", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "User-authored messages are never locally compressed or rewritten before the paid model", paidFallback: "Verbatim user words; paid may quote/condense itself"),
        LibrarianFunction(id: "fabricate_handles", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Never mint or answer for handle IDs that don't exist in scope", paidFallback: "Unknown handle → unavailable; rc_search/rc_stats enumerate real handles"),
        LibrarianFunction(id: "silent_model_downgrade", safety: .forbidden, mcp: "none", lane: "none", usesLLM: true, runtime: .never, summary: "Host/local must never silently change the user-selected paid model or reasoning effort", paidFallback: "Explicit user policy only; UI discloses any routing"),
        LibrarianFunction(id: "overstate_savings_ledger", safety: .forbidden, mcp: "none", lane: "none", usesLLM: false, runtime: .never, summary: "Ledger must never count estimates/caps as measured savings, nor skipped items as saved", paidFallback: "Measured-only headline; estimates labeled separately; skips shown as kept-originals"),
    ]

    public static let byID: [String: LibrarianFunction] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    public static func function(id: String) -> LibrarianFunction? { byID[id] }

    public static var ids: [String] { all.map(\.id) }

    public static var forbiddenIDs: Set<String> {
        Set(all.filter { $0.safety == .forbidden }.map(\.id))
    }

    /// Catalog ops the paid model may call (`rc_ask.op`). Forbidden and
    /// runtime-disabled ids stay out of both discovery and execution.
    public static var implementedIDs: [String] {
        exposedFunctions.map(\.id)
    }

    public static var exposedFunctions: [LibrarianFunction] {
        all.filter {
            $0.safety != .forbidden && !disabledOnNineB.contains($0.id)
        }
    }

    /// Deterministic, local-only catalog lookup. Cursor tokens are opaque,
    /// query-bound continuations; malformed, stale, or cross-query tokens fail
    /// closed instead of silently restarting at page one.
    public static func page(
        query: String?,
        cursor: String?,
        limit: Int
    ) throws -> LibrarianCatalogPage {
        guard (1...20).contains(limit) else {
            throw LibrarianCatalogPageError.invalidLimit
        }

        let normalizedQuery = normalizeQuery(query)
        let matches: [LibrarianFunction]
        if normalizedQuery.isEmpty {
            matches = exposedFunctions
        } else {
            var exact: [LibrarianFunction] = []
            var textual: [LibrarianFunction] = []
            exact.reserveCapacity(exposedFunctions.count)
            textual.reserveCapacity(exposedFunctions.count)
            for fn in exposedFunctions {
                if fn.id.compare(normalizedQuery, options: .caseInsensitive) == .orderedSame {
                    exact.append(fn)
                } else if fn.id.range(of: normalizedQuery, options: .caseInsensitive) != nil
                    || fn.summary.range(of: normalizedQuery, options: .caseInsensitive) != nil {
                    textual.append(fn)
                }
            }
            matches = exact + textual
        }

        let offset: Int
        if let cursor {
            offset = try decodeCursor(cursor, query: normalizedQuery)
            guard offset < matches.count else {
                throw LibrarianCatalogPageError.invalidCursor
            }
        } else {
            offset = 0
        }

        let upperBound = min(offset + limit, matches.count)
        let items = matches[offset..<upperBound].map {
            LibrarianCatalogItem(id: $0.id, summary: $0.summary)
        }
        let nextCursor = upperBound < matches.count
            ? encodeCursor(offset: upperBound, query: normalizedQuery)
            : nil
        return LibrarianCatalogPage(items: items, nextCursor: nextCursor, total: matches.count)
    }

    private static func normalizeQuery(_ query: String?) -> String {
        query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func encodeCursor(offset: Int, query: String) -> String {
        let signature = DistillSHA256.hex("\(version)\u{0}\(query)\u{0}\(offset)").prefix(16)
        let payload = Data("\(offset):\(signature)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "rcc1.\(payload)"
    }

    private static func decodeCursor(_ cursor: String, query: String) throws -> Int {
        guard cursor.hasPrefix("rcc1.") else {
            throw LibrarianCatalogPageError.invalidCursor
        }
        var encoded = String(cursor.dropFirst("rcc1.".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded),
              let payload = String(data: data, encoding: .utf8) else {
            throw LibrarianCatalogPageError.invalidCursor
        }
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let offset = Int(parts[0]),
              offset > 0,
              encodeCursor(offset: offset, query: query) == cursor else {
            throw LibrarianCatalogPageError.invalidCursor
        }
        return offset
    }
}
