---
name: isolated-sandbox
description: >
  Isolate RemoteCode macOS agent work from the user's running host app.
  Create a git worktree, then build/test/run with a debug bundle id, own
  Application Support, and HTTP 18218 so the original io.remotecode.desktop
  instance is never edited, quit, or overwritten.
  Use when building or testing this repo, launching a second RemoteCode,
  creating a worktree, running script/build_and_run.sh, or the user runs
  /isolated-sandbox.
---

# Isolated sandbox

The host RemoteCode (`io.remotecode.desktop`) stays up. Work in a linked git worktree and prove through `scripts/isolated-sandbox.sh`.

Identity, ports, and App Support are defined only in that script. Print them with `scripts/isolated-sandbox.sh identity` — do not invent bundle ids or ports.

## Every session

1. From the product checkout: `cd "$(scripts/isolated-sandbox.sh ensure)"`
2. Edit only files under that printed path.
3. Tests: `scripts/isolated-sandbox.sh test` or `scripts/isolated-sandbox.sh test --filter NameTests`
4. Second GUI (optional): `scripts/isolated-sandbox.sh run` and later `stop`

`ensure` from the primary tree creates `.sandbox-worktrees/<stamp>` on branch `sandbox/isolated-<stamp>` at `HEAD`. Already inside a linked worktree, it reprints `pwd`. Use `RC2_SANDBOX_REF=origin/production` and `RC2_SANDBOX_FETCH=1` when the sandbox must track origin, not the current `HEAD`.

## Forbidden

- `pkill -x RemoteCode`
- `osascript` quit `io.remotecode.desktop`
- `script/build_and_run.sh` and `scripts/run-app.sh` (stable bundle id + quit host)
- `git checkout production` / reset / commit in the primary worktree
- Token Saver / `~/.local/bin/distill` install from the sandbox
- `open dist/RemoteCode.app` (stable packaging)

`RC2_SURFACE_ID` in this shell means you are inside the host app. `isolated-sandbox.sh run` is still allowed; `run-app.sh` is not.

## Proof

- File edits: `git -C <sandbox> status` is dirty; primary `git status --porcelain` is unchanged aside from ignored sandbox dirs.
- Tests: `swift test` output from the sandbox path.
- GUI: `identity` shows `linked_worktree=yes`, `bundle_id=io.remotecode.desktop.debug`, `http_port=18218`, and the running executable is `dist/RemoteCodeDebug.app/Contents/MacOS/RemoteCode`.
