#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${RC_E2E_BASE_URL:-http://127.0.0.1:8835}"
TOKEN="${RC_E2E_TOKEN:-local-dev-token}"
BACKEND_LOG="${TMPDIR:-/tmp}/remotecode-ios-e2e-backend.log"
BACKEND_PID=""
APP_NAME="${RC_APP_NAME:-io.remotecode}"
SESSION_PREFIX="${RC_AD_SESSION_PREFIX:-rc-e2e-thread-activity}"
FAKE_CODEX_DIR=""
BASE_HOST_PORT="${BASE_URL#*://}"
BASE_HOST_PORT="${BASE_HOST_PORT%%/*}"
BASE_PORT="${BASE_HOST_PORT##*:}"
IOS_DIR="$(cd "${SCRIPT_DIR}/../ios" && pwd)"
IOS_WORKSPACE="${RC_IOS_WORKSPACE:-${IOS_DIR}/RemoteCode.xcworkspace}"
IOS_SCHEME="${RC_IOS_SCHEME:-RemoteCode}"
IOS_CONFIGURATION="${RC_IOS_CONFIGURATION:-Release}"
IOS_SIMULATOR_NAME="${RC_IOS_SIMULATOR_NAME:-iPhone 16}"
IOS_SIMULATOR_UDID="${RC_IOS_SIMULATOR_UDID:-}"
IOS_SIMULATOR_ARCH="${RC_IOS_SIMULATOR_ARCH:-arm64}"
IOS_BUILD_LOG="${TMPDIR:-/tmp}/remotecode-ios-e2e-build.log"
IOS_FORCE_REBUILD="${RC_IOS_FORCE_REBUILD:-1}"

if [[ -z "${RC_AD_SESSION:-}" ]]; then
	export RC_AD_SESSION="${SESSION_PREFIX}-$(date +%s)"
fi

cleanup() {
	if [[ -n "${BACKEND_PID}" ]]; then
		kill "${BACKEND_PID}" >/dev/null 2>&1 || true
		wait "${BACKEND_PID}" >/dev/null 2>&1 || true
	fi
	if [[ -n "${FAKE_CODEX_DIR}" ]]; then
		rm -rf "${FAKE_CODEX_DIR}"
	fi
}

cleanup_stale_ios_e2e_processes() {
	local patterns=(
		'/mobile/e2e/ios-thread-activity-flow.sh'
		'/mobile/e2e/ios-chat-pagination-flow.sh'
		'AgentDeviceRunnerUITests/RunnerTests/testCommand'
		'agent-device --platform ios'
	)

	echo "Clearing stale iOS e2e worker processes..."
	for pattern in "${patterns[@]}"; do
		pkill -f "${pattern}" >/dev/null 2>&1 || true
	done
}

resolve_simulator_udid() {
	if [[ -n "${IOS_SIMULATOR_UDID}" ]]; then
		printf "%s\n" "${IOS_SIMULATOR_UDID}"
		return 0
	fi

	local resolved_udid
	resolved_udid="$(
		xcrun simctl list devices available \
			| awk -v simulator_name="${IOS_SIMULATOR_NAME}" '
				index($0, simulator_name " (") {
					if (match($0, /\(([0-9A-F-]+)\)/)) {
						print substr($0, RSTART + 1, RLENGTH - 2)
						exit
					}
				}
			'
	)"

	if [[ -z "${resolved_udid}" ]]; then
		echo "Unable to resolve a simulator named ${IOS_SIMULATOR_NAME}." >&2
		return 1
	fi

	printf "%s\n" "${resolved_udid}"
}

ensure_simulator_booted() {
	IOS_SIMULATOR_UDID="$(resolve_simulator_udid)"
	echo "Using iOS simulator ${IOS_SIMULATOR_NAME} (${IOS_SIMULATOR_UDID})..."
	booted_simulator_udids="$(
		xcrun simctl list devices booted \
			| awk '
				match($0, /\(([0-9A-F-]+)\)/) {
					print substr($0, RSTART + 1, RLENGTH - 2)
				}
			'
	)"
	if [[ -n "${booted_simulator_udids}" ]]; then
		while IFS= read -r booted_udid; do
			if [[ -z "${booted_udid}" || "${booted_udid}" == "${IOS_SIMULATOR_UDID}" ]]; then
				continue
			fi
			echo "Shutting down competing booted simulator ${booted_udid}..."
			xcrun simctl shutdown "${booted_udid}" >/dev/null 2>&1 || true
		done <<< "${booted_simulator_udids}"
	fi
	xcrun simctl shutdown "${IOS_SIMULATOR_UDID}" >/dev/null 2>&1 || true
	xcrun simctl boot "${IOS_SIMULATOR_UDID}" >/dev/null 2>&1 || true
	open -a Simulator --args -CurrentDeviceUDID "${IOS_SIMULATOR_UDID}" >/dev/null 2>&1 || true
	xcrun simctl bootstatus "${IOS_SIMULATOR_UDID}" -b >/dev/null
}

simulator_destination() {
	printf "platform=iOS Simulator,id=%s,arch=%s" "${IOS_SIMULATOR_UDID}" "${IOS_SIMULATOR_ARCH}"
}

is_app_installed() {
	xcrun simctl listapps "${IOS_SIMULATOR_UDID}" | rg -q "CFBundleIdentifier = \"${APP_NAME}\";"
}

resolve_built_app_path() {
	xcodebuild -showBuildSettings \
		-workspace "${IOS_WORKSPACE}" \
		-scheme "${IOS_SCHEME}" \
		-configuration "${IOS_CONFIGURATION}" \
		-destination "$(simulator_destination)" 2>/dev/null \
		| awk -F ' = ' '
			$1 ~ /TARGET_BUILD_DIR$/ {
				target_build_dir=$2
			}
			$1 ~ /FULL_PRODUCT_NAME$/ {
				full_product_name=$2
			}
			END {
				if (target_build_dir != "" && full_product_name != "") {
					print target_build_dir "/" full_product_name
				}
			}
		'
}

ensure_app_installed() {
	if [[ "${IOS_FORCE_REBUILD}" != "1" ]] && is_app_installed; then
		echo "RemoteCode app already installed on simulator."
		return 0
	fi

	echo "Building RemoteCode (${IOS_CONFIGURATION}) for iOS simulator..."
	if [[ "${IOS_FORCE_REBUILD}" == "1" ]]; then
		xcodebuild \
			-workspace "${IOS_WORKSPACE}" \
			-scheme "${IOS_SCHEME}" \
			-configuration "${IOS_CONFIGURATION}" \
			-destination "$(simulator_destination)" \
			clean > "${IOS_BUILD_LOG}" 2>&1
	fi
	if ! xcodebuild \
		-workspace "${IOS_WORKSPACE}" \
		-scheme "${IOS_SCHEME}" \
		-configuration "${IOS_CONFIGURATION}" \
		-destination "$(simulator_destination)" \
		build > "${IOS_BUILD_LOG}" 2>&1; then
		echo "iOS simulator build failed." >&2
		tail -n 120 "${IOS_BUILD_LOG}" >&2 || true
		return 1
	fi

	local app_path
	app_path="$(resolve_built_app_path)"
	if [[ -z "${app_path}" || ! -d "${app_path}" ]]; then
		echo "Unable to locate built RemoteCode.app after simulator build." >&2
		tail -n 120 "${IOS_BUILD_LOG}" >&2 || true
		return 1
	fi

	echo "Installing RemoteCode on simulator from ${app_path}..."
	xcrun simctl uninstall "${IOS_SIMULATOR_UDID}" "${APP_NAME}" >/dev/null 2>&1 || true
	xcrun simctl install "${IOS_SIMULATOR_UDID}" "${app_path}" >/dev/null
}

grant_simulator_permissions() {
	echo "Granting simulator notification permission for ${APP_NAME}..."
	xcrun simctl privacy "${IOS_SIMULATOR_UDID}" grant notifications "${APP_NAME}" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

echo "Clearing stale agent-device sessions (rc-e2e-*)..."
session_names="$(
	npx -y agent-device --platform ios session list --json 2>/dev/null \
		| jq -r '.data.sessions[]?.name // empty' \
		| rg '^rc-e2e-' -S || true
)"
if [[ -n "${session_names}" ]]; then
	while IFS= read -r name; do
		if [[ -z "${name}" || "${name}" == "${RC_AD_SESSION}" ]]; then
			continue
		fi
		echo "Closing stale session: ${name}"
		gtimeout 20 npx -y agent-device --platform ios --session "${name}" close "${APP_NAME}" >/dev/null 2>&1 || true
		gtimeout 20 npx -y agent-device --platform ios --session "${name}" close >/dev/null 2>&1 || true
	done <<< "${session_names}"
fi

remaining_session_names="$(
	npx -y agent-device --platform ios session list --json 2>/dev/null \
		| jq -r '.data.sessions[]?.name // empty' \
		| rg '^rc-e2e-' -S || true
)"
if [[ -n "${remaining_session_names}" ]]; then
	echo "Restarting agent-device daemon to clear stale rc-e2e sessions..."
	stale_daemon_pids="$(pgrep -f 'agent-device/dist/src/daemon.js' || true)"
	if [[ -n "${stale_daemon_pids}" ]]; then
		while IFS= read -r daemon_pid; do
			if [[ -z "${daemon_pid}" ]]; then
				continue
			fi
			kill "${daemon_pid}" >/dev/null 2>&1 || true
			wait "${daemon_pid}" >/dev/null 2>&1 || true
		done <<< "${stale_daemon_pids}"
	fi
	sleep 1
fi

if [[ "${BASE_PORT}" =~ ^[0-9]+$ ]]; then
	stale_backend_pids="$(lsof -tiTCP:"${BASE_PORT}" -sTCP:LISTEN 2>/dev/null || true)"
	if [[ -n "${stale_backend_pids}" ]]; then
		echo "Clearing stale backend listeners on port ${BASE_PORT}:"
		while IFS= read -r stale_pid; do
			if [[ -z "${stale_pid}" ]]; then
				continue
			fi
			echo " - killing PID ${stale_pid}"
			kill "${stale_pid}" >/dev/null 2>&1 || true
			wait "${stale_pid}" >/dev/null 2>&1 || true
		done <<< "${stale_backend_pids}"
	fi
fi

cleanup_stale_ios_e2e_processes
ensure_simulator_booted
ensure_app_installed
grant_simulator_permissions
export RC_IOS_SIMULATOR_UDID="${IOS_SIMULATOR_UDID}"

FAKE_CODEX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/remotecode-fake-codex.XXXXXX")"
ln -sf "${SCRIPT_DIR}/fake-codex.sh" "${FAKE_CODEX_DIR}/codex"
chmod +x "${SCRIPT_DIR}/fake-codex.sh" "${FAKE_CODEX_DIR}/codex"
export PATH="${FAKE_CODEX_DIR}:${PATH}"

echo "Starting deterministic iOS e2e backend..."
bun run "${SCRIPT_DIR}/start-ios-e2e-backend.ts" > "${BACKEND_LOG}" 2>&1 &
BACKEND_PID="$!"

echo "Waiting for backend health at ${BASE_URL}..."
attempt=0
until curl -sf -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
	"${BASE_URL}/v1/auth/verify" -d '{}' >/dev/null; do
	attempt=$((attempt + 1))
	if [[ "${attempt}" -ge 60 ]]; then
		echo "Timed out waiting for iOS e2e backend." >&2
		tail -n 120 "${BACKEND_LOG}" >&2 || true
		exit 1
	fi
	sleep 1
done

echo "Running iOS thread activity flow..."
echo "Using agent-device session: ${RC_AD_SESSION}"
bash "${SCRIPT_DIR}/ios-thread-activity-flow.sh"

echo "Running iOS chat pagination flow..."
bash "${SCRIPT_DIR}/ios-chat-pagination-flow.sh"

echo "iOS E2E suite completed."
