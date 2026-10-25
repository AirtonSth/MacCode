# Apps Catalog and Workspace Navigation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans with parallel independent task owners. User explicitly requested direct implementation through tested push, without further design gates.

**Goal:** Show owned workspace resources consistently, reduce creation controls to section menus, and offer an app catalog with guided connection from the sidebar.

**Architecture:** Preserve the app-owned ConnectionBroker and run authorization. Add a Composio project coordinator for toolkit catalog, managed OAuth links, verified account status, and exact-account MCP sessions. Keep manual MCP configuration secondary. Workspace catalog membership is distinct from permission to read/send conversations.

**Tech Stack:** SwiftUI, Swift concurrency, URLSession, SQLite settings metadata, Keychain credentials, existing host RPC contracts.

**Spec:** User's 2026-10-25 screenshots and direct instructions in this conversation; prior approved design in docs/superpowers/specs/2026-10-24-bot-workspace-connections-design.md.

## Global Constraints

- Edit/build/test only in linked worktree; root owns SwiftPM and UI lease.
- No copied OpenMausBot credentials/backend, no client secret in repo/SQLite/provider argv.
- OAuth browser completion alone never marks an app connected: verify exact user/toolkit/account ACTIVE.
- Project setup is one-time, secure, and explicit; per-app connection should need no endpoint/JSON.
- Preserve existing identities, histories, destinations, current authorizations and manual MCPs.
- UI English, DS tokens, narrow/wide native verification, honest errors and cancellation.

## Review Focus

- Owner metadata without host grant must show the resource without inventing conversation authority.
- Revoked contexts must not show/replay unauthorized transcripts.
- OAuth cancellation/late completion must not silently connect, grant all scopes, or cross accounts.
- API keys and hosted session URLs must remain protected, including errors and HTTP redirects.
- Project unconfigured/offline catalog must remain useful and honest; manual MCP remains available.

## Tasks

- [x] Reproduce workspace membership mismatch and pin regression; merge owner catalog with authorized rows safely.
- [x] Replace two workspace bot/VM creation rows with ellipsis section menus; verify disclosure persistence.
- [x] Add secure Composio project setup/client/coordinator and transport tests; preserve broker authority.
- [x] Build catalog search/categories, connected accounts/actions, connect/access sheet and advanced manual MCP.
- [x] Add sidebar Connections icon/entry opening the same connections surface.
- [x] Run focused regressions, independent code review, native wide/narrow/relaunch/OAuth fixture QA.
- [ ] Commit/push fork, optimized release package, install preserving data, capture screenshots and report real limitations.
