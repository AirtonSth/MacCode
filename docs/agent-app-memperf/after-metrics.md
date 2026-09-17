# After metrics — Agent App mem/perf (2026-09-15)

HEAD base: `28029d43`. Fix commits on `perf/agent-app-memperf-20260915T151657Z`.

Method: **operation-count / code-path accounting** (DEBUG `itemLookupComparisonsForTesting`) plus cache-key size arithmetic. **No Instruments wall-clock or process RSS samples** were taken in this run. Broader “% faster overall” claims are therefore not asserted as measured facts.

## Evidenced before → after

### 1. Non-active timeline item lookup (P0)

Scenario encoded in
`test_streamingDeltasToNonActiveItemStayBoundedRegardlessOfAccumulatedItems`:
3 000 prior items, 2 000 deltas targeting `item-0`.

| | BEFORE (newest-first scan from live end) | AFTER (map hit) |
| --- | --- | --- |
| Comparisons | ~`M × N` = **6 000 000** | ~`M × 1` = **2 000** (map validate counts 1) |
| Bound in test | would fail `≤ M×3` | **PASS** (`≤ M×3`) |

**Claim (evidenced):** about **99.97% fewer item-id scan comparisons** on this path (~**3 000×** reduction for that scenario). The mutateItem-bound portion of history replay / non-active updates therefore tends to cost **~O(1) per event** instead of **~O(N)**.

Decode rebuild is covered by `test_decodedTimelineNonActiveDeltasStayBounded` (also PASS in isolated gitless CoreModel proof).

### 2. User-bubble `idealSize` cache keys (P1)

| | BEFORE | AFTER |
| --- | --- | --- |
| Key material | full prompt string in key | `sourceFingerprint` (~20 chars) |
| `countLimit` | 256 | 128 |

For an illustrative **4 000-byte** average prompt, retained **key-string** material at full occupancy:

- BEFORE: `256 × (~40 + 4000)` ≈ **1.03 MB** of key strings  
- AFTER: `128 × (~40 + 20)` ≈ **7.7 KB** of key strings  

**Claim (evidenced for keys only):** about **99% less key-string RAM** in the hug-measure NSCache at those assumptions. The cached value is a small `CGSize` box (not a retained layout manager). Process-wide RSS change was **not** measured; do not read this as “10% less app memory” without Instruments.

### 3. Host-metadata occurrence pairing (P1)

Persisted ordinals are single-pass; snapshot side is **pre-indexed once per turn** (review follow-up), so attested pairing is **O(items)** rather than per-item full-turn `filter`.

**Claim (evidenced structurally):** for an all-attested turn of N items, identity matching work drops from ~**N²** filter scans to ~**N** map builds + lookups. End-to-end cold-open wall time was **not** measured.

## What we are *not* claiming as measured

- Whole Agent App “5–10% less memory” or “5–15% faster thread open” (SQLite/decode still dominate open; no RSS/time samples here).
- “90–99% faster” as a user-visible stopwatch result (only comparison counts are evidenced).

## Proof

Isolated gitless CoreModel package (`/tmp/rc-agent-app-memperf-gitless`):

- `test_streamingDeltasToNonActiveItemStayBoundedRegardlessOfAccumulatedItems` **PASS**
- `test_decodedTimelineNonActiveDeltasStayBounded` **PASS**
- `test_streamingDeltasToActiveItemStayBoundedRegardlessOfAccumulatedItems` **PASS**

MR: https://gitlab.com/desenvolvimento-ninja/remodecode/remotecode/-/merge_requests/372
