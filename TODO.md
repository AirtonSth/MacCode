# Bots plan-loop TODO

Inventory: 2026-08-15T18:08-03:00 on `bots` @ e7acac15, worktree `dist/RemoteCode.app` pid 40635 window 38895 title **Bots**.
Compared plan-bots `index.html` (P1a) + assets (`bots-home.png`, `bot-studio.png`, `bot-desk.png`) + runtime (Fleet, Studio, Desk, Memory/Routines/Brain, Attention, roster). Did not touch Codex CUA or `/tmp/remotecode-rcw1-e2e-*`.

## Open

- [ ] inspector-drafts Inspector memory/skill/routine field drafts are process-wide and leak across bots — evidence: typed `only-new-agent-2-memory-draft-1805` on New Agent (@new-agent-2) Studio Memory; Batatilson Desk Memory showed the same unsent text; Batatilson Studio Skills still held leftover `weekly-account-health`. Code: `BotsViewModel.memoryDraft` / `skillDraft` / `routineName` / `routinePrompt` / `routineScheduleNote` are single fields, not keyed by BotID (unlike composer drafts). — seen: 2026-08-15

## Done

- [x] Brain Inspector P1a (Source vs Effective, context receipts) still unshipped vs plan-bots — evidence: loop leftover after persist-switcher fire — seen: 2026-08-15 — done: 3414e347
- [x] Live Desk still duplicates some historical assistant bubbles — evidence: prior Desk isolation/order fires left residual dups on Batatilson — seen: 2026-08-15 — done: 0550e618
- [x] Shell destination (Bots vs workspace) does not persist across app restart — evidence: MR !255 limitations; clicking Bots after relaunch is not the last dest — seen: 2026-08-15 — done: e7acac15
- [x] Desk composer was process-wide so an unsent line leaked onto the next bot — evidence: prior fire — seen: 2026-08-15 — done: 448d1b5f

## Out of scope (not open P1)

- Honesty Desktop stays: **Same macOS account; not isolated. Not a dedicated Desktop.** Studio Desktop tab labels VM/remote **Not shipped**. Observed on Batatilson Studio Desktop and every Desk/Fleet pane.
- P1b approval policy / Allow once / Deny — Security tab is explicitly read-only until P1b.
- P2 dedicated VM Desktop and remote Mac — gated, unlabeled as real.
- P3 app-closed routines, @mention collaboration preflight, handoff — Routines honesty: “Test runs are real work. App-closed schedules stay off until autonomy is enabled.”
- P4 iOS Fleet/Desk — separate plan; not this macOS fire.
- Retrieval scores, candidate approve/reject, captured per-adapter golden fixture file — still out of this P1a slice (unchanged).

## Runtime notes (not new work)

- Fleet Home, Studio (Profile/Brain/Memory/Skills/Routines/Security/Desktop), Desk chat, Attention empty state, and roster all match the P1a slice. Fallback order labeled “not shipped in P1a.”
- Desk isolation held: Batatilson has `one-bubble`; New Agent (@new-agent-2) has `pong` / `Olá` only.
- Brain Inspector Last call on New Agent showed receipt for `Olá` (payload digest present).
