# Explicit contextual cleanup receipt repair

## Supported operation

`RemoteCode --repair-context-receipts` repairs durable cleanup evidence for canonical contextual runs after interruption or receipt-persistence failure. It requires the current host schema and the same exclusive Application Support lock as normal startup. Stop the owning host before running maintenance; a held or unavailable lock refuses the command. Mixed flags are rejected before cleanup or scheduled-agent side effects. The command uses normal host paths; isolated verification supplies owned `RC2_APP_SUPPORT` and `RC2_DB_PATH` overrides.

This is cleanup-evidence repair, not arbitrary command-outcome resolution. Interrupted remote command claims become permanent `unknown`; the operation never releases those claims, invents a successful send, replays a command, drains a queue, grants authority, launches a provider, or opens public contextual gates. Unknown outcomes without evidence remain unknown.

Before cleanup, the host validates each recovery record against the canonical conversation pin, bot, host, context, policy revision, thread and run. Native directories are opened relative to trusted parent descriptors. Only selected pending scopes enter the existing physical recovery path. Ended scopes use inspection-only verification and refuse a running container. Existing containers must match the exact bot/runtime/network labels, network and home mount; a mismatched container is neither stopped nor accepted as cleanup proof.

After environment/configuration cleanup and stopped-or-absent runtime confirmation, the exact persisted active run/provider session may become interrupted. Existing terminal outcomes and current authority remain unchanged. Delegation closes; queued intent remains untouched. Receipt data contains only canonical identifiers, policy state/revision at repair, terminal run status and confirmed cleanup, never prompts, queue text, paths or credentials.

A permanent settings receipt and one `bot.context.cleanup.repaired` event commit in one SQLite transaction. Event allocation advances past both the durable allocator and ordinary persisted events. Failed receipt persistence rolls back its event and sequence allocation; a later process can repair from the retained cleanup evidence. Repeated repair returns the existing historical receipt without creating another event. A historical receipt is never current execution authorization. Event-retention pruning does not erase the permanent receipt.

The JSON report contains `repaired`, `existing` and `failures`. Any failure exits unsuccessfully and preserves an honest partial state: physical cleanup or terminal reconciliation can already be complete while durable receipt persistence remains incomplete. Retry does not restart execution.

## Exact verification

macOS repository/worktree: `macos-app/.sandbox-worktrees/20261016T013608Z`; pre-change baseline `f4b5de9f0cc14e3707f6c330074b4c130ae5b924`. iOS baseline `95c65d2804041434db91eb9d71fd3e0aa7300309`; this checkpoint changes iOS documentation only.

Native packaging passed with exit 0 at tree `fc9c0e6c220bff211468fc81d30b76ccc2347719`. Signature validated for team `6SV3W8BFYJ`; executable SHA-256 `512f7272aa96ef3f45bf321c421d4d52bc2f71c330799bbd68a1f2c7753f1b3f`.

Final Sources/Tests tree `fc9c0e6c220bff211468fc81d30b76ccc2347719` is the same tree used for that package. The orchestrator ran the supported isolated native runner with `RC_HOST_MATRIX_BINARY` pointing to the actual packaged executable, `RC_LIVE_DOCKER=1 RC_LIVE_DOCKER1=1`, and caller-owned `RC_CONTEXT_PROBE_ROOT`:

```sh
scripts/isolated-sandbox.sh test --build-system native --filter 'BotContextReceiptRepairCLITests|BotContextResolverCleanupFailureDockerTests|BotContextScopedResumeTests|Phase4CommandReceiptRepositoryTests|EventLogRepositoryTests'
```

Result: **36 tests passed, zero failures or skips, 22.909 seconds, exit 0**.

A final test-only ownership-cleanup hardening uses the exact container ID returned by Docker and refuses pre-existing fixture names. At Sources/Tests tree `23ea7a7125c8303851e269d851abeba7a5371fcd`, all five CLI tests passed again with zero failures/skips in 4.953 seconds. Sources remain identical to the packaged and 36-test tree above. An earlier teardown iteration incorrectly used the name-only existence API with a container ID; its stopped task container was inspected against the owned home, removed by exact ID, and absence verified before the corrected test passed.

Five actual packaged-CLI tests cover:

- A real SQLite trigger rejects the permanent receipt write after event insertion. The first process reports failure, leaves zero repair events, and retains completed cleanup plus a cancelled run and revision-2 revoked grant. After removing the owned failure trigger, a new process repairs exactly one receipt/event; another process returns the existing receipt with no duplicate. An interrupted `agent.message.send` claim remains unknown throughout.
- Mixed operation flags and an occupied host lock refuse maintenance before environment/configuration cleanup or event persistence.
- A real stopped Docker container with the expected name/home but mismatched bot ownership label is refused. Its complete inspection readback remains unchanged; no repair event is written. The exact owned container and network are removed and their absence asserted.
- Imported active run/provider rows become interrupted after real Docker absence verification. The same queued intent remains queued, no message or replacement run appears, revoked authority stays revoked, and private queue text is absent from the report. These rows are recovery input data, not evidence of provider execution or authentication.
- Ended history and a newer recoverable run in the same thread reconcile together. The current provider must match a separately validated candidate with the same scope, thread and exact run ID. Historical cancellation remains unchanged while the newer run becomes interrupted; two distinct receipts represent two distinct runs, and queued intent stays queued.

Selected regressions also exercise real Docker Stop failure/retry and native-history preservation, permanent unknown receipt fences, event retention, and transaction rollback. The repair CLI failure fixture itself uses an absent runtime; the mismatched-ownership fixture uses a stopped container. Neither is presented as live authenticated provider execution or a combined live-provider/receipt-failure journey.

Independent review `01a14943-ac72-7630-801d-7601ea7433d4` found an ended-only ownership-validation gap. The shared inspection-only helper fixed it; follow-up `01a14946-b85e-7ad0-9e85-aa0a6f63e06d` closed that finding at source level. A later narrow review `01a1494c-34f7-7eb3-8227-b56b01a38030` found no unresolved defect in the same-thread historical/current-run correction. Reviews ran no tests; the runtime results above are separate orchestrator proof.

Owned repair/Docker fixtures were cleaned by their tests. Four delayed resume remnants from the final combined run were inspected after test-process exit, contained only generated locks, and were removed. Final absence of selected repair, resume and cleanup fixture roots was verified. Existing user resources were preserved.

## Remaining limits

UI/UX, iOS source/protocols and the existing 21-skill design ledger remain unchanged. No new native UI or simulator proof is claimed. Public execution remains closed. Full-plan acceptance, authenticated provider/child execution and real provider session load after process restart, OAuth refresh, broader lifecycle probes, rollout and representative hardware measurements remain pending. This bounded repair checkpoint does not complete stages S-007/S-008 or resolve arbitrary unknown business outcomes without evidence.
