# UX + Performance Audit

Regenerated from scratch on 2026-03-19 from the current codebase, existing E2E coverage, hook output, and runtime validation paths.

Rules for completion:
- `[x]` only when the behavior is implemented, reproduced, and backed by explicit E2E proof.
- `[ ]` means open, unproven, or blocked.
- A task stays open if tests exist but the real E2E path is still failing or missing.

## Critical UX Breakers

### [ ] UXR-01 Mobile iOS end-to-end flow hangs before the full UX path completes
- Title: Mobile iOS full-session validation is nondeterministic and blocks proof of UX stability
- Platform: Mobile
- Category: UX / Performance / State
- Severity: Critical
- Description: The real iOS suite does not complete reliably. The current blocking point is the thread activity flow started from `mobile/e2e/run-ios-e2e.sh`, which prevents proving real navigation, streaming, keyboard, modal, and long-session stability on the app runtime.
- Why it matters: Without a passing real-device/simulator flow, there is no evidence that mobile interactions remain stable under actual mounting, focus, keyboard, notification-permission, and async timing conditions.
- Reproduction steps:
  1. Run `bun run --cwd mobile test:e2e:ios`
  2. Wait for build, install, backend startup, and app launch
  3. Observe the run stalling inside `mobile/e2e/ios-thread-activity-flow.sh` instead of finishing the full suite
- Suggested fix: Add deterministic checkpoints and tighter failure boundaries to the iOS flow, identify the first unstable selector/screen transition, fix the app or the flow script, and rerun until the full suite completes.
- Evidence:
  - Current observed behavior: build/install/backend launch succeed, full suite does not finish deterministically
  - Blocking entrypoint: `mobile/e2e/ios-thread-activity-flow.sh`
  - The stale-worker contention path was reduced: the runner now clears prior `ios-thread-activity-flow.sh`, `AgentDeviceRunnerUITests`, and stale `agent-device` workers before each suite
  - The simulator foreground path was reduced: the suite now avoids sending the app into the `Agent Device Runner` helper during normal open/bootstrap
  - The current blocker is still before proof: the iOS suite reaches the real `Server` screen but does not complete the connection bootstrap deterministically, and the `settings` deep-link auto-connect path still does not deliver a working backend connection in runtime
  - Backend evidence: the deterministic backend starts and passes health verification, but no subsequent app-side connection requests arrive when the suite stalls
  - Local crash mitigation landed: the previous router crash `Property 'normalizeMessagePage' doesn't exist` no longer reappeared during the latest clean rebuild path, but the full suite is still not complete
- Proof:
  - Pending

### [x] UXR-02 Desktop transient thread state is unbounded across long thread-switching sessions
- Title: Desktop keeps per-thread transient state without an explicit upper bound
- Platform: Desktop
- Category: Performance / Memory / State
- Severity: Critical
- Description: The desktop workspace store retains per-chat transient structures such as `streamHistoryByChat`, `streamingByChat`, `streamTurnsByChat`, and `lastAssistantEventIdByChat` across a project session. There is no explicit cap for long sessions that churn through many threads in one workspace.
- Why it matters: Power-user sessions that open many threads can accumulate retained objects and grow memory pressure over time, even when only one thread is active.
- Reproduction steps:
  1. Open a workspace with many threads
  2. Switch across many threads while generating stream history
  3. Inspect the desktop workspace store and observe retained per-thread transient entries growing with visited chats
- Suggested fix: Bound transient per-thread caches to the active thread plus a small recent set, remove stale completed thread state aggressively, and add stress E2E proof for bounded cache growth.
- Evidence:
  - State surfaces live in `desktop/src/react/features/workspace/model/useWorkspaceStore.ts`
  - Retained maps currently include `streamHistoryByChat`, `streamingByChat`, `streamTurnsByChat`, and `lastAssistantEventIdByChat`
- Proof:
  - Reducer pruning added in `desktop/src/react/features/workspace/model/useWorkspaceStore.ts`
  - Unit proof: `bun test desktop/src/react/features/workspace/model/useWorkspaceStore.test.ts` => `8 pass`, `0 fail`
  - E2E proof: `bun run --cwd desktop e2e:run:playwright --grep "D-57"` => `1 passed`

## Memory Leaks / Memory Risks

### [x] UXR-03 Desktop has no stress E2E proving bounded cache behavior under repeated thread churn
- Title: Desktop has no end-to-end memory guard for repeated mount/unmount and thread churn
- Platform: Desktop
- Category: Performance / Memory
- Severity: High
- Description: The current Playwright suite covers targeted polish cases, but it does not prove that repeated thread switching, pagination, and streaming leave the transient cache bounded over long sessions.
- Why it matters: Regressions in cache retention or render-order stability can land without any failing end-to-end signal.
- Reproduction steps:
  1. Run `bun run --cwd desktop e2e:run:playwright`
  2. Review the suite coverage
  3. Observe there is no long-session cache-boundary assertion for repeated thread switching
- Suggested fix: Add a desktop stress E2E that cycles across many threads, forces repeated mounts, and asserts bounded transient-state counters after churn.
- Evidence:
  - Existing desktop Playwright coverage is concentrated in `desktop/e2e/playwright/tests/*.spec.ts`
  - No current spec asserts cache-size ceilings after repeated navigation
- Proof:
  - New stress proof: `desktop/e2e/playwright/tests/thread-transient-cache-playwright.spec.ts`
  - E2E result: `bun run --cwd desktop e2e:run:playwright --grep "D-57"` => `1 passed`
  - Runtime assertion: every transient per-chat map remained capped at `<= 1` entry after repeated thread churn

### [ ] UXR-04 Mobile has no passing stress E2E for repeated drawer, picker, keyboard, and terminal overlay interactions
- Title: Mobile lacks end-to-end proof for stacked overlay and keyboard stability
- Platform: Mobile
- Category: UX / Performance / State
- Severity: High
- Description: The current mobile E2E coverage is centered on thread activity, pagination, terminal, and account compliance. It does not yet provide passing proof for repeated drawer open/close, picker scroll persistence, keyboard transitions, and terminal overlay stacking in one stress flow.
- Why it matters: These are the highest-risk paths for flicker, wrong z-order, scroll jumps, and input latency on mobile.
- Reproduction steps:
  1. Review `mobile/e2e/*.sh`
  2. Observe there is no passing stress flow covering repeated drawer, picker, keyboard, and terminal overlay churn end to end
- Suggested fix: Add a deterministic iOS stress flow that exercises drawer, selector strip, picker modals, keyboard, and terminal overlay in one run after the base suite is stable.
- Evidence:
  - Current suite entrypoints: `mobile/e2e/run-ios-e2e.sh`, `ios-thread-activity-flow.sh`, `ios-chat-pagination-flow.sh`, `ios-terminal-flow.sh`, `ios-account-compliance-flow.sh`
- Proof:
  - Pending

## Performance Bottlenecks

### [x] UXR-05 Desktop root shell still concentrates too many interaction surfaces in one fan-out path
- Title: Desktop root shell remains a broad rerender surface for unrelated interaction paths
- Platform: Desktop
- Category: Performance / State
- Severity: Medium
- Description: `desktop/src/react/app/App.tsx` coordinates sidebar, conversation, git controls, terminal, update banners, selection, and error timers in one surface. That increases the risk that local interactions trigger wider commits than necessary.
- Why it matters: Broad rerender fan-out raises the chance of typing latency, scroll jank, and subtle ordering glitches under rapid interaction.
- Reproduction steps:
  1. Profile the desktop app during thread switching, sidebar dragging, and terminal toggling
  2. Observe root-level commits touching multiple concerns from the same shell
- Suggested fix: Isolate shell concerns behind narrower state boundaries and prove reduced rerender scope with profiling plus stress E2E.
- Evidence:
  - Primary surface: `desktop/src/react/app/App.tsx`
- Proof:
  - Desktop shell now applies sidebar width through a CSS variable on the layout shell instead of state writes on every pointer move
  - Unit proof: `bun test desktop/src/react/app/App.ux-v2.test.ts desktop/src/react/app/App.d57.test.ts desktop/src/react/features/workspace/model/useWorkspaceStore.test.ts` => `25 pass`, `0 fail`
  - E2E proof: `bun run --cwd desktop e2e:run:playwright --grep "D-50|D-56|D-57|D-58"` => `4 passed`
  - Runtime proof: `[D-58] sidebar drag avoids root rerenders on pointer move` kept `app-root` render count at `<= 2` during repeated drag movement

### [ ] UXR-06 Mobile chat screen still concentrates drawer, keyboard, pickers, terminal, and message rendering in one surface
- Title: Mobile chat screen remains a high-fanout interaction surface
- Platform: Mobile
- Category: Performance / State
- Severity: Medium
- Description: `mobile/src/features/chat/ui/chat-screen.tsx` still owns drawer state, modal state, keyboard handling, terminal overlay behavior, project actions, and conversation rendering in one component tree.
- Why it matters: Rapid interaction in one concern can force expensive work in unrelated concerns and raise input latency risk.
- Reproduction steps:
  1. Profile the mobile chat screen while toggling drawer, keyboard, terminal overlay, and picker modals
  2. Observe the same screen surface coordinating all of those transitions
- Suggested fix: Split overlay/drawer/picker orchestration away from the message/composer path and validate reduced interaction cost with runtime profiling plus E2E.
- Evidence:
  - Primary surface: `mobile/src/features/chat/ui/chat-screen.tsx`
  - Local refactor landed: chat composer input state moved out of the `ChatScreen` root into a memoized `ChatComposer`, so chat typing no longer mutates root state directly
  - Local verification:
    - `bun test mobile/src/features/chat/ui/chat-screen-ux-v2.test.ts mobile/src/features/chat/api/use-messages-query.test.ts` => `19 pass`, `0 fail`
    - `bun run --cwd mobile typecheck` => success
- Proof:
  - Pending

## Systemic Problems

- Desktop and mobile still rely on a few oversized coordination surfaces for high-frequency UX paths.
- Real long-session validation is weaker than the product requirements: targeted UI regressions have coverage, but stress flows are not yet proving bounded state growth and stacked interaction stability.
- Mobile proof is blocked by nondeterministic real E2E execution, which makes every claimed UX completion weaker than required.

## Quick Wins

- Make the mobile iOS flow deterministic enough to finish end to end.
- Add explicit debug counters and bounded-cache assertions for desktop transient thread state.
- Add one desktop stress Playwright flow and one mobile stress iOS flow before taking any UX claim as complete.

## Long-Term Fixes

- Split desktop root-shell state so conversation, sidebar, terminal, and git controls do not share the same rerender surface.
- Split mobile chat-screen orchestration so composer/scroll rendering is insulated from drawer, picker, and terminal overlay transitions.
- Keep explicit cache ceilings and stress E2E assertions as permanent regression guards for long-session reliability.

## Evidence Log

- `git push` gate status: current branch is synced with `origin/main` after hook execution and fetch verification
- Desktop bounded-cache proof:
  - `bun test desktop/src/react/features/workspace/model/useWorkspaceStore.test.ts` => `8 pass`, `0 fail`
  - `bun run --cwd desktop e2e:run:playwright --grep "D-57"` => `1 passed`
- Desktop root-shell proof:
  - `bun test desktop/src/react/app/App.ux-v2.test.ts desktop/src/react/app/App.d57.test.ts desktop/src/react/features/workspace/model/useWorkspaceStore.test.ts` => `25 pass`, `0 fail`
  - `bun run --cwd desktop e2e:run:playwright --grep "D-50|D-56|D-57|D-58"` => `4 passed`
- Mobile current E2E baseline: real iOS suite still blocked by `ios-thread-activity-flow.sh`
- Mobile local mitigations added in this round:
  - `mobile/src/features/chat/api/use-messages-query.ts`: removed direct dependency on the crashing `normalizeMessagePage` export inside the hook path
  - `mobile/src/features/chat/ui/chat-screen.tsx`: isolated composer-local input state into a memoized `ChatComposer`
  - `mobile/e2e/run-ios-e2e.sh`: stronger stale-session cleanup, daemon restart fallback, and target-simulator reboot before each run
  - `mobile/e2e/ios-thread-activity-flow.sh`: router-error fast-fail, lighter polling snapshots, simulator foreground fixes, stale-worker cleanup compatibility, and manual-connection bootstrap hardening
  - `mobile/e2e/ios-chat-pagination-flow.sh`: matching iOS session/polling fixes
