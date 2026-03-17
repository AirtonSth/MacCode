#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${RC_APP_NAME:-RemoteCode}"
SESSION_NAME="${RC_AD_SESSION:-rc-e2e-account-compliance}"

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

wait_for() {
	local test_id="$1"
	local timeout_ms="${2:-30000}"
	ad wait "id=\"${test_id}\"" "${timeout_ms}" >/dev/null
}

echo "Opening app on iOS simulator..."
ad open "${APP_NAME}" >/dev/null
ad wait 2000 >/dev/null

echo "Verifying settings screen is visible..."
wait_for "screen-settings"

echo "Checking privacy policy link exists..."
if ! exists "private-account-privacy-policy"; then
	echo "FAIL: Privacy Policy link not found on settings screen." >&2
	exit 1
fi
echo "PASS: Privacy Policy link is visible."

echo "Checking terms of use link exists..."
if ! exists "private-account-terms-of-use"; then
	echo "FAIL: Terms of Use link not found on settings screen." >&2
	exit 1
fi
echo "PASS: Terms of Use link is visible."

echo "Checking options button visibility (should NOT be visible when logged out)..."
if exists "private-account-options"; then
	echo "FAIL: Options button should not be visible when user is not logged in." >&2
	exit 1
fi
echo "PASS: Options button is hidden when not logged in."

echo "Account compliance flow passed."
ad close >/dev/null || true
