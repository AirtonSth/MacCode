# Context-scoped backup and restore

This document records bounded native CLI proof for backup and restore of context-scoped resume state. It does not change UI, public gates, or iOS source behavior. iOS work is documentation-only.

## Backup scope and handling

Backup contains scoped session history and host bindings alongside the SQLite database. Keep the backup SQLite file and its matching `<backup>.scoped-sessions` archive together; separating or replacing one without its pair loses the captured scoped state. Archive covers scoped history and bindings only, not browser state or unrelated Application Support data. Only top-level generated configuration and credential entries are excluded: `config.toml`, `auth.json`, `claude-auth.json`, `codex-auth.json`, `openrouter-auth.json`, `accounts`, `.env`, and `.mcp.json`; `.DS_Store` is excluded as system metadata. Other native session and tool-output data remain included. Legacy database-only restore is accepted only when current native history is absent.

Example against the actual host executable, with exclusive host lock and appropriate host paths/permissions:

```sh
RemoteCode --create-database-backup /secure/path/remotecode.sqlite.backup
RemoteCode --inspect-database-backup /secure/path/remotecode.sqlite.backup
RemoteCode --restore-database-backup /secure/path/remotecode.sqlite.backup --restore-review '<review_fingerprint from inspect>'
```

Inspect first and replace the quoted placeholder with its exact `review_fingerprint`. Every paired scoped archive requires confirmation. Restore does not start execution. Preserve the paired `.scoped-sessions` archive when moving/copying the database backup.

Restore stages the incoming files and a complete recovery pair before changing live native paths. An exclusive host lock covers both stores. Native directories move through a durable journal and undo area before the final SQLite commit. Rollback atomically retires installed history into a discard area before restoring undo, so interrupted cleanup never destroys the only original copy. Startup reconciles the journal before opening application state; unknown database state refuses startup and retains recovery material. Current authority remains authoritative, imported active provider state becomes interrupted, delegation closes, and queued work requires explicit review.

## Bounded implementation and proof

Source tree `c7ccfaeafd1d79f1d284c3a6059db63bd3100e41` was packaged by native build, exit 0; signed team `6SV3W8BFYJ`; executable SHA-256 `38c275a3d1849504da42ee0a05f2a954201265148ae69b6c9dfc6e5e349b8dd7`. Selected isolated native tests used filter `HostScopedSessionBackupCLITests|PrivateDirectoryTreeTests|HostDatabaseRestoreTests|HostRestoreRollbackMatrixTests|BotContextScopedResumeTests`, environment `RC_HOST_MATRIX_BINARY` set to actual dist binary, `RC_LIVE_DOCKER=1 RC_LIVE_DOCKER1=1`, and caller-owned `RC_CONTEXT_PROBE_ROOT`. Result: 21 selected, 19 passed, 2 skipped, 0 failed, 80.542 seconds. The two skips (`test_exportPreRevocationHostRestoreFixture` and `test_verifyPreRevocationHostRestoreFixture`) require explicit fixture environment; they are not core journey skips.

Follow-up exact Sources/Tests tree `c3f1523dcff5bc0d582d85d335173dad2031eee7` added test-only archive-history tampering with a valid review token and DB-only refusal over native history. Same selected source tree; five CLI tests passed, zero skips/failures, 32.422 seconds.

Final source review `01a1492b-4a5a-7a72-bd36-cadc6c14f00c` closed final retry-sync P1. Findings fixed included nonexistent destination, invalid initialization, partial deletion rollback, journal ownership, bounded enumeration, fsync, and equal-fingerprint rollback phase. Two real CLI child processes were SIGSTOP/SIGKILLed: first during install, then during rollback after atomic discard. A third process recovered full current DB fingerprint, native bytes and bindings, and removed journal/stage. This proves those exercised process-kill recovery windows, not host power loss or injected fsync failure.

Twelve scoped sessions and 199 owned native files were covered. IDs, pins and cursor remained preserved; current revoked revision 2 and terminal status remained; imported running child was interrupted; queues were held and delegation closed on successful restore. Aborted restore returned original current state, not forced new queue holds. Real Docker quiescence was checked; no provider execution occurred. Fixture data is not proof of native provider load or authentication.

Owned backup and file-tree fixtures were removed by their tests. After the test processes exited, four delayed resume remnants were inspected and removed: three contained only generated locks; one contained a generated lock and an empty SQLite schema with zero bots and zero threads. Final scoped fixture-directory absence was verified. Existing user resources were preserved.

## Limits and pending work

Full-plan acceptance, OAuth refresh, live provider execution, OS provider load, repair, rollout and measurements remain pending. UI/UX and the 21-skill ledger are unchanged; backend-only evidence does not open public gates or complete S-008.

## Later cleanup receipt repair checkpoint

The bounded explicit cleanup receipt repair path is now implemented and verified; see [CONTEXT-RECEIPT-REPAIR.md](CONTEXT-RECEIPT-REPAIR.md). Historical backup evidence above remains unchanged. Arbitrary unknown command outcomes still require evidence and are never replayed; broader lifecycle, provider, rollout and measurement limits remain open.
