# Agent App mem/perf before → after (2026-09-25)

HEAD base: `5515958f` (`origin/production`). Isolated worktree `perf/agent-app-memperf-20260925T150320Z`.

Open MRs 386/389/393 are **not** in this tree. This change ships leftover 393 wins **and** unique extras so ranks 1–2 / mutateItem / idealSize fingerprints are not the only win.

## Measurement basis

**Cache-key byte arithmetic**, **provider / parse / signature-builder / ChatFlowRow / Date() call counts**, and XCTest seams (`toolInputObjectComputeCountForTesting`, `normalizedTextCacheComputeCountForTesting`, `mentionableBotsSnapshotProviderCallCountForTesting`, `chatRowPaintContextSignatureBuilderCountForTesting`, `normalizedFinalsComputeCountForTesting`, `chatFlowPaintComputeCountForTesting`, `subagentActivityBadgeNow`).

No Instruments samples were taken. Do **not** read the estimates below as process RSS % or a whole-app wall-clock “% faster.” Values are occupancy/call-count models for the named caches and hot paths.

## Before → after (393 leftovers)

| Rank | Site | What changed | Before | After |
| --- | --- | --- | --- | --- |
| 1 | `toolInputObject` / `toolInputCache` | Key = `AgentMessageMarkdown.cacheKey` (`utf8Count:hash`), not `body as NSString` | Key bytes ≈ cached JSON bodies. Cost-limit occupancy up to **128 KiB of keys**. Illustrative 20 tools × 4 KiB JSON = **80 KiB keys**. | Keys ~20–40 ASCII bytes. 256 entries → **~10 KiB keys**. **~87–92% fewer key bytes** on that cache. Parse count unchanged. |
| 2 | `normalizedTextCache` + `compactTextCache` | Same fingerprint keys | 2 caches × 128 KiB cost occupancy → up to **~256 KiB of key NSStrings**. | ~20–40 B × 128 × 2 ≈ **~10 KiB keys**. **~96% fewer key bytes**. |
| 3 | Transcript column + header `SubagentActivityBadge` | Snapshot `mentionableBots` once per `contentGeneration`. Composer `@` still live on the provider. | Column: **1** provider call / `timeline` publish. Header: **1** / VM chrome publish. | Generation-stable column/header re-entry: **0** (**100% fewer** on that path). Composer `@` still 1 call per suggestion gather. |
| 4 | `cachedChatRowPaintContext` | Return cached context when `contentGeneration` **and** row/visible **counts** match, **before** the signature String. | 1 signature String per column body (~2 KiB for 50 bots). | Tool-body-only ticks: signature-builder count **0** after first fill (**100% fewer**). |
| 5 | `normalizedFinalsMemo` | `countLimit` 512 → 128; `totalCostLimit` **128 KiB**; fingerprint key. | Unbounded value cost; 512 entries; length-only keys. | **75% fewer retained entries** at the count ceiling; 128 KiB cap; equal-length finals miss independently. |
| 6 | Edit/diff `jsonObject` | Reuse `toolInputObject(forBody:)` | Second `JSONSerialization` of the same object JSON. | Warm Edit JSON: **0 extra parses** (**100% fewer** duplicate object decodes). |

## Unique extras vs 393

| Rank | Site | What changed | Before | After |
| --- | --- | --- | --- | --- |
| 7 | `splitTrailingLiveTurns` + `chatFlowRows` | Memoize **history** ChatFlowRows by `contentGeneration` + history first/last ids + counts. Always recompute liveTail (split + live `chatFlowRows`) when a live turn exists. Full-sequence memo when there is no live tail. | 1 split + 2 `chatFlowRows` walks per column body, including chrome-only / ~30 Hz paint ticks. | Chrome-only with a live turn: history compute **0** after first fill; live suffix still weaves. Tool-body growth on a live turn updates live rows. No-live: full-sequence compute **0** after first fill. |
| 8 | Header `SubagentActivityBadge` `now` | Skip `vm.currentTime()` when snapshot is empty **and** popover is closed; use a stable sentinel. | **1** `Date()` per header body whenever Auto mounts idle chrome (or empty closed badge). | Empty closed: **0** clock calls (**100% fewer** header `Date()` on that path). Open popover / non-empty snapshot still live. |

## Conservative totals (named caches / calls only)

- **Key RSS (ranks 1–2):** up to ~128 KiB + ~256 KiB = **~384 KiB extra key NSStrings** → **~20 KiB** fingerprint keys (**about 95% less key RAM** on those caches). Values unchanged.
- **Provider calls (rank 3):** **1 call per publish** → **0** while `contentGeneration` is stable. Composer `@` unchanged (still live).
- **Signature allocs (rank 4):** **1 String / column body** → **0** on generation-stable count matches.
- **Finals memo (rank 5):** **75% fewer entries** at the count ceiling plus a new 128 KiB cost cap.
- **Edit/diff JSON (rank 6):** duplicate object parse **eliminated** on the warmed live-tool path.
- **ChatFlowRow (rank 7):** chrome-only **history** weave **1 → 0**; live suffix stays fresh (tool-body growth is a live miss). No-live full sequence still **0** after first fill.
- **Header Date() (rank 8):** **1 / header body** on idle Auto chrome → **0**.

## What this is not

- Not process RSS % (no Instruments).
- Not a claim that token/tool storms stop publishing `timeline`.
- Not a whole Agent App “10% less memory” or “1% faster” stopwatch result.

## Proof

```
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  /usr/bin/swift test --package-path /private/tmp/isolated-agent-app-memperf-20260925T150320Z \
  --filter AgentAppMemPerfWinsTests \
  --filter AgentAppMemoryR6CapTests \
  --filter AgentChromePerfGapTests \
  --skip Distill
```
