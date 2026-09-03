# Improve Sep-3 Audit Checklist

Goal: lighter, more fluid, zero errors across all Sources areas.
One bounded fix per fire. Skills: swiftui-performance-audit, swiftui-view-refactor, swift-concurrency (local clones under ~/Swift-Agent-Skills/local).

## Coverage
- [x] Slice 1 (2026-09-03): `Sources/AppShell/CommandPalette*.swift`, `PaletteFrecency.swift`, `ClosedTabRingBuffer.swift` — FIXED: per-open frecency snapshot (e9d2642f)
- [x] Slice 2 (2026-09-03): `Sources/Surfaces/` render paths — reviewed AgentChatTimelineChrome (fresh prod SIGSEGV rework, untouched), BrowserSurface (cached UA, KVO gates, bounded Google-refresh, untouched), AgentChatLiveTurnChrome (memoized, untouched), AgentChatUXPresentation (paint windows/NSCache, untouched), FeedSurface (ingest gate/precomputed keys, untouched). FIXED: MarkdownSurface.headingLevel painted `#hashtag` as `<h1>` — now requires space/tab/EOL (3c7da16b)
- [x] Slice 3 (2026-09-03): `Sources/Persistence/` — reviewed Repositories (one-shot lists, writer-side occupancy, gateway off MainActor), list gateways, PromptHistory/Settings/TokenSaver codecs (shared, untouched). FIXED: BotAttentionPushBindingStore + BotAttentionNotificationMetadataStore allocated JSONEncoder/Decoder per call — now shared static pairs under existing lock (commit pending)
- [ ] `Sources/Surfaces/` (AgentAppSurface, transcript/timeline chrome, markdown cache, terminal, browser)
- [ ] `Sources/AppShell/` rest (windows, controllers, pet, sidebar, pane tabs)
- [ ] `Sources/Persistence/` (repos, SQLite, snapshot, attachments)
- [x] Slice 3 (2026-09-03): `Sources/Persistence/` — reviewed Repositories (one-shot lists, writer-side occupancy, gateway off MainActor), list gateways, PromptHistory/Settings/TokenSaver codecs (shared, untouched). FIXED: BotAttentionPushBindingStore + BotAttentionNotificationMetadataStore allocated JSONEncoder/Decoder per call — now shared static pairs under existing lock (34f78ffc)
- [x] Slice 4 (2026-09-03): `Sources/CoreModel/` — reviewed WrappedCommandCatalog (static sets), AgentTypes Grok policy (clean), codecs/regexes (all shared), RCWireProtocol, turn-boundary logic, TabColor/Schedule/Session/Graphify (clean). FIXED: BotMentionParser.suggestions lowercased handle+name per bot per keystroke — now allocation-free case-insensitive range match, semantics identical (9567ad5a)
- [x] Slice 5 (2026-09-03): `Sources/SocketServer/` — reviewed EventBus (shared codecs/locks), WebSocketEventBatcher/OutboundQueue (coalescing, FIFO, serial writer), PayloadCodec (streaming caps), metrics/redactor (clean). FIXED: BrowserSurface.publishNavigationChange fanned out persist+EventBus on every KVO/didFinish/script repeat — now dedupes identical url+title, every change still emits (commit pending)
- [ ] `Sources/DistillCore/` + Token Saver stack (no formula/display changes)
- [ ] `Sources/AgentRuntime/` + providers (Claude/Codex/Grok parity)
- [ ] `Sources/SocketServer/` (event bus, dispatcher, browser sync parity)
- [ ] `Sources/AppLifecycleSupport/`, `DesignSystemKit/`, `RC2CLI/`, misc targets

## Invariants (every slice)
- Token Saver counting/display contract untouched.
- Browser parity (macOS <-> iOS host-state sync) intact.
- Loading/perf rules: immediate ack, coalesced freshness, latest-wins, honest cache-first.
