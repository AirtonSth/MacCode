#!/usr/bin/env bash
set -euo pipefail

ran=0

require_text() {
  local label="$1"
  local text="$2"
  local needle="$3"
  if ! grep -F -- "$needle" <<<"$text" >/dev/null; then
    echo "FAIL: $label missing '$needle'" >&2
    return 1
  fi
}

if command -v claude >/dev/null 2>&1; then
  ran=1
  claude_version="$(claude --version 2>&1)"
  claude_help="$(claude --help 2>&1)"
  require_text "claude --help" "$claude_help" "--print"
  require_text "claude --help" "$claude_help" "--output-format"
  require_text "claude --help" "$claude_help" "--permission-mode"
  require_text "claude --help" "$claude_help" "--tools"
  require_text "claude --help" "$claude_help" "--effort"
  echo "PASS: claude smoke: $claude_version"
else
  echo "SKIP: claude binary not found"
fi

if command -v codex >/dev/null 2>&1; then
  ran=1
  codex_version="$(codex --version 2>&1)"
  codex_help="$(codex --help 2>&1)"
  codex_exec_help="$(codex exec --help 2>&1)"
  codex_resume_help="$(codex exec resume --help 2>&1)"
  codex_app_server_help="$(codex app-server --help 2>&1)"
  require_text "codex --help" "$codex_help" "app-server"
  require_text "codex exec --help" "$codex_exec_help" "resume"
  require_text "codex exec --help" "$codex_exec_help" "--model"
  require_text "codex exec --help" "$codex_exec_help" "--sandbox"
  require_text "codex exec resume --help" "$codex_resume_help" "SESSION_ID"
  require_text "codex app-server --help" "$codex_app_server_help" "app-server"
  echo "PASS: codex smoke: $codex_version"
else
  echo "SKIP: codex binary not found"
fi

if command -v grok >/dev/null 2>&1; then
  ran=1
  grok_version="$(grok --version 2>&1)"
  grok_help="$(grok --help 2>&1)"
  require_text "grok --help" "$grok_help" "--output-format"
  require_text "grok --help" "$grok_help" "streaming-json"
  require_text "grok --help" "$grok_help" "--permission-mode"
  require_text "grok --help" "$grok_help" "--resume"
  require_text "grok --help" "$grok_help" "--model"
  require_text "grok --help" "$grok_help" "--single"
  require_text "grok --help" "$grok_help" "agent"
  echo "PASS: grok smoke: $grok_version"
else
  echo "SKIP: grok binary not found"
fi

if [[ "$ran" -eq 0 ]]; then
  echo "SKIP: no provider binaries found; lane is gated by installed binaries"
fi
