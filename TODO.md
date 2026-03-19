# Production-Grade TODO

Regenerated from scratch on 2026-03-19 from the current codebase only.

Principle:
- This file is not a UX audit.
- This file is the minimum work I believe is still required before calling the product production-grade for real users.
- Items are ordered by release impact, not by convenience.

Completion rule:
- Do not mark an item done without proof.
- Acceptable proof: passing automated tests, passing typecheck/build, stable runtime behavior, and relevant E2E for user-facing flows.

## Release Verdict

Current recommendation:
- Desktop: close to release-ready, but still needs a few structural and regression-hardening tasks.
- Mobile: not production-grade yet.
- Whole product: do not call it production-grade until the mobile release path is proven end to end.

## P0 Release Blockers

### [ ] P0-1 Mobile iOS bootstrap must complete deterministically
- Platform: Mobile
- Why this blocks release:
  - The app cannot be considered production-grade while the real startup and connect path is not proven stable.
  - This is currently the biggest gap between code quality and release confidence.
- What to change:
  - Remove ambiguity in the mobile server-connect bootstrap path.
  - Make the app choose one deterministic startup path for E2E and for first-run connection.
  - Stop depending on fragile simulator-only interaction sequences for the initial connection handshake.
- Expected implementation direction:
  - Add a first-class test bootstrap mode in the app, not a pile of runner workarounds.
  - Make initial local connection injectable by config/state before the UI path starts.
  - If deep-link bootstrap is kept, make it a real supported path and prove it with tests.
- Required proof:
  - `mobile test:e2e:ios` green from clean state
  - at least 3 consecutive green runs
  - explicit proof that bootstrap reaches `workspaces -> threads -> chat`

### [ ] P0-2 Mobile real E2E coverage must exist for the highest-risk flows
- Platform: Mobile
- Why this blocks release:
  - Right now mobile still depends too much on code confidence instead of runtime proof.
- What to change:
  - Add or finish deterministic E2E for:
    - app bootstrap/connect
    - thread open
    - message send
    - pagination
    - terminal open/close
    - drawer open/close
    - picker/modal open/close
    - keyboard transitions
- Required proof:
  - passing iOS E2E suite
  - one stress flow covering repeated overlay and navigation churn

### [ ] P0-3 Mobile connection state must be simplified and hardened
- Platform: Mobile
- Why this blocks release:
  - The current startup/connect behavior is too sensitive to UI state, discovery state, and simulator quirks.
  - That is a bad release property even if local code is “mostly correct”.
- What to change:
  - Separate these concerns cleanly:
    - persisted active config
    - saved connections
    - LAN discovery
    - manual connect
    - debug/test bootstrap
  - Ensure one source of truth for “current backend target”.
  - Ensure the app can recover from stale saved hostnames and old local hosts without getting stuck in `Connecting...`.
- Required proof:
  - unit/integration coverage for config resolution
  - E2E proving a clean connect from known local config

## P1 Must-Have Before Wide Launch

### [ ] P1-1 Split mobile chat orchestration into smaller surfaces
- Platform: Mobile
- Why it matters:
  - `chat-screen.tsx` still coordinates too much in one surface.
  - That is a medium-term maintainability and performance risk.
- What to change:
  - Separate at least:
    - composer/input path
    - message list / pagination path
    - drawer/project actions
    - terminal overlay
    - picker/modal orchestration
- Exit criteria:
  - lower rerender fan-out on interaction-heavy paths
  - tests for each split path
  - no behavior regressions in chat flow

### [ ] P1-2 Add production-grade runtime observability for mobile and desktop
- Platform: Both
- Why it matters:
  - Once users are live, silent connection failures and UI stalls become expensive to debug.
- What to change:
  - Add structured logs and lightweight metrics around:
    - startup
    - server connection attempts
    - connection success/failure reason
    - thread open latency
    - send-message lifecycle
    - stream start/stop
    - terminal session open/close
  - Add explicit error classification, not generic “Unable to connect”.
- Exit criteria:
  - logs identify failure stage precisely
  - errors are grouped by actionable cause

### [ ] P1-3 Add regression guards for long-session reliability
- Platform: Both
- Why it matters:
  - Production-grade means behavior stays stable after 30-120 minute sessions, not just first-use correctness.
- What to change:
  - Add stress/regression tests for:
    - repeated thread switching
    - repeated send/stop/send
    - repeated overlay open/close
    - repeated pagination
    - terminal mount/unmount churn
- Exit criteria:
  - desktop stress proof remains green
  - mobile stress proof exists and is green

### [ ] P1-4 Harden async ordering and stale-response handling on mobile
- Platform: Mobile
- Why it matters:
  - Mobile is still the higher-risk surface for race conditions and stale updates.
- What to change:
  - Review and tighten guards around:
    - selection changes during fetch
    - pagination during chat switch
    - send/stop while stream state changes
    - discovery/connect while settings state changes
  - Prefer explicit request ownership and ignore stale responses deterministically.
- Exit criteria:
  - tests covering out-of-order responses
  - no state contamination across chat/project switches

## P1 Desktop Hardening

### [ ] P1-5 Finish decomposing the desktop root shell
- Platform: Desktop
- Why it matters:
  - The resize hot path is better, but `App.tsx` is still too broad.
- What to change:
  - Continue reducing root-shell responsibility for:
    - terminal state
    - git controls
    - banners/errors
    - conversation shell
    - sidebar state
  - Move coordination into narrower surfaces or dedicated hooks/components.
- Exit criteria:
  - smaller root render surface
  - no new regressions in sidebar/thread/terminal behavior

### [ ] P1-6 Add idle-performance and multi-tab consistency checks on desktop
- Platform: Desktop
- Why it matters:
  - Production users will leave the app open for long periods.
- What to change:
  - Validate:
    - idle CPU stays low
    - websocket reconnect behavior is stable
    - selection/store state does not drift after reconnection
    - multiple desktop windows or sessions do not corrupt transient UI state
- Exit criteria:
  - repeatable smoke/regression checks
  - no unexpected store growth or reconnect loops

## P2 Important Cleanup

### [ ] P2-1 Replace brittle mobile E2E script heuristics with supported test hooks
- Platform: Mobile
- Why it matters:
  - The current script layer is doing too much product orchestration.
- What to change:
  - Add app-level test hooks for:
    - deterministic connection bootstrap
    - opening known project/chat
    - dismissing first-run prompts
    - forcing stable navigation start points
- Exit criteria:
  - smaller shell scripts
  - fewer simulator-specific hacks

### [ ] P2-2 Review secure storage and config migration paths
- Platform: Mobile
- Why it matters:
  - First-run and upgrade paths are part of production quality.
- What to change:
  - Audit `ApiConfigStore` and related persistence for:
    - migration correctness
    - stale host/token cleanup
    - safe fallback behavior
    - explicit handling for invalid saved targets
- Exit criteria:
  - tests for migration and stale-config recovery

### [ ] P2-3 Add targeted perf instrumentation hooks for desktop
- Platform: Desktop
- Why it matters:
  - The current render stats are useful but narrow.
- What to change:
  - Keep production-safe debug hooks or internal perf probes for:
    - sidebar drag
    - thread switch
    - send-message commit path
    - terminal toggle
- Exit criteria:
  - actionable render/latency visibility in dev and CI smoke paths

## P3 Nice-to-Have But Worthwhile

### [ ] P3-1 Unify release smoke suites across desktop and mobile
- Platform: Both
- What to change:
  - Define one release smoke command per platform.
  - Each should cover the minimum user-critical flow from launch to active usage.

### [ ] P3-2 Add explicit launch checklist artifacts
- Platform: Both
- What to change:
  - Standardize:
    - typecheck
    - core unit/integration tests
    - E2E smoke
    - stress smoke
    - release notes / known issues

## Minimum Release Gate

Do not call the product production-grade until all of these are true:

- [ ] Mobile iOS bootstrap E2E passes reliably
- [ ] Mobile chat/navigation stress E2E exists and passes
- [ ] Mobile connection/bootstrap path is simplified and proven
- [ ] Desktop root-shell decomposition is reduced beyond the current resize fix
- [ ] Desktop and mobile both have release smoke commands
- [ ] Observability is good enough to diagnose startup/connect/send failures in production

## Practical Release Recommendation

If shipping before all items above:

- Desktop:
  - acceptable for broader rollout after P1-5 and P1-6 are reasonably covered
- Mobile:
  - only acceptable for staged rollout or controlled beta until P0 is closed
