#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
preflight="$repo_root/scripts/release-preflight.sh"
guard="$repo_root/scripts/release-publication-guard.sh"
fixture_root="$(mktemp -d)"
cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

fake_bin="$fixture_root/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "rev-parse" ]; then
  printf '%s\n' "${RC2_FAKE_TAG_SHA:-$CI_COMMIT_SHA}"
  exit 0
fi
exec /usr/bin/git "$@"
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
method="GET"
output=""
write_out=""
args=("$@")
for ((index = 0; index < ${#args[@]}; index += 1)); do
  case "${args[$index]}" in
    --request)
      method="${args[$((index + 1))]}"
      index=$((index + 1))
      ;;
    --output)
      output="${args[$((index + 1))]}"
      index=$((index + 1))
      ;;
    --write-out)
      write_out="${args[$((index + 1))]}"
      index=$((index + 1))
      ;;
  esac
done
if [ "$method" = "DELETE" ]; then
  printf 'DELETE %s\n' "$url" >> "${RC2_FAKE_CURL_LOG:?}"
  if [ -n "${RC2_FAKE_RELEASE_STATE:-}" ]; then
    rm -f "$RC2_FAKE_RELEASE_STATE"
  fi
  printf '%s' "${RC2_FAKE_RELEASE_DELETE_CODE:-200}"
  exit 0
fi
case "$url" in
  */releases/v9.8.7)
    printf 'GET %s\n' "$url" >> "${RC2_FAKE_CURL_LOG:?}"
    if [ -n "${RC2_FAKE_RELEASE_STATE:-}" ] && [ -f "$RC2_FAKE_RELEASE_STATE" ]; then
      owner="$(<"$RC2_FAKE_RELEASE_STATE")"
      body="$(jq -n --arg marker "remotecode-release-owner:$owner" \
        '{description: ("RemoteCode macOS 9.8.7\n\n" + $marker)}')"
      code="200"
    else
      body='{"message":"404 Release Not Found"}'
      code="404"
    fi
    if [ -n "$output" ]; then
      printf '%s\n' "$body" > "$output"
    else
      printf '%s\n' "$body"
    fi
    if [ -n "$write_out" ]; then
      printf '%s' "$code"
    fi
    ;;
  *)
    echo "unexpected fake curl URL: $url" >&2
    exit 22
    ;;
esac
EOF

cat > "$fake_bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="${RC2_FAKE_S3_ROOT:?}"
log="${RC2_FAKE_AWS_LOG:?}"
printf '%s\n' "$*" >> "$log"

s3_path() {
  local url="$1"
  local rest="${url#s3://}"
  printf '%s/%s\n' "$root" "${rest#*/}"
}

if [ "${1:-}" = "s3api" ] && [ "${2:-}" = "head-object" ]; then
  key=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--key" ]; then key="$2"; break; fi
    shift
  done
  if [ -f "$root/$key" ]; then
    printf '{"ContentType":"application/octet-stream","CacheControl":"no-cache, max-age=0"}\n'
    exit 0
  fi
  echo 'An error occurred (404) when calling HeadObject: Not Found' >&2
  exit 255
fi

if [ "${1:-}" = "s3" ] && [ "${2:-}" = "cp" ]; then
  src="$3"
  dst="$4"
  if [[ "$src" == s3://* ]]; then src="$(s3_path "$src")"; fi
  if [[ "$dst" == s3://* ]]; then dst="$(s3_path "$dst")"; fi
  mkdir -p "$(dirname "$dst")"
  /bin/cp "$src" "$dst"
  exit 0
fi

if [ "${1:-}" = "s3" ] && [ "${2:-}" = "rm" ]; then
  target="$(s3_path "$3")"
  rm -f "$target"
  exit 0
fi

if [ "${1:-}" = "cloudfront" ] && [ "${2:-}" = "create-invalidation" ]; then
  exit 0
fi

echo "unexpected fake aws command: $*" >&2
exit 2
EOF

chmod +x "$fake_bin/git" "$fake_bin/curl" "$fake_bin/aws"

CI_COMMIT_SHA="0123456789abcdef0123456789abcdef01234567"
export CI_COMMIT_SHA
export RELEASE_TAG="v9.8.7"
export CI_COMMIT_TAG="$RELEASE_TAG"
export CI_PIPELINE_ID="456"
export CI_API_V4_URL="https://gitlab.example/api/v4"
export CI_PROJECT_ID="1"
export CI_JOB_TOKEN="job-token"
export RC2_FAKE_CURL_LOG="$fixture_root/curl.log"
export PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

"$preflight" >/dev/null

expect_preflight_failure() {
  local label="$1"
  shift
  if ( "$@" ) >/dev/null 2>&1; then
    echo "FAIL: preflight accepted $label" >&2
    exit 1
  fi
}

export RC2_FAKE_TAG_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect_preflight_failure "wrong tag SHA" "$preflight"
unset RC2_FAKE_TAG_SHA

saved_tag="$CI_COMMIT_TAG"
export CI_COMMIT_TAG="v9.8.8"
expect_preflight_failure "mismatched RELEASE_TAG" "$preflight"
export CI_COMMIT_TAG="$saved_tag"

saved_release_tag="$RELEASE_TAG"
export RELEASE_TAG="v9.8.7-beta"
export CI_COMMIT_TAG="$RELEASE_TAG"
expect_preflight_failure "non-semver tag" "$preflight"
export RELEASE_TAG="$saved_release_tag"
export CI_COMMIT_TAG="$saved_release_tag"

saved_commit_tag="$CI_COMMIT_TAG"
unset CI_COMMIT_TAG
expect_preflight_failure "missing CI_COMMIT_TAG" "$preflight"
export CI_COMMIT_TAG="$saved_commit_tag"

ci_yaml="$repo_root/.gitlab-ci.yml"
stable_rules="$(awk '
  /^stable_macos_arm64_dmg:/ { in_job=1 }
  in_job && /^[^[:space:]][^:]*:/ && $0 !~ /^stable_macos_arm64_dmg:/ { exit }
  in_job { print }
' "$ci_yaml")"
other_jobs="$(awk '
  /^[a-zA-Z][A-Za-z0-9_]*:/ {
    name=$1
    sub(/:.*/, "", name)
    if (name != "stages" && name != "workflow" && name != "variables" && name != "stable_macos_arm64_dmg") {
      print name
    }
  }
' "$ci_yaml")"
if [ -n "$other_jobs" ]; then
  echo "FAIL: CI defines an unexpected job:" >&2
  printf '%s\n' "$other_jobs" >&2
  exit 1
fi
if grep -E 'release_validation_receipt:|lint_scripts:|pr_unit_tests:|package_bundle_check:|RUN_ALL_MACOS_CI|merge_request_event|RC2_VALIDATED_PIPELINE_ID|RC2_ACCEPTANCE_MANIFEST' "$ci_yaml" >/dev/null; then
  echo "FAIL: CI still contains non-release pipeline jobs or controller gates" >&2
  exit 1
fi
# shellcheck disable=SC2016
if ! printf '%s\n' "$stable_rules" | grep -F "if: '\$CI_COMMIT_TAG =~ /^v[0-9]+\\.[0-9]+\\.[0-9]+$/'" >/dev/null; then
  echo "FAIL: stable publication is not admitted by a bare glab semver tag" >&2
  exit 1
fi
# shellcheck disable=SC2016
if ! grep -F "if: '\$CI_COMMIT_TAG =~ /^v[0-9]+\\.[0-9]+\\.[0-9]+$/'" "$ci_yaml" >/dev/null \
  || grep -F 'merge_request_event' "$ci_yaml" >/dev/null \
  || grep -F 'CI_PIPELINE_SOURCE == "push"' "$ci_yaml" >/dev/null
then
  echo "FAIL: workflow must admit only semver tags" >&2
  exit 1
fi
# shellcheck disable=SC2016
if ! printf '%s\n' "$stable_rules" | grep -F 'bash scripts/orchestrate-launch-smoke.sh "$MOUNT/RemoteCode.app"' >/dev/null; then
  echo "FAIL: stable publication does not gate on mounted-app launch smoke" >&2
  exit 1
fi
# shellcheck disable=SC2016
if printf '%s\n' "$stable_rules" | grep -F 'orchestrate-launch-smoke.sh "$MOUNT/RemoteCode.app" ||' >/dev/null; then
  echo "FAIL: stable launch smoke is still non-gating" >&2
  exit 1
fi
release_owned_check_line="$(printf '%s\n' "$stable_rules" \
  | grep -nF 'if [ "$RELEASE_OWNED" != "1" ]; then' \
  | cut -d: -f1)"
release_owned_line="$(printf '%s\n' "$stable_rules" \
  | grep -nF 'rc2_release_guard_note_release_created' \
  | cut -d: -f1)"
if [ -z "$release_owned_check_line" ] || [ -z "$release_owned_line" ] \
  || [ "$release_owned_line" -le "$release_owned_check_line" ] \
  || ! printf '%s\n' "$stable_rules" | grep -F 'rc2_release_guard_confirm_release_ownership' >/dev/null \
  || ! printf '%s\n' "$stable_rules" | grep -F 'rc2_release_guard_ownership_marker' >/dev/null
then
  echo "FAIL: release ownership is not proved or reconciled before it is recorded" >&2
  exit 1
fi

run_rollback_boundary() {
  local boundary="$1"
  local case_root="$fixture_root/rollback-$boundary"
  export RC2_FAKE_S3_ROOT="$case_root/s3"
  export RC2_FAKE_AWS_LOG="$case_root/aws.log"
  export RC2_FAKE_RELEASE_STATE="$case_root/gitlab-release.state"
  mkdir -p "$RC2_FAKE_S3_ROOT/downloads/macos/latest" "$case_root/backup"
  printf 'old-dmg' > "$RC2_FAKE_S3_ROOT/downloads/macos/latest/stable-macos-arm64-RemoteCode.dmg"
  printf 'old-appcast' > "$RC2_FAKE_S3_ROOT/downloads/macos/appcast.xml"
  : > "$RC2_FAKE_AWS_LOG"
  : > "$RC2_FAKE_CURL_LOG"

  export RC2_RELEASE_BACKUP_DIR="$case_root/backup"
  export RC2_RELEASE_S3_BUCKET="bucket"
  export RC2_RELEASE_LATEST_KEY="downloads/macos/latest/stable-macos-arm64-RemoteCode.dmg"
  export RC2_RELEASE_APPCAST_KEY="downloads/macos/appcast.xml"
  export RC2_RELEASE_CLOUDFRONT_DISTRIBUTION_ID="distribution"
  export RC2_RELEASE_API="https://gitlab.example/api/v4/projects/1/releases"
  export RC2_RELEASE_TAG="v9.8.7"
  export RC2_RELEASE_JOB_TOKEN="job-token"
  export RC2_RELEASE_OWNERSHIP_TOKEN="owned-token"
  unset RC2_RELEASE_GUARD_CAPTURED RC2_RELEASE_GUARD_MUTATED
  unset RC2_RELEASE_GUARD_RELEASE_CREATED RC2_RELEASE_GUARD_COMMITTED

  # shellcheck disable=SC1090,SC1091
  source "$guard"
  rc2_release_guard_capture
  rc2_release_guard_begin_mutation
  printf 'new-dmg' > "$RC2_FAKE_S3_ROOT/$RC2_RELEASE_LATEST_KEY"
  if [ "$boundary" != "latest" ]; then
    printf 'new-appcast' > "$RC2_FAKE_S3_ROOT/$RC2_RELEASE_APPCAST_KEY"
  fi
  if [ "$boundary" = "invalidation" ] || [[ "$boundary" == release* ]]; then
    aws cloudfront create-invalidation \
      --distribution-id "$RC2_RELEASE_CLOUDFRONT_DISTRIBUTION_ID" \
      --paths "/$RC2_RELEASE_LATEST_KEY" "/$RC2_RELEASE_APPCAST_KEY"
  fi
  if [ "$boundary" = "release-unowned" ]; then
    printf 'another-owner' > "$RC2_FAKE_RELEASE_STATE"
  elif [ "$boundary" = "release-mismatched-marked" ]; then
    printf 'another-owner' > "$RC2_FAKE_RELEASE_STATE"
    rc2_release_guard_note_release_created
  elif [ "$boundary" = "release-response-lost" ]; then
    printf '%s' "$RC2_RELEASE_OWNERSHIP_TOKEN" > "$RC2_FAKE_RELEASE_STATE"
    rc2_release_guard_retry rc2_release_guard_confirm_release_ownership
    rc2_release_guard_note_release_created
  elif [[ "$boundary" == release* ]]; then
    printf '%s' "$RC2_RELEASE_OWNERSHIP_TOKEN" > "$RC2_FAKE_RELEASE_STATE"
    rc2_release_guard_note_release_created
  fi
  if [ "$boundary" = "release-mismatched-marked" ]; then
    if rc2_release_guard_rollback >/dev/null 2>&1; then
      echo "FAIL: rollback accepted a release owned by another job" >&2
      exit 1
    fi
  else
    rc2_release_guard_rollback >/dev/null
  fi

  [ "$(<"$RC2_FAKE_S3_ROOT/$RC2_RELEASE_LATEST_KEY")" = "old-dmg" ]
  [ "$(<"$RC2_FAKE_S3_ROOT/$RC2_RELEASE_APPCAST_KEY")" = "old-appcast" ]
  grep -F 'cloudfront create-invalidation' "$RC2_FAKE_AWS_LOG" >/dev/null
  if [ "$boundary" = "release-unowned" ] || [ "$boundary" = "release-mismatched-marked" ]; then
    [ -e "$RC2_FAKE_RELEASE_STATE" ]
    if grep -F 'DELETE https://gitlab.example/api/v4/projects/1/releases/v9.8.7' "$RC2_FAKE_CURL_LOG" >/dev/null; then
      echo "FAIL: rollback deleted a release without confirmed ownership" >&2
      exit 1
    fi
  elif [[ "$boundary" == release* ]]; then
    grep -F 'DELETE https://gitlab.example/api/v4/projects/1/releases/v9.8.7' "$RC2_FAKE_CURL_LOG" >/dev/null
    [ ! -e "$RC2_FAKE_RELEASE_STATE" ]
  fi
}

run_rollback_boundary latest
run_rollback_boundary appcast
run_rollback_boundary invalidation
run_rollback_boundary release
run_rollback_boundary release-response-lost
run_rollback_boundary release-unowned
run_rollback_boundary release-mismatched-marked

export RC2_FAKE_RELEASE_DELETE_CODE="204"
run_rollback_boundary release-204
export RC2_FAKE_RELEASE_DELETE_CODE="404"
run_rollback_boundary release-404
unset RC2_FAKE_RELEASE_DELETE_CODE

missing_root="$fixture_root/rollback-missing"
export RC2_FAKE_S3_ROOT="$missing_root/s3"
export RC2_FAKE_AWS_LOG="$missing_root/aws.log"
mkdir -p "$RC2_FAKE_S3_ROOT" "$missing_root/backup"
: > "$RC2_FAKE_AWS_LOG"
export RC2_RELEASE_BACKUP_DIR="$missing_root/backup"
unset RC2_RELEASE_GUARD_CAPTURED RC2_RELEASE_GUARD_MUTATED
unset RC2_RELEASE_GUARD_RELEASE_CREATED RC2_RELEASE_GUARD_COMMITTED
# shellcheck disable=SC1090,SC1091
source "$guard"
rc2_release_guard_capture
rc2_release_guard_begin_mutation
mkdir -p "$(dirname "$RC2_FAKE_S3_ROOT/$RC2_RELEASE_LATEST_KEY")"
printf 'new-dmg' > "$RC2_FAKE_S3_ROOT/$RC2_RELEASE_LATEST_KEY"
printf 'new-appcast' > "$RC2_FAKE_S3_ROOT/$RC2_RELEASE_APPCAST_KEY"
rc2_release_guard_rollback >/dev/null
[ ! -e "$RC2_FAKE_S3_ROOT/$RC2_RELEASE_LATEST_KEY" ]
[ ! -e "$RC2_FAKE_S3_ROOT/$RC2_RELEASE_APPCAST_KEY" ]

echo "stable release guards: PASS"
