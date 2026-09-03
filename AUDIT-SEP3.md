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

## Invariants (every slice)
- Token Saver counting/display contract untouched.
- Browser parity (macOS <-> iOS host-state sync) intact.
- Loading/perf rules: immediate ack, coalesced freshness, latest-wins, honest cache-first.
