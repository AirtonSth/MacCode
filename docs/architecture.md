# RemoteCode Architecture (current state)

A walk through what's actually built right now. Use this together with `report.html` (the human-facing changelog) and `project/14-reference-repos-distillation.md` (cmux + T3 Code reference notes).

## Module layout

```
Package.swift
├── CSystem            — forkpty/TIOCSWINSZ C shim
├── CoreModel          — pure-Swift domain (IDs, surfaces, split tree,
│                        layout reducer, AssistantEvents reducer,
│                        agent types, session snapshot)
├── Persistence        — direct sqlite3 wrapper, versioned schema (current v29),
│                        repositories, fixture factory, EventLog,
│                        DeviceTrustRepository, NotificationRepository,
│                        ReversibleContentStore
├── AgentRuntime       — AgentProviderRunner protocol; Codex+Claude
│                        parsers, runners, FakeProviderRunner,
│                        AgentRunCoordinator, GitDiff helper,
│                        provider skill/MCP installer
├── SocketServer       — JSON-RPC 2.0 envelope/dispatcher, Unix-socket
│                        transport, DirectHTTPServer (loopback or LAN,
│                        pair endpoints, /v1/ws WebSocket), EventBus
├── Surfaces           — Surface protocol + registry, ANSIRenderer,
│                        TerminalSurface (forkpty PTY), BrowserSurface
│                        (WKWebView + P0+P1 automation), AgentAppSurface
│                        (SwiftUI), MarkdownSurface, FilePreviewSurface,
│                        DiffPanelSurface
├── AppShell  (exe)    — NSApplication delegate, NSWindow shell,
│                        SwiftUI sidebar, NSSplitView pane tree,
│                        AppCommandRouter, CommandPalette,
│                        SettingsWindowController, SystemNotifier
├── RC2CLI    (exe)    — rc2 binary, thin Unix-socket client
└── RemoteCodeDistillService (exe) — provider proxy, Agent App middleware,
                                     subagent telemetry, Chrome host, and
                                     bot / computer-use MCP servers
```

## State flow

```
            (CLI / future mobile / UI)
                       │
              JSON-RPC over Unix socket
                       │
                 JSONRPCDispatcher
                       │  (always @MainActor)
                       ▼
              AppCommandRouter
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
    AppContext    SurfaceRegistry   AgentRunCoordinator
    (reducer)     (live NSViews)    (Codex/Claude processes)
        │              │              │
   SQLite DB      AppKit/SwiftUI    EventBus → SQLite events
        │              │              │
        └──────────────▼──────────────┘
                 SessionSnapshot
            (persisted; replayed on launch)
```

Every domain mutation goes through `AppCommandRouter`, which is `@MainActor` so it can safely touch AppKit. Mutations produce events on the in-memory `EventBus`; the bus persists each event to the SQLite `events` table and fans out to:

- Local CLI clients subscribed via `events.stream`.
- HTTP `/v1/ws` WebSocket clients.

## Surfaces

| Type | Backing | Notes |
|------|---------|-------|
| `terminal` | `Sources/Surfaces/TerminalSurface.swift` | forkpty + ANSIRenderer; emits raw bytes on stdin, attributed grid into NSTextView. |
| `browser` | `Sources/Surfaces/BrowserSurface.swift` | WKWebView; P0 + P1 automation via injected JS + WeakMap-based stable element refs. |
| `agentApp` | `Sources/Surfaces/AgentAppSurface.swift` | SwiftUI host: provider/model picker, streaming timeline, branch toolbar, changed-files card, plan sidebar, terminal drawer, composer. |
| `markdown` | `Sources/Surfaces/MarkdownSurface.swift` | WKWebView rendering in-app minimal markdown → HTML. |
| `filePreview` | `Sources/Surfaces/FilePreviewSurface.swift` | NSImageView / PDFView / NSTextView by extension. |
| `rightSidebarTool` | `Sources/Surfaces/DiffPanelSurface.swift` | SwiftUI diff viewer (status glyphs + tinted patch body). |

Every surface conforms to `Surface` and registers in `SurfaceRegistry.shared` keyed by `SurfaceID`. The pane tree (`Sources/AppShell/PaneTabsView.swift`) renders the registered view inside an `NSTabView` per pane.

## Identity / authentication

- The Unix socket is `chmod 0600`, local-only.
- The HTTP server defaults to `127.0.0.1:18217`. Flipping `settings.remote_access_enabled=1` rebinds to `0.0.0.0` and turns on token auth.
- Pairing: `POST /v1/pair` mints a 6-digit code (10-min TTL). `POST /v1/pair/redeem {code, device_name}` returns `{device_id, token}`. Token hashes (SHA-256) are stored in `device_trust`; every non-loopback `/v1/*` request requires `Authorization: Bearer ...` or `X-RC2-Token`.
- Audit events are appended to the `audit_log` table.

## Persistence

`Sources/Persistence/Schema.swift` defines versioned schema steps through the current head. The migration matrix pins historical upgrades, including the reversible content store, the dormant tables of the removed Token Saver, cache-state columns, and permanent trusted-device fields. Schema migration is idempotent and each step is transactional.

Channels (`debug`, `canary`, `stable`) get their own app-support directory and Unix socket so the user can run them side by side without data contention.

Bootstrap sets the channel App Support directory to `0700` and the live SQLite
database, WAL, and SHM files to `0600`. Failure to apply those permissions is a
startup error; the app must not silently continue with credential-bearing state
readable by another local user.

### Remote mutation receipt retention

Durable remote mutation receipts are the at-most-once authority, not a replay
cache. Their retention rules are deliberately asymmetric:

- `claimed` rows are never pruned; bootstrap converts interrupted claims to the
  permanent `unknown` terminal state before command admission.
- `unknown` rows are permanent tombstones and must never permit re-execution.
- `committed` rows permanently retain the canonical result required by an exact
  retry. Retries never depend on retained event payloads.
- The `events` table retains the newest 5,000 replay payloads. Receipt
  finalization applies that cap in the same transaction as its event/outcome
  commit. `command_receipt_events` links are removed only after their event is
  pruned, so the newest links remain available for ambiguous-commit reread and
  post-commit fanout.

Consequently, `command_receipts` is a monotonic high-water set in the current
protocol. This is intentional: strict bounded storage is incompatible with
permanent at-most-once results for an unlimited request-ID namespace. Do not add
an age/count delete. A future bounded design requires a persisted receipt epoch,
atomic epoch retirement, and pre-effect rejection of every stale-epoch request
with snapshot reconciliation.

`GET /v1/health` exposes aggregate-only receipt counters and claim/finalization
latency high-water values. It must never expose request IDs, owner fingerprints,
parameter hashes, raw params, or results.

## Session restore

On launch:
1. `Bootstrap` opens the channel-scoped DB, runs schema migrations.
2. `AppContext` loads the latest `SessionSnapshot`.
3. `AppCommandRouter.reinstantiateRestoredSurfaces()` walks every workspace, builds fresh `Surface` instances for each descriptor, captures an `old_id → new_id` map and rewrites the layout so PaneTabsView finds the live surfaces.
4. `AgentRunCoordinator.reconcileOnLaunch()` flips any `running` rows back to `interrupted` — we never auto-resume a crashed run.

## Test layout

```
Tests/
├── CoreModelTests        — reducer + AssistantEvents + Phase-H actions
├── PersistenceTests      — bootstrap, schema idempotency, repositories,
│                           fixtures, filesystem-trace, device trust,
│                           reversible store
├── AgentRuntimeTests     — Codex parser, Claude parser, FakeRunner,
│                           GitDiff, provider install
├── SurfacesTests         — ANSIRenderer, MarkdownSurface renderer
└── SocketServerTests     — JSONRPCDispatcher, HTTP discovery, pairing
                            integration, EventBus, dispatcher coverage
```

Run tests with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (CommandLineTools alone is missing XCTest).

## Packaging

`scripts/package-app.sh` compiles in `release` (or whatever `RC2_CONFIG` you set) and assembles `dist/RemoteCode.app`:

```
dist/RemoteCode.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo
    └── MacOS/
        ├── RemoteCode
        ├── RemoteCodeDistillService
        └── rc2
```

`scripts/package-app.sh` is only for local bundle assembly. Release artifacts must use
`scripts/package-dmg.sh` and the GitHub release workflow. The DMG build fails unless a
`Developer ID Application` signing identity is available, and upload happens only after
notarization, stapling, and Gatekeeper verification pass.
