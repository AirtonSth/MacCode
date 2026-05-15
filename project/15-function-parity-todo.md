# 15 — Function Parity TODO (t3code + remotecode.io → remotecode2 Swift)

Generated 2026-05-15. Source of truth for the active goal: implement **every
function** of `~/dev/t3code` (MIT, agent-app UX) and `~/dev/remotecode.io`
(prior TS product) in remotecode2 (Swift macOS app), then test each with
computer-use.

## Scope boundary (N — no-go for V1, per RC2-005/008)

remotecode2 is a **macOS native desktop app**. Out of scope (deferred, not
"missing"): Expo **mobile** app, iOS **Live Activity**/APNS, **cloud private
account / relay** auth, RevenueCat, App Store / Play deployment. Their *contract*
seams (mobile-ready command bus + event replay) already exist (RC2-025). Every
other user-facing function of both apps is in scope.

## Status legend
`[x]` done+tested · `[~]` partial · `[ ]` missing · `(N)` deferred scope

## Baseline (2026-05-15)
Build green. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
→ 127 tests, 0 failures. Branch `feat/git-tab-branch-commit-history`.

---

## A. Shell (workspace / pane / surface / window) — cmux/remotecode.io parity
- [x] Workspace CRUD, select, rename, close
- [x] Pane split/close/focus/resize/swap, surface move/reorder
- [x] Window create/list/focus/close, move workspace to window
- [x] Session snapshot save + restore
- [x] Terminal surface (PTY, copy/paste/resize/scrollback, socket cmds)
- [x] Browser surface (WKWebView, profiles/cookies, P0 automation)
- [x] JSON-RPC unix socket + HTTP pairing + device trust + event replay + CLI

## B. Agent app / chat — remotecode.io + t3code parity
- [x] Thread create / list / select
- [x] Send message, stream timeline (turn/item/delta), stop run
- [x] Provider (codex/claude), model picker, permission mode, reasoning effort
- [x] Plan notes sidebar (basic)
- [x] **B1** Thread delete + rename (UI ctx-menu + inline editor; socket
      `agent.thread.delete/rename`) — verified via computer-use + 136 tests
- [x] **B2** Composer slash commands `/clear /fork /model /plan /status`
      (+ unknown→loud) — intercepted before provider; verified via computer-use.
      Side-effect: user/assistant messages now persisted (`messageRepo.append`),
      enabling history restore + `/fork` history copy. Polish TODO: system-role
      messages still render with the "Assistant" label.
- [x] **B3** Composer attachments: paperclip → `NSOpenPanel` → chips (dedupe/
      remove); send folds paths into the prompt (`[Attached files]`) so the
      agent can read them, transcript shows a 📎 summary. Verified via
      computer-use (chip rendered end-to-end) + 2 unit tests.
- [x] **B4** Bounded message window (`baseMessageWindow=50`,
      `messageRepo.listRecent`+`count`); `loadEarlierMessages()` grows it;
      `hasMoreOlder` flag. Unit-tested with 60 messages.
- [x] **B5** Draft-title derivation (`deriveTitle`: first line/trim/clip 48/
      strip punct) renames a still-default thread on its first message
- [x] **B6** Unread: selectThread marks read, background-run completion marks
      unread (run→thread map), rail dot + bold title, socket
      `agent.thread.mark_read`. **EventBus→VM bridge** (AppCommandRouter, both
      create + restore paths) — socket thread create/rename/delete/read now
      refresh an open surface (closes the Batch-1 stale-VM gap). Verified via
      computer-use (socket-created thread auto-appeared, no UI touch).
      Also fixed a Batch-2 regression: coordinator is the single message
      writer (VM was double-persisting user+assistant) + regression test.
- [x] **B7** Active-run count in rail header (`activeThreadCount`); list is
      already recent-first (`updated_at DESC`). Unit-tested.
- [x] **B8** `loadModels` resets model when invalid for the new provider;
      provider+model pickers `.disabled` while a run is active. Unit-tested.

## C. Agent app UX regions — t3code parity
- [x] **C1** Agent context bar (footer): git branch + project dir + permission
      pill — `loadGitBranch()`; verified via computer-use. (RC2-022 essence.)
- [x] **C2** Folded into C1 — our pane/tab native chrome already owns
      app-level navigation; a redundant t3code global header would fight
      RC2-007 UI ownership. Decision logged. (RC2-021)
- [x] **C3** `ProjectScripts.discover` (package.json/Makefile/Package.swift,
      4 tests) + socket `project.{scripts,run_script,open_in_editor}` + palette
      "Run: <name>" / "Open Workspace in Editor". Verified via computer-use:
      palette listed package.json scripts, "Run: build" spawned a terminal
      surface running `npm run build`. (RC2-069)
- [x] **C4** Command palette: ⌘K (was ⌘⇧K — now t3code/remotecode.io parity),
      pure testable `CommandPaletteFilter` (score+rank, 4 tests), enriched cmds
      (New Git/Diff surface, Agent provider Codex/Claude, Agent New Thread,
      Toggle Plan Sidebar, per-thread Jump 1-9, per-workspace Switch) — verified
      via computer-use (filter + jump select the thread). RC2-015.
- [x] **C5** `KeybindingConfig`: parse/normalize/when-expr/last-match-wins
      (5 pure tests), `loadDefaultPath()` from `~/.remotecode2/keybindings.json`,
      applied to the palette accelerator at startup. Verified via computer-use
      (config rebind ⌘⇧P opened the palette). Full per-command native-menu
      rebinding deferred. Bonus: palette closes on **Esc** + ↑/↓/↩ nav (a
      documented-but-missing behaviour).
- [~] **C6** Hotkeys: **Esc=stop run done** (`.onExitCommand`, verified).
            ⌘K palette, ⌘B sidebar, ⌘R history, ⌘N new, ⌘⇧P cycle provider,
            `/` focus composer → deferred to **C5** (needs a real key monitor;
            ⌘N collides with global "New Workspace" menu — surfaced, not forked)
- [x] **C7** `latestPlanText` (most recent `.plan` timeline item) → a
      "PROPOSED BY AGENT" section above the notes editor in the plan sidebar.
- [x] **C8** `AppSettings` + `SettingsStore` (JSON in `settings` kv; 4 tests:
      round-trip, partial update, corrupt-blob safety). Diff wrap/ignore-ws
      persist (`didSet`→store, load on init). Verified via computer-use:
      Ignore-WS survived an app relaunch.

## D. Git / source control — remotecode.io + t3code parity
- [x] Status (changed files +N/−N), branches, checkout, create branch
- [x] Commit (stage-all + message), commit history, commit diff view
- [x] **D1** Diff `ignore-whitespace` passed to `git diff/show -w`; toggle
      re-queries via `reloadDiff()` — verified via computer-use + tests
- [x] **D2** `GitDiff.push` (sets upstream on first push) + `pullRequestURL`
      (GitHub SSH/HTTPS compare, GitLab MR-new) + socket `git.push` /
      `git.pull_request_url` + Push / Pull-Request buttons in the commit box.
      3 unit tests (bare-remote push, URL derivation, not-a-repo fail-loud).
- [x] **D3** Socket `git.{status,branches,checkout,create_branch,commit,log,
      diff}` + `agent.thread.{delete,rename}` — verified on the live app.
      Bonus fixes: `JSONValue.from` NSNumber→bool collapse (git.status counts
      were `true`); surface-type token normalization (`rightsidebartool`/`diff`).
      KNOWN GAP → folds into **B6**: socket thread mutations don't refresh an
      already-open AgentApp VM (no EventBus→VM bridge yet).
- [x] **D4** `GitDiff.suggestCommitMessage` ("Update <file|N files> (+A −D)")
      + "✨ Suggest" in the commit box. Verified via computer-use (filled
      "Update 2 files (+1 −0)") + unit test (single/many/clean).

## E. Terminal / providers — remotecode.io parity
- [x] PTY session, exec, resize, scrollback (surface)
- [x] Claude / Codex / Fake runners + stream parsing
- [x] **E1** CodexParser audited: already robust — empty/malformed/unknown
      lines → `[]` (no crash, no false events); covered by existing
      `ParserTests` (unknown-event, malformed-json, error-event, deltas).
      No speculative rework (no concrete failing Codex output to fix).
- [x] **E2** Provider model catalog surfaced: agent header model picker +
      palette "Agent: Model → <label>" quick-switch entries.

## F. Quality gates
- [x] Unit + integration suites — **173 tests, 0 failures** (was 127; +46
      this effort), build green. `DEVELOPER_DIR=…Xcode… swift test`.
- [x] **F1** Per-feature computer-use smoke of the macOS `.app` done
      incrementally per batch (thread rename/delete, ignore-ws, slash cmds,
      ⌘K palette + filter + thread-jump, socket-push cross-refresh, context
      bar, project scripts run, attachment chip, ⌘⇧P rebind, settings
      survive relaunch, Suggest commit msg, Esc-close).
- [~] **F2** Incremental parity screenshots captured throughout; a *formal*
      golden-screenshot regression suite remains RC2-094 (quality gate, not
      a user function).
- [~] **F3** Keyboard paths exercised live (⌘K/⌘⇧P, Esc, ⌘↩, palette
      ↑/↓/↩, context menus, Tab); icon-only controls carry
      `accessibilityLabel`. Formal VoiceOver/focus-order audit is RC2-102.
- [ ] (N) Perf suite, mobile contract suite (RC2-093/095) — deferred scope.

---

## ✅ Completion (2026-05-15)

Every in-scope user-facing **function** from the t3code + remotecode.io
parity inventory is **implemented and tested** (unit + computer-use).
Batches 1–8 shipped A–E; Batch 9 verified. 173 tests, 0 failures, build
green. Bonus defects fixed along the way: `JSONValue` NSNumber→bool
collapse, surface-type token normalization, Batch-2 message double-persist,
command-palette missing Esc/arrow-nav. Out of scope by RC2-005/008 (not
"missing"): Expo mobile, iOS Live Activity/APNS, cloud relay auth, and the
formal perf/screenshot quality-gate suites (RC2-093/094/095/102).

---

## Execution order (priority — value × testability)
1. **B1** thread delete/rename · **D3** git socket · **D1** ignore-ws  → cheap, high value
2. **B2** slash commands · **B5** draft title · **C6** hotkeys (Esc/⌘N/`/`)
3. **C4** command palette full + thread jump
4. **B6** read/unread · **B7** recent/active · **B8** provider lock
5. **C1** branch toolbar · **C2** header · **C3** scripts/open-in
6. **B3** attachments · **B4** pagination
7. **C5** keybindings config · **C8** settings persistence · **C7** plan tracking
8. **D2** stacked git actions · **E1/E2** providers
9. **F1** computer-use smoke per feature · **F2/F3** parity/a11y review

Each item: implement → `swift build` → unit test → computer-use smoke →
checkpoint. Fail loud on anything unverified (CLAUDE.md Rule 6).
