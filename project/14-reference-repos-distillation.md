# 14 — Reference Repo Distillation (cmux + T3 Code)

Generated 2026-05-14. Both repos were cloned into `~/dev/remotecode2/.references/` (git-ignored). This file captures the patterns we will base RemoteCode 2 on — without copying code, and respecting each repo's license.

## Repositories

| Repo | URL | License | Role for RemoteCode 2 |
|------|-----|---------|------------------------|
| `manaflow-ai/cmux` | https://github.com/manaflow-ai/cmux | GPL-3.0-or-later **OR** commercial | Behavioral reference for the **shell**: window/workspace/pane/surface, terminal (libghostty), browser (WKWebView), socket/CLI automation, notifications, session restore. **Do not copy source** without a license decision. |
| `pingdotgg/t3code`  | https://github.com/pingdotgg/t3code  | MIT | Behavioral reference for the **Agent App surface**: sidebar, chat header, branch toolbar, chat composer, messages timeline, diff panel, terminal drawer, command palette. MIT is compatible if we attribute. |

## cmux highlights worth copying patterns from

### `Sources/Panels/Panel.swift`
- `PanelType { terminal, browser, markdown, filePreview, rightSidebarTool }`. RemoteCode 2's `SurfaceType` covers `terminal/browser/agentApp` for V1. `markdown` and `filePreview` are deferred and should be added as new `SurfaceType` cases when the time comes — not as siblings inside the Agent App.
- Focus intents are typed per panel: `TerminalPanelFocusIntent`, `BrowserPanelFocusIntent`, `FilePreviewPanelFocusIntent`. We need an analog `SurfaceFocusIntent` enum so the same Surface protocol can express "address bar vs find field vs webview" without leaking concrete classes.
- `WorkspaceAttentionFlashReason` and `WorkspaceAttentionFlashAccent` model the visual cue that an inactive surface produced new output. Map to a future `WorkspaceAttention` event.

### `Sources/Panels/PanelContentView.swift`
- Pattern is "type-dispatched root view" — exactly what `PaneTabsView` already does. Mirror their lifecycle handling for focus/blur/unread.

### `Sources/CLI/` and `Sources/CmuxSocketEventMapper.swift`
- cmux's socket emits an event stream alongside command responses. Our `events` table exists but is unused; cmux confirms it is required for parity. Plan: write JSON-RPC notifications on the unix socket when domain mutations happen, gated by an `events.subscribe` method.

### `Sources/AppDelegate*.swift`
- Their `AppDelegate` is split into many partial files (URL handling, equalize splits, recoverable routes, move tab to new workspace). Each file is one feature seam. Our `AppDelegate.swift` should follow the same convention as features grow.

### `BonsplitTabBar*.swift`
- cmux uses Bonsplit as the split engine. Ours is a hand-rolled `LayoutNode` reducer + `NSSplitView`. If we later need pixel-faithful tab bars, evaluate Bonsplit again under its license.

### `Sources/CmuxEventStream.swift`, `CmuxEventLogWriter.swift`
- Confirms the architectural pattern: domain events are written to a log, then fanned out to subscribers (UI, socket clients, future mobile). RC2-025 expects this.

## T3 Code highlights worth copying patterns from

### `apps/web/src/components/`
- `AppSidebarLayout.tsx` — projects, threads, status pills, settings footer.
- `ChatView.tsx` + `ChatView.logic.ts` — split between view and pure-logic test target. We should mirror this in Swift by keeping `AgentAppViewModel` pure-Swift (no AppKit/SwiftUI) and putting view code in `AgentAppView`. Today the VM already does this but the next pass should extract per-feature logic helpers like t3code does.
- `BranchToolbar.tsx`, `BranchToolbarBranchSelector.tsx`, `BranchToolbarEnvironmentSelector.tsx`, `BranchToolbarEnvModeSelector.tsx` — small composable controls for the bottom toolbar. We don't have these yet; add as Swift views in `Sources/AppShell/AgentAppToolbar.swift` later.
- `ChatComposer.tsx`, `ComposerPromptEditor.tsx`, `composerFooterLayout.ts` — the composer is split into editor + footer layout helper. Swift port: `AgentAppComposer.swift` + a pure `ComposerFooterLayout.swift` for unit tests.
- `CommandPalette.tsx`, `CommandPalette.logic.ts`, `CommandPaletteResults.tsx` — palette pure-logic in `.logic.ts`. Our `CommandPalette.swift` is fine but the search/filter could be extracted to a testable `CommandPaletteFilter` value type.
- `DiffPanel.tsx`, `DiffPanelShell.tsx`, `DiffWorkerPoolProvider.tsx` — diff rendering with a worker pool. Swift port: NSView host + a `DispatchQueue.concurrentPerform` chunk renderer; or `Process` running `git diff` and parsing.
- `KeybindingsToast.browser.tsx`, `KEYBINDINGS.md` — keybinding documentation. We should ship `docs/keybindings.md` mirroring T3 Code's defaults (⌘K palette, ⌘T new terminal, ⌘B toggle diff, etc.).
- `PlanSidebar.tsx`, `NoActiveThreadState.tsx`, `GitActionsControl.tsx` — additional Agent App regions we will need.

## Decisions reaffirmed

1. **License compliance**: any direct translation of code from either repo must include attribution and respect the source license. Default is "pattern reference only".
2. **cmux source reuse is still blocked** pending the RC2-001 license decision. Reading the source to learn structure is OK; copying lines into RemoteCode 2 is not.
3. **T3 Code is MIT**, so direct adaptation is allowed with attribution. Add a `THIRD_PARTY_NOTICES.md` when we ship our first translated chunk.

## Concrete follow-ups for the Swift implementation

| ID | Action |
|----|--------|
| F-1 | Add `markdown` and `filePreview` to `SurfaceType` (still defer their implementations) so the model is open to cmux parity later. |
| F-2 | Introduce `SurfaceFocusIntent` enum modeled on cmux's `PanelFocusIntent` cases. |
| F-3 | Add a `events.subscribe` JSON-RPC method that streams domain events over the unix socket; write to the `events` table whenever the dispatcher mutates state. |
| F-4 | Extract reusable Agent App regions: `AgentAppSidebar`, `AgentAppHeader`, `AgentAppComposer`, `AgentAppTimeline`, `BranchToolbar`. Mirror t3code's file split. |
| F-5 | Document default keyboard shortcuts in `docs/keybindings.md`, copied from `t3code/KEYBINDINGS.md` (MIT) with attribution. |
| F-6 | Add a `THIRD_PARTY_NOTICES.md` and credit T3 Code (MIT) for any UI patterns we directly adapt. |
| F-7 | Re-read `cmux/docs/cli-contract.md` and `cmux/Sources/CLI/cmux.swift` to align RemoteCode 2's JSON-RPC method names with cmux v2 — we already used cmux terminology, but a 1:1 audit is owed. |
