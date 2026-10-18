# Contextual fork authority and replay refusal

## Selected uncovered entry

Earlier evidence covered the dispatcher rejecting scoped resource/fork requests. That did not establish the direct in-process native router, Agent App coordinator, or durable fork-recovery boundaries. This checkpoint selects that entry from the stage-2/7/8 mapping without requiring provider credentials.

Direct `forkAgentThread` and `sideAgentThread` now call the existing current-host conversation authority guard before entering the coordinator. An authorized pinned conversation still reports contextual execution unavailable because public execution remains closed. Revoking its binding produces the existing inactive/invalid-authority error; reopening the real SQLite/AppContext does not revive permission.

The shared coordinator rejects canonical context pins before adapter lookup, capability probing, session recovery or provider fork. This also protects Agent App callers that bypass the router. Durable intent creation and local child-graph persistence recheck the canonical pin inside their SQLite transactions. The check delegates to the existing BotStore pin lookup, not sidebar selection, legacy workspace affinity or provider capabilities. Unpinned sources keep the legacy path.

Startup recovery checks the source pin before consulting an adapter. An intent prepared while the source was unscoped is retained with `contextualSourceUnsupported` if that source later becomes pinned; it is not replayed or silently deleted. The private reconciliation path checks again before effects. A diagnostic error update is intentional; it is not a completed fork or cleanup receipt. This checkpoint does not implement positive contextual fork/export or claim that retained native artifacts have been compensated.

## Requirement mapping

- **S-002 / V-002:** explicit authority at direct native fork/side entry, independent of the paired dispatcher and provider capability refusal.
- **S-007 / V-007:** current revoked policy is read before execution, including after reopening persisted state; no child, run, message, queue or new intent is produced by denial.
- **S-008 / V-008:** a real pre-pin durable intent survives reconciliation without replaying revoked contextual work or committing a child graph. Legacy fork persistence and recovery regressions remain verified below.

This is one bounded entry, not completion of the entire endpoint matrix or any of those stages. UI layouts, controls, public execution gates and iOS source/protocols are unchanged.

## Exact verification

macOS repository/worktree: `macos-app/.sandbox-worktrees/20261016T013608Z`; pre-change baseline `ac38a2f51fb5ef424b4b46b70daea43427919f48`. iOS baseline `9c8d92ca815d7b5fa4d32404dc93ecd5bf82bff9`; iOS receives this host contract as documentation only.

At exact Sources/Tests tree `7d1dfd16e8ab105a31d73f313d500a6a6bc69bb2`, the orchestrator ran:

```sh
swift package clean
RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1 scripts/isolated-sandbox.sh test --build-system native --filter 'BotContextForkAuthorityTests|AgentForkAtomicityTests|ThreadReorderTransactionTests'
```

The runner also received caller-owned `RC_CONTEXT_PROBE_ROOT` for the new fixtures. Cleaning affected only the isolated worktree's ordinary build products, not the user's app or primary checkout. Result: **44 passed, zero failures/skips, 7.799 seconds, exit 0**.

Four new tests exercise real router/coordinator/persistence functions:

1. Actual router fork and side calls reject an active pin at the closed execution gate, then reject current revocation, then reject again through a reopened SQLite/AppContext. Counts and canonical identity remain unchanged.
2. Actual coordinator fork, durable prepare and direct child-graph commit reject pinned sources with the exact contextual error, both before and after revocation. The expected error distinguishes authority refusal from unsupported adapter capabilities or a missing provider session.
3. The fixture prepares a durable intent through the shipped repository while its source is unscoped, then pins and revokes it through shipped store APIs. Reopened production recovery retains the prepared intent and contextual error, creates no child, and preserves counts and the canonical pin. This is owned initial recovery data, not a fabricated provider acceptance result.
4. Unscoped legacy durable intent creation remains allowed.

The other 40 selected tests cover atomic/idempotent fork persistence, rollback/compensation/recovery, retained transcripts, concurrency and thread-cap transactions. Existing adapter protocol fixtures in those legacy tests are unit boundaries, not live-provider authentication proof. The four new authority tests introduce no provider or runner replacement; their account API/secret-store fixtures avoid personal services and Keychain access.

The first incremental run passed the four new tests but produced five mismatched existing error-case assertions. The new enum case was appended after existing cases, and the isolated products were cleanly rebuilt; the final 44-test run above passed unchanged legacy assertions. The failing incremental run is not counted as a pass.

Native packaging from the same tested tree passed with exit 0 and validated team `6SV3W8BFYJ`. Executable SHA-256: `5d8e52d12a7feb3bb64c5362f2c13bc37cf61676de07bfe478144ed41242969c`.

Independent source review `01a1496a-896e-7792-8602-d809d73132c9` found no concrete defect in the named fork boundaries. It ran no commands or tests; runtime results are separate orchestrator evidence. After test-process exit, six delayed fixture remnants were inspected, contained only generated locks, and were removed. Final fork fixture-directory absence was verified. No Docker or provider execution was needed for the new denial tests; existing user resources were preserved.

## Remaining limits

Positive contextual fork, human-reviewed cross-context summary/export, authenticated provider/child execution, real provider session load after process restart, OAuth refresh, other authority/lifecycle entrypoints, resource calibration, native accessibility/usability and rollout remain pending. The existing 21-skill design ledger and native UI evidence are preserved; no new UI or simulator verification is claimed.
