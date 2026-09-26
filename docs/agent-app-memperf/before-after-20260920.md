# Agent App mem/perf before → after (2026-09-20)

HEAD base: `5515958f` (`origin/production`). Isolated worktree `perf/agent-app-memperf-20260920T150527Z`.

Open MR 389 (`8805deb0`) overlaps ranks 1–4 and is **not** in this tree. This change ships those leftovers **and** unique extras (ranks 5–6) so ranks 1–2 are not the only win.

## Measurement basis

**Cache-key byte arithmetic**, **provider / parse / signature-builder call counts**, and XCTest seams (`toolInputObjectComputeCountForTesting`, `normalizedTextCacheComputeCountForTesting`, `mentionableBotsSnapshotProviderCallCountForTesting`, `chatRowPaintContextSignatureBuilderCountForTesting`, `normalizedFinalsComputeCountForTesting`).

No Instruments samples were taken. Do **not** read the estimates below as process RSS % or a whole-app wall-clock “% faster.” Values are occupancy/call-count models for the named caches and hot paths.

## Before → after

| Rank | Site | What changed | Before | After |
| --- | --- | --- | --- | --- |
| 1 | `toolInputObject` / `toolInputCache` | Keep `body as NSString` as the key after the fingerprint-key variant regressed the comparable 20-tool preview benchmark by ~23%. | Key bytes scale with retained JSON bodies; the 128 KiB value-cost limit does not include key storage. Parse count 1/unique body after warming. | Retains the existing body-key memory cost to keep warm preview latency within the settled-latency guardrail. Parse count remains 1/body. |
| 2 | `normalizedTextCache` + `compactTextCache` | Same fingerprint keys | 2 caches × 128 KiB cost occupancy → up to **~256 KiB of key NSStrings** on top of values. Unicode-scalar walk skipped on hit. | ~20–40 B × 128 × 2 ≈ **~10 KiB keys**. **~96% fewer key bytes**. Transform CPU on miss unchanged; warm hits still skip unicode walks. |
| 3 | Transcript column + header `SubagentActivityBadge` | Snapshot `mentionableBots` once per `contentGeneration` and `BotStore.botsListRevision`; pass into **both** column and header. Composer `@` still calls the provider live. | Column: **1** `mentionableBotsProvider()` / `timeline` publish. Header: **1** provider call / VM chrome publish. | Revision-stable column/header re-entry: **0** provider calls (**100% fewer** on that path); bot catalog writes invalidate without a transcript edit. Composer `@` still 1 call per suggestion gather. |
| 4 | `cachedChatRowPaintContext` | Return cached context when transcript/catalog revisions and row/visible **counts** match, **before** `chatRowPaintContextSignature`. | 1 signature `String` per column body. 50 bots × ~40 chars ≈ **~2 KiB alloc + hash** per `timeline` publish, even when F2 then returns the cached context. | Revision-stable tool-body-only ticks: signature-builder count **0** after first fill (**100% fewer** signature allocs on that path). |
| 5 (unique vs 389) | `normalizedFinalsMemo` | `countLimit` 512 → 128; add `totalCostLimit` **128 KiB**; key fingerprints the finished final instead of utf8 length. | Unbounded value cost; 512 entries. Length-only keys reused equal-length finals (`alpha`/`bravo`). | **75% fewer retained entries** at the count ceiling; occupancy capped at 128 KiB. Equal-length finals miss independently. |
| 6 (unique vs 389) | Edit/diff `jsonObject` + object `diffFromJSONChanges` | Reuse `toolInputObject(forBody:)` | Second `JSONSerialization` of the same `{…}` body already parsed for live tool rows. | Warm Edit JSON: **0 extra parses** (**100% fewer** duplicate object decodes on that path). Array JSON still uses `JSONSerialization`. |

## Conservative totals (named caches / calls only)

- **Key RSS (ranks 1–2):** only `normalizedTextCache` and `compactTextCache` use fingerprint keys; at the stated count/cost ceilings, their estimated key storage falls from up to ~256 KiB to ~10 KiB. `toolInputCache` keeps full-body keys to avoid a measured preview latency regression. Values and parsed JSON objects are unchanged.
- **Provider calls (rank 3):** **1 call per publish** → **0** while transcript and bot-catalog revisions are stable.
- **Signature allocs (rank 4):** **1 String / column body** → **0** on revision-stable count matches.
- **Finals memo (rank 5):** **75% fewer entries** at the count ceiling plus a new 128 KiB cost cap (was unbounded).
- **Edit/diff JSON (rank 6):** duplicate object parse **eliminated** on the warmed live-tool path.

## What this is not

- Not process RSS % (no Instruments).
- Not a claim that token/tool storms stop publishing `timeline`.
- Not a whole Agent App “10% less memory” or “1% faster” stopwatch result. The evidenced reductions are the named paths above.

## Proof

```
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  /usr/bin/swift test --filter AgentAppMemPerfWinsTests \
  --filter AgentAppMemoryR6CapTests \
  --filter AgentChromePerfGapTests \
  --skip Distill
```
