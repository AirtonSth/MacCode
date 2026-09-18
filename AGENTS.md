# RemoteCode macOS Rules

- Browser parity is mandatory: every macOS browser URL change must emit host state so iOS mirrors the same target.
- External URLs, localhost/dev-server URLs, and macOS file URLs must stay synchronized between macOS and iOS.
- Browser target changes on either side must propagate to the paired side, or the control must stay host-driven/read-only.
- Do not add browser behavior that only works on one side without updating the other side in the same change.
- User workflow state must survive closing and reopening RemoteCode. Persist the user's active workspace, panes, selected tabs, browser URLs/titles, surface metadata, agent thread state, and other explicit user choices unless the user intentionally closes/deletes them.

## Privilege escalation (mandatory)

- Use the single installed root-owned helper at `/Library/PrivilegedHelperTools/io.remotecode.RunAsUserHelper`. Its first install may show one administrator dialog; it remains available after RemoteCode closes and reopens.
- The password is never persisted or stored. Provider run-as-user, Insomnia `pmset`, scheduled tasks, and provider teardown are the four consumers; all privilege escalation for them must call `RunAsUserProcessBootstrap`.
- Do not use direct `sudo`, AppleScript administrator authorization, sudoers edits, or password files. The bootstrap installer is the only in-app `sudo` exception, and it must verify the helper owner, mode, and version before reuse.

## Loading and perceived performance (mandatory)

Apply these rules to every user-visible load on macOS: navigation, tabs, rows, lists, details, search, reconnect, hydration, refresh, restore, and provider-backed content.

- Acknowledge the user's intent immediately. Publish the selected destination, identity, and safe cached/local state before database, network, Docker, provider, transcript, inspector, or other freshness work. Target first feedback within 100 ms and zero unacknowledged dead time.
- Mount the destination on the interaction turn. Do not put navigation-boundary animations, blocking overlays, or duplicate synchronous reloads in front of the first useful frame. Preserve local motion only when it does not delay acknowledgement, and respect reduced motion.
- Run freshness after the initial state commit, in one coalesced asynchronous pass. `Task.yield()` is only a next-executor-turn boundary, not proof that a frame painted; use an actual render/frame barrier when correctness requires post-paint work.
- Make deferred work latest-wins and destination-safe: use cancellation plus a monotonic generation/request identity, check the current destination/selection before every visible effect, and let only the task that owns a handle clear it. A stale task must never overwrite newer state or clear newer work.
- Cache-first must remain honest. Never show another workspace/bot/thread's data, never present consequential stale data as fresh, never fake progress or success, and never suppress errors. If no safe cache exists, use a layout-stable placeholder or real progress appropriate to the latency.
- Preserve exact behavior while deferring work: persistence, canonical events, read/attention state, routing, queued follow-ups, error surfaces, and other required side effects must still occur exactly once for the winning request.
- Every loading-performance change needs regression coverage for the immediate path, eventual exact completion, rapid A→B races/stale-result rejection, and failure behavior. Performance claims require comparable before/after measurements on the same environment and workload, at least five warmed samples, and no settled-latency regression beyond `max(25 ms, 5%)`.

## Isolated sandbox (mandatory)

The user's running RemoteCode (`io.remotecode.desktop`) is off-limits. A git worktree isolates files; it does not isolate bundle id, Application Support, SQLite, port `18217`, or `/tmp/RemoteCode.sock`.

- Create/enter a linked worktree, then edit, build, and test only there: `cd "$(scripts/isolated-sandbox.sh ensure)"`
- Prove with `scripts/isolated-sandbox.sh test` (optional `--filter …`). Launch a second GUI only via `scripts/isolated-sandbox.sh run`.
- Never `pkill -x RemoteCode`. Never `osascript` quit `io.remotecode.desktop`. Never `scripts/run-app.sh` (it packages the stable bundle id and quits the host). `script/build_and_run.sh` launches the debug sandbox app via `scripts/isolated-sandbox.sh`.
- Do not install or overwrite `~/.local/bin/distill` from the sandbox. Leave Token Saver off on the debug instance.
- Identity, ports, and App Support live in `scripts/isolated-sandbox.sh`. Ritual: `.grok/skills/isolated-sandbox/SKILL.md`.

## macOS UI automation lease (mandatory)

- macOS event posting is host-global even when a harness targets an app PID. Run every
  macos-harness or Computer Use session through `scripts/macos-ui-lease.sh -- ...`; its shared
  `/tmp/remotecode-macos-ui-lease.lock` is single-flight across all worktrees.
- This is a cooperative repository guard, not an OS-enforced sandbox: a raw external
  Computer Use client can bypass it. Therefore the default acceptance path uses read-only
  macos-harness only; do not run input-capable Computer Use in parallel with a user's session.
  If another agent cannot honor the lease, stop the UI E2E rather than competing for HID.
- The lease is read-only by default and rejects input-producing snippets. Use `--allow-input`
  only for one bounded, reversible E2E that must click, type, press keys, scroll, drag, or run
  AppleScript. Prefer `see`/`state` and targeted AX actions.
- Target the exact debug bundle ID `io.remotecode.desktop.debug`, then exit the session. Never
  target stable RemoteCode or leave SkyComputerUseService, `node_repl`, or Computer Use MCP
  daemons running; never use a persistent harness `repl`.

## Shared components

- Reusing components is welcome and encouraged when it is done well. If two surfaces already show the same control (composer chips, popovers, bubbles, live-turn chrome, queued header), extract one component and mount it from both. Do not copy a second SwiftUI implementation just because the caller lives in another file.
- "Well done" means the shared type owns the real look, copy, a11y, and behavior — not a lookalike fork, and not a wrapper that still paints its own capsule. Different products stay different (Desk editor placeholder, workspace-less Local execution, bot @mentions). Same control must stay one component.

## Token Saver / Distill rules

- **CRITICAL — Estimated save must never go down.** The user-facing Estimated save / thread-savings figure is a one-way ratchet. New Token Saver features or capabilities must **add** a positive leg (or leave the number unchanged). They must **never** lower the original calculation: no new caps, no smaller multipliers, no day-scoping that replaces permanent thread amort, no dropping cache/dialect/graphify/orchestration legs, no switching the chip from permanent `runs` to a short painted timeline. Forbidden examples that already shipped and must not return: capping amort at `todayMeasured × 200` (painted 2.6M instead of the lifetime stack), capping extra turns at `min(runs − 1, 50)`, scaling dialect/Graphify down by 4× measured or 12% billed, capping Week to avoid “fantasy,” using only visible timeline turns instead of `token_saver_thread_totals.runs`, dropping PATH-wrapper savings that arrived without `RC_TOKEN_SAVER_THREAD_ID`. Wraps must attribute `RC_TOKEN_SAVER_THREAD_ID` or fall back to `RC_REMOTE_CODE_SUBAGENT_THREAD_ID`; leftover empty thread ids still amortize in the unscoped bucket. Token Saver **off** still reports 0 — that is the feature being off, not a formula reduction. Prove any savings-math change with a test that the same ledger inputs produce a total **≥** the previous formula.

### Token Saver counting algorithm (do not silently rewrite)

This is the product contract for the paying customer. The headline is a **counterfactual vs a bare agent** (no Distill pipes, no dialect, no Graphify, no Auto, full tool re-reads every later turn). It is labeled Estimated save. It is **not** an Anthropic/OpenAI invoice line and must not be relabeled as billed-only to shrink the number.

**Ledger (measured floor).** Every delivered Distill replacement records `saved = TokenEstimator(original) − TokenEstimator(compressed)` on `token_saver_savings` with `delivered = 1`. Fail-open / verbatim / discarded-no-handle rows are `delivered = 0` and do not raise the thread chip. Permanent per-thread totals live in `token_saver_thread_totals` (`saved_tokens`, `runs`). PATH wraps and hooks must stamp `RC_TOKEN_SAVER_THREAD_ID`, else `RC_REMOTE_CODE_SUBAGENT_THREAD_ID`. Empty thread ids normalize to the `unscoped` bucket so they still amortize. Exact-output tools (`rg`, `cat`, …) and Distill fail-open do not save — they are zeros, not hidden positives.

**Granted estimate (`TokenSaverBareUserEstimator`, formula `credible_v10`).** When Token Saver is on:

```
totalCredible = measuredPipes
              + dialect
              + graphify
              + cacheAmortization
              + orchestration
```

- **dialect** = outputTokens × (`dialectVerbosityMultiplier` − 1). Output tokens are `max(billed × outputShare, assistantChars / 4)` when billed units are known. Default output share is 0.007 (live share only after ≥ 8 stream samples). Grant the raw dialect. Do not scale it down by 4× measured or 12% of billed.
- **graphify** (only if Graphify is runtime-active **and** the window has signals **and** billed is known) = `max(shareModel, avoidedExploration)` when answer tokens exist, else shareModel. Share intensity is `signalCount / 40` and is **not** clipped at 1.0. Do not take `min(share, avoided)` — that zeroed the leg. No signals → 0, not a preference-on invention.
- **cacheAmortization** per thread = `permanentSaved × max(0, runs − 1)`, or `0.1 × cacheReadInputTokens` when that floor is larger. Extra turns are **never** capped (not 8, not 50). Today/Week sum this across threads that delivered in the window, using **permanent** `token_saver_thread_totals`, including `unscoped`. Do not substitute painted timeline turns, day-only SUM, or `todayMeasured × 200`.
- **orchestration** = `0.25 × measured` when Auto is active on that surface. Footer includes it when Auto is on. Do not delete the leg.

When Token Saver is **off**, estimate legs are 0. Measured rows may exist in the DB; the UI still reports 0 saved because the feature is deactivated.

**Adding a capability** (new Distill mode, Graphify phase, cache signal, wrap catalog entry, provider) may only add a non-negative leg or leave totals unchanged for the same ledger inputs. Bump `TokenSaverDailyEconomyRepository.formulaVersion` when the stack changes so Week does not mix formulas. A new version must not produce a smaller total for the same inputs; prove that with a test.

### Token Saver display (do not hide or shrink)

- **Thread footer** (`AgentChatTokenSaverThreadFooter`) always shows after a finished Agent App / Bot Desk turn. Pending thread-switch snapshots stay nil (not a red flash). Off → red, copy `Token Saver: 0 tokens saved because Token Saver is deactivated`. On with measured 0 → yellow, copy `Token Saver: 0 tokens saved because something went wrong` (do not invent a green total from assistant text). On with measured > 0 → green, amount is `max(measured, totalCredible)` with copy `Token Saver: {N} tokens saved (tool output, shorter answers, multi-turn cache)` plus the Auto note when routing is on. English product copy; do not translate the chip.
- **Today Estimated save** is the current-formula `total_credible` for today: day's measured pipes + dialect/graphify + **uncapped permanent-thread cache amort** (and unscoped). It must be allowed to exceed any historical day-measured cap. The sidebar provider split uses the same uncapped amort.
- **Week** is Σ current-formula daily `total_credible` (stale-formula days fall back to measured pipes until recompute, never to a smaller invented cap).
- Do not hide the footer when Token Saver is off or when measured is 0. Do not show another thread's savings. Do not paint Distill success when Distill failed open.

Canonical code: `TokenSaverBareUserEstimator`, `TokenSaverSavingsRepository`, `TokenSaverDailyEconomyRepository`, `AgentAppView.tokenSaverThreadFooter*`, `TokenSaverThreadFooterReload`. Tests that lock this contract include `test_estimatedSavePath_neverCapsAmortAgainstDayMeasured`, `test_cacheAmortization_scalesWithTurnsUncapped`, `test_dialectAndGraphify_areGrantedRawWithoutUsageCeiling`, `test_deliveredRecordWithoutThreadId_amortizesInUnscopedBucket`.

- Token Saver is the only paid token-economy feature. No Distill dialect injection, `| distill` PATH/wrappers, PostToolUse compression, prompt compression, or SR1 humanize may run while `tokenSaverEnabled` is false.
- Never distill exact-output shell tools: the agent needs full stdout for line slices and matches. Skip `| distill` (and do not PATH-wrap) for raw `rg`/`grep`/`sed`/`awk`/`cat`/`head`/`tail`/`nl`/`cut`/`tr`/`diff`/`jq`/`yq` and `git grep|show|cat-file|blame`. Voluntary `rg … | distill "<question>"` is allowed when the last pipeline command is distill and the agent wants an extractive answer rather than every match line. Prefer distill for noisy builds, tests, logs, large listings, and summary-friendly git/CI output only.
- Graphify is a Token Saver sub-capability. Host preflight, ensure/update, `RC_GRAPHIFY_*` injection, and query-first agent prompts must not run unless `tokenSaverEnabled && graphifyEnabled` (`AppSettings.isGraphifyRuntimeActive`). When Token Saver is off, fail open: no Graphify env, no ensure, no FSEvents watchers, no query-first nudge.
- Token Saver must fail open for provider turns: if the local Distill sidecar is unavailable, over deadline, or rejects output, preserve the original provider input.
- Never introduce Python, Rust, external headroom code, or an HTTP provider proxy for Token Saver. Prefer native Swift, Core ML/MLX, deterministic parsers, and explicit localhost endpoints.
- ONNX Runtime C++ is fallback-only and needs an explicit benchmark/licensing decision before any dependency is added; Core ML/MLX remains the default native path.
- Any lossy or truncating path must store the original before loss and attach a recoverable `[[rc:<handle>]]` marker; final assistant messages must strip unresolved handles before user-facing persistence.
- `distill` CLI subcommands are reserved intentionally. Implement new subcommands explicitly; never let `stats`, `rank`, `wrap`, `retrieve`, or `dsl` fall through as compression prompts.
- Distill **ledger rows** must be measured from TokenEstimator deltas or provider token-usage events, not raw character counts passed off as tokens. That honesty rule is the **measured floor**. It does not authorize stripping dialect / Graphify / cache amort / orchestration from Estimated save — those granted legs are defined in the counting algorithm section above.
- Every Token Saver technique (compression hooks, sandbox network grants, PATH wrappers, ledger recording) must work uniformly across all three providers (Claude, Codex, Grok) and across every run shape: primary/top-level agents, same-provider subagents, and cross-provider nested subagents. Gate on a provider-neutral "Token Saver is admitted for this run" signal (e.g. `RC_TOKEN_SAVER_DISTILL_HINT`), never on a run-kind signal like "is this a subagent" — parent/telemetry identity markers (e.g. `RC_REMOTE_CODE_SUBAGENT_THREAD_ID`) are present on primary runs too and must not be mistaken for a subagent-only gate. Do not scope a fix to one provider or one run kind unless the underlying blocker is genuinely provider- or kind-specific — prove that with evidence before narrowing scope.
- **Per-provider tool-output-rewrite ceiling (re-verified 2026-09-17 against the installed binaries; do not re-attempt without new upstream evidence):** Claude's CLI `PostToolUse` hook genuinely replaces tool output via `updatedToolOutput` before the model sees it, and it is wired in `ClaudeRunner.swift`. **Grok ≥ 1.0.34 (build 2026-09-16) also replaces built-in tool output from a settings-file `PostToolUse` hook** via `updatedToolOutput`, validated against the ran tool's serialized output shape (`{"type":"ReadFile","FileContent":{…}}`, `ListDir`, `WebFetch`); MCP tool output passes through un-checked, the replacement cap is 64K characters, and mismatch keeps the original. Hooks registered through the grok-agent-sdk can only add `additionalContext`, so the replacement hook must stay a `$GROK_HOME/hooks/*.json` settings-file hook — that lane is wired in `AgentSkillInstaller.installGrokPostToolUseHook`, and only shapes verified end to end may be added to `ManagedDistillCLI.grokReplaceableShapes` (shell `Bash`, search `GrepSearch`, and mutation `EditsApplied` results still fail open). Codex 0.154.0 remains the only provider that cannot rewrite tool output: its `PostToolUseHookSpecificOutputWire` carries only `hookEventName` / `additionalContext` / `updatedMCPToolOutput`, and the dispatcher rejects `updatedMCPToolOutput` as unsupported — so for Codex the PATH-command-wrapper catalog (`WrappedCommandCatalog.commands`, `Sources/CoreModel/`) and the PreToolUse `updatedInput` command rewrite remain the levers that actually replace tool output. Keep the wrapper catalog as complete as safely possible (matching the categories already endorsed in the voluntary `| distill` prompt hint: package managers, build tools, test runners, linters, containers/IaC), never adding a command that needs byte-exact stdout (see the exact-output rule above). Re-verify each provider's ceiling directly against its current binary before adding a new rewrite lane.

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
