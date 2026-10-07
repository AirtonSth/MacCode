# C8: durable replay, stream gaps and paged backlog (opt-in)

Date: 2026-10-07. Branch: `fix/bots-vm-agent` (worktree `20261006T005023Z`).
Before: `cb90e98cb`. After: the C8 commit. Raw samples: `c8-durable-replay-raw.json`.

## What changed

Everything below is behind an opt-in. A client that does not send the new
header or parameter gets exactly the old behaviour and the old welcome shape.

- **Durable replay.** A `/v1/ws` upgrade with `X-RC2-Durable-Replay: v1`
  whose cursor the in-memory ring (4096 events / 2 MiB, about 2 minutes of
  live traffic) no longer covers is now served from the `events` table on the
  read-only connection, then from the ring. Before, such a cursor always got
  `baselineRequired` and a full `sync.snapshot`.
- **Live-only kinds leave the contiguity check.** `agent.item.delta`,
  `agent.item.progress`, `surface.output` and its ring stand-in are never in
  the event log. The bus keeps a bounded ledger (1024 streams) of the newest
  lost event per thread or terminal. A thread whose deltas were lost after the
  cursor gets one `streamGap` frame; nothing else does. The ring deltas of a
  stream that already has a gap are skipped too (the client refetches it whole).
- **Paged backlog outside the delivery queue.** The socket subscribes before
  the welcome in a buffering mode (live events wait in the subscription, at
  most 16384 events / 4 MiB). The backlog is streamed from a background queue
  in 256 KiB slices; each slice waits until the outbound queue drains below
  256 KiB, so the backlog never fills the queue or sheds frames, and no
  publisher waits on it (`deliveryQueue.sync` only covers registration).
  Then `streamGap` frames, then `replayComplete`, then the buffered live
  events in order.
- **Honesty guards.** Durable replay is refused (the client gets
  `baselineRequired`, as before) when: a log write is not yet committed, a
  log write failed after the cursor, retention pruned past the cursor (checked
  per page with an anchor row in the same statement), the lost-stream ledger
  overflowed after the cursor, a row cannot be decoded, the live buffer
  overflows during the replay, the estimated replay is above the budget, the
  cursor is 0 (a client with no state), or the cursor sits below the ring
  and no resume envelope proves which boot it came from.
- **Replay budget (256 KiB).** See the receipt: replaying a one-hour gap from
  the log cost more than the snapshot it replaces, so a log replay estimated
  above 256 KiB of wire bytes falls back to the baseline. The estimate is
  an index seek for an anchor row (none: the log no longer reaches the
  cursor, baseline without a sum) and a count + byte sum over at most
  `256 KiB / 200 + 1` rows, so its cost does not grow with the gap.
- **Restart.** A clean quit writes `event_bus.durable_resume.v1` (last seq,
  newest lost seq per stream) as its last step, after the servers stopped and
  the log was flushed. Any later non-diagnostic event clears it. The next boot
  consumes it, continues its sequence above that high water (no seq a client
  saw is reused), and accepts a cursor from the previous boot epoch for
  durable replay. Without the record (crash, forced quit, pending writes) a
  previous-epoch cursor still gets a baseline.
- `events.recent` accepts `durable: true` for the same replay over HTTP.
- `/v1/health` gains `durable_replay` (`served_total`,
  `baseline_required_total`, `closed_total`, `live_buffer_overflows_total`,
  `events_replayed_total`, `stream_gaps_sent_total`); each replay also logs
  `[RC2.WS] durable replay since=… head=… outcome=… ms=…`.

## Wire contract (iOS must adopt to benefit)

All additive and opt-in; old iOS builds are unaffected.

- Welcome capability `events.durable_replay_v1` (on every welcome; old peers
  ignore unknown capability strings).
- WebSocket request header `X-RC2-Durable-Replay: v1`. Safe to send to any
  host: an older host ignores it (no `replayFromSequence`, old behaviour).
- On a durable socket only, the welcome carries one more key,
  `replayFromSequence` (integer, `0...currentSequence`). iOS decodes welcome
  with an exact key set, so it must accept this key exactly when it sent the
  header.
  - `replayFromSequence == the client's cursor`: the socket replays
    everything after the cursor. No `sync.snapshot` and no `events.recent` is
    needed. `oldestReplaySequence` is `cursor + 1` (or `currentSequence`).
  - `replayFromSequence == currentSequence` (and != cursor): a
    `baselineRequired` frame follows; take the snapshot as today.
- New frame `streamGap` (durable sockets only):
  `{protocolVersion, type: "streamGap", connectionId, hostId, bootEpoch,
  threadId | surfaceId, sinceSequence, throughSequence}`. Exactly one of
  `threadId` / `surfaceId`. Action: refetch that thread's tail with
  `agent.thread.read` v1 (or that terminal), after applying the replayed
  events. This is the plan's `stream_gap {thread_id, since_seq}`.
- New frame `replayComplete` (durable sockets only):
  `{protocolVersion, type: "replayComplete", connectionId, hostId,
  bootEpoch, throughSequence}`, `throughSequence == welcome.currentSequence`.
  Catch-up is done when it arrives; mark the stream live then. A
  `baselineRequired` can still follow later (live-buffer overflow or
  outbound pressure), as on any socket.
- Replayed events are ordinary `event` frames in ascending sequence with
  holes (live-only seqs are skipped); `sequence.omissions.v1` already says a
  hole is not a gap. Replayed events from the log carry `occurredAtEpochMs`
  at whole-second precision (the log stores ISO-8601 seconds).
- The event log only serves a cursor whose boot the host can prove: send
  `X-RC2-Resume-Host-Id` / `X-RC2-Resume-Boot-Epoch` (iOS already does). A
  durable socket without them is served from the ring or gets
  `baselineRequired`, as before C8: its cursor could come from a boot that
  crashed before persisting its tail, and that boot's lost deltas are in no
  ledger.
- `streamGap` is only sent for streams the socket's filter carries. A
  `cellular-safe` socket with interest threads gets no gap for a thread
  outside its interest set; replayed events go through the same filter as
  live ones.
- A durable socket that cannot drain one 256 KiB replay slice within 10 s
  gets `baselineRequired` instead of an indefinite wait.
- Restart: send the old `X-RC2-Resume-Host-Id` / `X-RC2-Resume-Boot-Epoch`
  as today. With the durable header, a cursor from the immediately previous
  boot epoch can now be accepted (`replayFromSequence == cursor` although
  `bootEpoch` changed). iOS must then keep its mirror instead of treating the
  epoch change as a reset (today `identityAllowsEventsRecentCatchUp` requires
  the same epoch).
- `events.recent` param `durable` (boolean; any other type is `-32602`),
  with optional `resume_host_id` (string) and `resume_boot_epoch` (integer;
  other types are `-32602`): the `host_id` / `boot_epoch` of the response
  the cursor came from. The event log serves the cursor only when they match
  this boot or the immediately previous boot after a clean quit. Without
  them the ring serves it or `requires_baseline` is true; with a mismatch the
  result is `requires_baseline: true` and no events. iOS should keep its
  same-epoch check for HTTP unless it sent both params.
  With `durable: true` the result adds `stream_gaps:
  [{thread_id | surface_id, since_seq, through_seq}]`; `events` may skip
  sequences (iOS's `httpReplayWindowHasInternalHole` must not treat that as a
  hole for a durable response); `truncated: true` means page again from the
  last returned seq; gaps are reported on the pages whose `since_seq` is
  still before them, so accumulate them across pages. Send it only after
  seeing the capability.

## Method

Harness: `Tests/AppShellTests/HostConnectionDurableReplayReceiptTests.swift`,
opt-in with `RC_HOST_CONN_RECEIPTS=1`, run through
`scripts/isolated-sandbox.sh test`. Machine: Apple M5 Max, macOS 27.0.1. The
harness file was identical in both runs and only speaks raw HTTP/WS, so it
compiles against both sources. Before ran on the `cb90e98cb` sources (a
detached scratch worktree) and after on the C8 sources, back to back. Another
workflow was building on the same machine (load average 14-20 during both
runs), so absolute times are noisy; both runs saw the same load.

Each sample uses a file-backed `AppContext` with the production persister,
`AppCommandRouter`, `JSONRPCDispatcher` and a real `DirectHTTPServer` over
loopback TCP with a paired bearer, seeded with 9 workspaces x 20 threads (the
snapshot a baseline costs: 129 KB). It then simulates an iPhone that saw
through a cursor and was away for 5 minutes or 1 hour while the host kept the
live event mix measured in the live DB: 32.5 agent deltas/s on two streaming
threads and 0.5 persisted state events/s (thread updates, token usage,
renames, completed items). The client reconnects with its cursor, the resume
envelope and the durable header, and does what iOS would: on
`replayFromSequence == cursor` it reads until `replayComplete`; otherwise it
waits for `baselineRequired` and calls `sync.snapshot`. "Time to live" is
from the upgrade request to the last byte the client needs. 3 warm-ups, then
7 samples per cell.

## Receipt

| Cell | Before: path, bytes, p50 / p95 | After: path, bytes, p50 / p95 |
|---|---|---|
| 5 min gap, durable header | baseline + snapshot, 129,192 B, 86.8 / 88.8 ms | durable replay (150 events, 2 gaps), 69,402 B, 22.9 / 23.9 ms |
| 1 h gap, durable header | baseline + snapshot, 129,182 B, 109.2 / 109.8 ms | baseline + snapshot (over budget), 129,233 B, 111.5 / 117.5 ms |
| 5 min gap, no header (old client) | baseline + snapshot, 129,191 B, 86.6 / 90.0 ms | baseline + snapshot, 129,221 B, 87.5 / 93.0 ms |

Without the budget (first after run, same harness), the 1 h cell replayed
1800 events: 818,699 B, 289.6 / 312.5 ms. That is why the budget exists.

## Reading it

- **A 5 minute gap now costs about half the bytes and a quarter of the
  time.** 69 KB in 23 ms instead of a 129 KB snapshot in 87 ms. The two
  streaming threads get one `streamGap` each instead of the roughly 4000
  deltas still in the ring.
- **A 1 hour gap keeps the baseline.** The replay would be 6x the bytes and
  2.6x the time of the snapshot, so the budget sends `baselineRequired`. The
  51 extra bytes are the welcome's new key and capability. p50 is 2.3 ms
  (2%) and p95 7.7 ms (7%) slower, within the `max(25 ms, 5%)` gate (the
  gate is 25 ms here); the extra work is one indexed count query.
- **Old clients are unchanged.** Same path, +30 bytes (the new welcome
  capability string), p50 +1.0 ms / p95 +3.0 ms, within noise and the gate.
- The crossover for this workload is roughly 18 minutes away (about 560
  state events). With a larger live snapshot (the live DB's 177 threads are
  about 270 KB) the budget is conservative.

## Review fixes (follow-up commit)

Fixes from the C8 review, all behaviour except the last two items:

- **Deadlock.** `DurableReplaySubscription.goLive` called `onOverflow` while
  holding its lock. HTTPServer's overflow handler can publish a pressure
  diagnostic; that publish waits on the EventBus delivery queue, which
  delivers to the same subscription and blocks on the same lock, after which
  every publisher (main thread included) waits forever. No closure now runs
  under the lock: the overflow is reported, events after it keep buffering
  and drain in order, then the subscription goes live. The regression test
  hangs on the old code (`Asynchronous wait failed: Exceeded timeout of 5
  seconds`) and passes on the new one.
- **Replay ignored the socket filter.** `subscription.map` was
  `bus?.mapForSubscriber(...) ?? full.map(event)`: whenever the subscriber's
  filter dropped an event, the `??` resent it unfiltered. Replayed events now
  go through the socket's filter like live ones, and `streamGap` is sent only
  for streams that filter carries (no gap for a thread outside a cellular
  interest set or for a kind-prefix socket that never carries deltas).
- **Unproven cursors.** The event log only serves a cursor whose resume
  envelope matches this boot or the clean previous one. An envelope-less
  durable socket, or `events.recent` without `resume_host_id` /
  `resume_boot_epoch`, gets the ring or a baseline, as before C8.
- **Estimate.** since == 0 goes to the baseline before any SQLite read. The
  estimate is an anchor seek (no anchor: baseline, no sum) plus a sum over at
  most `256 KiB / 200 + 1` rows.
- **Drain wait.** The 2 ms poll is gone: the driver blocks on a condition the
  outbound queue signals on dequeue, degrade and close (100 ms recheck for
  state changes nothing signals). A slice that cannot drain in 10 s ends the
  replay with `baselineRequired`.

Same harness, extended with a fresh-connect cell (since=0, 5000-row log,
the bus wired at seq 0 as at boot), a clean-restart cell (the resume record
is written and restored and a new boot epoch's server is started for every
sample) and an SQLite micro-benchmark of the old and new estimate SQL on the
same 5000-row file-backed log. Before: `97bc3c26d` with the extended harness
file (scratch worktree). After: the fix. Cells ran interleaved, 3 warm-ups +
7 samples each, load average 16-17. Raw data: `review_fixes` in
`c8-durable-replay-raw.json`.

| Cell | Before p50 / p95 | After p50 / p95 | Path, bytes |
|---|---|---|---|
| Fresh connect, durable header | 86.3 / 88.9 ms (welcome 1.32 ms) | 88.1 / 96.7 ms (welcome 1.35 ms) | baseline + snapshot, 129 KB |
| Fresh connect, no header | 89.3 / 93.0 ms | 90.3 / 91.9 ms | baseline + snapshot, 129 KB |
| Clean restart, 5 min gap, durable | 26.4 / 28.6 ms (welcome 10.1 ms) | 26.2 / 27.5 ms (welcome 10.7 ms) | durable replay, 154 events, 2 gaps, 70 KB |
| 5 min gap, durable | 25.2 / 27.2 ms | 25.2 / 27.0 ms | durable replay, 150 events, 2 gaps, 69 KB |
| 1 h gap, durable | 130.5 / 134.4 ms | 118.7 / 122.9 ms | baseline (over budget), 129 KB |
| 5 min gap, no header (5 rounds) | p50 88.7, 88.5, 89.6, 88.9, 95.7 ms | p50 100.4, 98.3, 88.0, 85.8, 87.6 ms | baseline + snapshot, 129 KB |

| Estimate SQL (5000 rows), p50 / p95 | Old (unbounded) | New (anchor + bounded) |
|---|---|---|
| Fresh cursor (0) | 0.372 / 0.404 ms | 0.003 / 0.004 ms |
| Cursor below the oldest row | 0.358 / 0.425 ms | 0.003 / 0.004 ms |
| 1 h cursor (1800 rows) | 0.131 / 0.136 ms | 0.135 / 0.170 ms |
| 5 min cursor (150 rows) | 0.017 / 0.063 ms | 0.027 / 0.027 ms |

Reading it:

- No end-to-end win is claimed. At the 5000-row retention cap the old
  estimate cost a third of a millisecond, invisible next to an 86 ms
  baseline; the fix bounds the worst case rather than moving p50.
- The 5 min, restart and fresh cells are within 2 ms of before, inside the
  `max(25 ms, 5%)` gate. The 1 h cell is 12 ms faster, which this change
  cannot explain (its estimate costs 0.13 ms either way): load noise.
- The legacy cell does not touch any changed code. Its after p50 was 10 ms
  slower in two of five rounds and faster in three; the medians are 88.9 ms
  before and 88.0 ms after. That is noise and inside the gate.
- The 5 min estimate gained 0.01 ms (one more statement for the anchor).

## Not measured

- The live sandbox app over `RC2_SANDBOX_HTTP_PORT=18219`. Every debug
  instance binds `/tmp/RemoteCodeDebug.sock` (no override at launch), and
  that path is held by another worktree's sandbox app (pid 22345, worktree
  `20261005T042010Z`, running since 5 Oct); launching would unlink and steal
  its socket, as in C3 to C7. All cells above are the in-process loopback
  harness with the production objects.
- A real host restart through the GUI, including the quit-time record write
  in `applicationWillTerminate`. The restart cell writes and restores the
  record in-process on the shared bus; the ring is not actually emptied (its
  coverage floor jumps to the head, which is what replay planning reads).
- On-device iOS time to first useful frame: iOS has not adopted the contract.
- Cellular / Tailcat links: loopback only.
