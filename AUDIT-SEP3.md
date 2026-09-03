# Improve Sep-3 Audit Checklist

Goal: lighter, more fluid, zero errors across all Sources areas.
One bounded fix per fire. Skills: swiftui-performance-audit, swiftui-view-refactor, swift-concurrency (local clones under ~/Swift-Agent-Skills/local).

## Coverage
- [x] Slice 1 (2026-09-03): `Sources/AppShell/CommandPalette*.swift`, `PaletteFrecency.swift`, `ClosedTabRingBuffer.swift` — FIXED: per-open frecency snapshot (commit pending)
- [ ] `Sources/Surfaces/` (AgentAppSurface, transcript/timeline chrome, markdown cache, terminal, browser)
- [ ] `Sources/AppShell/` rest (windows, controllers, pet, sidebar, pane tabs)
- [ ] `Sources/Persistence/` (repos, SQLite, snapshot, attachments)
- [ ] `Sources/CoreModel/` (types, wrapped-command catalog)
- [ ] `Sources/DistillCore/` + Token Saver stack (no formula/display changes)
- [ ] `Sources/AgentRuntime/` + providers (Claude/Codex/Grok parity)
- [ ] `Sources/SocketServer/` (event bus, dispatcher, browser sync parity)
- [ ] `Sources/AppLifecycleSupport/`, `DesignSystemKit/`, `RC2CLI/`, misc targets

## Invariants (every slice)
- Token Saver counting/display contract untouched.
- Browser parity (macOS <-> iOS host-state sync) intact.
- Loading/perf rules: immediate ack, coalesced freshness, latest-wins, honest cache-first.
