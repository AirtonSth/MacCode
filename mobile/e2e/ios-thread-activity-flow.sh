#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${RC_APP_NAME:-io.remotecode}"
SESSION_NAME="${RC_AD_SESSION:-rc-e2e-thread-activity}"
BASE_URL="${RC_E2E_BASE_URL:-http://127.0.0.1:8835}"
STATE_PATH="${RC_IOS_E2E_STATE_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.ios-e2e-state.json}"
AD_TIMEOUT_SECONDS="${RC_AD_TIMEOUT_SECONDS:-60}"
AD_MAX_RETRIES="${RC_AD_MAX_RETRIES:-3}"

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
		local command=("${AD[@]}" --platform ios --session "${SESSION_NAME}" "$@")
		local capture_file
		capture_file="$(mktemp "${TMPDIR:-/tmp}/agent-device-capture.XXXXXX")"
		set +e
		AD_EXPECT_TIMEOUT="${AD_TIMEOUT_SECONDS}" expect -f /dev/stdin -- "${command[@]}" >"${capture_file}" 2>&1 <<'EOF'
set timeout $env(AD_EXPECT_TIMEOUT)
set cmd $argv
spawn -noecho {*}$cmd
set child_pid [exp_pid -i $spawn_id]
expect {
	eof {}
	timeout {
		catch { close -i $spawn_id }
		catch { exec kill -TERM $child_pid }
		after 1000
		catch { exec kill -KILL $child_pid }
		puts stderr "agent-device command timed out after $env(AD_EXPECT_TIMEOUT)s: [join $cmd { }]"
		exit 124
	}
}
catch wait result
set exit_code [lindex $result 3]
if {$exit_code eq ""} {
	set exit_code 0
}
exit $exit_code
EOF
		status=$?
		set -e
		output="$(cat "${capture_file}" 2>/dev/null || true)"
		rm -f "${capture_file}"
		output="${output//$'\r'/}"
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

snapshot_json() {
	ad snapshot --json
}

full_snapshot_json() {
	ad snapshot --json
}

node_json_by_id() {
	local test_id="$1"
	local node_json
	node_json="$(snapshot_json | jq -c --arg test_id "${test_id}" 'first(.data.nodes[] | select(.identifier? == $test_id)) // empty')"
	if [[ -n "${node_json}" ]]; then
		printf "%s\n" "${node_json}"
		return 0
	fi

	full_snapshot_json | jq -c --arg test_id "${test_id}" 'first(.data.nodes[] | select(.identifier? == $test_id)) // empty'
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
	[[ -n "$(node_json_by_id "${test_id}")" ]]
}

click() {
	local test_id="$1"
	local node_json
	node_json="$(node_json_by_id "${test_id}")"
	if [[ -z "${node_json}" ]]; then
		echo "Unable to find node for ${test_id}." >&2
		return 1
	fi

	local coords
	coords="$(node_center_from_json "${node_json}")"
	if [[ -z "${coords}" ]]; then
		echo "Unable to resolve tap coordinates for ${test_id}." >&2
		return 1
	fi

	local x y
	read -r x y <<< "${coords}"
	ad press "${x}" "${y}" >/dev/null
}

fill() {
	local test_id="$1"
	local value="$2"
	local node_json
	node_json="$(node_json_by_id "${test_id}")"
	if [[ -z "${node_json}" ]]; then
		echo "Unable to find text field ${test_id}." >&2
		return 1
	fi

	local coords
	coords="$(node_center_from_json "${node_json}")"
	if [[ -z "${coords}" ]]; then
		echo "Unable to resolve focus coordinates for ${test_id}." >&2
		return 1
	fi

	local x y
	read -r x y <<< "${coords}"
	ad focus "${x}" "${y}" >/dev/null
	ad type "${value}" >/dev/null
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
		if exists "${test_id}"; then
			return 0
		fi

		ad wait 500 >/dev/null
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
		dismiss_alert_if_present
		if exists "thread-item-title-${index}"; then
			local content
			content="$(get_text "thread-item-title-${index}" | tr -d '\r' || true)"
			if [[ "${content}" == "${expected}" ]]; then
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

open_thread_by_chat_id() {
	local chat_id="$1"
	local timeout_ms="${2:-25000}"
	wait_for "thread-item-chat-${chat_id}" "${timeout_ms}"
	click "thread-item-chat-${chat_id}"
	wait_for "screen-chat" 15000
}

dismiss_alert_if_present() {
	local node_json
	node_json="$(full_node_json_by_label "Don’t Allow")"
	if [[ -z "${node_json}" ]]; then
		node_json="$(full_node_json_by_label "Don't Allow")"
	fi
	if [[ -n "${node_json}" ]]; then
		local coords
		coords="$(node_center_from_json "${node_json}")"
		if [[ -n "${coords}" ]]; then
			local x y
			read -r x y <<< "${coords}"
			ad press "${x}" "${y}" >/dev/null 2>&1 || true
		fi
	fi
	ad wait 400 >/dev/null
}

dismiss_keyboard_tip_if_present() {
	local node_json
	node_json="$(node_json_by_label "Continue")"
	if [[ -z "${node_json}" ]]; then
		return 0
	fi

	local coords
	coords="$(node_center_from_json "${node_json}")"
	if [[ -z "${coords}" ]]; then
		return 0
	fi

	local x y
	read -r x y <<< "${coords}"
	ad press "${x}" "${y}" >/dev/null 2>&1 || true
	ad wait 400 >/dev/null
}

wait_for_settings_screen() {
	dismiss_alert_if_present
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		if exists "server-manual-connect"; then
			return 0
		fi
		if exists "screen-workspaces"; then
			return 0
		fi
		ad wait 1200 >/dev/null
	done

	dismiss_alert_if_present
	if exists "server-manual-connect" || exists "screen-workspaces"; then
		return 0
	fi

	echo "Unable to reach the server connection screen." >&2
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
	if ! exists "server-item-0" && exists "server-scan-button"; then
		click "server-scan-button"
		wait_for "server-item-0" 20000
	fi
	if exists "server-item-0"; then
		click "server-item-0"
	else
		echo "Unable to discover the iOS e2e backend via LAN Discovery." >&2
		return 1
	fi
	dismiss_alert_if_present
	wait_for "screen-workspaces" 40000
}

echo "Opening RemoteCode on iOS simulator..."
ad open "${APP_NAME}" >/dev/null
ad wait 1600 >/dev/null
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
ad wait 3500 >/dev/null

tap_nav_back_if_present
wait_for "screen-threads" 15000

wait_for_thread_title_at_index "0" "Idle Bottom" 30000

echo "iOS thread activity flow passed."
ad close "${APP_NAME}" >/dev/null || true
ad close >/dev/null || true
