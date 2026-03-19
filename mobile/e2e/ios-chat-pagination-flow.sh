#!/usr/bin/env bash
set -euo pipefail

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

get_text() {
	local test_id="$1"
	local node_json
	node_json="$(node_json_by_id "${test_id}")"
	if [[ -z "${node_json}" ]]; then
		return 1
	fi

	printf "%s\n" "${node_json}" | jq -r '.value // .label // ""'
}

fill() {
	local test_id="$1"
	local value="$2"
	ad find id "${test_id}" fill "${value}" >/dev/null
	dismiss_keyboard_tip_if_present
}

wait_for() {
	local test_id="$1"
	local timeout_ms="${2:-30000}"
	local elapsed=0

	while [ "${elapsed}" -lt "${timeout_ms}" ]; do
		dismiss_alert_if_present
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
		if ! exists "${test_id}"; then
			return 0
		fi

		pause_ms 500
		elapsed=$((elapsed + 500))
	done

	echo "Expected ${test_id} to disappear within ${timeout_ms}ms." >&2
	return 1
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

tap_nav_back_if_present() {
	if exists "nav-back"; then
		click "nav-back"
		pause_ms 800
	fi
}

wait_for_settings_screen() {
	dismiss_alert_if_present
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		if exists "server-manual-connect" || exists "screen-workspaces" || exists "screen-threads" || exists "screen-chat"; then
			return 0
		fi
		pause_ms 1200
	done

	echo "Unable to reach the server connection screen." >&2
	return 1
}

connect_and_open_workspaces() {
	wait_for_settings_screen
	if exists "screen-workspaces" || exists "screen-threads"; then
		return 0
	fi

	echo "Connecting mobile app to e2e backend (${BASE_URL})..."
	if exists "server-manual-connect"; then
		fill "server-manual-base-url" "${MANUAL_CONNECTION_TARGET}"
		click "server-manual-connect"
	elif ! exists "server-item-0" && exists "server-scan-button"; then
		click "server-scan-button"
		wait_for "server-item-0" 20000
	fi
	if ! exists "screen-workspaces" && ! exists "screen-threads" && exists "server-item-0"; then
		click "server-item-0"
	fi
	dismiss_alert_if_present
	wait_for "screen-workspaces" 40000
}

ensure_threads_screen() {
	for _ in 1 2 3 4 5 6 7 8; do
		if exists "screen-threads"; then
			return 0
		fi

		if exists "screen-chat" || exists "screen-active-threads"; then
			tap_nav_back_if_present
			pause_ms 1000
			continue
		fi

		if exists "screen-workspaces" && exists "workspace-item-0"; then
			click "workspace-item-0"
			pause_ms 1200
			continue
		fi

		pause_ms 1000
	done

	echo "Unable to reach screen-threads." >&2
	return 1
}

open_thread_by_chat_id() {
	local chat_id="$1"
	local timeout_ms="${2:-25000}"
	wait_for "thread-item-chat-${chat_id}" "${timeout_ms}"
	click "thread-item-chat-${chat_id}"
	wait_for "screen-chat" 15000
}

wait_for_message_row() {
	local message_id="$1"
	local timeout_ms="${2:-20000}"
	wait_for "chat-message-row-${message_id}" "${timeout_ms}"
}

wait_for_message_row_absent() {
	local message_id="$1"
	local timeout_ms="${2:-20000}"
	wait_until_absent "chat-message-row-${message_id}" "${timeout_ms}"
}

scroll_until_message_visible() {
	local message_id="$1"
	local timeout_ms="${2:-25000}"
	local elapsed=0

	while [ "${elapsed}" -lt "${timeout_ms}" ]; do
		if exists "chat-message-row-${message_id}"; then
			return 0
		fi

		ad scroll up 0.92 >/dev/null 2>&1 || true
		pause_ms 700
		if exists "chat-older-messages-loading"; then
			pause_ms 1200
		fi
		if exists "chat-message-row-${message_id}"; then
			return 0
		fi

		ad scroll down 0.92 >/dev/null 2>&1 || true
		pause_ms 500
		elapsed=$((elapsed + 2400))
	done

	echo "Unable to reveal message row ${message_id}." >&2
	return 1
}

scroll_until_latest_restored() {
	local latest_marker_id="$1"
	local older_marker_id="$2"
	local timeout_ms="${3:-25000}"
	local elapsed=0

	while [ "${elapsed}" -lt "${timeout_ms}" ]; do
		if exists "chat-message-row-${latest_marker_id}" && ! exists "chat-message-row-${older_marker_id}"; then
			return 0
		fi

		ad scroll down 0.92 >/dev/null 2>&1 || true
		pause_ms 700
		ad scroll up 0.50 >/dev/null 2>&1 || true
		pause_ms 500
		elapsed=$((elapsed + 2400))
	done

	echo "Unable to restore the latest message window." >&2
	return 1
}

assert_rows_present() {
	for message_id in "$@"; do
		wait_for_message_row "${message_id}" 20000
	done
}

assert_rows_absent() {
	for message_id in "$@"; do
		wait_for_message_row_absent "${message_id}" 20000
	done
}

PAGED_CHAT_ID="$(jq -r '.chats.paged.id' "${STATE_PATH}")"
LATEST_PAGE_IDS=()
while IFS= read -r message_id; do
	LATEST_PAGE_IDS+=("${message_id}")
done < <(jq -r '.chats.paged.latestPageMessageIds[]' "${STATE_PATH}")
OLDER_PAGE_IDS=()
while IFS= read -r message_id; do
	OLDER_PAGE_IDS+=("${message_id}")
done < <(jq -r '.chats.paged.olderPageMessageIds[]' "${STATE_PATH}")

SOCKET_MESSAGE="socket-pagination-check-$(date +%s)"

echo "Opening RemoteCode on iOS simulator for pagination flow..."
open_app
pause_ms 1600
dismiss_alert_if_present

connect_and_open_workspaces
ensure_threads_screen

echo "Opening paged thread..."
open_thread_by_chat_id "${PAGED_CHAT_ID}" 30000
dismiss_alert_if_present

echo "Validating latest page only..."
assert_rows_present "${LATEST_PAGE_IDS[@]}"
assert_rows_absent "${OLDER_PAGE_IDS[@]}"

echo "Loading older page..."
scroll_until_message_visible "${OLDER_PAGE_IDS[0]}" 30000
assert_rows_present "${OLDER_PAGE_IDS[@]}"
assert_rows_absent "${LATEST_PAGE_IDS[@]}"

echo "Triggering external websocket message while older page is visible..."
bun run "${STATE_PATH%/*}/send-chat-message.ts" "${BASE_URL}" "${PAGED_CHAT_ID}" "${SOCKET_MESSAGE}"
wait_for "chat-latest-dirty-indicator" 30000

echo "Re-checking that the visible page stayed capped to the older page..."
assert_rows_present "${OLDER_PAGE_IDS[@]}"
assert_rows_absent "${LATEST_PAGE_IDS[@]}"

echo "Returning to the latest page and verifying the old page was evicted..."
scroll_until_latest_restored "${LATEST_PAGE_IDS[4]}" "${OLDER_PAGE_IDS[0]}" 30000
wait_until_absent "chat-latest-dirty-indicator" 30000
assert_rows_absent "${OLDER_PAGE_IDS[@]}"
wait_for "chat-run-details-toggle" 20000
ad wait text "${SOCKET_MESSAGE}" 30000 >/dev/null
ad wait text "E2E assistant reply" 30000 >/dev/null

echo "iOS chat pagination flow passed."
