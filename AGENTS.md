# RemoteCode macOS Rules

- Browser parity is mandatory: every macOS browser URL change must emit host state so iOS mirrors the same target.
- External URLs, localhost/dev-server URLs, and macOS file URLs must stay synchronized between macOS and iOS.
- Browser target changes on either side must propagate to the paired side, or the control must stay host-driven/read-only.
- Do not add browser behavior that only works on one side without updating the other side in the same change.
- User workflow state must survive closing and reopening RemoteCode. Persist the user's active workspace, panes, selected tabs, browser URLs/titles, surface metadata, agent thread state, and other explicit user choices unless the user intentionally closes/deletes them.

## Token Saver / Distill rules

- Token Saver is the only paid token-economy feature. No Distill dialect injection, `| distill` PATH/wrappers, PostToolUse compression, prompt compression, or SR1 humanize may run while `tokenSaverEnabled` is false.
- Never distill exact-output shell tools: the agent needs full stdout for line slices and matches. Skip `| distill` (and do not PATH-wrap) for raw `rg`/`grep`/`sed`/`awk`/`cat`/`head`/`tail`/`nl`/`cut`/`tr`/`diff`/`jq`/`yq` and `git grep|show|cat-file|blame`. Voluntary `rg … | distill "<question>"` is allowed when the last pipeline command is distill and the agent wants an extractive answer rather than every match line. Prefer distill for noisy builds, tests, logs, large listings, and summary-friendly git/CI output only.
- Graphify is a Token Saver sub-capability. Host preflight, ensure/update, `RC_GRAPHIFY_*` injection, and query-first agent prompts must not run unless `tokenSaverEnabled && graphifyEnabled` (`AppSettings.isGraphifyRuntimeActive`). When Token Saver is off, fail open: no Graphify env, no ensure, no FSEvents watchers, no query-first nudge.
- Token Saver must fail open for provider turns: if the local Distill sidecar is unavailable, over deadline, or rejects output, preserve the original provider input.
- Never introduce Python, Rust, external headroom code, or an HTTP provider proxy for Token Saver. Prefer native Swift, Core ML/MLX, deterministic parsers, and explicit localhost endpoints.
- ONNX Runtime C++ is fallback-only and needs an explicit benchmark/licensing decision before any dependency is added; Core ML/MLX remains the default native path.
- Any lossy or truncating path must store the original before loss and attach a recoverable `[[rc:<handle>]]` marker; final assistant messages must strip unresolved handles before user-facing persistence.
- `distill` CLI subcommands are reserved intentionally. Implement new subcommands explicitly; never let `stats`, `rank`, `wrap`, `retrieve`, or `dsl` fall through as compression prompts.
- Token Saver savings claims must be measured from the local ledger or provider token-usage events, not projected from character counts alone.
- Every Token Saver technique (compression hooks, sandbox network grants, PATH wrappers, ledger recording) must work uniformly across all three providers (Claude, Codex, Grok) and across every run shape: primary/top-level agents, same-provider subagents, and cross-provider nested subagents. Gate on a provider-neutral "Token Saver is admitted for this run" signal (e.g. `RC_TOKEN_SAVER_DISTILL_HINT`), never on a run-kind signal like "is this a subagent" — parent/telemetry identity markers (e.g. `RC_REMOTE_CODE_SUBAGENT_THREAD_ID`) are present on primary runs too and must not be mistaken for a subagent-only gate. Do not scope a fix to one provider or one run kind unless the underlying blocker is genuinely provider- or kind-specific — prove that with evidence before narrowing scope.
- **Per-provider tool-output-rewrite ceiling (verified against each provider's real source, 2026-07-30 — do not re-attempt without new upstream evidence):** Claude's CLI `PostToolUse` hook genuinely replaces tool output via `updatedToolOutput` before the model sees it — this is the only provider where a native hook can compress arbitrary tool output, and it is already wired (`ClaudeRunner.swift`). Codex has a real, full hook engine (`codex-rs/hooks`) with its own `PostToolUse` event, but the event's output schema has no `updatedToolOutput` field, and its dispatcher explicitly rejects the one similar-looking field (`updatedMCPToolOutput`) as unsupported (`codex-rs/hooks/src/engine/output_parser.rs`) — Codex hooks can only block/allow, append `additionalContext`, or notify; they cannot replace output. Grok's `PostToolUse` hook is documented as fully passive — official docs state stdout is ignored for that event. Native Grok/Codex `read_file`/`Read` therefore cannot be rewritten after the fact (`ReadLifecycleMasker` is library-only / default off; `GrokRunner`/`GrokACPClient` register no output-rewrite hook). Grok (and Claude) `PreToolUse` may rewrite wrap-eligible shell `command` to append `| distill "<question>"` via official `updatedInput` — that is command rewrite, not output rewrite; exact-output `rg`/`grep`/`cat`/… stay unpiped. For Codex and Grok, the PATH-command-wrapper catalog (`WrappedCommandCatalog.commands`, `Sources/CoreModel/`) remains the mechanism that actually replaces tool output when the model does not pipe, and is the primary lever for maximizing their savings — keep it as complete as safely possible (matching the categories already endorsed in the voluntary `| distill` prompt hint: package managers, build tools, test runners, linters, containers/IaC), never adding a command that needs byte-exact stdout (see the exact-output rule above). Re-verify this ceiling directly against each provider's current source before ever attempting a Codex/Grok "hook that rewrites output" again — do not assume Claude's design transfers.

## macOS crash / long-running terminal diagnostics

- For reports that RemoteCode closes while a long Claude terminal or Agent run is active, first collect unified logs from the app diagnostics subsystems:
  ```bash
  log stream --style compact --predicate 'subsystem == "io.remotecode.app" || subsystem == "io.remotecode.surfaces" || subsystem == "io.remotecode.agent"'
  ```
- After an unexpected close, capture the recent persisted log window:
  ```bash
  log show --last 30m --style compact --predicate 'process == "RemoteCode" && subsystem BEGINSWITH "io.remotecode"'
  ```
- Check for crash reports before guessing root cause:
  ```bash
  ls -lt ~/Library/Logs/DiagnosticReports/*RemoteCode* | head
  ```
- Also check for stale Claude provider processes. Orphaned `ClaudeAgentSDKBridge.mjs` and Claude SDK child processes can accumulate across app sessions and create memory pressure:
  ```bash
  ps -axo pid,ppid,rss,etime,args | awk '/ClaudeAgentSDKBridge\\.mjs|claude --output-format stream-json|claude --dangerously-skip-permissions/ && !/awk/ {print}'
  ```
- Useful log events added for this class of issue: `app.heartbeat`, `app.will_terminate`, `terminal.spawned`, `terminal.output_health`, `terminal.pty_eof`, `terminal.dead`, and `terminal.close`. These intentionally log IDs, PIDs, counts, RSS, statuses, and byte totals, not terminal contents or secrets.
