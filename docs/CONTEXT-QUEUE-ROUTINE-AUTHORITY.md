# Contextual routine and queue authority

## Bounded authority result

At exact tested source tree `c9c496c1917243e168ef3edb8156d4cf03aa02cf`, the bounded native tests target routine dispatch, queue admission/drain, current bot context, scheduler/store behavior, host catalog, queued follow-up and failed-bot restart behavior. This records authority and refusal behavior; it does not claim provider execution.

Automatic routine dispatch rereads current settings and the enabled routine definition after claiming work. Pausing routines reseeds future slots; it does not replay an already consumed slot. `routineRun` and `queueForceNow` enforce the current master gate before metadata writes, queueing or callback invocation. Explicit manual dispatch intentionally ignores the autonomy-only pause. `requireControlPlane` reloads canonical settings before checking authority.

Native enqueue validates exact conversation ownership and its context pin before effectful legacy Docker admission. Automatic queue drain first reloads the undeleted bot and checks its current context gate. Boundary callbacks deliberately throw, so their invocation is not positive evidence of a provider run. Contextual routine/tick active-state requests return `-32602`; revoked or reopened authority returns `-32084`.

No contextual export API was found in the bounded audit. Legacy profile duplication copies neither memory nor conversations; no export completion is claimed. UI/layout/public gates remain unchanged.

## Verification evidence and limits

The exact tree was tested with the broad isolated native command below. `RC_CONTEXT_PROBE_ROOT` is caller-assigned; do not persist its value.

```sh
RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1 RC_CONTEXT_PROBE_ROOT=<caller-assigned> scripts/isolated-sandbox.sh test --build-system native --filter 'BotContextColdAdmissionTests|BotRoutineDispatchAuthorityTests|BotRemoteControlAuthorityTests|BotContextAuthorityTests|BotRoutineSchedulerTests|BotStoreTests.test_duplicate_copiesProfileAndRoutinesButNotMemoryOrConversations|BotsWindowTests.test_hostCatalog|BotsWindowTests.test_queuedFollowUpOnBotThread|HostRestoreBotRestartTests.testReopenHoldsFailedBotAttemptAndForceDoesNotStartProvider'
```

The test completed: 117 tests, zero failures/skips, 14.887 seconds, exit 0. Build completed with exit 0 using `RC2_SWIFT_BUILD_SYSTEM=native scripts/isolated-sandbox.sh build`; signed bundle is valid. Binary SHA256: `9238daa1d871e7bde23f0ddbc7596d1f1d782d115eaeafc7808a2a6c691603f2`. Logs contained Live Activity SQLite disk-I/O warnings despite passed assertions; this run does not verify that subsystem.

Baseline failed reproductions were fixed: cold `notReady` idle→failed transition; automatic callback after pause; and manual dispatch with master off failed because `routineRun` omitted `requireControlPlane`. Review references: automatic `01a14985-0af2-7cc0-a724-4266e9fbfc2b`, queue `01a14991-cc44-7d53-adcf-9614d341d6c1`, final master `01a149a1-22fd-7213-a466-39128388b4f3`. Final review was source-only with no material findings. An earlier reviewer found a missing invocation; that was fixed.

Full S-002/S-007/S-008 acceptance, provider execution, OAuth, load, accessibility and rollout remain open. The macOS checkpoint contains code and test changes; the iOS checkpoint mirrors host contract documentation only. No iOS build or simulator run is claimed for this documentation-only delta.


## Master policy changed between enqueue and drain

During first controlled public `router.sendHostBot` run, a follow-up was enqueued. After selecting another Bot, an independent `SettingsStore` disabled master control plane. Finishing first run produced terminal follow-through, but shared `admitDesktopSend` reloaded master policy before revision/readiness/provision checks; no second runner admission or second user transcript/run occurred. Durable queue rows, order and content remained unchanged. This confirms shared send admission behavior, not provider authentication or isolation. Stop, read and cleanup paths remain unaffected.

Before guard, regression test failed five assertions: two requests, consumed row and second user message. Exact tested tree `717215d311ade0e9f24796c64507f5961aa55826`; 119 tests, zero failures/skips, 16.192 seconds, exit 0, using the prior doc filter plus `|BotsWindowTests.test_dockerDesktopAdmissionStartsGuestOffMainAndFailsClosedUntilReady` (hostCatalog regex includes new test). Native build passed with `RC2_SWIFT_BUILD_SYSTEM=native scripts/isolated-sandbox.sh build`; signed bundle is valid; executable SHA256 `57e0a21a801d0505a7ce6ee7fbbbda7e50f2e3fdb98bdbe2285000476800896a`. Source-only review `01a149b1-7e79-79f2-b120-cb1b1a8fd06a` found no concrete defect.

No positive contextual enqueue-to-revocation runtime was possible because public gates are closed. No atomicity is claimed for changes after admission guard passes or arbitrary concurrent writes. Controlled runner test does not prove authenticated provider execution or isolation. Provider/OAuth, full matrix, UI accessibility, load and rollout remain open. Logs contained Live Activity SQLite disk-I/O warnings; this test does not verify Live Activity durability. Layout/design unchanged.
