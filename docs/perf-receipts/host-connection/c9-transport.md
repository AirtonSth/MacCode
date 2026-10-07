# C9: transport tuning, measurement-gated

Date: 2026-10-07. Branch: `fix/bots-vm-agent` (worktree `20261006T005023Z`).
Before: `712646082`. After: the C9 commit. Raw samples: `c9-transport-raw.json`.
A/B instrumentation (not shipped): `c9-ab-instrumentation.diff`.

C9 had five candidate sub-changes. Each one shipped only if a before/after receipt
showed an improvement larger than the noise band and no settled-latency regression.
The noise band is the one AGENTS.md uses for regressions: `max(25 ms, 5%)`. A
latency gain inside that band counts as no improvement.

| Sub-change | Decision | Why |
|---|---|---|
| DispatchSource disconnect watchdog (replaces the 5 ms MSG_PEEK poll) | **Shipped** | Process CPU while 8 RPCs wait: about 20 ms/s → 0.15 ms/s. Context switches: about 1050/s → 6/s. Drop → socket release: 1-3 ms (p95 5-8 ms) → 0.19 ms. Settled ping and message-page latency unchanged. |
| `TCP_NODELAY` on accepted fds (HTTP + Tailcat) | **Rejected** | No measurable change on any scenario. No Nagle stall reproduces on loopback (see below). |
| `SO_KEEPALIVE` on accepted fds | **Rejected, not implemented** | Not measurable here. A half-open peer cannot be produced on loopback without root (`pf`/dummynet). `SO_RCVTIMEO` idle close and the WS heartbeat already bound half-open lifetime. |
| `writev` for header + body | **Rejected** | No measurable change on ping or a 50-message page, alone or with NODELAY. |
| WS drain gathers frames per wakeup (≤ 64 KB, one write) | **Rejected** | Spaced streaming latency and 150-event burst time-to-last unchanged; process CPU per burst unchanged. Delivery is bound by per-message client work, not host syscalls. |
| Read-only top-level batch in a TaskGroup | **Rejected** | `agent.thread.read` v1 ×4: about −7 ms (−4%) in both runs; thread list + 3 pages: no change. Both are inside the noise band. The items still serialize on the main actor and the WAL reader, so the batch never approaches max-of-items. |

## What shipped

`RPCPeerDisconnectWatchdog` (Sources/SocketServer/RPCPeerDisconnectWatchdog.swift)
watches a handed-off `/v1/rpc` socket with a `DispatchSourceRead`. The kernel wakes it
on FIN, RST, or a host-side `shutdown` (revoke, server stop). It wakes on new bytes too:

- **Peer gone** (`recv` peek returns 0 or a hard error), or the registry no longer
  owns the fd: the release (unbind owner, close fd, cancel the work task) runs once,
  from the cancel handler, after libdispatch has dropped the descriptor.
- **Bytes waiting** (a pipelined request): it stops watching. The source is
  level-triggered and would otherwise spin. It never reads the bytes, so the
  keep-alive reader still gets them. The 5 ms poll also reported "connected" for the
  rest of the RPC in this case.
- `stop()` returns only after the cancel handler ran, so the response thread
  owns the fd again with no source still attached.

`DirectHTTPServer.isRPCPeerConnected` lost its only caller and was removed.

No wire change. No iOS change.

## Method

Receipts come from `Tests/AppShellTests/HostConnectionTransportReceiptTests.swift`
(opt-in with `RC_HOST_CONN_RECEIPTS=1`), run through `scripts/isolated-sandbox.sh test`.
Each scenario uses a file-backed `AppContext`, the production `AppCommandRouter` and
`JSONRPCDispatcher`, `LocalAuthAdapter`, and a real `DirectHTTPServer` on loopback TCP
with a paired bearer. The fixture holds 150 threads, the newest with 100 messages of
about 1 KB each. The client is URLSession, the iOS transport.

The machine was loaded the whole time: load average 13-15, two iOS simulators at about
130% CPU each, and other worktrees building. Sequential before/after runs drifted up to
about 20% between runs. To remove that drift, every candidate was measured in an
**instrumented build** with temporary switches (`C9TransportTuning`), and the variants
were **interleaved sample by sample** in one process. NODELAY is set at accept, so each
NODELAY variant used its own connection. For WS, every round opened a fresh
connection with that round's variant. The switches were removed before the commit.

Scenarios:

- `rpc_system_ping_keepalive`: 10 warm-ups, 60 samples per variant.
- `rpc_agent_message_page_50_keepalive`: 5 warm-ups, 30 samples per variant.
- `batch_*`: 3 warm-ups, 15 samples per variant.
- `inflight_rpc_x8_main_blocked_1s`: 8 `system.ping` RPCs in flight while main sleeps
  1 s. Process CPU (`getrusage`) and context switches during that second. 2 warm-ups, 7
  samples.
- `peer_drop_mid_rpc_release`: a raw client posts an RPC while main is blocked, then
  closes. Time until the server's accepted-socket count drops. 2 warm-ups, 7 samples.
- `ws_spaced_2ms_x200`: 200 `agent.item.completed` events, one every 2 ms, publish →
  client receive. 1 warm-up round and 5 measured rounds.
- `ws_burst_150`: 150 events back to back, first publish → last receive, plus process
  CPU. 2 warm-up passes and 10 measured passes.

## Receipts (milliseconds unless noted; p50 / p95)

### Watchdog (shipped)

| Scenario | Poll 5 ms (before) | DispatchSource (after) |
|---|---|---|
| CPU while 8 RPCs wait 1 s, interleaved run 1 | 22.6 / 25.1 ms | 0.18 / 0.22 ms |
| CPU, interleaved run 2 | 18.9 / 19.5 ms | 0.12 / 0.15 ms |
| CPU, interleaved run 3 | 18.6 / 26.0 ms | 0.15 / 0.18 ms |
| CPU, sequential before ×4 / after ×2 | 22.5, 21.9, 19.9, 21.8 | 0.146, 0.149 |
| Context switches in that second, interleaved runs | 1086, 1028, 991 | 7, 4, 6 |
| Peer drop → socket released, interleaved runs | 1.15 / 7.0, 2.15 / 4.9, 3.23 / 7.6 | 0.19 / 0.19, 0.18 / 0.20, 0.18 / 0.19 |
| Peer drop → released, after (committed harness) | — | 0.19 / 0.20, 0.18 / 0.20 |
| `system.ping` keep-alive, interleaved run 2 | 0.701 / 0.996 | 0.747 / 1.002 |
| `system.ping` keep-alive, interleaved run 3 | 0.518 / 0.723 | 0.550 / 0.685 |
| 50-message page, interleaved run 2 | 38.1 / 41.3 | 38.0 / 42.9 |
| 50-message page, interleaved run 3 | 38.0 / 38.8 | 38.0 / 39.7 |

Settled latency: ping p50 is +0.03 to +0.05 ms (creating one source and queue per RPC).
That is far inside `max(25 ms, 5%)`. Message pages are unchanged.

### Rejected candidates (interleaved)

| Scenario | base | nodelay | writev | nodelay + writev |
|---|---|---|---|---|
| ping, run 1 | 0.855 / 1.043 | 0.858 / 1.130 | 0.869 / 1.102 | 0.828 / 1.049 |
| ping, run 2 | 0.701 / 0.996 | 0.722 / 0.965 | 0.710 / 0.962 | 0.711 / 0.971 |
| ping, run 3 | 0.518 / 0.723 | 0.522 / 0.695 | 0.514 / 0.698 | 0.519 / 0.665 |
| 50-message page, run 1 | 39.8 / 43.4 | 39.5 / 44.8 | 39.6 / 43.8 | 39.8 / 44.2 |
| 50-message page, run 2 | 38.1 / 41.3 | 37.9 / 42.4 | 38.1 / 43.9 | 37.8 / 43.6 |
| 50-message page, run 3 | 38.0 / 38.8 | 37.8 / 39.3 | 37.8 / 40.0 | 37.7 / 39.3 |

| Scenario | base | nodelay | gather | nodelay + gather |
|---|---|---|---|---|
| WS spaced 2 ms, round p50 (run A) | 0.292 | 0.304 | 0.311 | 0.328 |
| WS spaced 2 ms, round p95 (run A) | 0.413 | 0.432 | 0.456 | 0.470 |
| WS burst 150, time to last (run B) | 13.3 / 63.2 | 12.8 / 61.4 | 12.6 / 55.8 | 13.0 / 62.6 |
| WS burst 150, process CPU (run B) | 37.9 / 134.3 | 37.9 / 139.1 | 39.3 / 128.2 | 40.9 / 141.9 |

| Batch | sequential | TaskGroup |
|---|---|---|
| `agent.thread.read` v1 ×4, run 1 | 154.2 / 155.4 | 147.5 / 150.4 |
| `agent.thread.read` v1 ×4, run 2 | 173.8 / 187.0 | 167.0 / 176.1 |
| thread list + 3 message pages, run 1 | 257.5 / 262.5 | 254.8 / 258.4 |
| thread list + 3 message pages, run 2 | 291.1 / 303.5 | 290.8 / 307.1 |

## Nagle (M3) on loopback, and why there is no pcap

`tcpdump` needs `/dev/bpf*`, which is `root:wheel 0600` on this machine. AGENTS.md
forbids `sudo`, so no packet capture was taken. As a stand-in, a scratch socket probe
(header write followed by body write, keep-alive, 60 samples) measured 0.04-0.10 ms
per exchange with or without `TCP_NODELAY`, for bodies of 60 B, 2 KB, 20 KB and
200 KB. The 40-200 ms Nagle/delayed-ACK stall that M3 inferred does not happen on
macOS loopback (the receiver ACKs at once). The in-app ping and WS receipts above agree.

**Not verified:** the LAN and cellular paths to a real iPhone, where the iOS
delayed-ACK policy applies. Traffic to the Mac's own LAN address is still routed over
`lo0`, so this machine cannot reproduce that path. If NODELAY is revisited, it needs an
on-device time-to-first-byte receipt over Wi-Fi.

## Observed, not changed

- A 400-event back-to-back burst on a fresh WS connection sheds events with
  `diagnostic.ws_outbound_pressure` (`baseline_required: true`) in every variant,
  including the unmodified base. The client then waits for events that never arrive
  (`incomplete_ws_rounds` in the raw file). Once several connections had cycled through
  the same fixture, the 150-event burst also shed in some rounds. This is the
  M4/C8 territory (outbound budget vs replay bursts). It is reported here and not
  touched in C9.
- On a connection with no cursor, the first frame after welcome can be a
  `baselineRequired` with reason `replayTruncated` when the bus already holds events.
  The harness skips it. Pre-existing.
