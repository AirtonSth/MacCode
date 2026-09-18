# Token Saver on Grok: PostToolUse output replacement (grok-build ≥ 1.0.34)

Status: shipped wiring (`installGrokPostToolUseHook` + `distill hook post-tool-use-grok`).
Verified 2026-09-17 against the installed `grok 1.0.34` binary (build 2026-09-16) and a live
`grok agent ... stdio` session.

## What changed upstream

Older notes said Grok's `PostToolUse` hook was fully passive (stdout ignored). That is no longer
true: a hook registered from a **settings-file** hook (`$GROK_HOME/hooks/*.json`, plugins, or the
`hooks` key of `settings.json`) can replace what the model reads:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "updatedToolOutput": { "type": "ReadFile", "FileContent": { "…": "…" } }
  }
}
```

Rules the binary documents and enforces:

- The replacement is validated against the ran tool's own serialized output shape; a mismatch throws
  the replacement away and keeps the original.
- MCP tool results are not shape-checked (`updatedToolOutput` passes through, like its
  `updatedMCPToolOutput` alias).
- The replacement is capped at 64 K characters; `additionalContext` / block reasons at 10 K.
- Hooks registered through the grok-agent-sdk can only add `additionalContext`; replacement is
  settings-file only.
- Fail-open on every error path (`… does not match the tool's output shape; keeping original`).

## Hook envelope (observed)

```json
{
  "hookEventName": "post_tool_use", "hook_event_name": "PostToolUse",
  "sessionId": "…", "cwd": "…", "workspaceRoot": "…", "transcriptPath": "…",
  "permissionMode": "…", "toolName": "read_file", "toolUseId": "call_…",
  "toolInput": { "…": "…" }, "toolInputTruncated": false,
  "toolResult": { "type": "ReadFile", "FileContent": { "content": "…" } },
  "toolResultTruncated": false, "durationMs": 0, "isBackgrounded": false,
  "tool_name": "read_file", "tool_input": {…}, "tool_response": {…}   // snake-case aliases
}
```

`toolResultTruncated` is authoritative: a truncated result never contains the full output, so the
hook returns `{}` instead of rewriting it.

## Result shapes (observed)

| Tool | `toolResult` |
| --- | --- |
| `read_file` | `{"type":"ReadFile","FileContent":{"content":str,"content_concise":str,"absolute_path":str,"offset":null,"raw_output":str,"total_lines":int}}` |
| `list_dir` | `{"type":"ListDir","Content":{"content":str,"absolute_root_path":str}}` |
| `web_fetch` | `{"type":"WebFetch","Content":{"url":str,"content":str,"content_type":str,"status_code":int,"bytes":int}}` |
| `run_terminal_command` | `{"type":"Bash","output":[bytes],"output_for_prompt":str,"exit_code":int,"command":str,"truncated":bool,"signal":null,"timed_out":bool,"description":str,"current_dir":str,"output_file":str,"total_bytes":int}` |
| `grep` | `{"type":"GrepSearch","stdout":[bytes],"stderr":[bytes],"exit_code":int,"match_count":int,"file_matches":[…]}` |
| `search_replace` | `{"type":"EditsApplied","old_string":str,"new_string":str,"tool_output_for_prompt":str,"tool_output_for_prompt_concise":str,"absolute_path":str,"edits":{…}}` |

The model reads `content` (ReadFile also mirrors it into `content_concise`). `raw_output` is left
untouched so recovery/diff paths keep exact bytes.

## In-tree implementation

- `ManagedDistillCLI.grokReplaceableShapes` — the only shapes the hook may rewrite; adding an entry
  requires reproducing that shape end to end, because an invalid replacement silently keeps the
  original (a no-op, not an error).
- `ManagedDistillCLI.hookPostToolUseGrok()` — `distill hook post-tool-use-grok`: policy gate →
  sidecar compression → receipt + `[[rc:<handle>]]` handle → same-shape replacement. Any failure
  returns `{}` and exit 0.
- `AgentSkillInstaller.installGrokPostToolUseHook()` — writes
  `$GROK_HOME/hooks/remotecode-token-saver-posttool.json` with matcher
  `read_file|list_dir|web_fetch`; removed whenever Token Saver is off.
- Deliberately excluded: `Bash` (byte-exact shell; the PATH wrapper / PreToolUse pipe lane owns it),
  `GrepSearch` (search matches) and `EditsApplied` (mutation output must stay exact).

## Why it matters

In a two-day local sample, Grok tool results were 45.6 MB, of which `read_file` alone was 48 %,
`web_fetch` 10 %, `grep` 10 %, `list_dir` 2.5 %. Only the shell class was reachable by the PATH
wrapper / PreToolUse pipe; the rest reached the model uncompressed on every turn. Codex still has no
equivalent lane: its `PostToolUse` hook output schema carries only `hookEventName` /
`additionalContext` / `updatedMCPToolOutput`, and the dispatcher rejects `updatedMCPToolOutput` as
unsupported (re-verified on codex-cli 0.154.0).

## End-to-end verification recipe

1. Run the service standalone against a scratch app-support dir (models optional with
   `REMOTE_CODE_DISTILL_ALLOW_TEST_RUNTIME=1`, which selects the deterministic router):
   `RemoteCodeDistillService --host 127.0.0.1 --port <p> --auth-token <t> --app-support-dir <dir>`.
2. Write `<dir>/Distill/DistillCLIState.json` (mode 600) with `base_url`, `auth_token`, `pid` of the
   running service, and a base64 32-byte `receipt_key`; put `app_settings` (with
   `tokenSaverEnabled: true`) and `private.account.session` (`{"user":{"subscribed":true}}`) in
   `<dir>/remotecode.sqlite`.
3. Pipe a captured Grok `post_tool_use` envelope into the built CLI with the env the app injects for
   admitted runs — `REMOTE_CODE_DISTILL_STATE_PATH`, `REMOTE_CODE_AGENT_PROVIDER=grok`,
   `RC_TOKEN_SAVER_DISTILL_HINT=1`, `RC_TOKEN_SAVER_ROOT_RUN_ID`, `RC_TOKEN_SAVER_THREAD_ID` —
   and inspect `hookSpecificOutput.updatedToolOutput`.
4. Wire the same command into `$GROK_HOME/hooks/` behind an env gate and drive a real
   `grok agent … stdio` session; the model then reads the compressed result.

Observed: a 6 125-byte repeated-line log compressed to 298 bytes in the CLI-only run (4.9 %,
`routeStage: deterministic`, receipt `[[rcd:v2.…]]`; `[[rc:<handle>]]` is appended only when the
sidecar stores a lossy original), and the same fixture delivered 1 670 bytes to the model in a live
session (72.7 % reduction — Grok's line-numbered rendering makes blocks less uniform than the raw
text).

