#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${RC_E2E_BASE_URL:-http://127.0.0.1:8835}"
TOKEN="${RC_E2E_TOKEN:-local-dev-token}"
BACKEND_LOG="${TMPDIR:-/tmp}/remotecode-ios-e2e-backend.log"
BACKEND_PID=""
APP_NAME="${RC_APP_NAME:-io.remotecode}"
SESSION_PREFIX="${RC_AD_SESSION_PREFIX:-rc-e2e-thread-activity}"

if [[ -z "${RC_AD_SESSION:-}" ]]; then
	export RC_AD_SESSION="${SESSION_PREFIX}-$(date +%s)"
fi

cleanup() {
	if [[ -n "${BACKEND_PID}" ]]; then
		kill "${BACKEND_PID}" >/dev/null 2>&1 || true
		wait "${BACKEND_PID}" >/dev/null 2>&1 || true
	fi
}

trap cleanup EXIT INT TERM

echo "Clearing stale agent-device sessions (${SESSION_PREFIX}*)..."
session_names="$(
	npx -y agent-device --platform ios session list --json 2>/dev/null \
		| jq -r '.data.sessions[]?.name // empty' \
		| rg "^${SESSION_PREFIX}" -S || true
)"
if [[ -n "${session_names}" ]]; then
	while IFS= read -r name; do
		if [[ -z "${name}" || "${name}" == "${RC_AD_SESSION}" ]]; then
			continue
		fi
		echo "Closing stale session: ${name}"
		npx -y agent-device --platform ios --session "${name}" close "${APP_NAME}" >/dev/null 2>&1 || true
	done <<< "${session_names}"
fi

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

echo "iOS E2E suite completed."
