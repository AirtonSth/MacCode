![RemoteCode in action](https://remotecode.io/videos/video-3x.gif)

# RemoteCode for macOS

Your entire dev workflow — agents, terminals, browsers, and git — in one native cockpit you can drive from anywhere.

All a developer need to code anywhere.

## Get Started

[Latest Release](https://github.com/samuelfaj/remotecode.io/releases/latest/download/stable-macos-arm64-RemoteCode.dmg)

## What RemoteCode Does

RemoteCode is a native macOS development cockpit. It brings the tools a developer normally keeps spread across terminals, browser tabs, git windows, agent CLIs, and mobile devices into one workspace that can be controlled locally on the Mac or remotely from iPhone.

RemoteCode is built around a simple rule: the Mac stays the source of truth. Agents, shells, git, browsers, files, and workspaces run on the Mac. Remote clients mirror and control that real host state instead of running separate copies.

## Core Capabilities

### Agent App

- Start and continue agent threads from a native macOS surface.
- Use Codex and Claude Code as first-class providers.
- Switch provider, model, reasoning effort, service tier, permissions, and execution mode before a run starts.
- Use dynamic provider model discovery where available, with safe fallback model aliases.
- Add custom model IDs, persist them, and manage them later from Settings.
- Run in local mode or isolated worktree mode.
- Attach files to the next agent message.
- Queue follow-up messages while a run is active.
- Stop active runs.
- Continue provider sessions without losing the provider thread cursor.
- Render assistant output, tool activity, work logs, proposed plans, approvals, provider questions, user-input requests, errors, and token/context status.
- Answer provider approval and user-input cards directly in the app.
- Rehydrate thread history and runtime state after app restart.
- Track running/failed/completed state in tabs and workspace chrome.

### Terminal

- Open real macOS terminal tabs inside the workspace.
- Run local shell commands in the selected workspace directory.
- Keep terminal output, scrollback, and tab state tied to the workspace.
- Mirror terminal output to remote clients.
- Preserve ANSI styling and terminal-like output for rich CLI/TUI workflows.
- Read terminal text through the host API for automation and remote proof.

### SSH

- Open SSH surfaces for remote machines.
- Save SSH host profiles.
- Scope saved hosts to the current workspace.
- Reconnect to saved hosts from the SSH sidebar.
- Show file-transfer controls only when a connection is active.
- Preserve active SSH tab behavior across tab and split-pane operations.

### Browser

- Open embedded browser surfaces inside a workspace.
- Navigate from a local address field.
- Keep browser state attached to the workspace layout.
- Open the current URL in the Mac default browser when needed.
- Mirror browser surfaces to remote clients where supported.

### Files

- Browse workspace files from a native surface.
- Open file previews for supported file types.
- Keep heavy previews unloaded when hidden so background tabs do not retain unnecessary memory.
- Support file-oriented workflows from macOS and mirrored mobile surfaces.

### Git And Delivery

- Open Git and diff surfaces from the workspace.
- Review changed files.
- Use git summary context in the Agent composer.
- Prepare pull-request-oriented agent flows.
- Keep git review actions close to the agent thread that produced the work.

### Panes, Tabs, And Workspaces

- Create multiple workspaces, each with its own current working directory.
- Use tabs for Terminal, SSH, Browser, Agent App, Files, Git, and preview surfaces.
- Split panes horizontally or vertically.
- Drag tabs between panes.
- Split a selected tab into a new pane.
- Minimize panes without destroying their tab strip.
- Right-click tabs to close all others, close all to the left, or close all to the right.
- Persist and restore workspace layout.
- Show busy indicators when an agent thread is running.

### iPhone Remote Control

- Pair an iPhone with the Mac over the local network or VPN.
- Mirror real Mac workspaces, surfaces, agent threads, terminals, browser surfaces, git state, and activity.
- Control the Mac from iPhone without running agents, shells, git, or browser logic on the phone.
- Send agent prompts, queue follow-ups, answer provider questions, approve or deny provider actions, and stop runs from iPhone.
- Drive hosted terminal surfaces from iPhone while the command still runs on the Mac.
- Use host readback and event streams so mobile state stays tied to actual Mac state.

### Watch And Notifications

- Surface agent thread state through iOS widgets and Live Activities.
- Schedule local notifications for host events.
- Keep mobile activity indicators aligned with host-side agent status.

### Account And Pairing

- Pair devices through host-issued pairing codes and trusted-device tokens.
- Store remote-control tokens in the iOS Keychain.
- Keep direct LAN/VPN control separate from optional private account features.
- Use private account sign-in for backend-assisted push delivery where configured.
- Keep the Mac usable without a private account for local/direct workflows.

### Settings And Diagnostics

- Toggle remote access for paired devices.
- Configure Codex and Claude executable paths.
- Inspect provider install/auth/update state.
- Run provider update actions.
- Manage custom model IDs.
- Configure diff defaults.
- Generate and revoke pairing codes.
- Review trusted devices.

## Security Model

- The Mac is the authority for workspace state and execution.
- Remote clients mutate state through explicit host RPCs and event streams.
- Paired-device tokens are required for remote control.
- Remote access can be disabled to bind the host API to localhost.
- When remote access is enabled, the host API binds to the LAN interface and still requires trusted-device authorization.
- iOS stores pairing tokens in Keychain.
- Remote clients do not run local shell, git, browser, or agent logic independently.
- Sensitive host state is not treated as a stale client cache; the host remains the source of truth.

## Architecture

RemoteCode is split into focused modules:

- `AppShell`: macOS app shell, workspaces, tabs, panes, settings, command routing, and app lifecycle.
- `Surfaces`: native macOS surfaces for Agent App, Terminal, Browser, Files, Git/Diff, previews, and related UI.
- `AgentRuntime`: provider adapters and runtime logic for Codex, Claude Code, streaming, approvals, user input, session recovery, and model discovery.
- `SocketServer`: local HTTP/RPC/WebSocket API, pairing, event streaming, and remote-control dispatch.
- `CoreModel`: shared workspace, surface, agent, provider, and event models.
- `Persistence`: SQLite-backed storage for settings, workspaces, threads, messages, queues, checkpoints, prompts, and trusted devices.
- `DesignSystemKit`: shared tokens and native UI components.
- `ios-app`: SwiftUI remote-control client for iPhone.
- `watchos-app`: watch-side companion surfaces.
- `private`: optional backend/account/push infrastructure.

## Typical Workflows

### Run an agent against a repository

1. Open a workspace pointing at a project directory.
2. Open an Agent App tab.
3. Choose Codex or Claude Code.
4. Select the model, reasoning effort, permission mode, and execution mode.
5. Send a prompt.
6. Review streaming output, work logs, proposed plans, approvals, and file changes.
7. Open Git/Diff review from the same workspace.

### Continue work from iPhone

1. Enable remote access on the Mac.
2. Pair the iPhone using a host pairing code.
3. Open the same workspace on iPhone.
4. Continue the agent thread, answer pending questions, stop a run, or drive a terminal command.
5. Let the Mac keep executing while the phone mirrors host state.

### Use RemoteCode as a local cockpit

1. Keep Terminal, Agent App, Browser, Files, and Git tabs in one workspace.
2. Split panes for side-by-side review.
3. Drag tabs into the layout that fits the task.
4. Use tab context actions to clean up finished work quickly.

## Build And Test

```bash
swift build --product RemoteCode
swift test
```

When running from environments where `xcode-select` points at Command Line Tools, use:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product RemoteCode
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Focused examples:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AgentAppViewModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaneActionTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProviderSnapshotRuntimeTests
```

## Design Principles

- Native macOS first: use platform controls, predictable window behavior, keyboard support, and desktop density.
- Host truth first: every remote surface must reflect real Mac state, not optimistic client-only state.
- Fail loud: provider auth, install, model, pairing, and runtime problems should be visible and recoverable.
- Keep workflows close: agent output, terminal state, browser context, files, and git review should stay in the same workspace.
- Mobile mirrors, Mac executes: iPhone control is powerful because it drives the real host instead of duplicating developer tools on the phone.
