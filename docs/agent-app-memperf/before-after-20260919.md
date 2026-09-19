# Agent App mem/perf before → after (2026-09-19)

HEAD base: `5515958f` (`origin/production`). Isolated worktree `perf/agent-app-memperf-20260919T150444Z`. Open MR 386 is **not** in this tree; ranks 1–2 are leftovers from that change, shipped here **together with** rank 3 header snapshot + rank 4 signature short-circuit (unique extras).

## Measurement basis

**Cache-key byte arithmetic**, **provider / parse / signature-builder call counts**, and existing XCTest seams (`toolInputObjectComputeCountForTesting`, `normalizedTextCacheComputeCountForTesting`, `mentionableBotsSnapshotProviderCallCountForTesting`, `chatRowPaintContextSignatureBuilderCountForTesting`, `chatRowPaintContextComputeCountForTesting`).

No Instruments samples were taken. Do **not** read the estimates below as process RSS % or wall-clock “% faster.” Values are occupancy/call-count models for the named caches and hot paths.

## Before → after

| Rank | Site | What changed | Before | After |
| --- | --- | --- | --- | --- |
| 1 | `toolInputObject` / `toolInputCache` | Key = `AgentMessageMarkdown.cacheKey` (`utf8Count:hash`), not `body as NSString` | Key bytes ≈ cached JSON bodies. Cost-limit occupancy up to **128 KiB of keys**. Illustrative 20 tools × 4 KiB JSON = **80 KiB keys**. Parse count already 1/unique body. | Keys ~20–40 ASCII bytes. 256 entries → **~10 KiB keys**. Parse count **unchanged** (still 1/body; warm `toolCommandPreview` extra_parses = 0). |
| 2 | `normalizedTextCache` + `compactTextCache` | Same fingerprint keys | 2 caches × 128 KiB cost occupancy → up to **~256 KiB of key NSStrings** on top of ~256 KiB of value NSStrings. Unicode-scalar walk skipped on hit. | ~20–40 B × 128 × 2 ≈ **~10 KiB keys**. Transform CPU on miss unchanged; warm hits still skip unicode walks (compute count stays 1). |
| 3 | Transcript column + header `SubagentActivityBadge` | Snapshot `mentionableBots` once per `contentGeneration`; pass into **both** column and header. Composer `@` still calls the provider live. | Column: **1** `mentionableBotsProvider()` / `timeline` publish (including tool-body-only). Header: **1** provider call / VM chrome publish (`applySubagentActivity`, status, …). SQLite stays 1 (`listCached`). | Generation-stable column re-entry: **0** provider calls. Header after `applySubagentActivity` with unchanged generation: **0**. SQLite still 1. Composer `@` still 1 call per suggestion gather. |
| 4 (unique vs 386) | `cachedChatRowPaintContext` | Return cached context when `contentGeneration` **and** row/visible **counts** match, **before** `chatRowPaintContextSignature`. | 1 signature `String` per column body. 50 bots × ~40 chars ≈ **~2 KiB alloc + hash** per `timeline` publish, even when F2 then returns the cached context. | Tool-body-only ticks: signature-builder count **0** (stays 1 after first fill). F2 compute count already 0 on that path. |

## Conservative totals (named caches / calls only)

- **Key RSS (ranks 1–2):** up to ~128 KiB + ~256 KiB = **~384 KiB extra key NSStrings** → **~20 KiB** fingerprint keys at the same count/cost ceilings. Values and parsed JSON objects are unchanged.
- **Provider calls (rank 3):** column storm + header chrome: **1 call per publish** → **0** while `contentGeneration` is stable. Unique extra vs MR 386: the **header** site is snapshotted too.
- **Signature allocs (rank 4):** **1 String / column body** → **0** on generation-stable count matches. Unique extra vs MR 386 (386 still built the signature after snapshotting bots).

## What this is not

- Not process RSS % (no Instruments).
- Not a claim that token/tool storms stop publishing `timeline` (`@Published` assigns remain; F2 + snapshot skip the expensive *work* on those publishes).
- Not ranks 5–9 (streaming-tools scan, Edit/diff JSON reuse, `normalizedFinalsMemo` cost limit, markdown rehash).

## Proof

- `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin /usr/bin/swift test --filter AgentAppMemPerfWinsTests`
- Plus `AgentAppMemoryR6CapTests` / `AgentChromePerfGapTests` additions that pin key shape, header/column snapshot, and signature-builder order.
