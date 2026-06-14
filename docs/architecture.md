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
│                        TokenSaverSavingsRepository, ReversibleContentStore
├── AgentRuntime       — AgentProviderRunner protocol; Codex+Claude
│                        parsers, runners, FakeProviderRunner,
│                        AgentRunCoordinator, GitDiff helper,
│                        managed Token Saver skill/CLI installer
├── DistillCore        — Token Saver runtime contracts, Distill HTTP server,
│                        deterministic routing, managed `distill` CLI,
│                        metrics/stats DTOs, retrieve protocol
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
└── RemoteCodeDistillService (exe) — localhost Token Saver sidecar for
                                     approved MLX model inference
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

## Token Saver / Distill

Token Saver is a paid-account local optimization path. `AppContext` starts
`RemoteCodeDistillService` only when the setting is enabled, the account is
eligible, and an approved MLX model manifest validates. The sidecar binds to
localhost with bearer auth and exposes:

- `POST /v1/distill` for prompt, command-output, watch-summary, and SR1-humanize requests.
- `GET /v1/retrieve/<handle>` for byte-exact original recovery from the reversible store.
- `GET /metrics` for request/cache/fallback counters.
- `GET /v1/stats` for measured Token Saver savings by provider and mode.

Provider-facing managed `/distill` instructions stay compact in
`AGENTS.md`/`CLAUDE.md`; detailed command examples live in the managed
`distill/SKILL.md`. The installed `distill` CLI reads sidecar state from
`DistillCLIState.json`, calls the sidecar directly, and reserves subcommands
such as `retrieve`, `stats`, `dsl`, `rank`, and `wrap`.

Lossy or truncating paths must be fail-open and store the original before loss.
Large originals are recoverable through `[[rc:<handle>]]`; final assistant
messages strip unresolved handles before persistence/display.

## Persistence

`Sources/Persistence/Schema.swift` defines versioned schema steps through the current head. The migration matrix pins historical upgrades, including the Token Saver savings ledger, reversible content store, cache-state columns, and permanent trusted-device fields. Schema migration is idempotent and each step is transactional.

Channels (`debug`, `canary`, `stable`) get their own app-support directory and Unix socket so the user can run them side by side without data contention.

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
│                           Token Saver savings, reversible store
├── AgentRuntimeTests     — Codex parser, Claude parser, FakeRunner,
│                           GitDiff, Token Saver managed install/compression
├── DistillCoreTests      — Distill service, managed CLI, routing,
│                           metrics, Token Saver compression contracts
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
