# Agent App memory/perf findings (2026-09-15)

Scope: Agent App transcript/render path in macos-app sparse worktree.
Baseline HEAD: `28029d43` (origin/production). Prior AA-02…AA-32 / EventBus 128 already landed.

## P0 — History/non-active item lookup still scales with timeline size

**Where:** `Sources/CoreModel/AssistantEvents.swift` `mutateItem(_:)` / `item(withId:)` (newest-first nested scan).

**Why it still hurts:** Live streaming to the *active* (last) item is ~O(1) and covered by `test_streamingDeltasToActiveItemStayBounded…`. History replay, progress/state updates, and deltas targeting *older* items still walk from the newest end. For an item near the start of a turn with N items, each event costs ~N comparisons. Replaying M events against mid-timeline items remains ~O(N·M) on the main actor at the ~5k-event prune cap.

**Evidence:** Comments at `AgentAppSurface.swift:17-22` describe this; `TimelineItemIndex` exists but AA-29 forbids rebuilding it unused on every open (`test_viewModelNoLongerBuildsTheUnreadTimelineItemIndex`). Index must live *inside* `AssistantTimelineState` and update incrementally on insert/prune — not rebuilt from the view model.

**Fix sketch:** Maintain private `[String:(turn,item)]` (and optional turnId→index) on `AssistantTimelineState`; update on `itemStarted` / prune / decode; `mutateItem` uses map first, falls back to scan. Exclude from Codable or rebuild after decode. Add comparison-count test for non-active deltas with large N.

**BEFORE metric:** Non-active delta lookups ≈ distance-from-end comparisons each (worst ~N).
**AFTER target:** ≤3 comparisons per known id regardless of N (same bound as active-item test).

## P1 — `idealSizeCache` keys store full prompt strings

**Where:** `AgentLinkedInlineText.swift` ~563-580 (`idealSizeCache`).

**Why:** Cache key is `"font|size|padding|\(string)"`. Long user prompts duplicate full UTF-16 in the key *and* the measured box. `countLimit=256`, `totalCostLimit=1MB` but cost may not reflect key retention well.

**Fix sketch:** Key by fingerprint (`AgentMessageMarkdown.sourceFingerprint` or utf8 hash) + font metrics; keep countLimit≤128.

**BEFORE:** Up to 256 full-string keys retained for hug measurement.
**AFTER target:** ~50% fewer retained key bytes (fingerprint keys); estimate **~5–10% less Agent App text-measure cache RAM** under long-prompt threads.

## P1 — Host-metadata ordinal pairing is O(items²) per turn

**Where:** `AgentAppSurface.swift` ~3492-3498 `snapshotPreservingPersistedHostMetadata` (`reduce` over prefix for each attested item).

**Why:** Rare path but runs during attested replay; quadratic in items/turn.

**Fix sketch:** Single pass counting `(id,type)` occurrences.

**BEFORE:** ~items² equality checks per attested turn.
**AFTER:** O(items) — estimate **~1–3% faster cold thread open** when host metadata attestations present on large turns.

## P2 — Markdown NSCache still 512×4MB budgets

**Where:** `AgentMessageMarkdown.swift` blocks/inline caches.

Already bounded; optional tighten to 256 / 2MB if Instruments shows pressure. Defer unless P0/P1 leave headroom.

## Already fixed (do not re-do)

- LazyVStack hang class audits; streaming partial cache skip; painted timeline cap=3; EventBus recentLimit=128; newest-first active-item mutateItem; AA-22/24/31/32 memoization; composer isolated ObservableObject; hot message page limits.
