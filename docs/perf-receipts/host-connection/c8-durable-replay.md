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
  overflows during the replay, or the estimated replay is above the budget.
- **Replay budget (256 KiB).** See the receipt: replaying a one-hour gap from
  the log cost more than the snapshot it replaces, so a log replay estimated
  above 256 KiB of wire bytes (count + byte sum over the seq range, one
  indexed query) falls back to the baseline.
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
- Restart: send the old `X-RC2-Resume-Host-Id` / `X-RC2-Resume-Boot-Epoch`
  as today. With the durable header, a cursor from the immediately previous
  boot epoch can now be accepted (`replayFromSequence == cursor` although
  `bootEpoch` changed). iOS must then keep its mirror instead of treating the
  epoch change as a reset (today `identityAllowsEventsRecentCatchUp` requires
  the same epoch).
- `events.recent` param `durable` (boolean; any other type is `-32602`).
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

## Not measured

- A real host restart through the GUI (the restart path is covered by
  `DurableReplayRestartTests` against the real SQLite log, not timed).
- On-device iOS time to first useful frame: iOS has not adopted the contract.
- Cellular / Tailcat links: loopback only.
