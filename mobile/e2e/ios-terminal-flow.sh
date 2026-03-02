#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${RC_APP_NAME:-RemoteCode}"
SESSION_NAME="${RC_AD_SESSION:-rc-e2e-terminal}"

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
fill "chat-input" "draft message stays here"
click "chat-terminal-open-button"
wait_for "terminal-modal"

echo "Running terminal command..."
fill "terminal-command-input" "echo remotecode-ios-e2e"
click "terminal-run-button"
ad wait 1500 >/dev/null

echo "Closing terminal modal..."
click "nav-back"
wait_for "screen-chat"

echo "Terminal modal flow passed."
ad close >/dev/null || true
