#!/usr/bin/env bash
set -euo pipefail

if [[ "${RC_IOS_E2E_TRACE:-0}" == "1" ]]; then
	set -x
fi

APP_NAME="${RC_APP_NAME:-io.remotecode}"
SESSION_NAME="${RC_AD_SESSION:-rc-e2e-thread-activity}"
BASE_URL="${RC_E2E_BASE_URL:-http://127.0.0.1:8835}"
TOKEN="${RC_E2E_TOKEN:-local-dev-token}"
MANUAL_CONNECTION_TARGET="${BASE_URL#*://}"
MANUAL_CONNECTION_TARGET="${MANUAL_CONNECTION_TARGET%%/*}"
STATE_PATH="${RC_IOS_E2E_STATE_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.ios-e2e-state.json}"
AD_TIMEOUT_SECONDS="${RC_AD_TIMEOUT_SECONDS:-60}"
AD_MAX_RETRIES="${RC_AD_MAX_RETRIES:-3}"
IOS_SIMULATOR_UDID="${RC_IOS_SIMULATOR_UDID:-}"

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
		local command=("${AD[@]}" --platform ios)
		if [[ -n "${IOS_SIMULATOR_UDID}" ]]; then
			command+=(--udid "${IOS_SIMULATOR_UDID}")
		else
			command+=(--session "${SESSION_NAME}")
		fi
		command+=("$@")
		set +e
		output="$(gtimeout "${AD_TIMEOUT_SECONDS}" "${command[@]}" 2>&1)"
		status=$?
		set -e
		output="${output//$'\r'/}"
		if [[ "${status}" -eq 124 ]]; then
			echo "agent-device command timed out after ${AD_TIMEOUT_SECONDS}s: ${command[*]}" >&2
		fi
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

pause_ms() {
	perl -e 'select(undef, undef, undef, ($ARGV[0] || 0) / 1000)' "$1"
}

build_auto_connect_deep_link() {
	local encoded_base_url
	local encoded_token
	encoded_base_url="$(jq -rn --arg value "${BASE_URL}" '$value|@uri')"
	encoded_token="$(jq -rn --arg value "${TOKEN}" '$value|@uri')"
	printf 'remotecode-mobile:///settings?debugAutoConnect=1&debugBaseUrl=%s&debugToken=%s' "${encoded_base_url}" "${encoded_token}"
}

snapshot_json() {
	ad snapshot -i --json
}

full_snapshot_json() {
	ad snapshot --json
}

get_router_error_message() {
	local node_json
	node_json="$(node_json_by_id "router_error_message" || true)"
	if [[ -z "${node_json}" ]]; then
		return 1
	fi

	printf "%s\n" "${node_json}" | jq -r '.label // .value // ""'
}

fail_if_router_error_present() {
	local router_error_message
	router_error_message="$(get_router_error_message || true)"
	if [[ -z "${router_error_message}" ]]; then
		return 0
	fi

	echo "Mobile app crashed into the router error screen." >&2
	echo "Router error: ${router_error_message}" >&2
	return 1
}

node_json_by_id() {
	local test_id="$1"
	snapshot_json | jq -c --arg test_id "${test_id}" 'first(.data.nodes[] | select(.identifier? == $test_id)) // empty'
}

node_json_by_label() {
	local label="$1"
	snapshot_json | jq -c --arg label "${label}" 'first(.data.nodes[] | select(.label? == $label)) // empty'
}

full_node_json_by_label() {
	local label="$1"
	full_snapshot_json | jq -c --arg label "${label}" 'first(.data.nodes[] | select(.label? == $label)) // empty'
}

node_center_from_json() {
	local node_json="$1"
	if [[ -z "${node_json}" ]]; then
		return 1
	fi

	printf "%s\n" "${node_json}" | jq -r 'if .rect? then "\((.rect.x + (.rect.width / 2)) | floor) \((.rect.y + (.rect.height / 2)) | floor)" else empty end'
}

exists() {
	local test_id="$1"
	local node_json
	node_json="$(node_json_by_id "${test_id}" || true)"
	[[ -n "${node_json}" ]]
}

click() {
	local test_id="$1"
	ad find id "${test_id}" click >/dev/null
}

open_app() {
	if [[ -n "${IOS_SIMULATOR_UDID}" ]]; then
		local deep_link
		deep_link="$(build_auto_connect_deep_link)"
		xcrun simctl terminate "${IOS_SIMULATOR_UDID}" "${APP_NAME}" >/dev/null 2>&1 || true
		xcrun simctl launch "${IOS_SIMULATOR_UDID}" "${APP_NAME}" >/dev/null
		xcrun simctl openurl "${IOS_SIMULATOR_UDID}" "${deep_link}" >/dev/null
		return 0
	fi

	ad open "${APP_NAME}" >/dev/null
}

fill() {
	local test_id="$1"
	local value="$2"
	ad find id "${test_id}" fill "${value}" >/dev/null
	dismiss_keyboard_tip_if_present
}

get_text() {
	local test_id="$1"
	local node_json
	node_json="$(node_json_by_id "${test_id}")"
	if [[ -z "${node_json}" ]]; then
		return 1
	fi

	printf "%s\n" "${node_json}" | jq -r '.value // .label // ""'
}

wait_for() {
	local test_id="$1"
	local timeout_ms="${2:-30000}"
	local elapsed=0

	while [ "${elapsed}" -lt "${timeout_ms}" ]; do
		dismiss_alert_if_present
		fail_if_router_error_present
		if exists "${test_id}"; then
			return 0
		fi

		pause_ms 500
		elapsed=$((elapsed + 500))
	done

	echo "Expected ${test_id} to appear within ${timeout_ms}ms." >&2
	return 1
}

wait_until_absent() {
	local test_id="$1"
	local timeout_ms="${2:-20000}"
	local elapsed=0

	while [ "${elapsed}" -lt "${timeout_ms}" ]; do
		dismiss_alert_if_present
		fail_if_router_error_present
		if ! exists "${test_id}"; then
			return 0
		fi

		pause_ms 500
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
		dismiss_alert_if_present
		fail_if_router_error_present
		local title_text
		title_text="$(get_text "thread-item-title-${index}" || true)"
		if [[ "${title_text}" == *"${expected}"* ]]; then
			return 0
		fi

		pause_ms 500
		elapsed=$((elapsed + 500))
	done

	echo "Expected thread-item-title-${index} to contain '${expected}'." >&2
	return 1
}

open_thread_by_chat_id() {
	local chat_id="$1"
	local timeout_ms="${2:-25000}"
	wait_for "thread-item-chat-${chat_id}" "${timeout_ms}"
	click "thread-item-chat-${chat_id}"
	wait_for "screen-chat" 15000
}

dismiss_alert_if_present() {
	local label
	local node_json
	local center
	for label in "Open" "Allow" "Continue"; do
		node_json="$(node_json_by_label "${label}" || true)"
		if [[ -z "${node_json}" ]]; then
			continue
		fi
		center="$(node_center_from_json "${node_json}" || true)"
		if [[ -z "${center}" ]]; then
			continue
		fi
		ad press ${center} >/dev/null 2>&1 || true
		pause_ms 600
		return 0
	done

	return 0
}

dismiss_keyboard_tip_if_present() {
	local node_json
	local center
	node_json="$(node_json_by_label "Continue" || true)"
	if [[ -z "${node_json}" ]]; then
		return 0
	fi
	center="$(node_center_from_json "${node_json}" || true)"
	if [[ -z "${center}" ]]; then
		return 0
	fi
	ad press ${center} >/dev/null 2>&1 || true
	pause_ms 400
}

wait_for_settings_screen() {
	dismiss_alert_if_present
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		fail_if_router_error_present
		if exists "server-manual-connect"; then
			return 0
		fi
		if exists "screen-workspaces"; then
			return 0
		fi
		pause_ms 1200
	done

	dismiss_alert_if_present
	fail_if_router_error_present
	if exists "server-manual-connect" || exists "screen-workspaces"; then
		return 0
	fi

	echo "Unable to reach the server connection screen." >&2
	return 1
}

tap_nav_back_if_present() {
	if exists "nav-back"; then
		click "nav-back"
		pause_ms 800
	fi
}

ensure_threads_screen() {
	for _ in 1 2 3 4 5 6 7 8; do
		fail_if_router_error_present
		if exists "screen-threads"; then
			return 0
		fi

		if exists "screen-chat"; then
			tap_nav_back_if_present
			pause_ms 1000
			continue
		fi

		if exists "screen-active-threads"; then
			tap_nav_back_if_present
			pause_ms 1000
			continue
		fi

		if exists "screen-workspaces"; then
			if exists "workspace-item-0"; then
				click "workspace-item-0"
				pause_ms 1200
				continue
			fi
		fi

		pause_ms 1000
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

	# Prefer the manual local connection path for deterministic simulator runs.
	# LAN discovery is useful for ad hoc testing, but it is inherently less stable
	# than connecting directly to the known local backend used by the suite.
	if exists "server-manual-connect"; then
		fill "server-manual-base-url" "${MANUAL_CONNECTION_TARGET}"
		click "server-manual-connect"
	elif exists "server-item-0"; then
		click "server-item-0"
	elif exists "server-scan-button"; then
		click "server-scan-button"
		if wait_for "server-item-0" 20000; then
			click "server-item-0"
		elif exists "server-manual-connect"; then
			echo "LAN discovery did not resolve a server; falling back to manual connection."
			fill "server-manual-base-url" "${MANUAL_CONNECTION_TARGET}"
			click "server-manual-connect"
		else
			echo "Unable to discover the iOS e2e backend via LAN Discovery." >&2
			return 1
		fi
	else
		echo "No connection path is available on the server selection screen." >&2
		return 1
	fi
	dismiss_alert_if_present
	wait_for "screen-workspaces" 40000
}

echo "Opening RemoteCode on iOS simulator..."
open_app
pause_ms 1600
dismiss_alert_if_present

connect_and_open_workspaces

ACTIVE_THREAD_ID="$(jq -r '.chats.active.id' "${STATE_PATH}")"
IDLE_BOTTOM_ID="$(jq -r '.chats.idleBottom.id' "${STATE_PATH}")"
IDLE_BOTTOM_TITLE="$(jq -r '.chats.idleBottom.title' "${STATE_PATH}")"

echo "Opening workspace thread list..."
wait_for "workspace-item-0" 15000
click "workspace-item-0"
dismiss_alert_if_present
wait_for "screen-threads" 15000

echo "Opening active thread from thread list..."
open_thread_by_chat_id "${ACTIVE_THREAD_ID}" 30000
dismiss_alert_if_present
wait_for "screen-chat" 15000

echo "Validating force stop appears while thread is active..."
ad wait text "Working..." 15000 >/dev/null
wait_for "chat-force-stop-button" 15000
click "chat-force-stop-button"
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
open_thread_by_chat_id "${IDLE_BOTTOM_ID}" 30000
dismiss_alert_if_present
wait_for "screen-chat" 15000
fill "chat-input" "move-thread-to-top"
click "chat-send-button"
pause_ms 3500

tap_nav_back_if_present
wait_for "screen-threads" 15000

wait_for_thread_title_at_index "0" "Idle Bottom" 30000

echo "iOS thread activity flow passed."
ad close "${APP_NAME}" >/dev/null || true
ad close >/dev/null || true
