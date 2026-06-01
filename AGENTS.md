# RemoteCode macOS Rules

- Browser parity is mandatory: every macOS browser URL change must emit host state so iOS mirrors the same target.
- External URLs, localhost/dev-server URLs, and macOS file URLs must stay synchronized between macOS and iOS.
- Browser target changes on either side must propagate to the paired side, or the control must stay host-driven/read-only.
- Do not add browser behavior that only works on one side without updating the other side in the same change.
- User workflow state must survive closing and reopening RemoteCode. Persist the user's active workspace, panes, selected tabs, browser URLs/titles, surface metadata, agent thread state, and other explicit user choices unless the user intentionally closes/deletes them.

## macOS crash / long-running terminal diagnostics

- For reports that RemoteCode closes while a long Claude terminal or Agent run is active, first collect unified logs from the app diagnostics subsystems:
  ```bash
  log stream --style compact --predicate 'subsystem == "io.remotecode.app" || subsystem == "io.remotecode.surfaces" || subsystem == "io.remotecode.agent"'
  ```
- After an unexpected close, capture the recent persisted log window:
  ```bash
  log show --last 30m --style compact --predicate 'process == "RemoteCode" && subsystem BEGINSWITH "io.remotecode"'
  ```
- Check for crash reports before guessing root cause:
  ```bash
  ls -lt ~/Library/Logs/DiagnosticReports/*RemoteCode* | head
  ```
- Also check for stale Claude provider processes. Orphaned `ClaudeAgentSDKBridge.mjs` and Claude SDK child processes can accumulate across app sessions and create memory pressure:
  ```bash
  ps -axo pid,ppid,rss,etime,args | awk '/ClaudeAgentSDKBridge\\.mjs|claude --output-format stream-json|claude --dangerously-skip-permissions/ && !/awk/ {print}'
  ```
- Useful log events added for this class of issue: `app.heartbeat`, `app.will_terminate`, `terminal.spawned`, `terminal.output_health`, `terminal.pty_eof`, `terminal.dead`, and `terminal.close`. These intentionally log IDs, PIDs, counts, RSS, statuses, and byte totals, not terminal contents or secrets.
