# Bots plan-loop TODO

Inventory: 2026-08-15T19:08-03:00 on `bots` @ 34a3f4b8, worktree `dist/RemoteCode.app` pid 81506 window 39072 title **Bots**.
Compared plan-bots `index.html` (P1a + Desktop table) + assets (`bots-home.png`, `bot-studio.png`, `bot-desk.png`) + live walk (Fleet Home, Studio Profile/Brain/Memory/Routines/Desktop, Desk + Brain/Memory/Routines inspector). Did not touch Codex CUA or `/tmp/remotecode-rcw1-e2e-*`.

Product intent this loop: ship remaining P1a-honest work **including Dedicated local VM Desktop as a real selectable option** (smallest honest slice if a full hypervisor cannot land). Remove Managed remote Mac from Studio/options/copy/enums exposed in UI. Do not invent P3 app-closed or P4 iOS as shipped.

## Open

- [ ] dedicated-local-vm Dedicated local VM Desktop is not a real selectable option — evidence: New Agent (@new-agent-2) Studio Desktop and Profile rail show **Dedicated local VM Desktop · Not shipped** (disabled); Settings toggle caption is still “Not shipped”; `BotsViewModel.desktopHonestyLabel` is hardcoded to `logicalExecutionSpaceHonestyLabel`; `resolvedDesktopKind` falls back unless `botsDesktopVMEnabled`. Fleet/Desk still paint only the purple “Logical execution space” card. Product intent: ship the smallest honest working slice (create / select / persist kind, honesty that matches what actually runs). No Take over / Isolated network / app-closed / “Active now in macOS VM” lies. Leave leftover hypervisor work open if the full guest cannot land in one fire. — seen: 2026-08-15

- [ ] hide-remote-mac Managed remote Mac Desktop is still advertised — evidence: Studio Profile rail + Studio Desktop tab show **Managed remote Mac Desktop · Not shipped**; Settings has a “Managed remote Mac Desktop” toggle; `BotDesktopKind.managedRemoteMac` honesty/copy and UI enums expose it. Product intent: remove it from Studio/options/copy/enums exposed in UI. Do not advertise it. — seen: 2026-08-15

- [ ] dedicated-local-vm-runtime Leftover after the select/persist slice: a real dedicated guest (Virtualization.framework or equivalent), not a fake screenshot of a VM. Start/stop, persist the VM identity with the Bot, honest running/stopped copy. No isolated-network / takeover / app-closed claims until those actually work. — seen: 2026-08-15

## Done

- [x] inspector-drafts Inspector memory/skill/routine field drafts are process-wide and leak across bots — evidence: typed `only-new-agent-2-memory-draft-1805` on New Agent (@new-agent-2) Studio Memory; Batatilson Desk Memory showed the same unsent text; Batatilson Studio Skills still held leftover `weekly-account-health`. Code: `BotsViewModel.memoryDraft` / `skillDraft` / `routineName` / `routinePrompt` / `routineScheduleNote` are single fields, not keyed by BotID (unlike composer drafts). — seen: 2026-08-15 — done: 903c77d7

- [x] Brain Inspector P1a (Source vs Effective, context receipts) still unshipped vs plan-bots — evidence: loop leftover after persist-switcher fire — seen: 2026-08-15 — done: 3414e347
- [x] Live Desk still duplicates some historical assistant bubbles — evidence: prior Desk isolation/order fires left residual dups on Batatilson — seen: 2026-08-15 — done: 0550e618
- [x] Shell destination (Bots vs workspace) does not persist across app restart — evidence: MR !255 limitations; clicking Bots after relaunch is not the last dest — seen: 2026-08-15 — done: e7acac15
- [x] Desk composer was process-wide so an unsent line leaked onto the next bot — evidence: prior fire — seen: 2026-08-15 — done: 448d1b5f

## Out of scope (not open P1)

- P1b approval policy / Allow once / Deny — Security tab is explicitly read-only until P1b.
- Concept-image chrome that is not yet true: Take over / Pause / Screenshot / Full screen, Isolated network, Encrypted disk, Last checkpoint, “Active now in macOS VM”, Spaces-as-isolation. Do not paint these as real.
- P3 app-closed routines, @mention collaboration preflight, handoff — Routines honesty: “Test runs are real work. App-closed schedules stay off until autonomy is enabled.”
- P4 iOS Fleet/Desk — separate plan; not this macOS fire.
- Retrieval scores, candidate approve/reject, captured per-adapter golden fixture file — still out of this P1a slice (unchanged).

## Runtime notes (not new work)

- Fleet Home, Studio (Profile/Brain/Memory/Skills/Routines/Security/Desktop), Desk chat, Attention empty state, and roster match the prior P1a slice. Fallback order labeled “not shipped in P1a.”
- Brain Inspector Source vs Effective is live on New Agent (payload digest present; Preview is a local compile).
- Desk isolation held: Batatilson has `one-bubble`; New Agent (@new-agent-2) has `pong` / `Olá` only.
- Routines honesty held on Studio + Desk inspector.
- Dirty uncommitted roster context-menu work exists in `BotsWindow.swift` / `SidebarView.swift` / `BotsWindowTests.swift` (Show hidden + right-click Pin/Hide/Duplicate/Edit/Delete). Not this inventory. Do not piggyback it onto the VM fire.
- Inventory screenshots: `.rc-autoloops/bots-ui-proof/inventory-{fleet-home,studio-profile,studio-brain,studio-memory,studio-routines,studio-desktop,desk}.png`
