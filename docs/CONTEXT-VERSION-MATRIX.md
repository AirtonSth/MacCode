# Context version compatibility matrix

## Scope

This is bounded compatibility evidence for host schema 93 and schema 97, not completion of stage S-008 or approval for broad adoption. Tests used synthetic tokens and databases, loopback-only servers, and disabled launch-run reconciliation. No personal database, provider credentials, or provider runs were used.

The actual macOS host sources were tested at old `640bf7662b808df0f8f68ae355f1ad1c7ec2a49f` (schema 93) and new `51672671ab026cd5dd0d93145c6b139aace46194` (schema 97). Each server used real AppContext, router, Dispatcher, DirectHTTPServer, and DeviceTrustRepository-generated synthetic tokens on loopback ports 18371 and 18372.

The actual iOS transport sources were tested at old `1db208d05ee0302dadfa186e48197e79abb2d8e6` and new `677a76a3cf821eaa1ba559b3753d89c7440b3d77`. The same appended `TEST` ran in registered `RealHostContractTests`; production sources were unchanged. Exact iOS test tree: `c5d1ef6f20fcd09fab47462d4744c0f797234d45`.

## Client and host matrix

Both platform builds-for-testing succeeded on exclusive iPhone 17 / iOS 26.5. Each client ran two tests against the two host versions: four tests total, one per matrix cell, with zero skips and failures. XCTest duration was 0.128 seconds per client. Combined xcodebuild orchestration took 34.96 seconds and exited 0.

| iOS transport | Host schema 93 | Host schema 97 |
|---|---|---|
| Old | 1 passed, 0 skipped, 0 failed | 1 passed, 0 skipped, 0 failed |
| New | 1 passed, 0 skipped, 0 failed | 1 passed, 0 skipped, 0 failed |

The real calls covered list/select, durable `agent.message.list` history, array-form AgentQueue and object-form BotQueue. UUID case normalization was checked. On current host, explicit complete-but-ungranted context read returned exact `-32084`. On old host, `bot.context.list` returned exact legacy refusal `-32097`, not method-not-found. Database inventories before and after matched for IDs, history, and queues. Both real server processes exited 0.

## Restore CLI and rollback

The unchanged packaged CLI binary had SHA-256 `fa92966d2372b56227e035d46ba19fc1f4808b96d2a62330decd0bf9448cd730`. The rollback-plus-current-hold tests ran on current tree `1fc527a448b55fdc0cb0e0cc849135a5cc63f049`: two tests, zero skips/failures, 1.471 seconds. Actual restore began from a pre-revocation snapshot; recovery rollback preserved one revoked binding at policy revision 2, the cancelled run, stable IDs, and queue-attempt identities. First restore imported pre-snapshot history; its recovery copy retained post-snapshot history. Restoring that recovery recovered the later history, while the second recovery copy retained the first imported snapshot. No provider run started.

Current host refused the claim after checking queued state, no initial lease, and hold approved=0. The historical probe asserted successful release and verified both lease fields cleared. In contrast, the negative diagnostic against a copied modern schema showed a real old host's `Schema.migrate` plus `claimFirst` could claim a held item: one test, zero failures, 0.059 seconds. This is an **unsafe diagnostic result**, never evidence of compatibility.

The tested rollback scope is the historical client transport against the new host, or the recovery CLI under the new host; this is not a claim of complete historical-app compatibility. Running a raw older host against a modern database is unsupported and unsafe. CLI test evidence does not establish broader compatibility or complete S-008. Earlier failed parser/history tests were not passes. No UI changes or new visual/accessibility proof are claimed; prior ledgers remain unchanged. No scratch paths or tokens were persisted. Cleanup results are recorded below.

## Host executable rollback — superseding checkpoint

The newer supported rollback command and its limits supersede any broader reading of the historical restore/rollback evidence above. It does not restore the database, prove the full native lifecycle, or make direct arbitrary older-binary launches safe; S-008 remains incomplete. See [CONTEXT-HOST-ROLLBACK.md](CONTEXT-HOST-ROLLBACK.md) for exact tested-tree evidence and guard conditions.

## Reproduction and limits

`HostVersionMatrixServerTests.test_serveHostVersionMatrixFixture` requires fresh `RC_HOST_VERSION_MATRIX_ROOT` and a non-primary loopback `RC_HOST_VERSION_MATRIX_PORT`. It writes the generated synthetic pairing token and stable IDs to a local manifest. Run the same test source with each historical/current host revision. Supply those two manifest JSON objects as `RC_MATRIX_OLD_HOST_JSON` and `RC_MATRIX_NEW_HOST_JSON` in each iOS test target environment; run `HostVersionMatrixContractTests` with `RC2_REAL_HOST_TEST` enabled. The transport matrix does not exercise the entire HostSession lifecycle, provider execution, native UI, or automatic launch reconciliation.

`RC_HOST_MATRIX_BINARY` selects the unchanged packaged host executable for `HostRestoreRollbackMatrixTests`. The held-copy probe takes `RC_HOST_MATRIX_HELD_COPY` and `RC_HOST_MATRIX_EXPECT_HELD`: 1 for the current host, 0 only for the historical unsafe-downgrade diagnostic on a disposable modern copy. Never apply that historical probe to a live database.

A file-byte checksum comparison during copy verification did not hold; byte-identical source preservation is not claimed for that step. A separate read-only comparison verified every logical table row in both probe copies against their source, excluding only the deliberately added hold rows. No runs or grants were added. The earlier four-cell inventory comparison also passed independently.

## Cleanup

Both host fixture processes exited successfully. The exclusive simulator was deleted and its absence verified. Five owned fixture/copy directories and both temporary historical worktrees were removed after source-diff checks. Pre-existing simulators, worktrees, App Support, and the running personal host were preserved. Independent review objections about exact authorization errors, bounded CLI execution, and lease cleanup were addressed and the affected checks rerun.
