#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${RC_APP_NAME:-io.remotecode}"
SESSION_NAME="${RC_AD_SESSION:-rc-e2e-thread-activity}"
BASE_URL="${RC_E2E_BASE_URL:-http://127.0.0.1:8835}"
AD_TIMEOUT_SECONDS="${RC_AD_TIMEOUT_SECONDS:-25}"
AD_MAX_RETRIES="${RC_AD_MAX_RETRIES:-2}"

if [ -n "${AGENT_DEVICE_BIN:-}" ]; then
	# shellcheck disable=SC2206
	AD=(${AGENT_DEVICE_BIN})
else
	AD=(npx -y agent-device)
fi

ad() {
	local attempt=1
	local status=0
	local output=""

	while true; do
		output="$(gtimeout "${AD_TIMEOUT_SECONDS}" "${AD[@]}" --platform ios --session "${SESSION_NAME}" "$@" 2>&1)"
		status=$?
		if [[ "${status}" -eq 0 && "${output}" != *"Error (COMMAND_FAILED):"* && "${output}" != *"Error (NO_SESSION):"* ]]; then
			if [[ -n "${output}" ]]; then
				printf "%s\n" "${output}"
			fi
			return 0
		fi

		if [[ -n "${output}" ]]; then
			printf "%s\n" "${output}" >&2
		fi

		if [[ "${attempt}" -ge "${AD_MAX_RETRIES}" ]]; then
			return 1
		fi

		attempt=$((attempt + 1))
		sleep 1
	done
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

wait_for() {
	local test_id="$1"
	local timeout_ms="${2:-30000}"
	ad wait "id=\"${test_id}\"" "${timeout_ms}" >/dev/null
}

wait_until_absent() {
	local test_id="$1"
	local timeout_ms="${2:-20000}"
	local elapsed=0

	while [ "${elapsed}" -lt "${timeout_ms}" ]; do
		if ! exists "${test_id}"; then
			return 0
		fi

		ad wait 500 >/dev/null
		elapsed=$((elapsed + 500))
	done

	echo "Expected ${test_id} to disappear within ${timeout_ms}ms." >&2
	return 1
}

wait_for_thread_title_at_index() {
	local index="$1"
	local expected="$2"
	local timeout_ms="${3:-25000}"
	local elapsed=0

	while [ "${elapsed}" -lt "${timeout_ms}" ]; do
		if exists "thread-item-title-${index}"; then
			local content
			content="$(get_text "thread-item-title-${index}" | tr -d '\r' || true)"
			if [[ "${content}" == *"${expected}"* ]]; then
				return 0
			fi
		fi

		ad wait 500 >/dev/null
		elapsed=$((elapsed + 500))
	done

	local actual
	actual="$(get_text "thread-item-title-${index}" | tr -d '\r' || true)"
	echo "Expected thread-item-title-${index} to contain '${expected}', got '${actual}'." >&2
	return 1
}

dismiss_alert_if_present() {
	gtimeout 5 "${AD[@]}" --platform ios --session "${SESSION_NAME}" alert dismiss >/dev/null 2>&1 || true
	ad wait 400 >/dev/null
}

wait_for_settings_screen() {
	dismiss_alert_if_present
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		if exists "screen-workspaces"; then
			return 0
		fi
		if exists "screen-settings"; then
			return 0
		fi
		ad wait 1200 >/dev/null
	done

	dismiss_alert_if_present
	if exists "screen-workspaces" || exists "screen-settings"; then
		return 0
	fi

	echo "Unable to reach screen-settings." >&2
	return 1
}

tap_nav_back_if_present() {
	if exists "nav-back"; then
		click "nav-back"
		ad wait 800 >/dev/null
	fi
}

ensure_threads_screen() {
	for _ in 1 2 3 4 5 6 7 8; do
		if exists "screen-threads"; then
			return 0
		fi

		if exists "screen-chat"; then
			tap_nav_back_if_present
			ad wait 1000 >/dev/null
			continue
		fi

		if exists "screen-active-threads"; then
			tap_nav_back_if_present
			ad wait 1000 >/dev/null
			continue
		fi

		if exists "screen-workspaces"; then
			if exists "workspace-item-0"; then
				click "workspace-item-0"
				ad wait 1200 >/dev/null
				continue
			fi
		fi

		ad wait 1000 >/dev/null
	done

	echo "Unable to reach screen-threads." >&2
	return 1
}

connect_and_open_workspaces() {
	wait_for_settings_screen
	if exists "screen-workspaces"; then
		return 0
	fi

	echo "Connecting mobile app to e2e backend (${BASE_URL})..."
	dismiss_alert_if_present
	fill "server-manual-base-url" "${BASE_URL}"
	click "server-manual-connect"
	dismiss_alert_if_present
	wait_for "screen-workspaces" 40000
}

echo "Opening RemoteCode on iOS simulator..."
ad open "${APP_NAME}" >/dev/null
ad wait 1600 >/dev/null
dismiss_alert_if_present

connect_and_open_workspaces

echo "Opening workspace thread list..."
wait_for "workspace-item-0" 15000
click "workspace-item-0"
dismiss_alert_if_present
wait_for "screen-threads" 15000

echo "Opening active thread from thread list..."
wait_for "thread-item-0" 15000
click "thread-item-0"
dismiss_alert_if_present
wait_for "screen-chat" 15000
wait_for "chat-bottom-working-indicator" 15000

echo "Validating force stop appears while thread is active..."
wait_for "chat-force-stop-button" 15000
click "chat-force-stop-button"
wait_until_absent "chat-bottom-working-indicator" 25000
wait_for "chat-send-button" 15000

echo "Returning to Threads list and validating active badge cleared..."
tap_nav_back_if_present
ensure_threads_screen
wait_for "screen-threads" 15000
if exists "thread-item-status-0"; then
	echo "Expected first thread to be inactive after force stop." >&2
	exit 1
fi

echo "Sending message from idle thread to validate reorder-to-top..."
wait_for "thread-item-2" 15000
click "thread-item-2"
dismiss_alert_if_present
wait_for "screen-chat" 15000
fill "chat-input" "move-thread-to-top"
click "chat-send-button"
ad wait 3500 >/dev/null

tap_nav_back_if_present
wait_for "screen-threads" 15000

wait_for_thread_title_at_index "0" "Idle Bottom" 30000

echo "iOS thread activity flow passed."
ad close >/dev/null || true
