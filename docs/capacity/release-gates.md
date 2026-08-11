# S13 — Release qualification, promotion, and rollback

## Environment limits (honest)

This implementer environment cannot run:

- Physical multi-GiB tier canaries (8/16/32 GiB) with warmed n≥3 on dedicated hardware
- Overnight soak
- Real appcast/latest promotion dry-run against production Sparkle feeds
- Paid real-provider progressive canaries with token/cost ceilings

Those gates are **not invented**. Artifacts below are the in-repo mandatory proof set.

## In-repo artifacts required before stable promotion

| Artifact | Path / location | Status |
|---|---|---|
| Qualification manifest v1 | `docs/capacity/qualification-manifest.v1.json` | present |
| Capacity contract + pressure pure SM | `Sources/AppLifecycleSupport/*` | present + unit tests |
| Semantic harness | `Sources/AgentRuntime/CapacitySemanticHarness.swift` | present + unit tests |
| Oversized payload recovery | `Sources/Persistence/AuthoritativePayloadRecovery.swift` | present + unit tests |
| Ownership elastic ledger | `Sources/AgentRuntime/ProviderProcessOwnership.swift` | present + unit tests (257 rows) |
| Preparation cancellable SM | `Sources/AgentRuntime/ProviderPreparationStateMachine.swift` + `AgentRunCoordinator` claimSpawn + `AgentAppSurface` Stop cancel | wired into accept→spawn + unit/production-wiring tests |
| Visibility cold-state | `Sources/Surfaces/AgentVisibilityColdState.swift` | present |
| Pressure coordinator | `Sources/AppLifecycleSupport/PressureGovernorCoordinator.swift` + `AppDiagnostics.heartbeat` ingest/execute | wired into live heartbeat + unit/production-wiring tests |
| Batcher admission bounds | `Sources/SocketServer/WebSocketEventBatcher.swift` | present + unit tests |
| Graphify/TS hardening pins | `Sources/AgentRuntime/GraphifyRuntimeHardening.swift` | present (default pin incomplete until physical canary; install refuses floating upgrade when unpinned) |
| Capacity UX model | `Sources/AppLifecycleSupport/CapacityUXStatus.swift` | present |
| S6/S8/S11 NO_CHANGE notes | `docs/capacity/NO_CHANGE-*.md` | present |

## Promotion policy (unchanged)

Stable tag / appcast / latest requires:

1. Immutable artifacts with required metrics present (null = fail)
2. Warmed n≥3 same-machine comparison for the claimed tier
3. ≤10% p95 regression vs prior baseline
4. No MainActor stall ≥2 s
5. No correctness/ownership failure
6. No unbounded queue
7. Declared host-memory plateau at the fixed workload
8. Prior appcast/latest snapshot + tested rollback/downgrade preflight (`ProviderProcessOwnershipStore.isWithinDowngradeSafeCeiling`)

## Staging waves

1. Telemetry-only pressure
2. Optional-work pressure actions
3. Local cold-state
4. Any measured global/fairness branch (one at a time)

Each wave is a separate revert boundary.

## Rollback / downgrade preflight (dry-run notes)

```
# Ownership downgrade is unsafe while live rows > 256
# Operator must sweep proven-dead tags first, then:
#   store.isWithinDowngradeSafeCeiling() == true
# Snapshot appcast feed metadata before overwrite; restore snapshot on health fail.
```

Physical dry-run of appcast restore was **not** executed in this environment.
