# C6: receipt claim/finalize off MainActor, per-batch commit fence

Date: 2026-10-07. Branch: `fix/bots-vm-agent` (worktree `20261006T005023Z`).
Before: `69e3c14f6`. After: the C6 commit. Raw samples: `c6-receipt-pipeline-raw.json`.

## What changed

- `JSONRPCDispatcher` claims, commits and finalizes remote mutation receipts
  through `CommandReceiptStateRouting.commandReceiptOffMainWriter`, which
  `AppCommandRouter` implements with `CommandReceiptOffMainWriter`. The claim
  and the eventless commit await the `.userInitiated` receipt queue
  (`CommandReceiptPersistenceGateway.perform`). MainActor is suspended, not
  blocked, while SQLite runs. Routers without a writer, such as the
  SocketServer test doubles, keep the synchronous path unchanged.
- Finalize goes through `EventBus.enqueuePersistedCommit`. The commit is
  queued on the EventBus delivery lane before the dispatcher's task suspends,
  so a publish that MainActor makes after the effect still gets a later
  sequence. The fence, the receipt + event transaction and the fanout run on
  the delivery lane at `.userInitiated`. The caller awaits a completion
  ticket that resolves exactly once, with the events or the error.
- The commit fence no longer runs `backgroundWriterQueue.sync {}` on a
  `.utility` queue. It waits only for event-log batches that a writer has
  already taken (each holds a completion token until its transaction
  returns). It then writes any rows no writer has picked up yet, on the
  fence's own thread, as one batch. The writer's own flush later finds that
  batch gone. Unrelated work on the writer queue (session snapshot saves,
  storage cleanup, usage files) no longer delays a receipt.
- New signposts on the `io.remotecode.perf` log: `receipt_claim`,
  `receipt_finalize`, `event_log_commit_fence`.
- Wire contract: unchanged. Same methods, result bytes (sorted-key JSON),
  error codes and event shapes. iOS needs nothing.

## Method

Harness: `Tests/AppShellTests/HostConnectionReceiptPipelineReceiptTests.swift`,
opt-in with `RC_HOST_CONN_RECEIPTS=1`, run in the debug build through
`scripts/isolated-sandbox.sh test`. Machine: Apple M5 Max, macOS 27.0.1. The
harness file was identical in both runs and uses only API that exists before
and after C6. Before ran on the `69e3c14f6` sources and after on the C6
sources, back to back, with no other build running.

Each scenario builds:

- a file-backed `AppContext` with the production event persister wired to
  `EventBus.shared`;
- the production `AppCommandRouter` and `JSONRPCDispatcher`;
- a real `DirectHTTPServer` over loopback TCP, with a paired bearer.

The request is `workspace.rename`, which takes the full receipt path: a
durable claim, the effect, one captured `workspace.renamed`, then finalize
behind the commit fence.

- "Writer queue busy": unrelated work holds `backgroundWriterQueue` for
  250 ms. The request starts 20 ms into that window.
- "SQLite writer held": another thread holds the SQLite connection for 250 ms.
  The request starts 20 ms into that window.
- "Main stall" is the longest a `MainActor.run {}` hop, polled from a
  background task every 0.25 ms, waited while the request was in flight.

Held scenarios discard 2 warm-up samples and keep 7. The idle scenario runs 5
warm-ups and keeps 30.

## Receipt (milliseconds, p50 / p95)

| Scenario | n | Before end-to-end | After end-to-end | Before main stall | After main stall |
|---|---|---|---|---|---|
| `workspace.rename`, writer queue busy 250 ms | 7 | 298.6 / 304.6 | 2.85 / 3.34 | 296.1 / 302.6 | 0.11 / 0.15 |
| `workspace.rename`, SQLite writer held 250 ms | 7 | 255.0 / 259.0 | 235.5 / 236.8 | 252.1 / 256.1 | 0.11 / 0.22 |
| `workspace.rename`, idle | 30 | 2.90 / 4.78 | 1.99 / 2.72 | 0.70 / 1.70 | 0.05 / 0.10 |

## Reading it

- **A receipt no longer waits for unrelated writer-queue work.** With a
  snapshot-save-sized job on the writer queue, the mutation drops from 299 ms
  to 2.9 ms. The Mac's main thread stalled for the whole 296 ms before. The
  before figure is about 50 ms longer than the remaining hold. That is
  consistent with main waiting on `.utility` work (the priority inversion
  named in the plan), but this run did not isolate the cause.
- **A mutation that has to wait for SQLite still waits, and main stays free.**
  When another thread holds the connection, the claim must wait, by design.
  End-to-end it is 235 ms, the remaining hold, against 255 ms before. The main
  stall drops from 252 ms to 0.1 ms, so the Mac UI, every other RPC and every
  main-thread publish keep running.
- **Idle mutations got cheaper.** p50 drops from 2.90 to 1.99 ms and p95 from
  4.78 to 2.72 ms. Main-thread time per mutation drops from 0.70 to 0.05 ms
  (p50). No scenario regressed.

## Correctness coverage (unit tests, not timings)

`Tests/AppShellTests/CommandReceiptOffMainPipelineTests.swift` (production
router, dispatcher and persister):

- immediate path: a claim waiting on a held SQLite connection leaves
  MainActor free;
- eventual exact completion: one receipt, one durable `workspace.renamed`
  linked to the request, and one delivery with its durable sequence; a retry
  answers from the receipt with no new row, delivery or sequence;
- ordering: receipt events sort after an earlier event whose batch is still
  in flight, and before a MainActor publish made after the effect; durable
  rows land in sequence order;
- A to B: two rapid renames, where the last delivered event matches the
  host's final name;
- failures: a claim failure returns -32091 (retryable) with no effect and no
  event; a finalize failure returns -32095, publishes nothing, allocates no
  sequence, leaves the receipt `unknown`, and a retry stays -32095.

`EventBusPersistencePerformanceTests`: the fence writes the earlier event
first without waiting for unrelated writer work, writes it exactly once, and
waits for an in-flight batch's token.

With the old pipeline restored in the working tree (writer returns nil and the
fence is `queue.sync {}`), three of these fail: the immediate-path test, the
ordering test and the unrelated-writer fence test. The contract tests pass on
both pipelines, as intended.

## Not measured

- The live sandbox app was not launched. As in C3 and C5, these receipts
  drive the production objects in-process over real loopback TCP.
- Release-build timings, and a real iPhone sending mutations while a run
  streams events into the writer.
- Per-method `dispatchCore` p50/p95 in `/v1/health` `request_phases` is still
  not added. Claim and finalization latency were already in
  `commandReceiptMetrics`.
