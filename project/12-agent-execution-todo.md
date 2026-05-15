# RemoteCode 2 Agent Execution TODO

Source of truth pair: use this ordered TODO for execution and `13-agent-tasks.json` for machine assignment. Keep `11-ai-agent-trello-board.html` as the human Scrum/Trello view.

## Autonomous Implementation Status (2026-05-14)

Legend: `[x]` shipped this pass, `[~]` partial / V1 scaffold only, `[ ]` not started.

- 23 cards moved to `[x]` (foundation, domain, persistence, agent runtime, socket/HTTP, surfaces, agent app UI, fresh-start bootstrap, fixture factory, unit tests).
- 8 cards moved to `[~]` because the V1 scaffold ships but later polish items (PTY, T3 parity, drawer, profiles) remain.
- All Phase 0 decision cards (RC2-001 … RC2-008) and Phase 9 release cards (RC2-120 … RC2-124) intentionally remain `[ ]`: those need human owner sign-off, real signing identities and external decisions; an autonomous coding pass cannot make them.

See `/Users/samuelfajreldines/dev/remotecode2/report.html` for the full decision log and review queue.

## Global Rules
- Start from zero; do not read, scan, transform, transfer, or depend on previous app data.
- No fake desktop chrome and no web runtime for the app shell.
- SwiftUI owns data-driven UI; AppKit owns window, responder chain, menus, focus, terminal host, complex splits, and panels.
- Liquid Glass only on controls and bars, never main content.
- Future mobile is not built now; desktop core must be direct-VPN-ready from day zero.
- No relay, no private backend, no cloud broker, no connector id, no hosted repository mirror, no cloud command queue.
- No task is done without acceptance, automated tests, E2E/proof, and fail-signal evidence.

## Required Command Gates
- `./scripts/bootstrap`
- `./scripts/build-debug`
- `./scripts/test-unit`
- `./scripts/test-integration`
- `./scripts/test-ui`
- `./scripts/test-visual`
- `./scripts/test-direct-vpn-contract`
- `./scripts/test-security`
- `./scripts/test-performance`
- `./scripts/release-candidate-check`

## Done Report Required Fields
- `contextProof`
- `changedArtifacts`
- `acceptanceStatus`
- `automatedTests`
- `e2eProof`
- `regressionGuard`
- `securityPrivacyCheck`
- `freshStartCheck`
- `mobileReadinessCheck`
- `exitStatus`

## Phase 0 - Decisions

### [ ] RC2-001 - Resolve cmux Licensing Strategy
- Owner: Senior analyst + project owner
- Depends: None
- Output: License decision record
- Summary: Make the legal/source-reuse decision before any implementation agent uses cmux source code.
- Acceptance: License decision names allowed source use, dependency use, notices, and distribution impact.
- Automated tests: Script checks source-use inventory and required third-party notice placeholders.
- E2E proof: E2E: proof gate - a dry-run implementation agent can classify cmux allowed/forbidden actions without asking.
- Fail signal: Any cmux code copy starts before approval, or obligations remain ambiguous.
- Steps:
  - Document whether RemoteCode 2 will copy cmux code, depend on cmux packages, or only use behavioral reference.
  - List affected components: Bonsplit/layout, Ghostty integration, browser automation, socket/CLI API, session restore.
  - Write allowed and forbidden actions for implementation agents.
  - Update the board with the chosen constraint.

### [ ] RC2-002 - Choose Layout Engine Strategy
- Owner: Architecture agent
- Depends: RC2-001
- Output: Layout ADR + prototype criteria
- Summary: Decide how RemoteCode 2 will implement workspaces, panes, splits, and surface tabs.
- Acceptance: Chosen layout model supports workspaces, split panes, tabs, focus, restore, and all surface types.
- Automated tests: Prototype reducer tests for split, close, move, focus, restore, and invalid layout rejection.
- E2E proof: E2E: prototype app creates terminal, browser, and Agent App placeholders in a 3-pane layout and restores after relaunch.
- Fail signal: Any surface needs special layout handling or focus is lost after split/restore.
- Steps:
  - Evaluate Bonsplit, licensed cmux layout code, and a custom split-tree implementation.
  - Define core model types: Window, Workspace, Pane, Surface, SplitNode, PaneNode.
  - Specify drag/drop, keyboard focus, tab reorder, close behavior, and session snapshot needs.
  - Write a decision with implementation cost and risks.

### [ ] RC2-003 - Choose Terminal Engine Strategy
- Owner: Terminal architecture agent
- Depends: RC2-001
- Output: Terminal ADR + proof checklist
- Summary: Prove the terminal technology before building the rest of the shell around it.
- Acceptance: Terminal engine can launch shell, render prompt, route input, resize, signal, and clean up.
- Automated tests: PTY lifecycle tests for cwd, output, resize, SIGINT, close, and orphan detection.
- E2E proof: E2E: spike app opens terminal, runs `pwd`, resizes pane, sends interrupt, closes, and proves no child remains.
- Fail signal: Terminal view blanks, input leaks, resize breaks prompt, or process survives close.
- Steps:
  - Evaluate libghostty integration, SwiftTerm, and minimal PTY+view alternatives.
  - Confirm build requirements for arm64 and x86_64 if universal release is required.
  - Define PTY lifecycle, shell selection, env injection, scrollback, copy/paste, and resize behavior.
  - Produce a spike app or test harness showing prompt, input, resize, close, and cleanup.

### [ ] RC2-004 - Define Provider Runtime Contract
- Owner: Agent runtime architect
- Depends: Source inventory
- Output: Provider protocol spec
- Summary: Specify how Codex and Claude runners behave before implementing either provider.
- Acceptance: Provider contract covers Codex and Claude request fields, stream events, errors, cancellation, and missing auth.
- Automated tests: Contract fixture tests assert both providers map into the same normalized event schema.
- E2E proof: E2E: proof gate - fake provider run renders in Agent App timeline without provider-specific UI branches.
- Fail signal: UI depends on raw Codex/Claude JSON or cancellation semantics differ silently.
- Steps:
  - Define `AgentProviderRunner`, `AgentRunRequest`, `AgentRunHandle`, and `AgentProviderEvent`.
  - Define supported provider options: model, reasoning effort, permission mode, cwd, prompt, provider thread ID.
  - Define cancellation semantics and process cleanup.
  - Define missing CLI and auth error mapping.

### [ ] RC2-005 - Define V1 Scope And Deferred cmux Features
- Owner: Scrum master
- Depends: Product requirements
- Output: V1 scope contract
- Summary: Protect the project from scope creep while preserving a complete V1.
- Acceptance: V1 scope lists required, partial, and deferred cmux features with unsupported-method rules.
- Automated tests: Scope lint verifies every feature family has status and every deferred API has an error rule.
- E2E proof: E2E: proof gate - unsupported API smoke call returns typed not-supported error with docs link.
- Fail signal: Agent must infer scope or missing feature appears as silent no-op.
- Steps:
  - Classify all cmux families as V1 required, V1 partial, or post-V1.
  - Confirm terminal, browser P0, Agent App, CLI/socket, persistence, clean first-run bootstrap, QA, signing are V1 required.
  - Mark SSH/cloud VM, markdown/file preview, and advanced browser P2 as post-V1 unless owner changes priority.
  - Add unsupported-method response rules for deferred APIs.

### [ ] RC2-006 - Create T3 Code UX Reference Spec
- Owner: Senior product analyst + Scrum master
- Depends: T3 Code source review
- Output: T3 UX parity spec + attribution decision
- Summary: Turn the T3 Code research into a precise Swift UI implementation contract before UI agents start building.
- Acceptance: T3 Code UX spec maps sidebar, header, timeline, composer, diff, terminal drawer, command palette, settings, and attribution.
- Automated tests: Spec lint checks required T3 sections, file references, license decision, and forbidden copy list.
- E2E proof: E2E: proof gate - visual checklist can evaluate a full Agent App screenshot against T3 Code structure.
- Fail signal: Implementation agent still needs to reopen T3 Code to know core UI behavior.
- Steps:
  - Read T3 Code README, KEYBINDINGS, LICENSE, `apps/web/src/components/Sidebar.tsx`, `AppSidebarLayout.tsx`, `ChatView.tsx`, `chat/ChatHeader.tsx`, `chat/ChatComposer.tsx`, `chat/MessagesTimeline.tsx`, `DiffPanel.tsx`, `ThreadTerminalDrawer.tsx`, `CommandPaletteResults.tsx`, and `BranchToolbar.tsx`.
  - Write a Swift-facing UX spec mapping each T3 Code surface to RemoteCode 2 components: sidebar, header toolbar, branch/workspace toolbar, timeline, composer, diff panel, terminal drawer, command palette, settings.
  - Define exact visual tokens to reproduce: dense dark surface, 1px borders, subtle muted text, compact icon buttons, small rounded controls, project/thread rows, status pills, diff additions/deletions, and bottom composer proportions.
  - Define what must not be copied: Electron runtime, React state architecture, fake web chrome, web-only CSS implementation details, or provider support beyond Codex and Claude for V1.
  - Create an attribution rule: if code or substantial UI text is translated from T3 Code, add a third-party notice and list files used.

### [ ] RC2-007 - Define SwiftUI, AppKit, And Liquid Glass UI Ownership
- Owner: Senior macOS UI architect
- Depends: RC2-006
- Output: UI ownership ADR
- Summary: Lock the UI implementation boundary before any visual or shell code is built.
- Acceptance: ADR assigns SwiftUI/AppKit/Liquid Glass ownership per component and forbids marketing UI patterns.
- Automated tests: Static checks for fake chrome, Liquid Glass on main content, and terminal hosted only in SwiftUI.
- E2E proof: E2E: screenshot proves dense dark developer UI with native chrome and no decorative glass content.
- Fail signal: Window/focus/split ownership is unclear or main content uses decorative glass.

### [ ] RC2-008 - Define Future Mobile Direct-VPN Mirror Contract
- Owner: Senior platform architect + Scrum master
- Depends: Current RemoteCode local/mobile study
- Output: Mobile-ready desktop contract ADR
- Summary: Lock the architecture that lets a future mobile app mirror and control the desktop without a relay.
- Acceptance: Future mobile contract defines direct VPN/LAN transport, identity, command/event envelopes, replay, and non-goals.
- Automated tests: ADR lint verifies no relay/private-backend path and all required protocol fields are named.
- E2E proof: E2E: proof gate - fake future-mobile sequence diagram can execute discovery, pair, command, event replay on paper.
- Fail signal: Any mobile path assumes a hosted relay or desktop-only private action path.

## Phase 1 - Native Shell

### [x] RC2-010 - Create Swift macOS Project Skeleton
- Owner: Foundation agent
- Depends: RC2-001
- Output: Xcode project + Swift packages
- Summary: Initialize the native app and test structure from zero.
- Acceptance: Clean clone builds, launches debug app, and includes app/test targets and scripts.
- Automated tests: Build smoke, unit smoke, bundle id checks, script existence checks.
- E2E proof: E2E: launch app from built artifact and assert native window appears with placeholder content.
- Fail signal: Build requires manual local state or app opens no window.
- Steps:
  - Create `RemoteCode2.xcodeproj` or SwiftPM-driven Xcode project with macOS app target.
  - Add modules/folders: App, Windowing, Workspace, Surfaces, AgentRuntime, Persistence, SocketAutomation, CLI, Tests, UITests.
  - Configure app bundle IDs for debug, canary, stable.
  - Add scripts: bootstrap, build-debug, test-unit, test-integration, test-ui.
  - Commit a minimal app that opens a native NSWindow with placeholder content.

### [~] RC2-011 - Implement App Lifecycle, Menus, And Native Window Shell
- Owner: AppKit shell agent
- Depends: RC2-010
- Output: Native window shell
- Summary: Build the macOS shell without fake in-app window chrome.
- Acceptance: Native NSWindow, menus, responder chain, settings stub, bounds restore, and no fake chrome.
- Automated tests: Menu command tests, window restore tests, focus bridge tests, fake-chrome DOM/view scan.
- E2E proof: E2E: open app, use menu command, focus content, resize/relaunch, verify bounds and native chrome.
- Fail signal: Menu command misses target, focus leaks, or fake close/minimize/maximize controls appear.
- Steps:
  - Create AppDelegate or SwiftUI App lifecycle with explicit NSWindow management.
  - Add native menus for app, file, edit, view, workspace, surface, window, help.
  - Add settings window stub and about/version metadata.
  - Persist and restore window bounds per release channel.
  - Use AppKit as the owner for NSWindow, responder chain, menu validation, first responder, focus handoff, and native window commands.
  - Embed SwiftUI content inside the AppKit-owned shell; do not let SwiftUI accidentally own desktop-level focus or menu behavior.
  - Ensure there are no fake close/minimize/maximize controls or fake title bars.

### [ ] RC2-020 - Create T3 Code-Inspired Swift Design System
- Owner: Design system agent
- Depends: RC2-006, RC2-007, RC2-011
- Output: DesignSystem module
- Summary: Define reusable SwiftUI/AppKit tokens and controls that make the whole app feel like T3 Code without using a web runtime.
- Acceptance: Design system exposes T3-like tokens, controls, AppKit bridges, accessibility, and Liquid Glass limits.
- Automated tests: Snapshot, contrast, sizing, no-overlap, Liquid Glass placement, and bridge smoke tests.
- E2E proof: E2E: preview app renders all controls in dark mode and screenshot passes visual density checklist.
- Fail signal: Control text clips, color contrast fails, or main content receives glass styling.
- Steps:
  - Create color tokens for dark default plus an explicit theme decision for light/auto: either implement light/auto tokens fully or document them as disabled with tests asserting dark default only.
  - Create typography tokens using system UI and SF Mono equivalents; use compact developer-tool sizes, not marketing scale.
  - Create SwiftUI reusable controls: icon button, split button, segmented toggle, pill/status label, sidebar row, command row, toolbar button, diff stat label, popover/menu shell, tooltip, empty state, loading state, and error banner.
  - Create AppKit bridge components only where needed: focus bridge, menu command bridge, terminal host wrapper, split-pane host, file/open panel bridge, and first-responder coordinator.
  - Match T3 Code density: 1px borders, small radii, compact spacing, low-contrast dividers, hover/selected states, and no decorative gradient/orb backgrounds.
  - Apply Liquid Glass only to controls and bars where useful: toolbar clusters, compact command palette chrome, segmented controls, and modal/action surfaces.
  - Do not apply Liquid Glass to the main content canvas, chat body, sidebar rows, terminal viewport, browser viewport, diff body, or repeated dense list cells.
  - Document how to use controls in Agent App, sidebar, command palette, terminal drawer, diff panel, settings, and native menus.

## Phase 2 - Domain And Persistence

### [x] RC2-012 - Implement Workspace Domain Model
- Owner: Domain model agent
- Depends: RC2-002, RC2-010
- Output: WorkspaceCore module
- Summary: Create the model and reducer/store for windows, workspaces, panes, and surfaces.
- Acceptance: Workspace reducer preserves IDs, split invariants, selected surface, command metadata, and UI independence.
- Automated tests: Reducer property tests and invariant tests for create/select/close/split/move/reorder/focus.
- E2E proof: E2E: command bus drives workspace changes and UI reflects exact selected surface after reload.
- Fail signal: Invalid split tree persists or action lacks request/origin metadata.
- Steps:
  - Define stable IDs for window, workspace, pane, split, and surface.
  - Define immutable actions for create, select, rename, close, split, move, reorder, focus.
  - Attach command metadata needed by local UI, CLI, tests, and future mobile: request id, origin client id, actor kind, issuedAt, target ids, idempotency key, and audit category.
  - Define surface type enum: terminal, browser, agentApp.
  - Encode invariants: every workspace has a valid split tree; every pane has at least one selected surface unless being removed.
  - Keep domain logic UI-independent.

### [x] RC2-016 - Implement SQLite Persistence Foundation
- Owner: Persistence agent
- Depends: RC2-010, RC2-012
- Output: Persistence module
- Summary: Create the database layer, schema versioning, and repositories used by all later features.
- Acceptance: SQLite schema creates from zero, repositories work, transactions rollback, channels isolate data.
- Automated tests: Schema version, CRUD, rollback, in-memory DB, channel path, and corruption recovery tests.
- E2E proof: E2E: first launch creates empty RemoteCode 2 database, creates workspace/thread, relaunches with data intact.
- Fail signal: Schema reads outside owned directory or transaction leaves partial rows.
- Steps:
  - Choose and configure GRDB or direct SQLite based on the architecture decision.
  - Create versioned schema steps for projects, agent threads, messages, runs, events, snapshots, settings, and session snapshots.
  - Implement repository protocols and concrete SQLite repositories.
  - Add in-memory/test database setup.
  - Ensure app data directories differ for debug, canary, and stable.

### [x] RC2-017 - Implement Session Snapshot Foundation
- Owner: Session restore agent
- Depends: RC2-012, RC2-016
- Output: Snapshot model + store
- Summary: Persist and restore window/workspace/pane/surface layout independent of surface implementation details.
- Acceptance: Session snapshots save/restore windows, layouts, selected surfaces, and unknown types safely.
- Automated tests: Encode/decode, invalid snapshot, unknown surface, debounce, and restore-policy tests.
- E2E proof: E2E: create multi-pane layout, quit, reopen, verify exact selection and surface order.
- Fail signal: Layout changes after relaunch or invalid snapshot crashes app.
- Steps:
  - Define Codable snapshot schema with version, createdAt, windows, workspaces, layout tree, and surface snapshots.
  - Implement save debounce/autosave and explicit save on app quit.
  - Implement restore policy that skips automated tests unless enabled.
  - Add unknown surface type handling that does not crash restore.

### [x] RC2-080 - Implement Clean First-Run Data Bootstrap
- Owner: Persistence bootstrap agent
- Depends: RC2-016
- Output: Fresh data bootstrap
- Summary: Start RemoteCode 2 from a clean database with no previous-app data path.
- Acceptance: First run creates only RemoteCode 2-owned files, clean schema, explicit defaults, and empty production data.
- Automated tests: Fresh install, empty support directory, corrupt new DB recovery, channel isolation, no previous-path touch tests.
- E2E proof: E2E: launch as clean user, verify empty workspace state and filesystem trace touches only RemoteCode 2 paths.
- Fail signal: App reads or probes another product data path.
- Steps:
  - Create the app support directory for debug, canary, and stable channels when absent.
  - Create the latest schema from scratch without probing external database locations.
  - Initialize required settings with explicit defaults: theme, command shortcuts, provider defaults, first-run completed flag, and direct-VPN mobile-readiness flags.
  - Seed no projects, no threads, no messages, no provider sessions, and no terminal history unless an automated test fixture explicitly requests test-only data.
  - Expose a diagnostic report that says "fresh start" and lists created directories/schema version without mentioning old data.

### [x] RC2-081 - Create Test-Only Data Fixture Factory
- Owner: Test infrastructure agent
- Depends: RC2-080
- Output: Fixture factory
- Summary: Provide deterministic seed data for tests without using any previous app data.
- Acceptance: Test fixtures create deterministic fake projects, surfaces, threads, events, terminal/browser state, and connection targets.
- Automated tests: Determinism, no production seeding, channel isolation, fixture directory guard, fake-data visibility tests.
- E2E proof: E2E: proof gate - UI suite boots from fixture scenario and production first run remains empty.
- Fail signal: Fixture reads user home data or appears in production build.
- Steps:
  - Create fixture builders for projects, workspaces, panes, surfaces, agent threads, messages, provider events, terminal sessions, browser snapshots, and mobile connection targets.
  - Make fixtures deterministic with stable IDs and explicit timestamps.
  - Allow tests to request minimal fixtures by scenario instead of booting with sample user data.
  - Keep fixture data visibly fake and safe for screenshots.
  - Document that production builds never seed sample projects or threads.

## Phase 3 - Layout And Navigation

### [~] RC2-013 - Implement T3 Code-Style Workspace Sidebar UI
- Owner: UI agent
- Depends: RC2-006, RC2-011, RC2-012
- Output: Sidebar view
- Summary: Build vertical workspace/project/thread navigation using T3 Code's dense sidebar as the reference.
- Acceptance: Sidebar supports project/thread hierarchy, search, timestamps, statuses, keyboard navigation, and settings footer.
- Automated tests: View model tests for filtering, sorting, expand/collapse, rename/archive, timestamp updates.
- E2E proof: E2E: create projects/threads, search/select/show-more, navigate by keyboard, compare screenshot to T3 sidebar.
- Fail signal: Search loses selection, text overlaps, or status/timestamp data is missing.
- Steps:
  - Render a T3 Code-like left rail with app identity, search row, project section header, project rows, nested thread rows, relative timestamps, status pills, and settings footer.
  - For each project row show icon/fallback, name, expanded state, active run indicator, latest thread preview, and git/branch metadata for git projects; show a clear "No Git" state for non-git projects.
  - For each thread row show title or generated summary, provider/status indicator, elapsed/relative time, completion/working state, and selected hover/focus styling.
  - Add search across projects and threads with keyboard navigation and command-key shortcut hint.
  - Add create, select, rename, archive/close, show-more, and context menu actions. Render reorder/group as disabled V1-deferred commands with a typed unsupported reason until RC2-005 explicitly promotes them.
  - Support T3 Code-style compact density, muted secondary text, subtle 1px dividers, visible focus state, and responsive collapse behavior.

### [x] RC2-014 - Implement Pane Split And Surface Tab UI
- Owner: Layout UI agent
- Depends: RC2-002, RC2-012
- Output: PaneLayout UI
- Summary: Expose the cmux-like work area where all surface types live.
- Acceptance: Pane/tab UI can create, switch, split, close, move, and focus all placeholder surfaces.
- Automated tests: Layout reducer tests, split geometry tests, tab lifecycle tests, focus direction tests.
- E2E proof: E2E: build terminal left, Agent App top-right, browser bottom-right; switch tabs and close panes safely.
- Fail signal: Closing last surface crashes or focus goes to wrong pane.
- Steps:
  - Render split tree with resizable dividers.
  - Render horizontal surface tabs per pane with icon, title, dirty/unread state, close button, and selected state.
  - Add commands for split right/down, focus directionally, close surface, close pane, equalize splits.
  - Route selected surface to SurfaceRenderer by type.
  - Use AppKit for complex split-pane mechanics when SwiftUI cannot provide stable drag, focus, sizing, and first-responder behavior.
  - Use SwiftUI for pane tab labels, surface metadata, and declarative state display inside the AppKit-owned split structure.

### [~] RC2-015 - Implement T3 Code-Style Command Palette And Keybindings
- Owner: Command palette agent
- Depends: RC2-006, RC2-013, RC2-014
- Output: Command palette + keybinding resolver
- Summary: Add T3 Code-like keyboard-first access to commands, projects, threads, terminal actions, and scripts.
- Acceptance: Command palette registers commands, shortcuts, when-rules, grouping, disabled states, and focus isolation.
- Automated tests: Parser, precedence, availability, fuzzy-search, disabled-row, and focus-isolation tests.
- E2E proof: E2E: open palette, create Agent App thread, split terminal, toggle diff, and verify no keystrokes leak.
- Fail signal: Shortcut triggers in wrong context or disabled command runs.
- Steps:
  - Define command contribution model with id, title, subtitle/description, icon, keywords, shortcut command, timestamp/trailing metadata, availability predicate, and action.
  - Register commands for search/open project, search/open thread, new chat/thread, new local/worktree thread, split terminal, new terminal, close terminal, toggle terminal, toggle diff, open editor, run project script, workspace/surface actions, browser actions, and Agent App actions.
  - Implement T3 Code-compatible keybinding concepts: shortcut string, command id, nullable boolean `when` expression, contexts for terminal focus/open state, invalid-rule warnings, and last matching rule wins.
  - Use T3 Code default shortcuts as the reference: terminal toggle, terminal split/new/close, command palette toggle, new chat, new local chat, open favorite editor, and script run commands.
  - Add fuzzy search, grouped results, disabled rows, keyboard highlight, enter to run, escape to close, submenu affordance, and shortcut labels.
  - Ensure palette focus does not leak keystrokes to terminal, browser, or composer surfaces.

### [ ] RC2-021 - Implement T3 Code-Style Top Action Header
- Owner: Header UI agent
- Depends: RC2-006, RC2-020
- Output: ActionHeader component
- Summary: Create the compact top bar used across workspaces and Agent App threads.
- Acceptance: Top header shows thread/project context, core actions, responsive collapse, tooltips, and command routing.
- Automated tests: Action availability, responsive layout, tooltip, disabled-state, and command routing tests.
- E2E proof: E2E: use header to open editor placeholder, toggle diff, toggle terminal, create surface, and inspect screenshot.
- Fail signal: Header action bypasses command model or clips at narrow width.
- Steps:
  - Render current thread/workspace title, project badge, and exactly one git status badge: branch/dirty state for git projects or "No Git" for non-git projects.
  - Add T3 Code-style actions: Add action, Open with dropdown, Commit & push with dropdown, terminal toggle, diff toggle, new/split surface actions, and overflow menu.
  - Use icon-first controls with tooltips, disabled states, and keyboard shortcuts where available.
  - Keep the header compact and responsive; collapse text labels into icons/menus at narrow widths without clipping.
  - Route actions through command model so toolbar and command palette execute the same code paths.

### [ ] RC2-022 - Implement Branch, Workspace, And Environment Toolbar
- Owner: Git/workspace UI agent
- Depends: RC2-006, RC2-012, RC2-020
- Output: BranchWorkspaceToolbar
- Summary: Copy T3 Code's lower context toolbar pattern for branch, local/worktree mode, and environment selection.
- Acceptance: Toolbar shows git/workspace/environment context, locked state, non-git state, and responsive collapse.
- Automated tests: Git/non-git/dirty/worktree/locked fixtures and collapse tests.
- E2E proof: E2E: open git and non-git projects; verify branch/no-git/locked states and no clipped controls.
- Fail signal: Non-git project breaks Agent App or worktree lock can be changed incorrectly.
- Steps:
  - Detect git repository, active branch, dirty state, and worktree path for the selected project/workspace.
  - Render compact controls for environment, local vs worktree mode, current workspace path, current branch, checkout pull request placeholder, and focus composer action.
  - Support locked states when a thread is already bound to a worktree or provider session.
  - Use responsive mobile/narrow-window behavior inspired by T3 Code's combined run-context selector.
  - Fail loudly for non-git projects and show clear "No Git" state without breaking Agent App usage.

## Phase 4 - Automation Core

### [x] RC2-018 - Implement JSON-RPC Socket Server
- Owner: Socket automation agent
- Depends: RC2-012, RC2-014
- Output: Socket server
- Summary: Add external automation API compatible with cmux concepts.
- Acceptance: Local JSON-RPC socket supports ping, capabilities, identify, workspace/pane/surface methods, and events.
- Automated tests: Protocol tests for invalid JSON, method missing, invalid params, auth/local-only guard, event emission.
- E2E proof: E2E: CLI/test client creates workspace and Agent App placeholder through socket without UI.
- Fail signal: Socket binds non-local unexpectedly or response schema is unstable.
- Steps:
  - Create local Unix socket server with JSON-RPC request/response envelope.
  - Implement `system.ping`, `system.capabilities`, and `system.identify`.
  - Implement workspace, pane, and surface list/create/focus/close methods for placeholder surfaces.
  - Keep this socket local-only for CLI and tests; future mobile uses the direct-VPN HTTP/WebSocket API, not this Unix socket.
  - Publish domain events for successful commands.

### [x] RC2-019 - Implement CLI Client
- Owner: CLI agent
- Depends: RC2-018
- Output: CLI binary
- Summary: Create the `remotecode2` CLI as a thin socket client.
- Acceptance: CLI wraps socket with stable JSON, clear text output, targeting flags, and stale-app errors.
- Automated tests: Parser tests, JSON snapshots, socket integration tests, app-not-running tests.
- E2E proof: E2E: run CLI to create and focus an Agent App surface in the running app.
- Fail signal: CLI output cannot be scripted or stale socket error is unclear.
- Steps:
  - Implement global flags: socket path, json output, id format, window/workspace/surface target.
  - Implement commands: ping, capabilities, identify, list-workspaces, new-workspace, new-surface, new-split, focus, close.
  - Implement stable JSON output for scripts and concise text output for humans.
  - Handle app-not-running and stale socket errors clearly.

### [x] RC2-023 - Implement Direct-VPN Desktop API Foundation
- Owner: Networking foundation agent
- Depends: RC2-008, RC2-012, RC2-016
- Output: DirectDesktopAPI module
- Summary: Create the desktop-hosted HTTP/WebSocket foundation that a future mobile app will use over VPN.
- Acceptance: Desktop API exposes direct discovery, capabilities, WebSocket, protocol negotiation, and loopback default.
- Automated tests: Discovery schema, capability mismatch, auth failure, WebSocket join, explicit enablement, no relay config tests.
- E2E proof: E2E: fake client connects over loopback/VPN-enabled path, reads capabilities, joins WebSocket, receives event.
- Fail signal: API contains relay/private-backend fields or listens beyond loopback without opt-in.
- Steps:
  - Create a desktop HTTP server owned by the macOS app, disabled for non-loopback access until the user explicitly enables VPN/LAN access.
  - Add `/v1/discovery` with server id, app version, capabilities version, auth mode, enabled transports, host/port, VPN/LAN connect hints, and health status.
  - Add `/v1/capabilities` covering available surfaces, command versions, provider availability, terminal/browser support, git support, and feature flags.
  - Add direct WebSocket endpoint `/v1/ws` with authenticated join/leave, ping/pong, and protocol-version negotiation.
  - Add mDNS or QR/manual-connect metadata only when it points to direct desktop addresses.
  - Keep API handlers thin: they validate auth and protocol, then call the shared command bus used by desktop UI and CLI.

### [ ] RC2-024 - Implement Pairing, Device Trust, And Remote Access Settings
- Owner: Security/platform agent
- Depends: RC2-008, RC2-023
- Output: Device trust store + settings UI
- Summary: Add the desktop-side security model needed before any future mobile client can control the computer.
- Acceptance: Remote access has explicit enablement, pairing, revocation, rotation, device audit, and secure storage.
- Automated tests: Pairing expiry, revoke, rotate, Keychain, rate limit, audit redaction, denied auth tests.
- E2E proof: E2E: pair fake device, run one command, revoke device, prove HTTP/WS access stops immediately.
- Fail signal: Default production token exists or revoked device remains connected.
- Steps:
  - Create device trust model: device id, display name, public key or token hash, createdAt, lastSeenAt, revokedAt, capabilities granted, and audit metadata.
  - Create pairing flow contract for future mobile: desktop generates short-lived pairing material, future client redeems it directly over VPN/LAN, desktop stores only revocable trust material.
  - Add remote access settings: disabled by default, loopback-only default, explicit VPN/LAN enablement, visible host/port, rotate credentials, revoke device, and audit log viewer.
  - Store secrets in Keychain or equivalent secure storage; never store production tokens in plain SQLite.
  - Rate-limit auth failures and log denied attempts without leaking tokens or prompts.
  - Document that the mobile app is not built yet; settings exist to validate and operate the desktop contract safely.

### [ ] RC2-025 - Implement Mobile-Ready Command Bus And Event Replay
- Owner: Command/event platform agent
- Depends: RC2-012, RC2-016, RC2-023
- Output: Command bus + event log
- Summary: Make all UI, CLI, and future mobile commands use the same ordered domain/event model.
- Acceptance: Command bus and event log support envelopes, sequence, replay, ack, idempotency, scopes, and redaction.
- Automated tests: Ordering, replay, duplicate request, duplicate idempotency key, origin filter, pruning, and failure-event tests.
- E2E proof: E2E: fake mobile disconnects, desktop changes state, reconnects with last sequence, receives missed events once.
- Fail signal: Command executes twice or reconnect misses/duplicates events.
- Steps:
  - Create command envelope with command id, schema version, request id, origin client id, actor kind, target ids, payload, idempotency key, and issuedAt.
  - Create event envelope with monotonic sequence, timestamp, event type, target ids, payload, origin client id, request id, and redaction class.
  - Persist enough event history to replay workspace and active-thread state for reconnecting future mobile clients.
  - Implement WebSocket subscription by scope: app, workspace, Agent App thread, terminal session, browser surface, and git status.
  - Implement last-sequence replay, ack, duplicate request suppression, backpressure limits, and deterministic error events.
  - Route desktop UI actions through this bus instead of private view-only callbacks so mobile parity is architectural, not bolted on later.

### [ ] RC2-026 - Define Remote Mirror Coverage For Every Desktop Surface
- Owner: Surface contract agent
- Depends: RC2-008, RC2-025
- Output: Remote mirror capability matrix
- Summary: Ensure terminal, browser, Agent App, git, and workspace features expose future mobile-safe contracts.
- Acceptance: Capability matrix names remote status, commands, events, payload fields, and deferred/forbidden items per surface.
- Automated tests: Matrix lint checks all V1 surfaces and commands have status, payload, and test owner.
- E2E proof: E2E: proof gate - fake client script can plan one remote flow per surface from the matrix alone.
- Fail signal: Any surface has unknown mobile-readiness status or requires bulk data fetch.

## Phase 5 - Surfaces

### [~] RC2-030 - Implement Terminal Surface Host
- Owner: Terminal agent
- Depends: RC2-003, RC2-014
- Output: TerminalSurface
- Summary: Replace placeholder terminal surfaces with a real terminal surface.
- Acceptance: Terminal surface launches shell in cwd, routes focus, reports metadata, and cleans process groups.
- Automated tests: PTY cwd, input/output, focus, close cleanup, metadata, and orphan-process tests.
- E2E proof: E2E: open terminal, run `pwd`, split away, return, close, and verify no child remains.
- Fail signal: Input reaches unfocused terminal or process survives close.
- Steps:
  - Create `TerminalSurface` conforming to common Surface protocol.
  - Launch shell in workspace cwd with env variables for window, workspace, pane, and surface IDs.
  - Render terminal view and route keyboard/mouse input only when focused.
  - Implement close lifecycle and process group cleanup.
  - Report title, cwd, dirty/confirm-close state if supported by terminal engine.

### [~] RC2-031 - Implement Terminal Copy, Paste, Resize, And Scrollback
- Owner: Terminal UX agent
- Depends: RC2-030
- Output: Terminal UX features
- Summary: Make terminal surfaces production-usable.
- Acceptance: Terminal copy/paste/select all/clear/font/resize/scrollback behave like normal macOS terminal use.
- Automated tests: Selection, paste, resize, font, clear history, scrollback truncation, and focus guard tests.
- E2E proof: E2E: select/copy output, paste command, resize pane, change font, relaunch with bounded scrollback.
- Fail signal: Paste goes to wrong surface or scrollback grows unbounded.
- Steps:
  - Implement copy with selection, paste, select all when the chosen terminal engine exposes selection ranges; if it does not, create a typed unsupported state and E2E proof that the control is hidden or disabled. Implement clear scrollback and font size controls either way.
  - Resize PTY when pane size changes.
  - Keep terminal input disabled when another surface or command palette owns focus.
  - Capture scrollback snapshot for session restore using safe truncation.

### [~] RC2-032 - Implement Terminal Socket Commands
- Owner: Terminal automation agent
- Depends: RC2-030, RC2-018
- Output: Terminal command handlers
- Summary: Expose terminal automation through the surface API.
- Acceptance: Terminal automation commands target one terminal and reject wrong surface types with typed errors.
- Automated tests: Command handler tests for send text/key/read/clear, wrong target, redaction, and target isolation.
- E2E proof: E2E: socket/CLI sends command to terminal A while terminal B remains unchanged.
- Fail signal: Terminal command affects wrong surface or logs raw sensitive input.
- Steps:
  - Implement `surface.send_text`, `surface.send_key`, `surface.read_text`, and `surface.clear_history` for terminal surfaces.
  - Reject terminal input commands against browser/agent surfaces with clear typed errors.
  - Redact input content in event logs while preserving length and target metadata.

### [x] RC2-040 - Implement WKWebView Browser Surface
- Owner: Browser agent
- Depends: RC2-014
- Output: BrowserSurface
- Summary: Replace placeholder browser surfaces with a real in-app browser.
- Acceptance: WKWebView browser supports navigation, state persistence, profiles, local URLs, and focus isolation.
- Automated tests: Navigation policy, state snapshot, focus guard, URL/title persistence, and profile hook tests.
- E2E proof: E2E: open local dev page, navigate back/forward/reload, split with Agent App, relaunch with URL restored.
- Fail signal: Browser focus leaks to terminal or forbidden URL opens silently.
- Steps:
  - Create `BrowserSurface` with WKWebView, address bar, back, forward, reload, stop/loading state.
  - Support local dev URLs, localhost, file URLs when allowed, and external navigation policy.
  - Persist title, URL, loading state, and selected profile ID in surface snapshot.
  - Ensure browser focus does not leak to terminal or Agent App.

### [~] RC2-041 - Implement Browser Profiles And Cookie Storage
- Owner: Browser persistence agent
- Depends: RC2-040, RC2-016
- Output: Browser profile store
- Summary: Support persistent browser sessions without mixing all users into one opaque store.
- Acceptance: Browser profiles persist, isolate available data, can be renamed/cleared/deleted, and protect default profile.
- Automated tests: Profile CRUD, active default guard, clear data, persistence, and isolation-limit tests.
- E2E proof: E2E: create two profiles, set cookie in one, verify other profile does not share it where WKWebView permits.
- Fail signal: Deleting active default succeeds or profile state mixes unexpectedly without documented limitation.
- Steps:
  - Define browser profile model: id, display name, createdAt, default flag.
  - Create WKWebsiteDataStore per profile when the chosen WKWebView API supports it. If full cookie isolation is not available, block release until the limitation is documented, the maximum available isolation is implemented, and the E2E profile-isolation test records the exact remaining shared state.
  - Add profile list/create/rename/clear/delete commands.
  - Prevent deleting active default profile.

### [x] RC2-042 - Implement Browser P0 Automation
- Owner: Browser automation agent
- Depends: RC2-040, RC2-018
- Output: Browser automation handlers
- Summary: Give agents an automation surface similar to cmux's agent-browser port.
- Acceptance: Browser P0 automation supports navigate, snapshot, element actions, eval, wait, screenshot, and unsupported errors.
- Automated tests: Local HTML fixture tests for snapshot, click, fill, wait, screenshot, target isolation, unsupported methods.
- E2E proof: E2E: CLI drives a browser surface through form fill, click, wait, screenshot, and verifies expected DOM.
- Fail signal: Element refs are unstable or action hits wrong browser surface.
- Steps:
  - Implement `browser.open_split`, navigate, back, forward, reload, URL get, title get.
  - Implement DOM snapshot with stable element refs.
  - Implement eval, wait, click, double click, hover, focus, fill, type, press, select, check/uncheck.
  - Implement screenshot to file and return path/metadata.
  - Return explicit unsupported errors for P1/P2 commands not implemented yet.

## Phase 6 - Agent App Runtime

### [x] RC2-050 - Implement Normalized Assistant Event Model
- Owner: Agent runtime agent
- Depends: RC2-004, RC2-016
- Output: AssistantEvent model
- Summary: Create provider-independent events for the Agent App timeline.
- Acceptance: Normalized event model builds provider-independent thread/turn/item snapshots.
- Automated tests: Reducer fixture tests for all event/item types, malformed events, ordering, and unknown event handling.
- E2E proof: E2E: proof gate - fake provider stream renders a full timeline without provider-specific conditionals.
- Fail signal: Timeline needs raw provider fields or malformed event crashes reducer.
- Steps:
  - Define event types: threadStarted, turnStarted, itemStarted, itemDelta, itemState, itemCompleted, turnCompleted, error.
  - Define item types: reasoning, plan, tool, assistantMessage.
  - Define item fields: id, turnId, state, summary, body, output, startedAtMs, finishedAtMs, expanded state.
  - Implement reducer that turns event stream into turn snapshots.

### [x] RC2-051 - Implement Codex Runner And Parser
- Owner: Codex provider agent
- Depends: RC2-004, RC2-050
- Output: CodexProviderRunner
- Summary: Run Codex CLI and convert its JSON events into normalized assistant events.
- Acceptance: Codex runner resolves CLI, spawns with correct options, parses JSON events, captures status, and cancels.
- Automated tests: Parser fixtures for reasoning, tools, assistant text, failure, malformed JSON, cancellation, missing binary.
- E2E proof: E2E: fake Codex fixture and real Codex smoke when authenticated produce identical normalized timeline shape.
- Fail signal: Unknown event kills run or missing CLI error is not actionable.
- Steps:
  - Resolve `codex` executable from PATH and surface missing binary errors.
  - Spawn Codex with cwd, prompt, model, reasoning effort, permission mode, and provider thread ID when resuming an existing Codex thread; omit provider thread ID only for a new thread.
  - Parse line-delimited JSON for thread, turn, item, delta, completed, failed, and error events.
  - Capture assistant final text, provider thread ID, diff counts if available, exit status, and cancellation.
  - Ensure unknown event types are ignored with debug logging, not fatal unless required fields are missing.

### [x] RC2-052 - Implement Claude Runner And Parser
- Owner: Claude provider agent
- Depends: RC2-004, RC2-050
- Output: ClaudeProviderRunner
- Summary: Run Claude CLI and normalize stream events into the same timeline model.
- Acceptance: Claude runner resolves CLI, spawns with supported options, parses stream blocks, maps events, and cancels.
- Automated tests: Parser fixtures for thinking, text, tool use/result, cost metadata, failure, missing binary, cancellation.
- E2E proof: E2E: fake Claude fixture and real Claude smoke when authenticated render in the same Agent App timeline.
- Fail signal: Claude UI branch diverges from shared event model.
- Steps:
  - Resolve `claude` executable from PATH and surface missing binary errors.
  - Spawn Claude with cwd, prompt, every supported model/runtime option from the provider contract, and session resume ID when resuming an existing Claude session; omit session resume ID only for a new session.
  - Parse system init session ID, stream content blocks, thinking deltas, text deltas, tool uses, tool results, result events, and errors.
  - Map Claude blocks to normalized reasoning/tool/assistant items.
  - Handle process exit and cancellation deterministically.

### [x] RC2-053 - Implement Agent Run Supervisor
- Owner: Agent runtime agent
- Depends: RC2-051, RC2-052, RC2-016
- Output: AgentRunCoordinator
- Summary: Own active run lifecycle so app restarts and cancellations never leave stale state.
- Acceptance: Run supervisor persists lifecycle, handles stop/fail/complete/cancel, and reconciles crashes.
- Automated tests: Lifecycle state-machine, DB persistence, cancellation, crash recovery, and final-message tests.
- E2E proof: E2E: kill app during fake run, relaunch, verify run is marked interrupted and no process remains.
- Fail signal: Stale run remains active after crash or final assistant message persists before success.
- Steps:
  - Implement start run, stop run, mark completed, mark failed, mark cancelled, and crash recovery.
  - Persist user message before provider process starts.
  - Persist stream events and snapshots during run.
  - Persist final assistant message only after successful run completion.
  - On app launch, reconcile rows that were running during previous crash and mark them failed or interrupted.

### [x] RC2-060 - Implement T3 Code-Style Agent App Surface Shell
- Owner: Agent App UI agent
- Depends: RC2-006, RC2-014, RC2-020, RC2-050
- Output: AgentAppSurface
- Summary: Create the native Agent App surface using T3 Code's ChatView structure as the product reference.
- Acceptance: Agent App surface supports lifecycle, T3-like shell, provider controls, errors, commands, restore, and snapshots.
- Automated tests: Surface lifecycle, header actions, empty states, provider status, diff/terminal toggles, snapshot tests.
- E2E proof: E2E: create/split/focus/rename/close/restore Agent App surface and compare first viewport to T3 Code.
- Fail signal: Surface cannot restore selected thread/provider or visual structure misses core T3 regions.
- Steps:
  - Create `AgentAppSurface` conforming to Surface protocol.
  - Assemble T3 Code-like layout: left sidebar already available, compact top action header, branch/workspace toolbar, central messages timeline, bottom composer, right/inline diff panel, and terminal drawer.
  - Add provider/model controls, runtime permission controls, plan/build mode control, run state, stop/interruption action, missing provider status banner, and thread error banner.
  - Add commands: add action, open editor, commit/push placeholder, open terminal split/drawer, open browser split, reveal project in Finder, toggle diff, toggle plan sidebar, and new Agent App thread.
  - Respect surface lifecycle: create, split, focus, rename, close, restore, and snapshot selected project/thread/provider/model.
  - Make empty state useful: no selected thread, no project, missing CLI, disconnected environment, and first-run prompt states.

### [x] RC2-061 - Implement T3 Code-Style Agent Thread List And Selection
- Owner: Agent App data UI agent
- Depends: RC2-006, RC2-013, RC2-016, RC2-060
- Output: Thread list UI
- Summary: Show project-scoped Codex/Claude threads using T3 Code's project/thread sidebar patterns.
- Acceptance: Thread list lazy-loads visible fields, supports project grouping, search, selection, rename/archive, ordering, restore.
- Automated tests: Lazy loading, active ordering, search, rename/archive, branch/worktree preservation, restore tests.
- E2E proof: E2E: create projects/threads, search, show more, select thread, relaunch, verify same active thread.
- Fail signal: Opening list loads full message bodies or loses branch/worktree context.
- Steps:
  - Load only thread fields required for visible list: id, title, updatedAt, status, provider, project id/name, branch/worktree label, unread state, active run state, and latest preview.
  - Render thread rows under projects with T3 Code-like active selection, muted previews, relative timestamps, working/completed status, and show-more controls.
  - Add create thread, create local/worktree thread, select thread, rename thread, archive/delete if in V1 scope, and preserve active thread's branch/worktree state when requested.
  - Sort by active/updatedAt while keeping search results predictable.
  - Keep selection persisted per workspace and surface snapshot, including selected provider/model where appropriate.

### [x] RC2-062 - Implement T3 Code-Style Agent Timeline Rendering
- Owner: Timeline UI agent
- Depends: RC2-006, RC2-050, RC2-061
- Output: Timeline view
- Summary: Render messages and structured streaming turns using T3 Code's MessagesTimeline as the UX model.
- Acceptance: Timeline renders all row types, streaming, long output collapse, markdown, images, scrolling, and accessibility.
- Automated tests: Fixture rendering, virtualization, stream update, long output, image preview, copy/link, a11y label tests.
- E2E proof: E2E: run fake provider with long tool output and image; verify smooth scroll, collapse, and final evidence rows.
- Fail signal: Streaming freezes UI or long output expands unbounded by default.
- Steps:
  - Render user message bubbles aligned right with attachments, terminal context chips, copy action, revert-to-message action when checkpoint exists, timestamp, and long-message collapse/expand.
  - Render assistant messages as markdown with streaming state, copy action on hover, timestamp plus elapsed duration, completion divider, and empty-response fallback.
  - Render work log/tool calls as compact grouped rows with icon/tone, collapsed overflow, show-more/show-less, normalized tool labels, and stable row identity.
  - Render proposed plan cards, working row with live timer, pending approval/user-input rows when applicable, and terminal context inline chips.
  - Use virtualization or bounded rendering for long histories and preserve scroll-at-end behavior while streaming.
  - Support image previews, markdown file path links, code copy, text selection, load older messages, and latest dirty state.

### [x] RC2-063 - Implement T3 Code-Style Agent Composer
- Owner: Composer UI agent
- Depends: RC2-006, RC2-060, RC2-053
- Output: Message composer
- Summary: Create the native prompt composer using T3 Code's ChatComposer as the reference.
- Acceptance: Composer handles prompt, attachments, provider/model/runtime controls, pending panels, disabled states, drafts, stop.
- Automated tests: Send-state, attachment limit, pending approval/input, provider picker, mode selector, stop, draft, focus tests.
- E2E proof: E2E: send prompt, attach image/path, stop active run, restore draft, verify composer clears only after accept.
- Fail signal: Submit is enabled in invalid state or prompt is lost on failed send.
- Steps:
  - Add rounded bottom composer with multiline prompt editor, send shortcut, accessible submit/stop button, collapsed/narrow-width mode, and disabled environment states.
  - Add provider/model picker, provider trait/reasoning controls, plan/build mode toggle, runtime permission mode selector with Supervised, Auto-accept edits, and Full access options.
  - Add context path mention support, file/folder tagging, terminal context chips, image attachments with preview/remove/warning state, and native file dialogs. Skill/command menu is V1-deferred unless RC2-005 explicitly promotes it; if deferred, expose a typed unsupported command and no visible broken control.
  - Add pending approval panel, pending user-input panel, plan follow-up banner, "implement plan in new thread" action, and context window meter where provider metadata supports it.
  - Disable submit when no workspace path, no provider, missing CLI/auth, unsupported model, empty prompt, environment disconnected, or active run for selected thread.
  - Support stop/interrupt action during active run, preserve drafts per thread, and clear composer only after prompt is accepted.
  - Normalize dead keys, paste, drag-over attachment, command menu highlight, and focus behavior on macOS.

### [x] RC2-064 - Integrate T3 Code-Like Agent App With Codex And Claude
- Owner: Agent integration agent
- Depends: RC2-051, RC2-052, RC2-062, RC2-063
- Output: Real agent runs
- Summary: Wire real provider runners into the Agent App surface while keeping the T3 Code provider-agnostic UI model.
- Acceptance: Codex and Claude run in one Agent App UI, stream normalized events, persist state, lock provider when needed.
- Automated tests: Fake provider integration, missing auth/binary, provider lock, cancellation, persistence tests.
- E2E proof: E2E: run fake Codex then fake Claude in separate threads and verify identical timeline/work evidence behavior.
- Fail signal: Provider switch corrupts thread history or UI forks into raw-provider screens.
- Steps:
  - Add provider selector and provider-specific model loading while preserving a shared model picker UI shape.
  - Lock provider selection for threads with existing provider thread IDs.
  - Start Codex and Claude runs from composer.
  - Stream normalized events into timeline and persist final messages.
  - Show missing CLI/auth/model errors in T3 Code-style banners and disabled composer states.
  - Persist provider session/thread IDs, model selection, runtime mode, effort/traits, and branch/worktree context.

### [x] RC2-065 - Implement Agent Socket And CLI Commands
- Owner: Agent automation agent
- Depends: RC2-018, RC2-019, RC2-064
- Output: `agent.*` API
- Summary: Allow external agents/scripts to create and drive Agent App surfaces.
- Acceptance: Agent socket/CLI commands can open Agent App, create/list threads, send message, stop run, and list models.
- Automated tests: API handler, CLI wrapper, target resolution, response schema, error handling, and provider state tests.
- E2E proof: E2E: CLI opens Agent App, sends prompt to fake provider, waits for completion, stops another active run.
- Fail signal: Command cannot target a specific workspace/surface or returns unstable IDs.
- Steps:
  - Implement socket methods: `agent.open`, `agent.thread.create`, `agent.thread.list`, `agent.message.send`, `agent.run.stop`, `agent.state.current`, `agent.models.list`.
  - Add CLI wrappers under `remotecode2 agent`.
  - Return window/workspace/pane/surface/thread/run IDs in responses.
  - Ensure command can target a specific workspace or surface.

## Phase 7 - Work Evidence And Project Actions

### [ ] RC2-066 - Implement T3 Code-Style Changed Files Summary
- Owner: Diff evidence UI agent
- Depends: RC2-022, RC2-062
- Output: ChangedFilesSummary component
- Summary: Add the changed-files card shown after agent turns, matching T3 Code's proof-of-work pattern.
- Acceptance: Changed-files summary shows totals, tree, per-file state, empty/no-git errors, collapse, and diff opening.
- Automated tests: Git fixtures for add/delete/rename/binary/no-git/no-change and UI state tests.
- E2E proof: E2E: fake agent changes files; timeline shows changed-files card; clicking file opens correct diff.
- Fail signal: Completed file-changing run lacks proof card or wrong file opens.
- Steps:
  - After each completed provider turn, compute git diff summary for the relevant checkpoint, branch, or working tree range.
  - Render a compact card titled "Changed files (N)" with additions/deletions totals, collapse all/expand all, view diff, and a nested file tree.
  - Show file icons/fallbacks, directory nesting, per-file additions/deletions, created/deleted/modified/renamed states, and selected hover/focus styling.
  - Open the diff panel to selected turn/file when a file or "View diff" is clicked.
  - Handle non-git projects, no changes, deleted files, binary files, large diffs, and git command failures with clear states.

### [ ] RC2-067 - Implement T3 Code-Style Diff Panel
- Owner: Diff panel agent
- Depends: RC2-066
- Output: DiffPanel surface/pane
- Summary: Build the dedicated diff inspection surface inspired by T3 Code's DiffPanel.
- Acceptance: Diff panel supports turns, files, stacked/split mode, wrap/whitespace, large diffs, fallback, restore.
- Automated tests: Diff parser fixtures, large-diff performance, no-git/no-change, selected-file scroll, accessibility tests.
- E2E proof: E2E: open diff from changed-files card, toggle modes/options, reopen, verify selected file persists.
- Fail signal: Large diff freezes UI or fallback hides parser failure reason.
- Steps:
  - Render turn selector chips including all turns and individual turns with timestamp/checkpoint labels.
  - Render stacked and split diff modes, word-wrap toggle, ignore-whitespace toggle, file collapse/expand controls, and open-file-in-editor action.
  - Support raw patch fallback when parser cannot render a diff, with a clear reason.
  - Virtualize or chunk large diffs so the UI remains responsive.
  - Persist selected diff turn/file and restore when reopening the surface.

### [ ] RC2-068 - Implement T3 Code-Style Terminal Drawer And Chat Context Bridge
- Owner: Terminal drawer agent
- Depends: RC2-030, RC2-031, RC2-063
- Output: ThreadTerminalDrawer
- Summary: Add the T3 Code terminal drawer behavior on top of RemoteCode 2 terminal surfaces.
- Acceptance: Terminal drawer supports toggle, split/new/close, resize persistence, shortcuts, link open, selection-to-context.
- Automated tests: Drawer state, resize, shortcuts, selection context, link open, lifecycle, restore, orphan-process tests.
- E2E proof: E2E: open drawer, split terminals, select output into composer context, hide/show, verify focus returns.
- Fail signal: Drawer steals composer focus or terminal process leaks on close.
- Steps:
  - Add a resizable bottom terminal drawer attached to the active Agent App thread with persisted height and visible/hidden state.
  - Support terminal toggle, split, new, close, active terminal selection, group sidebar when multiple terminals exist, and max split limit.
  - Route terminal shortcuts only when terminal focus/open context matches the keybinding resolver.
  - Open file paths and URLs from terminal output using preferred editor/external browser rules.
  - Allow selecting terminal text and adding it to the composer as a terminal context chip with label, line range, and body text.
  - Preserve terminal snapshot/history across drawer remounts and close terminal sessions cleanly.

### [ ] RC2-069 - Implement T3 Code-Style Project Scripts And Open-In Controls
- Owner: Project actions agent
- Depends: RC2-015, RC2-021, RC2-030
- Output: Project actions controls
- Summary: Add header actions that let users run project scripts and open the project like T3 Code.
- Acceptance: Project actions discover scripts safely, render Add action/Open controls, run in terminal, and log safely.
- Automated tests: Script discovery fixtures, unsafe disabled cases, open actions, command registration, log redaction tests.
- E2E proof: E2E: run project test script from header into terminal drawer and open project in preferred editor placeholder.
- Fail signal: Untrusted script executes automatically or secrets appear in logs.
- Steps:
  - Discover project scripts from package metadata, Makefile, or configured scripts file without executing untrusted commands automatically.
  - Render an "Add action" or scripts control in the top header with script name, command preview, and run-in-terminal behavior.
  - Render an "Open" control for preferred editor, Finder, Terminal, and external browser where applicable.
  - Register all actions in the command palette and expose shortcuts where configured.
  - Log script start/finish metadata without logging secrets from command output.

## Phase 8 - Quality Gates

### [x] RC2-090 - Create Unit Test Suite
- Owner: Test agent
- Depends: Foundation modules
- Output: Unit tests
- Summary: Build low-level tests that verify business intent and invariants.
- Acceptance: Unit suite covers reducers, snapshots, DB, providers, event model, CLI, and command validation intent.
- Automated tests: CI unit command fails on missing required test family or shallow no-intent tests.
- E2E proof: E2E: proof gate - mutation-style spot checks prove tests fail when key invariants are broken.
- Fail signal: Suite passes while stale run, bad layout, or provider-history corruption is injected.

### [~] RC2-091 - Create Integration Test Suite
- Owner: Integration test agent
- Depends: RC2-018, RC2-030, RC2-040, RC2-053
- Output: Integration tests
- Summary: Verify subsystems working together without relying on manual UI.
- Acceptance: Integration suite proves socket, CLI, terminal, browser, fake provider, and fixture factory work together.
- Automated tests: Headless/minimal-host integration tests for each required scenario with deterministic fixtures.
- E2E proof: E2E: CI launches minimal app host and drives full socket-to-UI-state workflow.
- Fail signal: Subsystem tests pass individually but integrated workflow cannot run.

### [ ] RC2-092 - Create UI Automation Suite With T3 Code Parity Flows
- Owner: UI test agent
- Depends: RC2-006
- Output: XCTest UI suite
- Summary: Validate the full app like a user would use it, including T3 Code-inspired Agent App workflows.
- Acceptance: UI automation covers fresh launch, workspace, surfaces, command palette, fake provider, diff, drawer, restore.
- Automated tests: XCTest UI suite with fixture setup, screenshots, recordings, and deterministic selectors.
- E2E proof: E2E: full happy path creates terminal/Agent App/browser layout, runs fake provider, inspects diff, relaunches.
- Fail signal: Any core daily workflow lacks UI automation or produces blank/overlapped screenshots.

### [ ] RC2-093 - Create Performance Test Suite
- Owner: Performance agent
- Depends: Core vertical slice
- Output: Perf reports
- Summary: Keep native rewrite fast and prevent regressions.
- Acceptance: Performance suite measures launch, idle memory, terminal/browser creation, timeline, diff, and large events against budgets.
- Automated tests: Automated perf benchmarks with baseline comparison and regression thresholds.
- E2E proof: E2E: scripted heavy workspace run records timings and screenshots, then flags regression above threshold.
- Fail signal: Perf data is manual-only or regressions do not fail CI/review gate.

### [ ] RC2-094 - Create T3 Code UI Parity Screenshot Suite
- Owner: Visual QA agent
- Depends: RC2-020, RC2-069
- Output: Visual parity test suite
- Summary: Create screenshot and semantic checks that prevent the Swift UI from drifting away from the T3 Code reference.
- Acceptance: Visual suite proves T3-like desktop/narrow/active/diff/drawer views with contrast and no overlap.
- Automated tests: Screenshot comparison, semantic control checks, blank-screen detection, contrast, and layout bounds tests.
- E2E proof: E2E: capture canonical screenshots for each major viewport and compare to approved T3 parity references.
- Fail signal: Missing core control, unreadable contrast, blank area, or overlapped text passes unnoticed.

### [ ] RC2-095 - Create Future Mobile Direct-VPN Contract Test Suite
- Owner: Contract test agent
- Depends: RC2-023, RC2-024, RC2-025, RC2-026
- Output: Direct-VPN API contract tests
- Summary: Prove the desktop core can support a future mobile mirror without building the mobile app.
- Acceptance: Direct-VPN contract suite proves discovery, auth, pairing, WS replay, command bus routing, revocation, and backpressure.
- Automated tests: Fake-client HTTP/WS contract tests plus negative tests for relay/private-backend fields.
- E2E proof: E2E: paired fake mobile drives workspace, Agent App, terminal, browser, git/status flows over direct API.
- Fail signal: Relay dependency appears, default token ships, replay metadata missing, or command bypasses bus.

### [ ] RC2-100 - Run Architecture Review
- Owner: Senior reviewer agent
- Depends: RC2-010, RC2-019
- Output: Review report
- Summary: Review module boundaries and lifecycle before feature work hardens.
- Acceptance: Architecture review lists P0/P1/P2 findings for module boundaries, source use, persistence, socket, and native constraints.
- Automated tests: Review checklist lint verifies all required focus areas are answered with evidence links.
- E2E proof: E2E: proof gate - reviewer runs one vertical slice smoke before approving architecture readiness.
- Fail signal: P0/P1 issue remains open or review lacks file/test evidence.
- Review focus:
  - Surface protocol does not leak concrete terminal/browser/agent details.
  - Socket API uses public terminology and stable IDs.
  - Persistence layer is testable and schema steps are deterministic.
  - No source license violation risk was introduced.
  - No fake desktop chrome or web runtime dependency exists.

### [ ] RC2-101 - Run Security And Privacy Review
- Owner: Security reviewer agent
- Depends: Provider, browser, socket, fresh-start bootstrap complete
- Output: Security review report
- Summary: Check secrets, provider process handling, browser data, socket access, and first-run local data handling.
- Acceptance: Security review clears secrets, auth, remote access, browser data, logging, first-run paths, and provider handling.
- Automated tests: Secret scan, auth negative tests, log redaction tests, denied remote access tests, path touch audit.
- E2E proof: E2E: attempted unauthorized HTTP/WS/CLI access fails; authorized paired device audit trail is visible.
- Fail signal: High severity issue open, token logged, or remote control works without explicit trust.
- Review focus:
  - Prompts and terminal input are redacted in logs/events where needed.
  - Provider thread IDs and tokens are not printed unnecessarily.
  - Local automation socket remains local-only; direct-VPN HTTP/WebSocket access requires explicit enablement, pairing, revocable device trust, and strong auth.
  - No relay, private backend, connector id, cloud command queue, or hosted repository mirror exists in the remote-control path.
  - Browser profiles/cookies are stored and cleared intentionally.
  - First-run bootstrap never scans other app data, home-folder previous-product paths, or external databases.

### [ ] RC2-102 - Run Accessibility And Keyboard Review
- Owner: Accessibility reviewer agent
- Depends: Core UI complete
- Output: A11y review
- Summary: Ensure the developer UI is keyboard-first and accessible enough for daily use.
- Acceptance: Keyboard and accessibility review confirms names, focus, command palette, composer, terminal/browser handoff, and no truncation.
- Automated tests: Accessibility tree checks, focus-order tests, keyboard-only navigation tests, text bounds checks.
- E2E proof: E2E: keyboard-only user completes create workspace, run fake provider, inspect diff, operate terminal drawer.
- Fail signal: Mouse-only required path or inaccessible critical control remains.
- Review focus:
  - Workspace/sidebar/surface tabs have accessible names and focus states.
  - Command palette is fully keyboard usable.
  - Agent composer, stop button, provider selectors, and copy buttons are accessible.
  - Terminal/browser focus handoff is predictable.
  - Text does not overlap or truncate critical controls at supported window sizes.

### [ ] RC2-103 - Run T3 Code UX Parity Review
- Owner: Senior UX reviewer + Scrum master
- Depends: RC2-060, RC2-069, RC2-094
- Output: T3 parity review report
- Summary: Senior design/product review proving RemoteCode 2 copied the right T3 Code behaviors without violating SwiftUI/AppKit/native constraints.
- Acceptance: T3 parity review passes sidebar, header, Agent App, drawer, SwiftUI/AppKit, Liquid Glass, and native adaptation checks.
- Automated tests: Parity checklist lint ties every required T3 pattern to screenshots/tests or explicit deferral.
- E2E proof: E2E: reviewer compares canonical app recording against T3 Code reference flow and marks each pattern pass/fail.
- Fail signal: Major T3 behavior missing without deferral or UI drifts into marketing style.
- Review focus:
  - Sidebar: search, project/thread grouping, selected state, status pills, timestamps, and settings footer match T3 Code intent.
  - Header: action density, Add action, Open, Commit & push deferred command, terminal toggle, diff toggle, and overflow controls are present with either working behavior or typed unsupported state from RC2-005.
  - Agent App: timeline rows, work log, changed-files card, diff panel, composer footer, provider/model/runtime controls, and pending approvals match T3 Code intent.
  - Terminal drawer: split/new/close, selection-to-chat, focus/keybinding behavior, and height persistence match T3 Code intent.
  - SwiftUI usage: sidebar, chat, composer, lists, settings, command palette, controls, and data-driven content are SwiftUI unless a documented AppKit need exists.
  - AppKit usage: window, responder chain, menus, focus, terminal host, complex split panes, and native panels are AppKit-owned where SwiftUI is weak.
  - Liquid Glass usage: present only in controls and bars; absent from main content, chat body, sidebar rows, terminal, browser, and diff content.
  - Swift/native adaptation: no Electron/React runtime, no fake window chrome, no CSS-only assumptions, no marketing-style UI, and all direct T3 Code source reuse has MIT attribution.

### [ ] RC2-104 - Run Future Mobile Readiness Review
- Owner: Senior platform reviewer + Scrum master
- Depends: RC2-008, RC2-023, RC2-026, RC2-095
- Output: Mobile readiness review report
- Summary: Senior review gate proving RemoteCode 2 was built from zero with the future mobile mirror in mind.
- Acceptance: Mobile readiness review proves direct-only networking, command bus, replay, device trust, surface coverage, and deferred mobile scope.
- Automated tests: Review checklist plus contract test report from RC2-095 and static scan for forbidden network paths.
- E2E proof: E2E: fake mobile readiness run pairs, reconnects, replays missed events, revokes access, and records evidence.
- Fail signal: Any mobile-critical invariant fails or mobile app work is accidentally added to scope.
- Review focus:
  - Architecture keeps the desktop as source of truth and stores repositories/provider credentials only on the user's computer.
  - Networking is direct VPN/LAN only, disabled by default beyond loopback, and contains no relay/private-backend/cloud-broker path.
  - Every desktop action that future mobile needs is routed through the shared command bus and emits replayable events.
  - Event envelopes include sequence, request id, origin client id, actor, target ids, replay semantics, and redaction class.
  - Device trust is explicit, revocable, auditable, and does not rely on production default credentials.
  - Surface contracts cover Agent App, terminal, browser, git/files, workspace/panes, and remote-access settings.
  - Mobile itself was not implemented in this phase; only desktop readiness contracts, APIs, fixtures, and tests were built.

## Phase 9 - Release

### [ ] RC2-120 - Implement Signing, Notarization, And DMG Packaging
- Owner: Release engineering agent
- Depends: Feature-complete app
- Output: Signed DMG
- Summary: Produce a macOS artifact that can launch on a clean machine.
- Acceptance: Signed/notarized DMG installs and launches cleanly with correct entitlements and CLI helper signing.
- Automated tests: Codesign, notarization, staple, entitlement, Gatekeeper, bundle structure, and CLI helper checks.
- E2E proof: E2E: install DMG on clean macOS account, launch app, run smoke flow, and verify Gatekeeper acceptance.
- Fail signal: Unsigned helper, unstapled ticket, or clean machine launch fails.
- Steps:
  - Configure signing identities, entitlements, hardened runtime, and app sandbox status if used.
  - Sign app bundle and CLI helper.
  - Create DMG with Applications drag target.
  - Submit for notarization and staple ticket.
  - Validate with `spctl` and launch on a clean macOS user account.

### [ ] RC2-121 - Implement Update Channel Strategy
- Owner: Release engineering agent
- Depends: RC2-120
- Output: Updater config
- Summary: Prepare debug/canary/stable channel separation and updater behavior.
- Acceptance: Update channels isolate bundle ids/data and canary updates from N to N+1 safely.
- Automated tests: Bundle id, app support path, update feed signing, canary update, stable isolation tests.
- E2E proof: E2E: install canary N, create data, update to N+1, verify data persists and stable remains untouched.
- Fail signal: Canary touches stable data or update requires manual repair.
- Steps:
  - Set separate bundle IDs and app support directories for debug, canary, stable.
  - Integrate Sparkle or approved updater.
  - Define update feed signing and release metadata workflow.
  - Test update from canary N to canary N+1.

### [ ] RC2-122 - Create Clean First-Run UX
- Owner: Onboarding agent
- Depends: RC2-080
- Output: First-run flow
- Summary: Guide users through dependency checks and first workspace creation from zero.
- Acceptance: First-run UX reaches first Agent App prompt from zero and keeps remote-access settings disabled and separate from onboarding.
- Automated tests: Dependency detection, provider missing states, folder chooser, initial surface, remote disabled default tests.
- E2E proof: E2E: clean user completes onboarding, opens folder, creates Agent App, sends fake prompt, sees response.
- Fail signal: User cannot reach first prompt without docs or remote access is enabled by default.
- Steps:
  - Detect Codex and Claude CLI availability.
  - State clearly that RemoteCode 2 starts clean and does not connect to another RemoteCode app's data.
  - Allow opening a folder and choosing initial surface: Agent App, terminal, browser.
  - Offer CLI symlink install/update only with explicit user approval.
  - Show remote access disabled by default, with direct-VPN readiness settings clearly separated from first workspace setup and unreachable unless the user explicitly opens remote access settings.

### [ ] RC2-123 - Create User And Developer Documentation
- Owner: Docs agent
- Depends: Feature behavior stable
- Output: Docs
- Summary: Document installation, first-run setup, CLI, T3 Code-inspired Agent App, direct-VPN desktop API, browser automation, and troubleshooting.
- Acceptance: Docs match actual behavior for install, first run, CLI/socket, Agent App, direct VPN, tests, limits, and notices.
- Automated tests: Docs lint for required sections, broken links, stale planned wording, command snippets, notice references.
- E2E proof: E2E: proof gate - new-agent dry run follows docs to complete first workspace and one direct-API fake-client check.
- Fail signal: Docs describe planned behavior as shipped or omit critical direct-VPN/no-relay constraints.

### [ ] RC2-124 - Run Final Release Readiness Review
- Owner: Scrum master + senior reviewer
- Depends: All V1 cards
- Output: Go/no-go report
- Summary: Scrum master gate before stable release.
- Acceptance: Final go/no-go report names version, commit, artifacts, tests, reviews, risks, and recovery path.
- Automated tests: Release checklist validates all blocking cards, test reports, notarization, screenshots, and review signoffs exist.
- E2E proof: E2E: final release candidate runs clean install, first prompt, terminal/browser/diff/drawer, direct-VPN fake-client, update smoke.
- Fail signal: Any P0/P1 open, missing artifact, missing evidence, or unsupported API fails silently.

