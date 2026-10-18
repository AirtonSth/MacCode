# Host executable rollback

## Supported command

Use `RemoteCode --rollback-host APP [-- args]` to validate and start a target host executable against the current host database. The host must be stopped: the command acquires the exclusive App Support instance lock and refuses to continue if another host owns it. The compatibility preflight opens the existing database read-only and does not restore it. After a successful handoff, normal target startup can write its ordinary state; the diagnostic query used in these tests exits before startup services.

The target must be an app directory with a regular executable at `Contents/MacOS/RemoteCode`, an `Info.plist` naming `RemoteCode` as `CFBundleExecutable`, containing the same bundle identifier and integer `RC2DatabaseSchemaVersion` equal to the running host's exact current schema, and a valid non-ad-hoc signature from the same signing team. The database schema must be a positive integer no newer than the target's advertised schema. Missing, old, malformed, or otherwise unknown metadata is rejected before the target executable runs. A forged current metadata value does not bypass signature verification.

Forwarded arguments require an explicit `--`. For example, `RemoteCode --rollback-host APP -- --database-schema-version` forwards only `--database-schema-version` to the target. This proves target execution and schema query only; it does not prove the full native application lifecycle or broad historical compatibility.

Packaging writes `RC2DatabaseSchemaVersion` as an integer, obtained by invoking the freshly built executable's side-effect-free `--database-schema-version` query before signing.

This command guards only the new supported rollback path. Launching an arbitrary older binary directly remains unsafe and is not retroactively fixed or covered by a whole-compatibility claim.

## Evidence and limits

Exact final tested tree: `a9c04a794f98c2ecb9e0ded77115d1790509f7f1`. Native packaging completed with signing team `6SV3W8BFYJ`. The packaged executable and sealed plist both reported schema 97. Binary SHA-256: `ea080c9fc5d30dcc4293324c11d9ec435407d91281e82ac9606fb18a03c248e2`.

The final combined run executed 18 tests with 2 optional pre-revocation fixture export/verification skips and zero failures in 11.944 seconds. All three new rollback tests ran without skips or failures in 1.675 seconds, including the real packaged CLI test. The existing recovery-rollback CLI test also passed in 1.385 seconds. Instance-lock, restore, and SQLite backup regressions passed in the same run. Package shell syntax validation passed.

The CLI fixture reproduces the modern held-row conditions from the unsafe historical claim probe: queued Agent and Bot intent, no lease, and approved=0 review holds. It also contains a canonical conversation/thread, history, a revoked binding at revision 2, and a cancelled attempt. Every logical schema/table row is compared before and after each CLI call; the held Agent queue remains unclaimable and no active runs appear.

A synthetic legacy app with absent version metadata never executed its marker. Forged current metadata on an unsigned target was refused. Invalid syntax and mixed restore commands were refused. A signed compatible target with a schema-98 database was refused before execution. A valid signed self-handoff using only `--database-schema-version` returned 97. Metadata tests also reject a different executable name, floating-point values, booleans, strings, and older versions. This does not establish normal target startup or full application lifecycle compatibility.

Independent source review `01a147fe-594c-7882-a930-e928c8170561` found no concrete defect in the rollback flow. The final executable-name binding was reviewed separately. An initial test variable compile error was fixed before the successful final run. Fixture directories and capture files were temporary; cleanup assertions passed for file closing and removal during test teardown. All task-owned CLI processes exited; no simulator, provider execution, personal host, or personal database was needed.

No UI changes or new visual/accessibility proof are claimed. Existing 21 skill ledgers remain preserved. This checkpoint does not mark S-008 complete.
