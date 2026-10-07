# C5: `agent.thread.read` v1 off MainActor, per-thread mirror lock, `bot.*` read/write split

Date: 2026-10-06. Branch: `fix/bots-vm-agent` (worktree `20261006T005023Z`).
Before: `9f3fd6da1`. After: the C5 commit. Raw samples: `c5-thread-read-bot-split-raw.json`.

## What changed

- `AgentRunCoordinator` uses one recursive mirror lock per thread
  (`MirrorEventLockTable`) instead of one lock for the whole process. Every holder
  (stream append and flush, the snapshot barrier, resume-cursor reads, purges) is
  already scoped to one thread id. A long flush or snapshot on thread A no longer
  holds a read of thread B, or B's stream durability and terminal path.
- `AppCommandRouter.readAgentThreadMirrorSnapshot` runs the v1 path (barrier
  flush, selection on the WAL reader, strict decode) in a detached
  `.userInitiated` task. The legacy unbounded path is unchanged.
- `JSONRPCDispatcher` encodes the v1 events and runs `boundToEnvelope` off
  MainActor (`threadReadV1Result`). It uses its own default `JSONEncoder` and
  `JSONDecoder`, so the bytes match the old path. The wire shape is unchanged.
- Paired `bot.*` reads (`list`, `get`, `settings.get`, `queue.list`,
  `conversation.list`, `attachment.list`, `routine.list`, `files.list`,
  `browser.state`, `guest.state`, `receipt.status`) run the authority off
  MainActor and never call `reloadQueuedFollowUpsFromStore`. `bot.attention.list`
  stays on MainActor, because its delegated-attention callback reads router state,
  but it no longer reloads the queue either.
- `bot.*` writes reload only the bot named by `bot_id`
  (`BotsViewModel.reloadQueuedFollowUpsFromStore(botID:)`). They publish only when
  that bot's persisted rows differ from what the desk holds. Writes that name no
  bot keep the fleet-wide reload.
- New signposts on the `io.remotecode.perf` points-of-interest log:
  `thread_read_v1_snapshot`, `bot_queue_reload_all` and `bot_queue_reload_bot`.

## Method

Harness: `Tests/AppShellTests/HostConnectionThreadReadBotReceiptTests.swift`, opt-in
with `RC_HOST_CONN_RECEIPTS=1`, run in the debug build through
`scripts/isolated-sandbox.sh test`. Machine: Apple M5 Max, macOS 27.0.1. The harness
file was identical in both runs and uses only API that exists before and after C5.
Before ran on the base sources. After ran on the C5 sources, about 35 minutes
later, with no other build running.

Each scenario builds:

- a file-backed `AppContext` (writer and WAL reader);
- the production `AppCommandRouter`, `BotsViewModel` and `JSONRPCDispatcher`;
- a real `DirectHTTPServer` over loopback TCP, with a paired bearer.

Threads A and B each hold 128 stream events with payloads of about 700 B, which is
a full v1 window. There are 20 bots with 10 queued follow-ups each (200 rows).

"Mirror lock held" means another thread holds thread A's mirror lock for 250 ms,
using the public v1 snapshot entry point, whose body runs under the lock. The
request starts 20 ms into that window.

"Main stall" is the longest a `MainActor.run {}` hop, polled from a background task
every 0.25 ms, waited while the request was in flight. It measures how long the
Mac UI and every other RPC were locked out by this request.

Held scenarios discard 2 warm-up samples and keep 7. Idle scenarios run 5 warm-ups
and keep 30.

## Receipt (milliseconds, p50 / p95)

| Scenario | n | Before end-to-end | After end-to-end | Before main stall | After main stall |
|---|---|---|---|---|---|
| `agent.thread.read` v1 of B, A's mirror lock held 250 ms | 7 | 273.0 / 282.3 | 56.5 / 59.1 | 231.9 / 238.0 | 0.13 / 0.20 |
| `agent.thread.read` v1 of A, A's mirror lock held 250 ms | 7 | 270.8 / 283.7 | 288.0 / 295.4 | 231.0 / 238.8 | 0.34 / 8.6 |
| `agent.thread.read` v1, 128 events, idle | 30 | 51.6 / 54.9 | 54.8 / 58.0 | 3.45 / 4.45 | 0.12 / 0.33 |
| `bot.receipt.status`, 20 bots / 200 queued, idle | 30 | 40.9 / 45.8 | 1.75 / 2.40 | 38.1 / 43.6 | 0.10 / 0.34 |
| `bot.list`, 20 bots / 200 queued, idle | 30 | 76.5 / 80.8 | 12.6 / 13.5 | 67.6 / 72.0 | 0.09 / 0.25 |
| `bot.set_pinned` (write, queue unchanged), idle | 30 | 55.5 / 61.0 | 6.7 / 35.4 | 53.2 / 58.0 | 3.8 / 32.2 |

## Reading it

- **A read of one thread no longer waits on another thread's mirror lock.** B's
  read under a held A lock goes from 273 ms to 56 ms, which is its idle cost. The
  main thread is no longer stalled for the 232 ms it used to spend blocked on the
  global lock.
- **A read of the same thread still waits, by design.** The barrier must order it
  after A's in-flight write (`test_threadReadV1_sameThreadWaitsForItsMirrorLock`).
  End-to-end it is +17 ms p50 and +12 ms p95, inside `max(25 ms, 5%)`. The main
  thread is free for the whole wait (231 ms → 0.34 ms p50). One sample showed an
  8.6 ms main stall that was not attributed.
- **Idle `agent.thread.read` v1 is +3.2 ms p50 and +3.1 ms p95 (+6%)**, inside
  `max(25 ms, 5%)` = 25 ms. Two detached hops cost a little end-to-end, and its main
  thread time drops from 3.45 ms to 0.12 ms. Most of the remaining ~50 ms is not on
  MainActor in either run. Where it goes (the barrier's `activeRunId` lookup, the
  reader query and decode, or response writing) was not traced in this slice.
- **Bot polls stop rescanning the fleet queue.** `bot.receipt.status` (24 iOS call
  sites) drops from 41 ms to 1.8 ms, and `bot.list` drops from 77 ms to 13 ms. Before,
  almost all of that time was MainActor time spent decoding 200 queue rows and
  republishing them.
- **Writes reload only their own bot, and only when it changed.** `bot.set_pinned`
  drops from 55 ms to 6.7 ms p50. The p95 of 35 ms comes from 2 of 30 samples (the
  4th and 14th, about 35 ms each) that also show in the main-stall lane. They were
  not attributed. Candidates are a WAL checkpoint, or the durable receipt
  claim/finalize that runs on MainActor (C6, not this slice). The write's p95 is
  still lower than before (61 → 35 ms).

## Not measured

- The live sandbox app was not launched. As in C3, `/tmp/RemoteCodeDebug.sock` is
  held by another worktree's sandbox app. These receipts instead drive the
  production objects in-process over real loopback TCP.
- Per-method `dispatchCore` p50/p95 in `/v1/health` `request_phases` was not
  added (see the harness section of the plan). Only the three signposts above were
  added.
- Release-build timings, and a real iPhone polling bots while a run streams.
