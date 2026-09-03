# Improve Sep-3 Audit Checklist

Goal: lighter, more fluid, zero errors across all Sources areas.
One bounded fix per fire. Skills: swiftui-performance-audit, swiftui-view-refactor, swift-concurrency (local clones under ~/Swift-Agent-Skills/local).

## Coverage
- [x] Slice 1 (2026-09-03): `Sources/AppShell/CommandPalette*.swift`, `PaletteFrecency.swift`, `ClosedTabRingBuffer.swift` — FIXED: per-open frecency snapshot (e9d2642f)
- [x] Slice 2 (2026-09-03): `Sources/Surfaces/` render paths — reviewed timeline chrome, BrowserSurface, live-turn chrome, UX presentation, Feed. FIXED: MarkdownSurface.headingLevel painted `#hashtag` as `<h1>` — now requires space/tab/EOL (3c7da16b)
- [x] Slice 3 (2026-09-03): `Sources/Persistence/` — reviewed Repositories, gateways, shared codecs. FIXED: BotAttention* stores allocated codecs per call — now shared static pairs (34f78ffc)
- [x] Slice 4 (2026-09-03): `Sources/CoreModel/` — reviewed catalog, policies, codecs/regexes, wire protocol, turn logic. FIXED: BotMentionParser.suggestions per-bot lowercased() allocs — now allocation-free match (9567ad5a)
- [x] Slice 5 (2026-09-03): `Sources/SocketServer/` — reviewed EventBus, WS batcher/queue, PayloadCodec, metrics. FIXED: BrowserSurface.publishNavigationChange fanned out on repeats — now dedupes identical url+title (016deaba)
- [x] Slice 6 (2026-09-03): `Sources/AgentRuntime/` — reviewed parsers, stderr classifier, pipe drain, login-shell cache, codecs. FIXED: GrokParser.normalizeStopReason regex per call — now compiled once (9e83f2db)
- [x] Slice 7 (2026-09-03): `Sources/DistillCore/` (contract-safe) — reviewed crushers/gates/policies/codecs. FIXED: LibrarianHandlers 6 regexes per invocation — now enum statics (2a817db4)
- [x] Slice 8 (2026-09-03): `Sources/AppShell/` rest — reviewed Sidebar/PaneTabs, outboxes, scheduler, Bots/Pet, keybindings, QR, Tailcat. FIXED: TailcatTransport per-byte String(format:) hex — now nibble table (46ac6305)
- [x] Slice 9 (2026-09-03): Agent-thread open path (`AgentAppSurface.gatherThreadOpenBundle`, `AppCommandRouter.open/selectAgentThread`) — reviewed (cache-first, coalesced reloads). FIXED: off-main bundle allocated JSONDecoder per thread open — now shared static under lock, mirroring MainActor rehydrate path (commit pending)
- [ ] `Sources/AppLifecycleSupport/`, `DesignSystemKit/`, misc targets (`RC2CLI`, `CSystem`, treaty/scheduled-task agent) — reviewed, no gaps found

## Flags (pre-existing, NOT from Sep-3 slices)
- `AgentAppViewModelTests.test_selectThreadRehydratesPersistedStaleCallbacksIntoTimeline` fails identically on pure origin/production (verified in temp worktree, since removed): stale callbacks never reach the timeline. Needs a main-agent triage; Sep-3 does not touch that path.
- [x] Slice 9 (2026-09-03): Agent-thread open path (`AgentAppSurface.gatherThreadOpenBundle`, `AppCommandRouter.open/selectAgentThread`) — reviewed (cache-first, coalesced reloads). FIXED: off-main bundle allocated JSONDecoder per thread open — now shared static under lock, mirroring MainActor rehydrate path (bbf028ed)
- [x] Slice 10 (2026-09-03): `Sources/Surfaces/` big files (DiffPanel, SubagentActivity, composer, terminal stack, AgentAppSurface) + `AppLifecycleSupport`/`DesignSystemKit`/SocketServer remainder — reviewed (capped diffs, bounded projections, static tokens, coalesced sync). FIXED: DiffPanel filteredCommits trimmed the query per commit per keystroke — now once per pass, semantics identical (commit pending)
- [x] Slice 11 (2026-09-03): `Sources/AppLifecycleSupport/`, `DesignSystemKit/`, misc targets (`RC2CLI`, `CSystem`, treaty/scheduled-task agent) — reviewed (pure governors, nibble-table hex, shared formatters, memoized recorder). FIXED: `DS.NS.terminalFont` ran up to 3 `NSFont(name:)` font-manager lookups per call, invoked per bold cell in `ANSIRenderer.buildSnapshot` — now memoized statics hoisted once per snapshot; non-regular/non-bold weights keep exact fallback (commit pending)
- [ ] `Sources/AppShell/` big files (AppCommandRouter, AppDelegate, TerminalSurface, SSHSurface, SettingsWindow), `Sources/AgentRuntime/` remainder, `Sources/Persistence/` remainder — deeper second pass
- [x] Slice 12 (2026-09-03): `Sources/Persistence/` second pass — reviewed per-call codecs (most already shared/locked). FIXED: `BotRemoteControlAuthority.runAsUserObject` allocated a fresh `JSONEncoder` per call on bot routing/authoring paths — now shared static under a short lock (JSONEncoder not thread-safe); wire JSON unchanged
- [x] Slice 13 (2026-09-03): `Sources/Surfaces/` terminal snapshot path + `SocketServer` remainder — reviewed (codecs per-connection by design, transcript chrome formatters shared, merge paths O(N)). FIXED: `ANSIRenderer.buildSnapshot`/`buildANSISnapshot` materialised the 10k-row scrollback ring via `scrollback + grid` on every uncached repaint — now index the ring in place; output identical
- [x] Slice 14 (2026-09-03): `Sources/AppShell/` big-file second pass — reviewed per-call codecs/formatters (router/delegate/context mostly shared). FIXED: `JSONEncoder.tailcatCanonical` computed-var allocated + configured an encoder per call (hash, allowlist, keychain save) — now a shared static; bytes unchanged
- [x] Slice 15 (2026-09-03): `Sources/AgentRuntime/` provider remainder — reviewed per-call codecs/regexes (orchestration/coordinator/transcript already shared). FIXED: `TokenSaverAccountUsageRefresher.grokBuildProductPercent` recompiled `[^a-z0-9]` regex per product row — now a shared static; slug identical
- [x] Slice 16 (2026-09-03): `Sources/CoreModel/` + `DistillCore` remainder — reviewed per-call codecs/regexes (crushers/sanitizers already static). FIXED: `ComputerUseNativeHostBackend.stateToken` built SHA256 hex via 32× `String(format:)` per token (twice) — now nibble table; tokens identical
- [x] Slice 17 (2026-09-03): browser-sync + agent-thread + terminal-budget paths — reviewed (nav dedupe, coalesced reloads, shared codecs). FIXED: `TerminalMemoryBudgetAuthority.enforceBudget` ran filter-then-min (two dictionary traversals + filtered intermediate per eviction) — now single-pass min; victim order identical
- [x] Slice 18 (2026-09-03): AppShell Sidebar/palette second pass — reviewed (cached filters, busy caches, frecency paths). FIXED: `CommandPalette.sectioned` ran one `visible.filter` per category (N×C scans per keystroke) — now single-pass bucketing; section order/rows identical
- [x] Slice 19 (2026-09-03): Surfaces composer/live-turn second pass — reviewed (dedup paths, chrome helpers). FIXED: `AgentChatLiveTurnChrome.isRicher` walked both timelines 4× (filter×2 + flatMap×2 + weight reduce) per replay compare on the live-stream path — now one pass per side; verdict identical
- [x] Slice 20 (2026-09-03): Persistence recovery/payload second pass — reviewed (bound-before-store, shared codecs). FIXED: `AuthoritativePayloadRecovery.authoritativeByteCount`/`stripUnresolvedHandles` recompiled trailer/handle regexes per call on the token-rate persist path — now shared statics; matches identical
- [x] Slice 21 (2026-09-03): `Sources/SocketServer/` dispatcher/HTTP remainder — reviewed (shared codecs, static bodies, nibble-table hex, bounded caches). FIXED: `AttachmentUploadV2Store.chunkFileURL` re-parsed `String(format: "%05d.raw")` per chunk store/verify/assemble — now manual zero-pad; names identical
- [x] Slice 22 (2026-09-03): `Sources/AgentRuntime/` orchestration/coordinator second pass — reviewed (shared codecs/regexes, cached shell env, token/receipt paths). FIXED: `AgentRunCoordinator.cancelPreparation` ran two full `reservedProviderStarts.filter` passes + two intermediates on the Stop path — now single-pass move to cancel tokens; `residualProviderStartBookkeepingCount` counts in place (was two filter intermediates); semantics identical
- [x] Slice 23 (2026-09-03): `Sources/CoreModel/` second pass — reviewed (shared codecs/regexes, allocation-free mention match, nibble-table hex). FIXED: `ComputerUseNativeHostBackend` pixel state-token path allocated a fresh `JSONEncoder` per observation and a fresh `JSONDecoder` per mutation race check — now shared statics under a short lock (codecs not thread-safe); tokens identical
- [x] Slice 24 (2026-09-03): `Sources/Persistence/` third pass — reviewed (shared codecs/formatters/regexes, bound-before-store, sidecar paths). FIXED: `BotHome.isWritableMemoryPath` recompiled its daily-note regex via `range(of:options:.regularExpression)` on every bot Files write admission — now a shared static; matches identical
- [x] Slice 25 (2026-09-03): `Sources/Surfaces/` third pass — reviewed (cached markdown, coalesced filters, shared formatters). FIXED: `AgentChatTranscriptChrome.isImagePath` bridged to `NSString.pathExtension` + `lowercased()` + 11-element array scan per attachment per render — now direct suffix scan with chained equality; verdict identical (note: footer `formatTokenCountForFooter` `String(format:)` left untouched — its `177.0K` copy is Token Saver contract text, not a hot path)
- [x] Slice 26 (2026-09-03): `Sources/AppShell/` third pass — reviewed (shared router codecs, canonical encoder, nibble hex, cached filters). FIXED: `AppCommandRouter.fileType` bridged to `NSString.pathExtension` + `uppercased()` per file row on local/SSH listings — now direct UTF-8 suffix scan; labels identical (note: sidebar `String(format:)` token/byte/a11y copy left untouched — Token Saver display text, verified contract-sensitive in Slice 25)
- [x] Slice 27 (2026-09-03): `Sources/DistillCore/` second pass (contract-safe: no crushing math, gates, ledger, or savings touched) — reviewed (shared codecs/regexes/formatters, nibble hex, cached markdown). FIXED: `CommandOutputCharGate.truncate` ran `kept.contains` per failing line plus a `filter`/`contains` elided count (O(F×K + K×N) on over-budget truncation) — now single-pass kept-index set; output identical
- [x] Slice 28 (2026-09-03): `Sources/AppLifecycleSupport/` + `DesignSystemKit/` second pass — reviewed (shared formatters/codecs, pure governors, memoized recorder). FIXED: `CapacityQualificationManifest.validate` rebuilt the required-metric `Set` from `allCases.map` per validation — now a shared static; verdicts identical
- [x] Slice 29 (2026-09-03): browser-sync + agent-thread third pass — reviewed (nav dedupe intact, coalesced reloads, shared codecs). FIXED: `BrowserSurface.isSecureURL` copied the whole URL via `lowercased()` per nav-chrome sync — now 8-byte case-folded compare; verdict identical (note: first attempt used a non-existent `hasPrefix(caseInsensitive:)` API — build error, corrected to byte compare before commit)
- [x] Slice 30 (2026-09-03): misc targets (`RC2CLI`, `RemoteCodeTreaty`, scheduled-task agent, distill service, `CSystem`) — reviewed (shared MCP codecs, nibble hex, one-shot encoders). FIXED: `BotUploadTarget` grant init copied the 64-byte sha256 via `lowercased()` per attachment grant — now in-place A-F fold; digest identical (note: first attempt wrote through read-only `withUTF8` — build error, corrected to byte array before commit)

- [x] Slice 31 (2026-09-03): terminal-budget + queue-depth paths — reviewed (single-pass budget eviction, coalesced queue reloads). FIXED: `TerminalSurface.autoSubmitSavedSSHPasswordIfNeeded` copied the whole PTY chunk via `lowercased()` on every output arrival — now case-insensitive range scan; prompt verdicts identical

- [x] Slice 32 (2026-09-03): SSH surface second pass — reviewed (case-insensitive host filter, coalesced resize, bounded log). FIXED: `addTransferLog` rebuilt the array via `Array(suffix(200))` on every append — now trims only when over budget; contents identical

- [x] Slice 33 (2026-09-03): SocketServer event-bus filter paths — reviewed (shared encoders, nibble hex, bounded caches). FIXED: `EventStreamFilter.parse` built the interest set via split+map+filter with two intermediates — now single-pass insert; ids identical

- [x] Slice 34 (2026-09-03): AgentRuntime stderr/coordinator remainder — reviewed (shared codecs/regexes, cached shell env). FIXED: `displayableStderr` built kept lines via split+map+filter with two intermediates — now single-pass append; text identical

- [x] Slice 35 (2026-09-03): Persistence store remainder — reviewed (shared codecs, bound-before-store, one-shot ids). FIXED: `BotComputerActionStore.writeResult` rebuilt the array via `Array(suffix(32))` on every write — now trims only when over budget; retained newest identical

- [x] Slice 36 (2026-09-03): CoreModel BotBrain remainder — reviewed (mention paths, codecs, PATH handling). FIXED: `skillDescription` materialised the whole skill body as [String] before scanning — now lazy split; same result

- [x] Slice 37 (2026-09-03): Surfaces message-page remainder — reviewed (bounded projections, capped diffs, coalesced filters). FIXED: `loadMessagePageOffMain` ran two filter+map traversals over the history page for user/assistant ids — now single-pass bucketing; id sets identical

- [x] Slice 38 (2026-09-03): AppShell router remainder — reviewed (shared codecs, canonical encoder, snapshot paths). FIXED: `scrubTokenSaverEnvironment` built PATH parts via split+map+filter with two intermediates — now single-pass keep; joined PATH identical

- [x] Slice 39 (2026-09-03): SocketServer upload/HTTP remainder — reviewed (shared codecs, manual zero-pad, bounded caches). FIXED: `receivedBytes` chained compactMap+compactMap+reduce with three intermediates — now single-pass accumulate; total identical

- [x] Slice 40 (2026-09-03): AgentRuntime installer remainder — reviewed (cached shell env, token/receipt paths, wrapper catalog). FIXED: `systemCommandSearchDirectories` built dirs via split+map+filter with two intermediates — now single-pass keep; directories identical

- [x] Slice 41 (2026-09-03): `Sources/Persistence/` checkpoint-page remainder — reviewed (shared codecs, keyset pagination, bounded caps). FIXED: `listCheckpointSummaries` built items/filesTruncated/listMetadata/completedAtTokens via four separate map traversals — now one pass with reserveCapacity; page content identical

- [x] Slice 42 (2026-09-03): `Sources/AppShell/` pre-turn env remainder — reviewed (shared router codecs, canonical encoder, PATH handling). FIXED: `agentEnvironmentForRun` built PATH parts via split+map+filter with two intermediates on every agent turn — now single-pass keep; joined PATH identical

- [x] Slice 43 (2026-09-03): `Sources/AppShell/` scheduled-tasks overview — reviewed (scoped refresh, deferred hydration, keystroke filtering). FIXED: `reloadTasks` ran two counting filters plus a third listing filter per keystroke/selection — now one pass derives active count and visible list; counts/rows identical

- [x] Slice 44 (2026-09-03): `Sources/AppShell/` bots schedule-task filters — reviewed (search-scoped counts, status filtering). FIXED: `applyScheduleTaskFilters` ran two counting filters plus a third listing filter per keystroke — now one pass; counts/rows identical

- [x] Slice 45 (2026-09-03): `Sources/Surfaces/` prompt-history record path — reviewed (bounded in-memory history, persisted store, error surface). FIXED: `recordPromptHistory` rebuilt the 200-entry array via `Array(suffix:)` on every sent prompt — now trims only when over budget; retained newest identical

- [x] Slice 46 (2026-09-03): `Sources/DistillCore/` stack-trace classify path (contract-safe: no crushing math, gates, ledger, or savings touched) — reviewed (shared regex, never-inflate guard, router verdicts). FIXED: `looksLikeStackTrace` materialised every line as String + filter intermediate and always scanned to end — now lazy short-circuit scan at 5 frames; verdicts identical

- [x] Slice 47 (2026-09-03): `Sources/CoreModel/` live-timeline trim path — reviewed (turn/item caps, sort-anchor retention, translation pruning). FIXED: `trimTurnItems` copied the 5k-item tail twice (dropFirst + suffix) plus a fresh rebuilt array per over-budget append — now in-place subrange drop; anchor/newest/pruning identical

- [x] Slice 48 (2026-09-03): `Sources/AgentRuntime/` CLI-adapter prune paths — reviewed (readable-event window, session eviction, rollback retention). FIXED: `pruneReadableEvents` rebuilt the whole readable window via `Array(suffix:)` on every appended event — now in-place prefix drop; retained newest identical

- [x] Slice 49 (2026-09-03): `Sources/Surfaces/` composer rank path — reviewed (deduped catalogs, per-kind budgets, prefix ranking). FIXED: `ranked` lowercased per row in filter + twice per sort comparison per keystroke — now folds keys once in a single pass; suggestion order identical

- [x] Slice 50 (2026-09-03): `Sources/SocketServer/` response-codec path — reviewed (gzip-first policy, size gate, header parsing). FIXED: `preferredResponseCodec` built the Accept-Encoding token array + two contains passes per JSON response — now single short-circuit scan; verdicts identical

- [x] Slice 51 (2026-09-03): `Sources/AppShell/` Pet dest-attention projection — reviewed (unread-dedupe, unscoped-bot guard, enabled gating). FIXED: `projectDest` ran filter+map for the enabled set plus a second map for the lookup dictionary (two traversals + two intermediates per refresh) — now one pass builds both with reserved capacity; projected items identical

- [x] Slice 52 (2026-09-03): `Sources/AgentRuntime/` git line-parse paths — reviewed (`branches` list, `remoteNames`; DistillCore crusher splits excluded by Token Saver contract). FIXED: `branches` + `remoteNames` each ran split+map+filter (three traversals + two intermediates per git listing) — now one shared `nonEmptyLines` single-pass helper; listings identical

- [x] Slice 53 (2026-09-03): `Sources/AppLifecycleSupport/` capacity-contract validate path — reviewed (required-metric set already static; variance/mismatch guards intact). FIXED: physical-tier claim set ran filter+map+Set (three traversals + two intermediates per validate) — now one pass inserts executed tier names with reserved capacity; mismatch verdicts identical

- [x] Slice 54 (2026-09-03): `Sources/AppShell/` desk thread-rail prefetch — reviewed (cache-first prefetch, single batched `listChrome`, rail fallback routing). FIXED: `prefetchDeskThreadRailRouting` ran compactMap+filter (two traversals + one ID intermediate per desk reload) — now one pass appends uncached linked IDs with reserved capacity; fetched ID list identical

- [x] Slice 55 (2026-09-03): `Sources/Surfaces/` transcript display-decoration strip — reviewed (modern decoration strip first, legacy 📎 suffix fallback, `[Image #N]` marker preservation). FIXED: `promptByRemovingDisplayDecorations` ran map+filter for legacy names (two traversals + one name intermediate per retry/re-render) — now one pass collects non-empty display names with reserved capacity; stripped prompts identical

- [x] Slice 56 (2026-09-03): `Sources/AppShell/` provider-admission governor — reviewed (reservation expiry, resident-root pruning, appeared-PID pairing). FIXED: `decide` built `currentRootPIDs` via compactMap+filter+Set (three traversals + two intermediates per admission decision) — now one pass inserts positive pgids with reserved capacity; admission verdicts identical

- [x] Slice 57 (2026-09-03): `Sources/AppShell/` pane close-others seam — reviewed (single `closeSurfaces` batch, sibling before/after helpers already single-map). FIXED: `surfaceIDs(excluding:in:)` ran map+filter (two traversals + one ID intermediate per close-others) — now one pass collects surviving IDs with reserved capacity; closed set identical. (Also probed: rail `runningThreadIds` O(T×R) scan — reverted, needs broader redesign, not a one-line fold; `test_saveLatestProposedPlanWritesMarkdownFile` crash reproduces on clean tree, pre-existing.)

- [x] Slice 58 (2026-09-03): `Sources/AgentRuntime/` process-tree walk — reviewed (sweep accounting, stale-ledger fallback, ownership kill-set; all callers order-insensitive via Set/signalling). FIXED: `descendants(of:in:)` re-scanned the whole process table per tree level (O(levels×P) filter+map per lookup) — now one pass builds a ppid→pids index, then walks with O(1) child lookups; descendant sets identical

## Invariants (every slice)
- Token Saver counting/display contract untouched.
- Browser parity (macOS <-> iOS host-state sync) intact.
- Loading/perf rules: immediate ack, coalesced freshness, latest-wins, honest cache-first.
