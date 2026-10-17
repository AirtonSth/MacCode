# Host database restore without authority rollback

## Scope and baselines

The checkpoint implements the pre-revocation backup case from plan stages 7–8. The repository previously had relational thread undo and corruption quarantine, but no complete database-import entry. The new entry is an explicit offline host command, not a replacement UI or an automatic startup migration.

- macOS worktree: `/Users/samuelfajreldines/dev/remote-code/macos-app/.sandbox-worktrees/20261016T013608Z`; baseline `26ca24c6185d5a9b528204813c6bd5b7a78f9085`.
- iOS worktree: `/Users/samuelfajreldines/dev/remote-code/ios-app/.sandbox-worktrees/contextual-workspaces-20261015`; baseline `0c54616ced9762a094ef0f818207c3fda4544fa0`.
- iOS remains the controller of host-owned data. This checkpoint changes host code and shared documentation only; no iOS production source, layout, or controls changed. Earlier iOS verification is not presented as a new restore journey.

## Production entry and security ordering

`RemoteCode --restore-database-backup <backup.sqlite>` runs after acquiring the normal App Support instance lock and before constructing AppDelegate/AppContext, networking, provider execution, or schedulers. It requires an existing current database and a separate existing regular backup file. Missing, symbolic-link, same-file, and hardlink aliases are refused. A held or unavailable instance lock causes a nonzero exit without launching the normal app.

The host builds a private staging copy through SQLite's online backup API, rather than replacing database/WAL files. Before importing source data, it compares all SQL-bearing schema objects with a fresh trusted current schema. Unexpected triggers and altered or older schemas are refused. It obtains an exclusive SQLite connection to the current database and keeps that connection through the final atomic SQLite backup transaction. A private mode-0600 pre-restore recovery database is retained and its path is printed on success or reported after a later failure.

The staging database restores historical data while current security state wins:

- Replace imported context bindings with all current bindings. A missing current binding never becomes an imported grant.
- Preserve current settings, including host identity, boot/activity counters, security switches, Bot authority receipts, and current file grants. This is intentionally not a rollback of current settings.
- Preserve current-only bound Bot identities with their revisions and handle reservations. Current Bot metadata and deletion state win; conflicting reservations fail rather than silently reassigning identity.
- Preserve the current command-receipt ledger. Interrupted claims become `unknown` through the existing shipped recovery function; they do not become fresh claims that may be blindly repeated.
- Preserve matching current terminal run status and reason. Imported pending/running runs become interrupted through existing repository recovery methods.
- Preserve contextual queued-message IDs, body, attachment metadata, and immutable conversation pins. Existing host admission checks still refuse stale or revoked pins before provider preflight, attachment resolution, queue claim, or dispatch.

Integrity and foreign-key checks run before committing staging into the current database. The command exits without starting execution. Temporary staging files are removed; the source backup remains unchanged. If restore committed but staging cleanup failed, the error explicitly identifies the committed state instead of claiming that no restore occurred.

## Deliberate ceilings

Only an exact trusted current schema is accepted. Older-schema adoption needs a separately validated data-only import path; an older binary or arbitrary manual database-file replacement does not use this protection. Backups containing unpinned legacy queued work or enabled schedules are refused before replacing current content until an explicit-review import path exists. The original files remain available; refusal is not silent deletion.

An existing valid current database is required as the authority source. This does not establish safe restoration when both the database and current authority are lost or rolled back. Files outside SQLite, private attachment bytes, cookies, provider credentials, and every background-delivery ledger are not covered by this checkpoint. Public contextual model execution and restricted mode remain unavailable. Full plan delivery, cross-version rollout, human usability and complete accessibility remain pending.

## Verification

Final Sources/Tests tree: `6ed614915ac30f87e2280165af90850a240bf2eb`. Production sources are identical to packaged CLI-tested tree `9bbaa8a882e984a347e3cc4b1d2d454ea24a4da6`; the final difference is a test assertion distinguishing restore from a later legitimate boot-counter increment.

The parent ran the supported isolated native runner with SQLite backup, pre-revocation restore, context authority, prior copied-restore, routine scheduler, and pinned queue suites: **19 tests, 0 failures, exit 0, 11.457 seconds**. A preceding export-enabled run executed 21 tests with one intentionally unconfigured read-only verification skip and zero failures; the exported real fixture was then verified separately. Tests cover committed WAL data, locked-destination atomic failure, source/hardlink refusal, retained recovery permissions, schema-trigger attack (including a `sqliteX_` name), missing current authority, legacy queue refusal, current-only Bot profile editing/handle reservation, current settings/receipts, and stopped/imported run states.

The packaged debug host was invoked against task-owned synthetic databases at explicit isolated App Support and database paths. The source backup held A active at revision 1 and an active run. Current state held A revoked at revision 2, B/C active at revision 1, a cancelled original run, and a later command claim absent from the backup. Actual command results:

- With the real instance-lock file held: exit 1, current revocation unchanged, no recovery created.
- After releasing the lock: exit 0; retained recovery mode 0600; no staging files; source database hash unchanged.
- Restored A remained revoked at revision 2; source backup remained active at revision 1.
- Original run remained `cancelled` with `userStop`; backup-only active run became `interrupted`.
- Current receipts survived; an interrupted claim became `unknown`, including after another claim attempt.

The parent then ran **2 tests, 0 failures, exit 0, 0.084 seconds** against the actual CLI-restored database. One opened a real AppContext/router and attempted ordinary drain with recovery and explicit force-now twice. The original queue record remained equal in all decoded fields, both run states remained terminal, no messages appeared, and the controlled provider boundary received zero starts; provider catalog/attachment probes remained untouched. The other read back the actual restored database and authority. Opening AppContext advances the boot epoch normally; the unit restore test independently asserts the exact preserved epoch before that launch.

Independent review identified imported-schema triggers, incomplete merged Bot identity, stale occupancy caches, and a possible nested-lock reacquisition. The implementation now validates trusted schema, preserves revision/handle records, and clears both caches directly inside the serialized backup operation. The corresponding real-function tests passed. Earlier staging-lock, SQL alias, WAL-alias fixture and boot-counter test failures were corrected; they are not omitted from the recorded command history. Cleanup-failure injection and adversarial power-loss testing were not performed. Background Live Activity teardown can log errors in existing AppContext tests; passing selected tests does not prove that service healthy.

## Design and cleanup

No native view or interaction layout changed. Existing design ledgers remain in `CONTEXT-OFFLINE-INTENT.md` and `CONTEXT-GROUPING-DESIGN.md`; this backend-only command does not claim new browser, keyboard, VoiceOver, simulator, or human-trial evidence. Verification used synthetic databases and dedicated paths; no personal database, credential store, running host, or shared tool installation was modified. Task fixture cleanup is recorded separately before publication; retained recovery files in a real user restore are intentional deliverables, not temporary files to delete automatically.
