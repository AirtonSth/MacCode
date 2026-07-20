# Token Saver T-003 operations

This runbook governs every Token Saver lane in the macOS app and local sidecar. It does not authorize a provider proxy, global recovery authority, or promotion based on heuristic token estimates.

## Safety state

- Unnamed owners, unknown provider versions, unavailable evidence, failed gates, integrity errors, storage errors, low disk, thermal pressure, and model validation errors keep the affected lane off or shadow-only.
- Provider turns fail open to verbatim input. A local estimate is diagnostic; a billing claim requires joined provider usage evidence.
- Provider usage whose semantics are unavailable is observational telemetry only. It cannot support a billing claim until the attempt is joined to the exact treatment and the exposed fields reconcile.
- Lossy output may become live only after atomic scoped storage and byte-exact read-back. Raw hashes prove integrity, never authority.
- The reader ships before the writer. Current and previous stable envelope/adapter versions are readable; unknown versions remain off.

## Scope and retention

Recovery authority is the exact tuple `workspace/project/thread/provider/attempt` plus an opaque capability. Initial admission limits are 32 MiB/object, 512 MiB/thread, 2 GiB/project, and 5 GiB/global. New lossy storage stops when free disk is below the greater of 5 GiB or 10%.

Per-project retention is visible in Token Saver project controls. `0 days` means no persistent duplicate content. The lifecycle sweep runs at app startup, after retention changes, and after rollover creation. It:

1. revokes capabilities and tombstones expired or orphaned recovery objects;
2. tombstones expired or orphaned SessionLearn records;
3. removes text, integrity hashes, and transitions from expired, opted-out, zero-retention, or orphaned rollover capsules;
4. writes only aggregate counts and reasons to the audit ledger;
5. is idempotent.

Project deletion immediately tombstones scoped content and revokes its capabilities. Account/workspace deletion must call the same project deletion path before removing the owning rows. Database backup may copy the SQLite store only while the app is stopped or through a SQLite-consistent snapshot. Restores remain read-only until schema migration, integrity audit, capability-scope tests, and lifecycle sweep pass. Restored capabilities never gain broader scope.

## SLOs and degraded mode

- RPO: zero for an emitted live handle. No handle is emitted before durable read-back.
- Detection: an integrity or scope failure disables new lossy writes within one minute.
- Repair RTO: four hours when a staffed owner exists. Otherwise the product stays degraded and verbatim.
- Audit logs contain IDs, states, counts, timings, and reason codes, never prompts, terminal output, secrets, or recovered content.

Degraded mode is visible in Token Saver details. Operators first force the affected project to Verbatim, then stop the writer. Compatible readers remain available only for authorized, unexpired references.

Project runtime admission is centralized and fail-closed. Missing scope, an off lane, unavailable evidence, an unnamed owner, opt-out, or a kill switch returns the original bytes and suppresses live savings/learning writers. Shadow lanes may write only their explicitly retained, exact-scope records and content-free observation rows. A launch lifecycle-sweep failure keeps AppContext and the UI available, exposes `tokenSaverLifecycleDegradedReason`, and denies every Token Saver writer/live substitution until lifecycle health is restored.

Provider hints are injected only for an admitted thread. The runtime environment carries exact workspace, project, thread, provider, and per-run attempt scope; legacy global AGENTS.md/CLAUDE.md managed blocks are removed. Fresh and recovered Claude, Codex, and Grok turns use the same admission contract.

Deterministic compression never adopts local-model output. A semantic candidate becomes live only when `semantic_prose` is promoted with positive retention, the sidecar returns one scoped capability, AppContext retrieves the byte-exact original in the same scope, and the corresponding outbox acknowledgment succeeds. Missing capability, idempotency key, read-back mismatch, or retention denial returns deterministic/verbatim bytes.

SessionLearn writes bounded private text only for the exact workspace/project/thread/provider scope when its lane is shadow-only or promoted. Shadow performs bounded relevance retrieval for content-free telemetry without changing provider bytes. Promoted retrieval may append at most 512 bytes of relevant exact-scope learning to the outbound prompt; wrong-thread records never participate. Semantic, adaptive-effort, visual, and provider-native shadow telemetry uses reachable request signals or an explicit `unavailable` reason and never stores prompt/attachment content in the attempt ledger.

The measurement lane begins an exact-scope attempt before provider send, records only input byte count at treatment join, and adds `unattributed_provider_input` from actual provider `inputTokens` events. Token estimates and character counts never populate the provider-input Pareto ledger.

## Incident procedure

1. Force Verbatim or activate the lane kill switch. Do not delete evidence yet.
2. Stop new writes; drain `PREPARED` work and quarantine `SENT_UNKNOWN`. Never replay an ambiguous external mutation.
3. Capture content-free audit rows, sidecar status, provider/adapter/model versions, schema version, free disk, and failing attempt IDs.
4. Run scoped authorization, integrity, lifecycle sweep, outbox idempotence, and provider parity tests.
5. Repair forward. If safe repair is unavailable, keep the lane off and tombstone affected content.
6. Restore a writer only after the lane-specific scorecard passes and its named owner signs. Preserve compatible readers until references expire or migrate.

## Rollback and decommission

Rollback order is writer off, in-flight drain/quarantine, verbatim provider delivery, compatible reader retention, then data expiry/migration. A rollback must preserve content-free audit evidence without retaining user-deleted content.

Decommission removes unused models, indexes, wrappers, and controls only after export and retention obligations are satisfied. Remove the writer before the reader. Persistent project opt-out survives relaunch.

## Quarterly game day

Once per quarter, Test and Release plus Operations exercise: corrupted bytes, wrong-scope capability, full quota, low disk, crash between `PREPARED` and `DELIVERED`, duplicate/reordered ACK, unknown adapter version, migration/rollback, project deletion, restore, orphan sweep, and rollover return-to-parent. Pass requires zero unauthorized retrieval, zero unrecoverable live marker, zero duplicated external effect, verbatim fail-open, and content-free audit evidence.

## Promotion record

Each lane requires a single named owner, provider/model/version/cache/language/hardware/workload strata, at least 99% local/provider join coverage, at most 2% reconciliation error for exposed fields, powered isolated crossover evidence, quality/latency/economics/compatibility gates, and a tested kill switch. Aggregate savings cannot hide a failing stratum. Without that record the lane remains off or shadow-only.
