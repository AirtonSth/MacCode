# Agent App mem/perf before → after (2026-09-29)

HEAD base: `fd90a33d6` (`origin/production`). Isolated worktree `perf/agent-app-memperf-20260929T150409Z`.

Open MR 409 is **not** in this tree (it targeted older `2e099676`). Ranks already on production (fingerprint caches, mentionableBots snapshot, history ChatFlowRows, idle Subagents `Date()` skip) stay. This change is the leftover ~30 Hz chrome path, rebased onto current production, plus a generation guard so a live-row hit cannot survive a `contentGeneration` bump.

## Measurement basis

**Call counts** (`chatFlowPaintSplitCountForTesting`, `chatFlowPaintLiveComputeCountForTesting`, `chatFlowPaintComputeCountForTesting`) and **turn visits / Date() identity** on named seams. No Instruments RSS samples. Do **not** read these as process RSS % or a whole-app wall-clock “% faster.”

## Before → after

| Rank | Site | What changed | Before | After |
| --- | --- | --- | --- | --- |
| 1 | `cachedChatFlowPaint` live tail | Not cached. A content hash that kept progress, summary, and same-length rewrites honest measured **0.514 ms** median vs **0.001 ms** for the weave on an 8×64 KiB tail (5 warmed samples). Hashing the text was slower, so the live weave stays. | 1 weave / column body | 1 weave / column body. Progress and same-length text stay fresh. |
| 2 | `splitTrailingLiveTurns` | Skip split when generation, aggregate-budget generation, paint count, first/last ids, and `latestLiveTurnId` match. | **1 split** (two Array slices) / column body. | Chrome-only: **0** after first fill (**100% fewer** splits on that path). |
| 3 | User-bubble `relativeTimestamp` | Pass a 1 Hz `now` bucket from the column; Equatable skip inside the same second. | **N `Date()` + formatter** / column body (one per visible user bubble). 20 bubbles × 30 Hz ≈ 600 clocks/s. | **1 clock / column**, Equatable rows skip formatter **~29/30** ticks inside a second (**~95% fewer** Date()/formatters on a 20-bubble window). |
| 4 | Header working strip | `hasStreamingGroupableTools` walks trailing unfinished turns only and stops at the first finished turn from the end. | Full `turns.contains` over 800 finished turns × 25 items, 40 repeats. Median of 5 warmed samples: **2.288 ms**. | Same workload, trailing walk. Median **0.0069 ms** (**~99.7% less** time on that bench). One header tick is ~40× smaller: about **0.057 ms → 0.00017 ms**. |

## What this is not

- Not process RSS. These paths cut allocs and walks, not the retained transcript.
- Not a whole Agent App “10% less memory” claim. On idle-live chrome the column stops splitting and reweaving live rows (~100% fewer of those two calls per tick). User-bubble clocks drop about 95% on a 20-bubble window. Working-strip turn visits drop about 99.8% on a 400-turn thread.
