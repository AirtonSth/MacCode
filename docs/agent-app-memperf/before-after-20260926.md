# Agent App mem/perf before → after (2026-09-26)

HEAD base: `2e099676` (`origin/production`, includes merged MR 404). Isolated worktree `perf/agent-app-memperf-20260926T150229Z`.

Ranks 1–8 from 2026-09-25 (fingerprint caches, mentionableBots snapshot, paint-context counts, history ChatFlowRows, empty-badge Date() sentinel) are **already on production**. This change ships unique leftovers on the ~30 Hz chrome path.

## Measurement basis

**Call counts** (`chatFlowPaintSplitCountForTesting`, `chatFlowPaintLiveComputeCountForTesting`, `chatFlowPaintComputeCountForTesting`) and **item visits / Date() identity** on named seams. No Instruments RSS samples. Do **not** read these as process RSS % or a whole-app wall-clock “% faster.”

## Before → after (unique vs 404)

| Rank | Site | What changed | Before | After |
| --- | --- | --- | --- | --- |
| 1 | `cachedChatFlowPaint` live tail | Memoize live `chatFlowRows` while ids + item counts + body/output UTF-8 lengths + states match. Tool-body growth still misses. | Chrome-only with a live turn: **1 live weave / column body** (~30 Hz). 200 ticks = 200 weaves. | Unchanged live bodies: **0** after first fill (**100% fewer** live weaves on that path). Growth still 1 weave. |
| 2 | `splitTrailingLiveTurns` | Skip split when generation, aggregate-budget generation, paint count, first/last ids, and `latestLiveTurnId` match. | **1 split** (two Array slices) / column body. | Chrome-only: **0** after first fill (**100% fewer** splits on that path). |
| 3 | User-bubble `relativeTimestamp` | Pass a 1 Hz `now` bucket from the column; Equatable skip inside the same second. | **N `Date()` + formatter** / column body (one per visible user bubble). 20 bubbles × 30 Hz ≈ 600 clocks/s. | **1 clock / column**, Equatable rows skip formatter **~29/30** ticks inside a second (**~95–97% fewer** Date()/formatters on a 20-bubble window). |
| 4 | Header working strip | `hasStreamingGroupableTools` walks trailing unfinished turns only and stops at the first finished turn from the end. | `turns.contains` visited **every** turn’s items on ~30 Hz header chrome. 400 finished + 1 live = **401** turn visits. | Trailing unfinished only: **1** visit when the newest turn is unfinished then a finished turn (**~99.8% fewer** turn visits on a 400-turn thread). |

## Conservative totals (named paths only)

- **Live ChatFlowRow (rank 1):** chrome-only live weave **1 → 0** after first fill (~**100% fewer** on that path; tends toward the column body being cheaper by the cost of one live-tail weave per tick).
- **Split (rank 2):** **1 → 0** on the same chrome-only ticks.
- **User-bubble clocks (rank 3):** **N → 1** Date() per column, then Equatable skips; on a 20-message window that is about **95% fewer** timestamp clocks/formatters during streaming chrome.
- **Working-strip scan (rank 4):** whole-timeline item walk → trailing unfinished only; on a 400-turn thread about **99.8% fewer** turn visits per header body.

Combined on idle-live chrome (~30 Hz, history cached, live bodies unchanged): the column no longer splits or reweaves live rows. That is the leftover 404 always paid.

## What this is not

- Not process RSS % (no Instruments).
- Not a claim that token/tool storms stop publishing `timeline`.
- Not a whole Agent App “10% less memory” stopwatch result. Rank 1–2 cut CPU/allocs on the named ~30 Hz path; they do not shrink the live-turn snapshot itself.

## Proof

```
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  /usr/bin/swift test --package-path /private/tmp/isolated-agent-app-memperf-20260926T150229Z \
  --filter AgentAppMemPerfWinsTests \
  --filter AgentAppMemoryR6CapTests \
  --filter AgentChromePerfGapTests \
  --skip Distill
```
