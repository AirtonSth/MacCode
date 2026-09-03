# Improve Sep-3 Audit Checklist

Goal: lighter, more fluid, zero errors across all Sources areas.
One bounded fix per fire. Skills: swiftui-performance-audit, swiftui-view-refactor, swift-concurrency (local clones under ~/Swift-Agent-Skills/local).

## Coverage
- [x] Slice 1 (2026-09-03): `Sources/AppShell/CommandPalette*.swift`, `PaletteFrecency.swift`, `ClosedTabRingBuffer.swift` — FIXED: per-open frecency snapshot (e9d2642f)
- [x] Slice 2 (2026-09-03): `Sources/Surfaces/` render paths — reviewed AgentChatTimelineChrome (fresh prod SIGSEGV rework, untouched), BrowserSurface (cached UA, KVO gates, bounded Google-refresh, untouched), AgentChatLiveTurnChrome (memoized, untouched), AgentChatUXPresentation (paint windows/NSCache, untouched), FeedSurface (ingest gate/precomputed keys, untouched). FIXED: MarkdownSurface.headingLevel painted `#hashtag` as `<h1>` — now requires space/tab/EOL (3c7da16b)
- [x] Slice 3 (2026-09-03): `Sources/Persistence/` — reviewed Repositories (one-shot lists, writer-side occupancy, gateway off MainActor), list gateways, PromptHistory/Settings/TokenSaver codecs (shared, untouched). FIXED: BotAttentionPushBindingStore + BotAttentionNotificationMetadataStore allocated JSONEncoder/Decoder per call — now shared static pairs under existing lock (commit pending)
- [ ] `Sources/Surfaces/` (AgentAppSurface, transcript/timeline chrome, markdown cache, terminal, browser)
- [x] Slice 7 (2026-09-03): `Sources/DistillCore/` (contract-safe: no formula/display/savings-math touched) — reviewed crushers/gates/policies/admission/codecs (all shared/compiled). FIXED: LibrarianHandlers rebuilt 6 NSRegularExpressions per handler invocation (errorSite/blob/secret/ANSI/alias/svg) — now compiled once as enum statics (2a817db4)
- [x] Slice 8 (2026-09-03): `Sources/AppShell/` rest — reviewed Sidebar/PaneTabs diff, outboxes (shared codecs/coalescing), scheduler/tabs (cache-first), Bots/Pet (shared codecs, injectable timers), Keybinding cache, QR payload. FIXED: TailcatTransport per-byte String(format:) hex digests — now nibble table matching HostMutationContract/WorkspaceFileService (commit pending)
- [ ] `Sources/Persistence/` (repos, SQLite, snapshot, attachments)
- [x] Slice 3 (2026-09-03): `Sources/Persistence/` — reviewed Repositories (one-shot lists, writer-side occupancy, gateway off MainActor), list gateways, PromptHistory/Settings/TokenSaver codecs (shared, untouched). FIXED: BotAttentionPushBindingStore + BotAttentionNotificationMetadataStore allocated JSONEncoder/Decoder per call — now shared static pairs under existing lock (34f78ffc)
- [x] Slice 4 (2026-09-03): `Sources/CoreModel/` — reviewed WrappedCommandCatalog (static sets), AgentTypes Grok policy (clean), codecs/regexes (all shared), RCWireProtocol, turn-boundary logic, TabColor/Schedule/Session/Graphify (clean). FIXED: BotMentionParser.suggestions lowercased handle+name per bot per keystroke — now allocation-free case-insensitive range match, semantics identical (9567ad5a)
- [x] Slice 5 (2026-09-03): `Sources/SocketServer/` — reviewed EventBus (shared codecs/locks), WebSocketEventBatcher/OutboundQueue (coalescing, FIFO, serial writer), PayloadCodec (streaming caps), metrics/redactor (clean). FIXED: BrowserSurface.publishNavigationChange fanned out persist+EventBus on every KVO/didFinish/script repeat — now dedupes identical url+title, every change still emits (commit pending)
- [x] Slice 6 (2026-09-03): `Sources/AgentRuntime/` — reviewed parsers (Claude/Codex lowercased-switch, compiled regexes), stderr classifier, pipe drain, login-shell cache, orchestration codecs (all shared). FIXED: GrokParser.normalizeStopReason recompiled its camelCase regex per call — now compiled once (9e83f2db)
- [x] Slice 7 (2026-09-03): `Sources/DistillCore/` (contract-safe: no formula/display/savings-math touched) — reviewed crushers/gates/policies/admission/codecs (all shared/compiled). FIXED: LibrarianHandlers rebuilt 6 NSRegularExpressions per handler invocation (errorSite/blob/secret/ANSI/alias/svg) — now compiled once as enum statics (commit pending)
- [x] Slice 5 (2026-09-03): `Sources/SocketServer/` — reviewed EventBus (shared codecs/locks), WebSocketEventBatcher/OutboundQueue (coalescing, FIFO, serial writer), PayloadCodec (streaming caps), metrics/redactor (clean). FIXED: BrowserSurface.publishNavigationChange fanned out persist+EventBus on every KVO/didFinish/script repeat — now dedupes identical url+title, every change still emits (016deaba)
- [x] Slice 6 (2026-09-03): `Sources/AgentRuntime/` — reviewed parsers (Claude/Codex lowercased-switch, compiled regexes), stderr classifier, pipe drain, login-shell cache, orchestration codecs (all shared). FIXED: GrokParser.normalizeStopReason recompiled its camelCase regex per call — now compiled once (commit pending)
- [ ] `Sources/SocketServer/` (event bus, dispatcher, browser sync parity)
- [ ] `Sources/AppLifecycleSupport/`, `DesignSystemKit/`, `RC2CLI/`, misc targets

## Invariants (every slice)
- Token Saver counting/display contract untouched.
- Browser parity (macOS <-> iOS host-state sync) intact.
- Loading/perf rules: immediate ack, coalesced freshness, latest-wins, honest cache-first.
