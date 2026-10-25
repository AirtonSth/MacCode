# MacCode bot workspace, chat and connections implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans task by task. User approved execution without another plan gate.

**Goal:** Deliver visible group conversations, exclusive existing-resource workspace transfers, provider-independent MCP connections and a clean bot chat.
**Architecture:** Extend existing group controller and ownership stores; preserve IDs and durable pins. Add an app-owned connection store/secret store/broker and managed MCP admission shared by provider launch paths. Keep UI integration thin and reuse DS controls.
**Tech Stack:** Swift, SwiftUI/AppKit, SQLite/Persistence, Keychain, MCP JSON-RPC, existing CLI/ACP runtimes.
**Spec:** docs/superpowers/specs/2026-10-24-bot-workspace-connections-design.md

## Global constraints
- User selected exclusive airtours ownership, not cosmetic grouping.
- Work only in linked worktree. Installed daily app remains available until verified replacement.
- Preserve history, IDs, filesystem homes, VM data and immutable conversation pins. No secret values in SQLite/logs or global credentials in agent environments.
- All relevant provider paths and scheduled runs must admit the same connection policy. Unsupported combinations report unavailable.
- Native UI checks at narrow/wide sizes, relaunch and switch persistence; mounted OpenMausBot tools only, bounded repository UI lease.

## Review focus
- Ownership move racing a VM start or leaving old thread/schedule/default bindings invalid.
- Rapid bot/group navigation showing a previous transcript or losing a draft.
- MCP disconnect/revocation during resumed or scheduled work.
- Secret/headers leaking through config serialization, diagnostics or process arguments.
- Fresh default clean layout versus persisted explicit panel visibility.

### Task 1: group and team sidebar
**Files:** Sources/AppShell/SidebarView.swift, BotsTeamsGroups.swift; Tests/AppShellTests sidebar/group tests.
**Produces:** first-class visible group rows using existing controller/service; team roster grouping; bot histories in left navigation.
- [ ] Add behavior tests for visible/hidden/pinned/unread groups and selecting correct existing room.
- [ ] Implement cached immediate rows + event reload, persisted expansion/selection, correct active states.
- [ ] Verify source/tests, then primary runs tests and native narrow/wide navigation checks.
- [ ] Review and commit this slice.

### Task 2: exclusive existing-resource transfers
**Files:** Sources/Persistence/BotStore+VirtualMachines.swift, new BotStore workspace-transfer extension, canonical host service/API wiring, new AppShell workspace-assignment UI; Tests/PersistenceTests and AppShellTests.
**Produces:** transactional compare-and-set transfers for bots and VMs retaining identity; explicit refusal for conflicting pinned/default/scheduled/live use; existing-resource picker usable by workspace and resource menus.
- [ ] Add transfer tests preserving ID/data and refusing stale/racy/incompatible changes.
- [ ] Implement owning-store operations and canonical runtime guard/revocation/events. Never weaken VM allows checks.
- [ ] Integrate existing-only UI, service readback and clear conflict messages.
- [ ] Run tests; exercise with temporary fixtures, then apply exact requested airtours transfers through canonical API and read back.
- [ ] Review and commit this slice.

### Task 3: connections
**Files:** new CoreModel connection types + Keychain store; Persistence ConnectionStore/migration; new runtime MCP broker/facade and provider admission integration; AppShell Connections view/Settings route; tests per layer.
**Produces:** app-owned remote HTTP and local stdio MCP configuration, secure credentials, discovery/test/connect/disconnect, tool execution through provider-independent admission; Composio hosted MCP usable as one connection type.
- [ ] Add fixture server tests for tools/list + tools/call, authentication, malformed replies, disconnect/revocation and restored sessions.
- [ ] Implement persistence with secret references only, new app-scoped Keychain namespace and broker.
- [ ] Integrate Claude CLI/SDK, Codex exec/app-server, Grok ACP, Distill host and guest plus scheduled use; prefer shared admission composition.
- [ ] Build DS Connections settings with secure inputs and honest tested/disconnected/error states.
- [ ] Verify real owned fixture across admitted runtimes. External accounts remain unconnected until real auth; request only a genuinely required credential.
- [ ] Review and commit this slice.

### Task 4: clean chat and integration
**Files:** Sources/AppShell/BotsWindow.swift, MainWindowController.swift as needed, shared timeline/composer only when necessary; DESIGN.md; targeted layout tests.
**Produces:** chat-first bot opening, optional persisted history/inspector, compact permission/error status preserving approvals and controls; groups consistent with shared chat surfaces.
- [ ] Add default-versus-persisted visibility and navigation/draft regression tests.
- [ ] Default redundant thread rail and inspector closed, preserve explicit preferences, widen readable chat, keep controls discoverable.
- [ ] Integrate Task 1 selection/history and Task 2 picker without concurrent edits to the same file.
- [ ] Targeted test suite, isolated build and native UI with fresh profile, narrow/wide and relaunch.
- [ ] Independent final diff review; fix blockers, recheck only affected paths.
- [ ] Push all verified changes to AirtonSth/MacCode branch; build release and replace daily install with backup if checks pass.

### Required integration: workspace groups
Code review found that legacy group member threads always used General. Exclusive ownership and workspace connections require group execution to use the canonical workspace context too.
- Persist new group scope in its existing room thread workspace (no schema migration).
- Require current-host read/send authority, create only missing minimal grants for bots owned by that exact workspace, and refuse revoked or incomplete authority.
- Bind new hidden member threads to immutable workspace pins, use workspace cwd, suppress global bot memory and revalidate before each turn.
- Preserve existing General groups and historical pins. Adopt an existing group only through a transactional empty-group check, keeping its IDs.
- Prove group creation, execution, revocation and empty-group adoption with actual orchestration/store fixtures before native QA.
