# C3: auth principal cache, single verify, read gateways on the WAL reader

Date: 2026-10-06. Branch: `fix/bots-vm-agent` (worktree `20261006T005023Z`).
Before: `1ecbeb139`. After: the C3 commit. Raw samples: `c3-auth-readdb-raw.json`.

## What changed

- `DeviceTrustRepository.verifyCached` keeps a token-hash → `DeviceTrust` cache per
  repository instance. An entry is good for 60 s and only while the process-wide
  `trustGeneration` is unchanged. Every trust write (revoke, delete revoked,
  always-allow, redeem, approve) bumps the generation after it commits, so a revoke from
  Settings (its own repository) is refused on the device's next request. Unknown and
  revoked tokens are never cached. A hit runs no SQLite.
- `last_seen_at` keeps the 60 s debounce but is written on a utility queue after the
  request is authorized. It is no longer an inline UPDATE on the request thread.
- `LocalAuthAdapter.verify`, `authorizedRPCPrincipal` and `authorizedOwnerFingerprint`
  use the cache.
- `DirectHTTPServer` resolves the bearer once per request and reuses the principal's
  owner fingerprint. Before, `/v1/rpc` resolved it twice and the other `/v1` routes
  verified and then resolved again. The WS upgrade gate reuses its owner the same way.
  `/v1/health` `request_phases` gains an additive `auth_ms` lane.
- These read on AppContext's WAL reader (`readDB`) instead of the writer connection:
  `AgentThreadListGateway` (thread list and running-workspace projection),
  `AgentAppReadGateway` (message list and pages, thread list, locked-thread set, queued
  messages, pending callbacks), and the `agent.thread.read` v1 stream-row selection
  (`AgentRunRepository(db:readDB:)`). The v1 path still flushes buffered stream writes
  under the mirror lock first. It releases the reader before decode, because rehydrating
  an oversized row writes `last_access_ms` on the writer.

## Method

The receipts come from an XCTest harness, `Tests/AppShellTests/HostConnectionAuthReceiptTests.swift`
(opt-in with `RC_HOST_CONN_RECEIPTS=1`), run in the debug build through
`scripts/isolated-sandbox.sh test`. Machine: Apple M5 Max, macOS 27.0.1. Before and after
ran on the same machine and in the same harness, minutes apart, with no other build
running.

The harness is unchanged between the two runs. The only difference is the production
wiring under test. Each scenario builds:

- a file-backed `AppContext` (writer and WAL reader, as in the app);
- the production `LocalAuthAdapter`, `AppCommandRouter` and `JSONRPCDispatcher`;
- a real `DirectHTTPServer` over loopback TCP, with a paired bearer;
- 150 threads, one of them holding 100 messages of about 1 KB each.

"Writer held" means another thread opens `BEGIN IMMEDIATE` on the writer connection for
250 ms, and the request starts 20 ms into that window. This is how a long stream batch,
receipt finalize or pruning pass holds the writer. "Other connection holds write lock" is
a second SQLite connection holding `BEGIN IMMEDIATE` for 1 s while the device's
`last_seen_at` is more than a minute old. It uses a fresh adapter per sample, so the run
is always a cache miss.

Held scenarios discard 2 warm-up samples and keep 7. Idle RPC scenarios run 5 warm-ups
and keep 30. Adapter idle runs 5 warm-ups and keeps 200.

## Receipt (milliseconds)

| Scenario | n | Before p50 / p95 | After p50 / p95 |
|---|---|---|---|
| Principal resolve, idle | 200 | 0.157 / 0.319 | 0.009 / 0.010 |
| Principal resolve, writer held 250 ms | 7 | 231.9 / 238.0 | 0.113 / 0.156 |
| Principal resolve, first request of the minute, other connection holds write lock 1 s (cache miss) | 7 | 143.3 / 153.9 | 0.648 / 0.864 |
| `/v1/rpc system.ping` + bearer, idle | 30 | 2.89 / 6.00 | 0.41 / 0.58 |
| `/v1/rpc system.ping` + bearer, writer held | 7 | 231.2 / 233.5 | 1.54 / 1.81 |
| `/v1/rpc agent.message.list` page of 50, idle | 30 | 58.5 / 60.5 | 37.5 / 38.5 |
| `/v1/rpc agent.message.list` page of 50, writer held | 7 | 290.0 / 295.9 | 51.1 / 53.8 |
| `/v1/rpc agent.thread.list` (150 threads), idle | 30 | 225.1 / 231.8 | 148.7 / 150.7 |
| `/v1/rpc agent.thread.list` (150 threads), writer held | 7 | 385.0 / 392.8 | 396.9 / 402.8 |

## Reading it

- Auth no longer waits on the writer. Before, a request that landed during a 250 ms
  writer transaction waited out the rest of it. Now it resolves in about 0.1 ms.
- The first request of each minute no longer stalls behind another connection's write
  lock. Before, it paid about 143 ms. Most likely the inline `last_seen_at` UPDATE ran
  while the lookup statement still held its read snapshot, so it got `SQLITE_BUSY` and
  retried until it gave up, then dropped the write. That cause is inferred, not traced.
  Now the request returns in under 1 ms, and the deferred write lands after the lock is
  released (`test_lookupMissDoesNotWaitForAnotherConnectionsWriteLock`).
- Message pages held behind the writer drop from 290 ms to 51 ms. The remaining 51 ms
  matches the idle cost of this RPC, not writer wait.
- **`agent.thread.list` under a held writer is not improved** (385 → 397 ms p50, +3%,
  inside `max(25 ms, 5%)`). Its SQL now runs on the reader, but `encodeThread` →
  `appendActiveRun` → `AppCommandRouter.activeAgentRun` → `durableActiveRunChrome` still
  issues one writer-connection SELECT per thread on MainActor (150 here). The first of
  them waits for the writer. Batching that projection on the reader and off MainActor is
  left for C5 (H2a/b) and is not claimed here.
- The idle `agent.thread.list` and message-page improvements (225 → 149 ms and
  58 → 38 ms) are larger than auth alone explains. Part of the gap may be run-to-run
  variance: the before thread-list samples drift down to 166 ms at the end. Only the
  held-writer rows are claimed as wins. The idle rows are claimed only as "no
  regression".

## Not measured

- The live sandbox app (`RC2_SANDBOX_HTTP_PORT=18219 scripts/isolated-sandbox.sh run`)
  was not launched. Every debug-channel instance binds `/tmp/RemoteCodeDebug.sock`, and
  that path is held by another worktree's sandbox app (pid 22345, worktree
  `20261005T042010Z`). Launching would unlink and steal its socket. These receipts
  instead exercise the same production objects in-process over real loopback TCP.
- Release-build timings, the reconnect burst from a real iPhone, and the `auth_ms` lane
  in a long-running host.
