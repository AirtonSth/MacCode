# S8 NO_CHANGE — coordinator / SQLite / MainActor ordering branches

**Status:** NO_CHANGE (threshold-gated; no measured breach in this environment).

## Measured precondition

No warmed n≥3 hardcore-swarm physical canary was executed in this sandbox (see `docs/capacity/release-gates.md`). Without a frozen-threshold breach of coordinator no-progress/lock wait, SQLite transaction/queue wait, or MainActor paint, the plan requires preserving current EventBus/coordinator/SQLite ordering.

## What was not changed

- No provider-neutral round-robin durability lane.
- No multi-writer SQLite batch rewrite.
- No MainActor no-op publication coalesce beyond existing paths.

## Next promotion step

Prerequisite (must exist before ranking): a physical canary collector that records
coordinator no-progress, SQLite lock/transaction wait, and MainActor stall intervals
via production gauges (`CapacityGaugeSnapshot` / process health) — **not** the S2
virtual-clock semantic harness (S2 has no signposts). Breach criteria remain the
frozen thresholds in `release-gates.md` (MainActor stall ≥2s, ownership failure,
unbounded queues). Promote **exactly one** branch if breached; rerun unchanged manifest.
