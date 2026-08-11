# S6 NO_CHANGE — host-wide Agent LRU

**Status:** NO_CHANGE for global Agent LRU (explicit plan gate).

## Measured precondition

Local visibility cold-state protocol is checked in (`AgentVisibilityColdState`) with generation-safe hide/reveal and full presentation checkpoint fields (composer, attachments, thread/tab, scroll/disclosure/plan intent, browser URL/title, unread/Stop ownership).

Host-wide Agent LRU remains **disabled** (`AgentVisibilityColdState.globalAgentLRUEnabled == false`) until a residual app-owned tier budget breach is measured under the frozen hardcore-swarm manifest after local visibility reclamation is promoted.

## Promotion gate (unchanged from T-003)

Promote local reclamation only if measured save ≥ max(128 MiB, 10% app footprint) without reveal p95 >500 ms, p99 >1 s, duplicate/missing events, or MainActor stall ≥2 s.

## What shipped

- Pure visibility state machine + checkpoint schema (unit-testable).
- Explicit non-enablement of global LRU.
