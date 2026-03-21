#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${RC_APP_NAME:-RemoteCode}"
SESSION_NAME="${RC_AD_SESSION:-rc-e2e-terminal}"
STATE_PATH="${RC_IOS_E2E_STATE_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.ios-e2e-state.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${AGENT_DEVICE_BIN:-}" ]; then
	# shellcheck disable=SC2206
	AD=(${AGENT_DEVICE_BIN})
else
	AD=(npx -y agent-device)
fi

ad() {
	"${AD[@]}" --platform ios --session "${SESSION_NAME}" "$@"
}

exists() {
	local test_id="$1"
	ad is exists "id=\"${test_id}\"" >/dev/null 2>&1
}

click() {
	local test_id="$1"
	ad click "id=\"${test_id}\"" >/dev/null
}

fill() {
	local test_id="$1"
	local value="$2"
	ad fill "id=\"${test_id}\"" "${value}" >/dev/null
}

get_text() {
	local test_id="$1"
	ad get text "id=\"${test_id}\""
}

type_text() {
	local value="$1"
	ad type "${value}" >/dev/null
}

wait_for() {
	local test_id="$1"
	local timeout_ms="${2:-30000}"
	ad wait "id=\"${test_id}\"" "${timeout_ms}" >/dev/null
}

open_chat_from_threads() {
	for _ in 1 2 3; do
		if exists "screen-chat"; then
			return 0
		fi

		if exists "thread-item-0"; then
			click "thread-item-0" || true
		else
			click "threads-new-button" || true
		fi

		if ad wait 'id="screen-chat"' 12000 >/dev/null 2>&1; then
			return 0
		fi
	done

	echo "Unable to open chat from threads" >&2
	return 1
}

ensure_chat() {
	if exists "screen-chat"; then
		return 0
	fi

	if exists "screen-settings"; then
		click "server-continue-button" || true
		ad wait 1000 >/dev/null
	fi

	if exists "screen-workspaces"; then
		wait_for "workspace-item-0"
		click "workspace-item-0"
		wait_for "screen-threads"
	fi

	if exists "screen-threads"; then
		open_chat_from_threads
	fi

	wait_for "screen-chat"
}

echo "Opening app on iOS simulator..."
ad open "${APP_NAME}" >/dev/null
ad wait 1200 >/dev/null

ensure_chat

echo "Opening terminal modal..."
click "chat-terminal-open-button"
wait_for "terminal-modal"
wait_for "terminal-session-cwd"

expected_initial_cwd="$(jq -r '.terminal.expectedInitialCwd' "${STATE_PATH}")"
expected_parent_cwd="$(jq -r '.terminal.expectedParentCwd' "${STATE_PATH}")"
current_cwd="$(get_text "terminal-session-cwd" | tr -d '\r' || true)"

if [[ "${current_cwd}" != "${expected_initial_cwd}" ]]; then
	echo "Unexpected initial terminal cwd: ${current_cwd} (expected ${expected_initial_cwd})" >&2
	exit 1
fi

echo "Changing directory inside the PTY session..."
click "terminal-surface"
type_text $'cd ..\n'
ad wait 1200 >/dev/null
updated_cwd="$(get_text "terminal-session-cwd" | tr -d '\r' || true)"
if [[ "${updated_cwd}" != "${expected_parent_cwd}" ]]; then
	echo "Terminal cwd did not change after cd ..: ${updated_cwd} (expected ${expected_parent_cwd})" >&2
	exit 1
fi

echo "Starting long-running command from mobile terminal..."
click "terminal-surface"
type_text $'while true; do printf '\''RC_MOBILE_TICK\\n'\''; sleep 1; done\n'
bun run "${SCRIPT_DIR}/terminal-session-observer.ts" wait-output "RC_MOBILE_TICK" "RC_MOBILE_TICK" 20000

echo "Interrupting long-running command from mobile terminal..."
click "terminal-interrupt-button"
ad wait 1000 >/dev/null

echo "Verifying the shell stays alive after interrupt..."
bun run "${SCRIPT_DIR}/terminal-session-observer.ts" roundtrip $'echo RC_MOBILE_AFTER_INTERRUPT\n' "RC_MOBILE_AFTER_INTERRUPT" 20000

echo "Closing and reopening terminal modal..."
click "nav-back"
wait_for "screen-chat"
click "chat-terminal-open-button"
wait_for "terminal-modal"
reopened_cwd="$(get_text "terminal-session-cwd" | tr -d '\r' || true)"
if [[ "${reopened_cwd}" != "${expected_parent_cwd}" ]]; then
	echo "Terminal cwd was not preserved after closing and reopening: ${reopened_cwd}" >&2
	exit 1
fi

echo "Restarting terminal session..."
click "terminal-restart-button"
ad wait 1500 >/dev/null
restarted_cwd="$(get_text "terminal-session-cwd" | tr -d '\r' || true)"
if [[ "${restarted_cwd}" != "${expected_initial_cwd}" ]]; then
	echo "Terminal restart did not restore the initial cwd: ${restarted_cwd}" >&2
	exit 1
fi

echo "Closing terminal modal..."
click "nav-back"
wait_for "screen-chat"

echo "Terminal modal flow passed."
ad close >/dev/null || true
