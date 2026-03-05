# Thread Activity Stabilization TODO

## Scope

Implement and validate end-to-end fixes across backend, desktop (ElectroBun), and mobile (iOS simulator) for:

1. Chat creation/send race causing `chat not found`.
2. Persistent active-thread state while the agent is still working.
3. Composer send action disabled while a thread is active.
4. Active-thread badge/indicator in thread lists and sidebars.
5. Thread reorder to top after sending.
6. Mobile footer CTA showing active thread count and a dedicated active-threads screen.

## Acceptance Criteria

- No `chat not found` after creating/sending in normal create-and-send flow.
- Active thread state is persisted and reflected consistently across REST + WS + UI.
- A `Working...` row with spinner is visible at the bottom of the active chat timeline.
- Send action is disabled for active threads on desktop and mobile.
- Active state is visible in desktop sidebar and mobile thread lists.
- Sending a message moves that thread to the top in desktop and mobile lists.
- Workspaces and Threads mobile screens show `X active threads` footer action when count > 0.
- Tapping footer action opens a dedicated active-threads screen.
- Every task has e2e proof, and no e2e test fails.

## Task Board

- [x] T1 Backend: fix create/send race handling and prevent stale thread send target.
- [x] T2 Backend: persist active-thread state and expose it via APIs/events.
- [x] T3 Desktop: show active indicators + `Working...` bottom row + disable send when active.
- [x] T4 Mobile: show active indicators + `Working...` bottom row + disable send when active.
- [x] T5 Desktop & Mobile: reorder thread to top immediately after send/update.
- [x] T6 Mobile: footer `X active threads` CTA on Workspaces/Threads + dedicated active-threads screen.
- [x] T7 E2E Backend coverage for all backend behaviors above.
- [x] T8 E2E Desktop (ElectroBun Playwright/CDP) coverage for all desktop behaviors above.
- [x] T9 E2E Mobile (iOS simulator) coverage for all mobile behaviors above.

## Force Stop (New Scope)

Implement and validate force interruption for active Codex threads:

1. Backend endpoint to force-stop a running Codex chat execution.
2. Runtime abort wiring so server can interrupt in-flight Codex process.
3. Desktop composer send button morphs to red `Force Stop` while active.
4. Mobile composer send button morphs to red `Force Stop` while active.
5. E2E proof for backend, desktop (Playwright/ElectroBun), and iOS simulator.

## Force Stop Task Board

- [x] F1 Backend: add `POST /v1/chats/:id/stop` and runtime-aware stop semantics.
- [x] F2 Backend: wire process abort for in-flight Codex run + stale-active cleanup path.
- [x] F3 Desktop: send button becomes red `Force Stop` for active thread and calls backend stop.
- [x] F4 Mobile: send button becomes red `Force Stop` for active thread and calls backend stop.
- [x] F5 E2E: backend + desktop Playwright + iOS simulator coverage for force-stop flow.

## Evidence Log

- 2026-03-05: `bun run typecheck:desktop` passed after integrating `isActive`/`projectId` changes.
- 2026-03-05: `bun run typecheck:mobile` passed after integrating active-threads/mobile navigation changes.
- 2026-03-05 (completed): Stabilizing iOS e2e navigation path so active-thread chat is opened from `Threads -> Active Threads -> Chat` before asserting return to `screen-threads`.
- 2026-03-05 (completed): Added deterministic selector `thread-item-title-{index}` and polling assertion for reorder-to-top in iOS e2e flow.
- 2026-03-05 (completed): Added `gtimeout` + retry wrapper for all `agent-device` calls in iOS flow to avoid hanging e2e runs.
- 2026-03-05 (completed): Fixed mobile send-block race by treating selected thread as running when it appears in `activeThreads`, even before chat context finishes loading.
- 2026-03-05 (completed): Replaced fragile `get text` assertion for blocked-send with `agent-device is text` predicate on `chat-input`.
- 2026-03-05 (completed): Hardened iOS `ad()` wrapper to fail on stderr `Error (COMMAND_FAILED)` / `Error (NO_SESSION)` even when CLI exit status is 0.
- 2026-03-05 (completed): Made `dismiss_alert_if_present` use a direct short-timeout call to avoid long `ios_runner_connect` retries during iOS e2e.
- 2026-03-05 (completed): iOS e2e runner now creates a unique `RC_AD_SESSION` per run to avoid stale agent-device session state across retries.
- 2026-03-05 (completed): iOS runner now closes stale `agent-device` sessions matching `rc-e2e-thread-activity*` before test start to prevent `DEVICE_IN_USE`.
- 2026-03-05: `bun run typecheck:mobile` re-run passed after active-thread send-block race fix.
- 2026-03-05: Backend e2e passed: `bun run --cwd desktop test:backend` => `125 pass / 0 fail` (includes stale chat target WS validation and active-thread API coverage).
- 2026-03-05: Desktop Playwright e2e passed: `bun run --cwd desktop e2e:run:playwright` => `5 passed / 0 failed` (includes `thread-activity-playwright.spec.ts`).
- 2026-03-05: ElectroBun CDP smoke passed: `bun run --cwd desktop automation:cdp-screenshot`; artifact `desktop/playwright-e2e/artifacts/electrobun-cdp-screenshot.png`; validated `1200x700`.
- 2026-03-05: Playwright Electron MCP endpoint verified: `bun run --cwd desktop mcp:playwright-electron` => listening on `http://localhost:8931`.
- 2026-03-05: iOS simulator e2e passed: `bun run --cwd mobile test:e2e:ios` => `iOS thread activity flow passed` and `iOS E2E suite completed.`
- 2026-03-05: Force-stop backend contract added and validated in e2e: `POST /v1/chats/:id/stop` (`chat.controller.e2e.test.ts`) with stale-active cleanup + 404 behavior.
- 2026-03-05: Backend test suite passed after force-stop implementation: `bun run --cwd desktop test:backend` => `132 pass / 0 fail`.
- 2026-03-05: Desktop typecheck passed after force-stop UI/API integration: `bun run typecheck:desktop`.
- 2026-03-05: Mobile typecheck passed after force-stop UI/API integration: `bun run typecheck:mobile`.
- 2026-03-05: Desktop Playwright e2e passed with force-stop scenario: `bun run --cwd desktop e2e:run:playwright` => `5 passed / 0 failed` (includes `active thread shows Force Stop and issues stop request`).
- 2026-03-05: ElectroBun CDP smoke re-run passed after stale process cleanup and fresh port: `ELECTROBUN_WINDOW_WIDTH=1200 ELECTROBUN_WINDOW_HEIGHT=700 ELECTROBUN_CDP_PORT=9555 bun run --cwd desktop automation:cdp-screenshot`; artifact `desktop/playwright-e2e/artifacts/electrobun-cdp-screenshot.png`.
- 2026-03-05: iOS simulator e2e passed with force-stop flow updates: `bun run --cwd mobile test:e2e:ios` => `iOS thread activity flow passed` and `iOS E2E suite completed.`

## Final Validation Gate

- [x] Backend e2e passing.
- [x] Desktop ElectroBun e2e passing.
- [x] Mobile iOS simulator e2e passing.
- [x] All tasks checked complete with linked proof.
