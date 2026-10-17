# Public contextual queue admission

## Scope

`bot.conversation.enqueue` is an explicit, authenticated, persistence-only mutation. It stores text in the existing Agent queue of an existing canonical contextual conversation. It does not call `bot.send`, provision a desktop, resolve attachments, select another conversation, start a provider or create a run/user transcript message. This supersedes the earlier absence of public contextual enqueue recorded in `CONTEXT-QUEUE-ROUTINE-AUTHORITY.md`; the earlier historical-queue evidence remains valid within its stated scope.

The iOS client registers the same finite mutation contract and uses its existing `HostSession.invoke` ledger. No new view, layout, composer control or queue engine is introduced. Prior native design consultation remains applicable; this checkpoint does not claim new manual UI or accessibility verification.

## Request and authority

The request contains exactly `client_request_id`, `host_id`, `bot_id`, `context_key`, `context_version`, `policy_revision`, `conversation_id` and `text`. The paired dispatcher injects the authenticated host identity rather than trusting the declared host. The Unix/provider socket refuses this mutation. There is no selected-conversation fallback or inferred legacy grant. Unsupported attachment and routing fields are rejected, as is whitespace-only text.

The host reloads the master setting, checks the current explicit send grant and matches the immutable conversation pin to the host, bot, context, version and policy revision. The linked thread must remain a locked Distill Bot thread with a guest execution target and matching workspace identity. Authorization is checked again inside the write transaction.

The existing Agent queue row, explicit human-review hold and Bot receipt/claim sidecars commit together. The queue repository reuses its existing row writer without a nested SQLite transaction. In-memory receipt/cache snapshots are restored on rollback and before a transaction retry. The new endpoint stores a SHA-256 parameter claim rather than another copy of the text in the receipt sidecar.

A completed receipt means that persistence completed, not that execution started. Its content-free readback identifies the queue row, conversation, thread, host, context and revision, with `enqueued: true`, `execution_available: false` and `requires_user_send: true`. Identical committed requests replay the original persistence acknowledgment without creating another queue row. Replaying that acknowledgment cannot revive revoked authority.

## Drain and failure semantics

The existing router checks current contextual authority before drain/force claim or recovery. Active contextual execution remains unavailable; revocation or a newer grant revision leaves the old pin unauthorized. The entire queue row and review hold remain intact, with no new run or transcript message. Public contextual execution, restricted mode and attachment admission remain closed until their independent probes and implementation are complete.

Typed domain refusals for this atomic enqueue operation remain definite refusals at the application-router boundary. A disabled master returns `-32081`, and revoked authority returns `-32084`, instead of incorrectly becoming `commandOutcomeUnknown`. Generic SQLite/commit errors retain the conservative unknown-outcome path. Existing mutation methods keep their previous behavior.

## Verification boundaries

The original macOS checkpoint used the actual `AppContext`, `AppCommandRouter`, authority, SQLite repositories and a direct `JSONRPCDispatcher.dispatchHTTP` call with a mutation principal. The follow-up below adds a real loopback listener and bearer admission; physical-device pairing remains unverified.

The iOS test uses the actual session and durable mutation ledger with a recording transport. It verifies the exact request fields, ledger-generated request identity and nested persistence receipt shape, not a real host connection or provider execution. The full iOS mutation catalog is checked against its vendored contract fixture.

The persistence failure test injects a real SQLite receipt-write abort. It verifies that the queue and review hold roll back, previous receipts/claims remain unchanged, and retry/reopen produce one durable row without private text in the receipt sidecars. This is not a power-loss, fsync-failure or authenticated provider test.

The complete eight-stage plan, contextual execution, OAuth, resource capacity, human usability/accessibility and rollout remain open. Live Activity SQLite warnings from AppContext fixtures do not establish Live Activity durability.

## Recorded native checks

At exact macOS Sources/Tests tree `f0a3e9a3977e934308221bb15b81d92e8b485f6f`, the isolated native runner completed 196 tests with 3 optional benchmark skips, zero failures, in 42.510 seconds (exit 0). The skipped formatter/checkpoint/stream benchmarks require `RC2_RUN_RESIDUAL_PERSISTENCE_BENCHMARKS=1`; they are not performance proof. The filter was:

```sh
RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1 RC_CONTEXT_PROBE_ROOT=<caller-owned> scripts/isolated-sandbox.sh test --build-system native --filter 'BotContextQueueAdmissionTests|BotContextPublicQueueTests|BotContextDispatcherTests|BotContextQueuedMessageTests|BotContextAuthorityTests|BotConversationContextTests|AgentQueuedMessageRepositoryTests|AgentQueuedMessageLeaseTests|Phase4MutationReceiptContractTests|ResidualPersistenceBenchmarkTests|BotRemoteControlAuthorityTests|BotsWindowTests.test_hostCatalogFollowUpDoesNotDrainAfterMasterControlPlaneDisabled|HostRestoreBotRestartTests.testReopenHoldsFailedBotAttemptAndForceDoesNotStartProvider'
```

At exact iOS App/Tests tree `c42dbbb5eaadb7299ea1bae7671be44c6459975b`, `xcodebuild test -project RemoteCode2App.xcodeproj -scheme RemoteCode2App -destination 'platform=iOS Simulator,id=CC8AB099-51D6-4AD7-95A2-EB006C80705C' -derivedDataPath .build-dd -parallel-testing-enabled NO -only-testing:RemoteCode2AppTests/ConnectionPhaseFourCatalogTests` passed 20 tests, zero failures, in 9.626 seconds (exit 0). The pre-existing simulator was reused, not deleted. This includes the exact finite catalog, wire fields, generated ledger identity and nested persistence receipt.

Earlier attempts are not passing evidence: initial test API assumptions did not compile; the iOS catalog initially lacked the new fixture entry; and the public master-off check exposed an incorrect unknown-outcome classification. The final checks above include those corrections. Independent source reviews `01a149dc-adcd-7a12-b257-c82acba4a205` and `01a149f5-751c-7df2-bfba-70b7435b5b57` found no concrete defect within their inspected scopes. They did not run the checks, prove live listener authentication or verify arbitrary commit/power-loss failures.

Native macOS packaging from the same tested source completed with exit 0 using `RC2_SWIFT_BUILD_SYSTEM=native scripts/isolated-sandbox.sh build`; codesign reported the bundle valid. Executable SHA-256: `80932d9ef2ccc16af48c64d2aab129a62f80c25555acf3ff12260987423a6a28`. No debug-host launch, production-host change, merge or release is claimed for this checkpoint.

## Real listener and authenticated-principal follow-up

The actual loopback HTTP entry initially inherited the existing trusted-local full-access fallback for the new mutation. Missing or invalid bearer could therefore enqueue contextual text despite the paired-only contract. The fix retains authentication provenance on `DirectRPCPrincipal`: verified credential resolvers produce authenticated principals, while both loopback fallback and the owner-fingerprint-only dispatch seam are unauthenticated. Only `bot.conversation.enqueue` requires the authenticated principal at the decoded RPC-item boundary, before dispatcher, ledger or repository work. Existing trusted-loopback behavior for other methods is unchanged.

The strengthened existing journey posts through `URLSession` to a real `DirectHTTPServer` listener. Missing and invalid fixture bearers are refused with no queued row or run; a valid fixture bearer creates the exact canonical queued intent and host-bound receipt. Existing replay, master-off, revocation, force/recovery and reopened-state checks then continue through the actual router. The listener binds only to loopback, retries only an occupied port before effects, and the test stops it and invalidates its ephemeral session. The synthetic auth adapter is kept alive because the server holds a weak auth reference; an intermediate fixture-lifetime failure is not counted as passing proof.

At exact Sources/Tests tree `f518e3e4a7345d3af35884791ff09b7e7cb5951b`, the isolated native run passed 80 tests, zero skips/failures, in 6.064 seconds (exit 0):

```sh
RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1 RC_CONTEXT_PROBE_ROOT=<caller-owned> scripts/isolated-sandbox.sh test --build-system native --filter 'BotContextPublicQueueTests|HTTPServerTests|BotContextDispatcherTests|HybridHTTPWebSocketContractTests'
```

Read-only source review `01a14a01-f28a-7440-90b3-a5d7ec7073d5` found no concrete defect in the new provenance guard and listener regression. It did not run the tests. The test uses a synthetic bearer resolver, not a production trusted-device pairing database or personal credentials; it does not establish a LAN/TLS, physical-device pairing, provider execution or runtime-isolation proof. iOS product code is unchanged in this follow-up, so the earlier 20-test contract proof is reused rather than presented as rerun. Layout and execution gates remain unchanged.

At this invocation, `RC_CONTEXT_OPENROUTER_PARENT_TEST_KEY`, `RC_CONTEXT_OPENROUTER_CHILD_TEST_KEY` and `RC_CONTEXT_OPENROUTER_TEST_MODEL` were absent (presence checked without printing values). Positive dedicated-provider delegation/revocation therefore remains blocked. Other implementation and acceptance gaps in the eight-stage matrix remain open independently of these inputs.

The follow-up native package build completed with exit 0 from the tested source; codesign reported the bundle valid. Executable SHA-256: `e66a13aaed6ad8b364a248016b871214c765ee8f0e4c59c18ab1a726176aafec`. Invocation-owned fixture remnants were inspected and removed; the test listener/session ended with the test process. The personal host and pre-existing simulator were not changed by this follow-up.
