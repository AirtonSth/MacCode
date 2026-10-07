# C4: unchanged push-token short-circuit, close diagnostics, eventGap jitter

Date: 2026-10-06. Branch: `fix/bots-vm-agent` (worktree `20261006T005023Z`).
Before: `342283e41`. After: the C4 commit. Raw samples: `c4-push-token-close-diagnostics-raw.json`.

## What changed

- **Push-token short-circuit.** `private.push_token.update` gets a check before the
  durable receipt claim. If the request only re-sends an alert token or a legacy
  single-target token, and the host already holds exactly that state, the dispatcher
  answers with the result the full path would return. It writes no receipt, no settings
  rows, and no `private.push_token.updated` event. "Exactly that state" means all of
  these hold:
  - the legacy target has the same token, type, device and Live Activity token;
  - for typed alerts, the v2 record set has the same alert record (device, server,
    environment, token, contract version, capabilities);
  - if `profile_id` is sent, the same profile/host/device attention binding exists.

  The check reads on the WAL reader. Any read or decode failure answers "not current",
  and the request takes the full path. The check never covers push-to-start,
  activity-update, or any `live_activity_v2` target. Those also feed the Live Activity
  coordinator's backend registration, which must still run on every request. It also
  never covers a request the full path might reject. `/v1/health`
  `command_receipts.push_token_unchanged_skips_total` counts the skips.
- **`diagnostic.ws_connection_closed`.** Every `/v1/ws` teardown records a reason.
  - Host-initiated: `eventGap`, `heartbeatTimeout`, `invalidEvent`, `writeFailed`,
    `protocolError`.
  - Peer close frame: `peerClose`.
  - No close frame (1006): `peerEOF`, `readTimeout`, `readError`, `socketReleased`.

  The first recorded reason wins. Along with the reason, each teardown records:
  - `code`: the close code;
  - `duration_ms`;
  - `since_seq`: the accepted resume cursor;
  - `replay_expired`;
  - `frames_shed`: frames dropped under pressure on that connection;
  - `suppressed_since_last`.

  The payload carries no owner, token, connection id or content. It emits at most once
  per reason per 10 s. `/v1/health` `connection_closes` counts every close by reason
  with no rate limit. Every close also writes one `[RC2.WS] connection closed …`
  NSLog line.
- **eventGap retry hint.** The 1012 eventGap closing frame now carries a
  `retryAfterMs` drawn uniformly from 250 to 1000 ms. Before, it was 0.

## Method

The harness is `Tests/AppShellTests/HostConnectionPushTokenReceiptTests.swift`
(opt-in: `RC_HOST_CONN_RECEIPTS=1`), run in the debug build through
`scripts/isolated-sandbox.sh test`. It wires the same objects as C3: a file-backed
`AppContext` (writer plus WAL reader), the production `LocalAuthAdapter`,
`AppCommandRouter` and `JSONRPCDispatcher`, and a real `DirectHTTPServer` over loopback
TCP with a paired bearer.

Every request uses a fresh `client_request_id` and the same token, device, Live
Activity token and profile. This is what an iPhone sends on reconnect. The harness
file uses no C4 API, so the same file measured both sides.

The before run came from reverse-applying the C4 diff in the working tree. The after
run was taken right after restoring it, on the same machine (Apple M5 Max, macOS
27.0.1), minutes apart.

| Scenario | Samples |
|---|---|
| Idle | 5 warm-ups discarded, 30 kept |
| Writer held | 2 warm-ups discarded, 7 kept; another thread holds `BEGIN IMMEDIATE` on the writer for 250 ms and the request starts 20 ms in |
| Rotating token | Every request carries a new token, so the full path runs before and after |

The rotating-token scenario is the regression check for the added probe.

## Receipt (milliseconds, end to end over loopback HTTP)

| Scenario | n | Before p50 / p95 | After p50 / p95 |
|---|---|---|---|
| Unchanged token, idle | 30 | 2.05 / 2.68 | 0.76 / 0.93 |
| Unchanged token, writer held 250 ms | 7 | 263.8 / 282.1 | 1.91 / 2.02 |
| Rotated token every request (full path both sides), idle | 30 | 2.26 / 3.49 | 2.06 / 2.54 |

| Durable effects of 35 unchanged re-sends (after one first registration) | Before | After |
|---|---|---|
| New `command_receipts` rows | 35 | 0 |
| New persisted `private.push_token.updated` events | 35 | 0 |

## Reading it

- An unchanged re-send no longer waits on the writer. Before, a reconnect that landed
  inside a 250 ms writer transaction waited out the rest of it to claim and finalize
  its receipt (264 ms p50). Now it answers from the reader in about 2 ms.
- Idle unchanged re-sends drop from 2.05 to 0.76 ms p50. The bigger effect is the
  durable work removed. Each skip saves:
  - a receipt claim and a finalize;
  - three settings writes;
  - one persisted event, which also took a replay-ring slot and advanced the
    sequence for every connected client.
- The full path is not slower. Rotated tokens were 2.26 → 2.06 ms p50 and
  3.49 → 2.54 ms p95, inside `max(25 ms, 5%)`. A separate after run before this pair
  measured 2.73 / 3.14 ms. Treat the rotated-token row as "no regression", not as a win.

## Not measured / not claimed

- Whether the live storm's re-sends match this shape is not measured. The 01:36Z
  storm produced 27 receipts, and the live DB holds 5094 push-token receipts. Current
  iOS sends `live_activity_v2` alerts behind its own 24 h acknowledgement ledger, and
  the short-circuit deliberately does not cover those. It covers legacy and non-v2
  alert re-sends. Older iOS builds send those on every reconnect, and the host must
  stay backward compatible with them. Receipts stored in the live DB keep only a params
  hash, so they cannot show which shape the storm used. The count of
  `push_token_unchanged_skips_total` and `connection_closes.by_reason` over a 24 h
  soak will answer this.
- The close diagnostics and the eventGap jitter carry no latency claim. The jitter
  deliberately delays an eventGap reconnect by 250 to 1000 ms. iOS already takes the
  larger of its own backoff and the host hint (`AppEnvironment.scheduleDelayNanoseconds`).
  Before, a burst that gapped every client made all of them reconnect in the same
  instant.
- The live sandbox app was not launched, for the same reason as C3.
  `/tmp/RemoteCodeDebug.sock` is still held by worktree `20261005T042010Z`'s sandbox
  app (pid 22345, re-checked during this slice). Release-build timings and a real
  iPhone reconnect burst were also not run.
