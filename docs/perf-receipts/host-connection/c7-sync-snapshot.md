# C7: `sync.snapshot` join, fence tolerance, off-main encode, bounded threads

Date: 2026-10-07. Branch: `fix/bots-vm-agent` (worktree `20261006T005023Z`).
Before: `04207888b`. After: the C7 commit. Raw samples: `c7-sync-snapshot-raw.json`.

## What changed

- **Late callers join the read.** `JSONRPCDispatcher.readConnectionSnapshot`
  used to throw `-32013 snapshot_timed_out` at once for every caller that
  arrived while another snapshot read was running. Now one physical read runs
  at a time and every caller that arrives during it waits for the same result.
  Each caller still has its own deadline and its own cancellation, so one
  caller timing out or disconnecting never fails another. The read stops
  before its next attempt once nobody is waiting. A failure reaches every
  joined caller and frees the slot for a fresh read.
- **The fence tolerates idempotent kinds.** `EventBus` keeps a second
  revision, `fenceRevision`, that skips live-only kinds and
  `EventBus.snapshotFenceIdempotentKinds`: `surface.renamed`,
  `surface.updated`, `surface.health`, `workspace.updated` and
  `agent.thread.updated`. These payloads only set absolute field values on an
  entity that already exists, and the iOS reducer applies them as field sets.
  The snapshot keeps the pre-read watermark, so the client replays them on top
  of the state and ends at the host's value. Creates, closes, moves, reorders
  and deletes still force a retry (`-32012` after three).
- **Rows are captured on main and encoded detached.** `AppCommandRouter`
  captures layout, surfaces and browser URLs on MainActor, lists threads off
  main as before, then does the grouping and the per-row
  encode → JSONSerialization → JSONValue round trip in a detached
  `.userInitiated` task. New signposts on `io.remotecode.perf`:
  `connection_snapshot_capture` and `connection_snapshot_encode`.
- **Opt-in bounded thread list.** See "Wire contract" below. Without the new
  parameter the snapshot is byte-for-byte what it was.
- **Chunked cap raised.** `sync.snapshot.begin` accepts frames up to 4 MiB
  (was 1 MiB). When a frame needs more than 128 chunks at the negotiated size,
  the chunks grow (at most 32 KiB). The cache budget is 16 MiB (was 8 MiB).
  The single-response `sync.snapshot` keeps its 1 MiB ceiling.
- `/v1/health` `request_phases` gains `snapshot_joined_total` and
  `fence_tolerated_total`.

## Wire contract (iOS)

All additive. Old iOS builds see no change except that a concurrent
`sync.snapshot` now succeeds instead of returning `-32013`, and that a
snapshot can now succeed while a rename or thread update is in flight.

- Welcome capability `snapshot.agent_threads.window.v1`.
- Parameter `agentThreadsRecentPerWorkspace` (integer, at least 1, clamped to
  500) on `sync.snapshot` and `sync.snapshot.begin`. Send it only after seeing
  the capability: older hosts reject unknown parameters with `-32602`. A
  boolean, float, string, 0 or a negative value is `-32602`.
- With the parameter, each workspace keeps its `pending` and `running`
  threads, its pinned threads, the threads its surfaces select
  (`metadata.selected_thread`), and the N most recently updated others, in the
  original order. Every `agentThreads` group then carries two more keys:
  `totalCount` (all threads of that workspace) and `truncated`
  (`items.count < totalCount`). When `truncated` is true, iOS must not treat
  missing threads as deleted; the full list comes from `agent.thread.list`
  with that `workspace_id`. `agent.thread.updated` can arrive for a thread
  outside the window.
- For the chunked path to help iOS above 1 MiB, iOS must raise its own
  `SnapshotChunkSizePolicy.maximumTotalBytes` and the decode limit it applies
  to the assembled frame. Until then a frame above 1 MiB fails on iOS with
  `limitsExceeded` instead of the old host `-32603`. Both end in
  `failSynchronization`.

## Method

Harness: `Tests/AppShellTests/HostConnectionSnapshotReceiptTests.swift`,
opt-in with `RC_HOST_CONN_RECEIPTS=1`, run in the debug build through
`scripts/isolated-sandbox.sh test`. Machine: Apple M5 Max, macOS 27.0.1. The
harness file was identical in both runs and sends raw JSON, so it compiles
against both sources. Before ran on the `04207888b` sources and after on the
C7 sources, back to back, with no other build running.

Each scenario builds a file-backed `AppContext` with the production event
persister, the production `AppCommandRouter` and `JSONRPCDispatcher`, and a
real `DirectHTTPServer` over loopback TCP with a paired bearer. The host is
seeded with 9 workspaces × 20 agent threads (180; the live DB has 177
workspace-bound threads). Each scenario runs 5 warm-ups, then keeps 15
samples (30 calls for the two-caller scenario).

- "Two concurrent callers": two `sync.snapshot` requests sent together.
- "Under updates": a background thread publishes one `surface.renamed`
  (spinner title) and one `agent.thread.updated` (unread flag) every 2 ms
  during the whole run. That is much denser than the live spinner (about one
  rename per second), so it is a stress case, not the typical load.
- "Main stall" is the longest a `MainActor.run {}` hop, polled from a
  background task every 0.25 ms, waited while the request was in flight.

## Receipt

| Scenario | Before | After |
|---|---|---|
| Two concurrent callers: calls that got a snapshot | 15 / 30 (every second caller `-32013`) | 30 / 30 |
| Under updates every 2 ms: calls that got a snapshot | 0 / 15 (all `-32012`) | 15 / 15 |
| Idle, end-to-end p50 / p95 (ms) | 89.6 / 106.2 | 91.3 / 95.3 |
| Idle, main stall p50 / p95 (ms) | 9.61 / 12.46 | 0.075 / 0.44 |
| Idle, response bytes (180 threads) | 128,428 | 128,428 |
| Bounded window, 5 per workspace: bytes | rejected (`-32602`) | 47,445 |
| Bounded window, 5 per workspace: p50 / p95 (ms) | n/a | 44.0 / 49.1 |

Two-caller latency after C7 is 98.5 / 104.3 ms (p50 / p95) for both callers.
Before, the first caller took about 90 ms and the second failed in about 2 ms.
Under updates, after C7 is 96.6 / 101.9 ms. Before, each call failed after
about 39 ms (three fenced attempts).

## Reading it

- **A second device no longer breaks the first reconnect.** Every concurrent
  caller now gets a snapshot from one SQLite read. Before, half of them got a
  retryable error and had to come back.
- **Title spinners and thread touches no longer starve the baseline.** With
  idempotent updates crossing every read, no snapshot succeeded before; all
  succeed now, each from one read (no retries).
- **Main thread is free during a snapshot.** The longest MainActor wait during
  a snapshot drops from 9.6 ms to 0.08 ms (p50), because the row encoding left
  main.
- **Idle latency is unchanged within noise.** p50 is 1.7 ms slower (1.9%,
  within the `max(25 ms, 5%)` budget) and p95 is 11 ms faster. Most of the
  90 ms is spent off main (thread list and HTTP-side encode); this slice did
  not profile it.
- **The opt-in window cuts the payload by 63%** for this seed (5 recent per
  workspace plus running, pinned and selected rows), and the request is about
  half as long.

## Correctness coverage (unit tests, not timings)

`Tests/SocketServerTests/ConnectionSnapshotJoinFenceTests.swift`:

- immediate path: two concurrent callers both succeed from one read with the
  same watermark; a caller after a timed-out caller joins the still-running
  read;
- eventual exact completion: one physical read per join; a cancelled caller
  does not fail the other;
- A to B: a structural change (`surface.closed`) inside read A discards A and
  returns read B;
- fence: all five idempotent kinds crossing the read succeed in one read and
  keep the pre-read watermark; `EventBus.fenceRevision` skips idempotent and
  live-only kinds and still advances on `agent.thread.created`;
- failure: a failed read reaches every joined caller, and the next caller
  starts a fresh read;
- size bound: the window keeps running, pending, pinned and selected rows plus
  N recent, in order, at most always-kept + N rows, with `totalCount` and
  `truncated`, and the frame passes the strict contract validator;
- HTTP: no parameter keeps the legacy group keys and the full list; the
  parameter bounds `sync.snapshot` and is accepted by `sync.snapshot.begin`;
  invalid values return `-32602`; the welcome advertises the capability;
- chunk cache: a 3 MiB frame inserts within 128 chunks, small frames keep the
  negotiated size, and 4 MiB + 1 is rejected.

`ConnectionSnapshotPhase3Tests` updates: the "fence still retries" test now
uses `surface.closed`, since `surface.renamed` is tolerated by design.

## Not measured

- The live sandbox app was not launched. As in C3, C5 and C6, these receipts
  drive the production objects in-process over real loopback TCP.
- One before run and one after run. Release-build timings, and a real iPhone.
- iOS does not yet send the window parameter or accept larger chunked frames,
  so the bounded and chunked gains reach users only after the iOS change.
