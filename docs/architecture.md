# RemoteCode 2 Architecture (current state)

A walk through what's actually built right now. Use this together with `report.html` (the human-facing changelog) and `project/14-reference-repos-distillation.md` (cmux + T3 Code reference notes).

## Module layout

```
Package.swift
├── CSystem            — forkpty/TIOCSWINSZ C shim
├── CoreModel          — pure-Swift domain (IDs, surfaces, split tree,
│                        layout reducer, AssistantEvents reducer,
│                        agent types, session snapshot)
├── Persistence        — direct sqlite3 wrapper, versioned schema (v2),
│                        repositories, fixture factory, EventLog,
│                        DeviceTrustRepository, NotificationRepository
├── AgentRuntime       — AgentProviderRunner protocol; Codex+Claude
│                        parsers, runners, FakeProviderRunner,
│                        AgentRunCoordinator, GitDiff helper
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
└── RC2CLI    (exe)    — rc2 binary, thin Unix-socket client
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

`Sources/Persistence/Schema.swift` defines two versioned schema steps. v1 sets up domain tables; v2 adds `device_trust`, `pairing_codes`, `audit_log`, `notifications`. Schema migration is idempotent.

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
│                           fixtures, filesystem-trace, device trust
├── AgentRuntimeTests     — Codex parser, Claude parser, FakeRunner,
│                           GitDiff
├── SurfacesTests         — ANSIRenderer, MarkdownSurface renderer
└── SocketServerTests     — JSONRPCDispatcher, HTTP discovery, pairing
                            integration, EventBus, dispatcher coverage
```

57 unit tests run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (CommandLineTools alone is missing XCTest).

## Packaging

`scripts/package-app.sh` compiles in `release` (or whatever `RC2_CONFIG` you set) and assembles `dist/RemoteCode2.app`:

```
dist/RemoteCode2.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo
    └── MacOS/
        ├── RemoteCode2
        └── rc2
```

Code signing and notarization require an Apple Developer ID and stay manual.
