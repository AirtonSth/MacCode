#!/usr/bin/env bash

# Source this file from a `set -euo pipefail` release script. The caller must
# configure the RC2_RELEASE_* variables below before capture/begin/rollback.

rc2_release_guard_require() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "release guard: $name is required" >&2
    return 1
  fi
}

rc2_release_guard_validate_configuration() {
  local name
  for name in \
    RC2_RELEASE_BACKUP_DIR \
    RC2_RELEASE_S3_BUCKET \
    RC2_RELEASE_LATEST_KEY \
    RC2_RELEASE_APPCAST_KEY \
    RC2_RELEASE_CLOUDFRONT_DISTRIBUTION_ID \
    RC2_RELEASE_API \
    RC2_RELEASE_TAG \
    RC2_RELEASE_JOB_TOKEN \
    RC2_RELEASE_OWNERSHIP_TOKEN
  do
    rc2_release_guard_require "$name" || return 1
  done
}

rc2_release_guard_capture_object() {
  local key="$1"
  local label="$2"
  local metadata="$RC2_RELEASE_BACKUP_DIR/$label.metadata.json"
  local body="$RC2_RELEASE_BACKUP_DIR/$label.body"
  local error_file="$RC2_RELEASE_BACKUP_DIR/$label.head.stderr"

  if aws s3api head-object \
    --bucket "$RC2_RELEASE_S3_BUCKET" \
    --key "$key" > "$metadata" 2> "$error_file"
  then
    aws s3 cp "s3://$RC2_RELEASE_S3_BUCKET/$key" "$body" >/dev/null
    printf 'present\n' > "$RC2_RELEASE_BACKUP_DIR/$label.state"
    return 0
  fi
  if grep -Eq '(404|Not Found|NoSuchKey)' "$error_file"; then
    printf 'missing\n' > "$RC2_RELEASE_BACKUP_DIR/$label.state"
    rm -f "$metadata" "$body"
    return 0
  fi
  echo "release guard: could not inspect s3://$RC2_RELEASE_S3_BUCKET/$key" >&2
  cat "$error_file" >&2
  return 1
}

rc2_release_guard_capture() {
  rc2_release_guard_validate_configuration || return 1
  mkdir -p "$RC2_RELEASE_BACKUP_DIR"
  rc2_release_guard_capture_object "$RC2_RELEASE_LATEST_KEY" latest || return 1
  rc2_release_guard_capture_object "$RC2_RELEASE_APPCAST_KEY" appcast || return 1
  RC2_RELEASE_GUARD_CAPTURED=1
  RC2_RELEASE_GUARD_MUTATED=0
  RC2_RELEASE_GUARD_RELEASE_CREATED=0
  RC2_RELEASE_GUARD_COMMITTED=0
  export RC2_RELEASE_GUARD_CAPTURED RC2_RELEASE_GUARD_MUTATED
  export RC2_RELEASE_GUARD_RELEASE_CREATED RC2_RELEASE_GUARD_COMMITTED
}

rc2_release_guard_begin_mutation() {
  if [ "${RC2_RELEASE_GUARD_CAPTURED:-0}" != "1" ]; then
    echo "release guard: capture must succeed before mutable publication" >&2
    return 1
  fi
  RC2_RELEASE_GUARD_MUTATED=1
  export RC2_RELEASE_GUARD_MUTATED
}

rc2_release_guard_note_release_created() {
  RC2_RELEASE_GUARD_RELEASE_CREATED=1
  export RC2_RELEASE_GUARD_RELEASE_CREATED
}

rc2_release_guard_commit() {
  RC2_RELEASE_GUARD_COMMITTED=1
  export RC2_RELEASE_GUARD_COMMITTED
}

rc2_release_guard_retry() {
  local _
  for _ in 1 2 3; do
    if "$@"; then
      return 0
    fi
  done
  return 1
}

rc2_release_guard_ownership_marker() {
  printf 'remotecode-release-owner:%s' "$RC2_RELEASE_OWNERSHIP_TOKEN"
}

rc2_release_guard_fetch_release_once() {
  local response="$1"
  curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    --header "JOB-TOKEN: $RC2_RELEASE_JOB_TOKEN" \
    "$RC2_RELEASE_API/$RC2_RELEASE_TAG"
}

rc2_release_guard_confirm_release_ownership() {
  local response="$RC2_RELEASE_BACKUP_DIR/release-ownership.json"
  local code marker
  if ! code="$(rc2_release_guard_fetch_release_once "$response")"; then
    return 1
  fi
  [ "$code" = "200" ] || return 1
  marker="$(rc2_release_guard_ownership_marker)"
  jq -e --arg marker "$marker" \
    '(.description // "" | split("\n") | index($marker)) != null' \
    "$response" >/dev/null
}

rc2_release_guard_restore_object_once() {
  local key="$1"
  local label="$2"
  local content_type="$3"
  local state
  state="$(<"$RC2_RELEASE_BACKUP_DIR/$label.state")"
  if [ "$state" = "present" ]; then
    local captured_content_type captured_cache_control
    local upload_options=()
    captured_content_type="$(jq -r '.ContentType // empty' \
      "$RC2_RELEASE_BACKUP_DIR/$label.metadata.json")"
    captured_cache_control="$(jq -r '.CacheControl // empty' \
      "$RC2_RELEASE_BACKUP_DIR/$label.metadata.json")"
    if [ -n "$captured_content_type" ]; then
      upload_options+=(--content-type "$captured_content_type")
    else
      upload_options+=(--content-type "$content_type")
    fi
    if [ -n "$captured_cache_control" ]; then
      upload_options+=(--cache-control "$captured_cache_control")
    fi
    aws s3 cp "$RC2_RELEASE_BACKUP_DIR/$label.body" \
      "s3://$RC2_RELEASE_S3_BUCKET/$key" \
      "${upload_options[@]}" >/dev/null
  elif [ "$state" = "missing" ]; then
    aws s3 rm "s3://$RC2_RELEASE_S3_BUCKET/$key" >/dev/null
  else
    echo "release guard: invalid backup state for $label" >&2
    return 1
  fi
}

rc2_release_guard_delete_release_once() {
  local response="$RC2_RELEASE_BACKUP_DIR/release-before-delete.json"
  local code marker
  if ! code="$(rc2_release_guard_fetch_release_once "$response")"; then
    return 1
  fi
  if [ "$code" = "404" ]; then
    return 0
  fi
  [ "$code" = "200" ] || return 1
  marker="$(rc2_release_guard_ownership_marker)"
  if ! jq -e --arg marker "$marker" \
    '(.description // "" | split("\n") | index($marker)) != null' \
    "$response" >/dev/null
  then
    echo "release guard: refusing to delete a release owned by another job" >&2
    return 1
  fi
  code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --request DELETE \
    --header "JOB-TOKEN: $RC2_RELEASE_JOB_TOKEN" \
    "$RC2_RELEASE_API/$RC2_RELEASE_TAG")"
  [ "$code" = "200" ] || [ "$code" = "204" ] || [ "$code" = "404" ]
}

rc2_release_guard_invalidate_once() {
  aws cloudfront create-invalidation \
    --distribution-id "$RC2_RELEASE_CLOUDFRONT_DISTRIBUTION_ID" \
    --paths \
      "/$RC2_RELEASE_LATEST_KEY" \
      "/$RC2_RELEASE_APPCAST_KEY" >/dev/null
}

rc2_release_guard_rollback() {
  if [ "${RC2_RELEASE_GUARD_MUTATED:-0}" != "1" ] || [ "${RC2_RELEASE_GUARD_COMMITTED:-0}" = "1" ]; then
    return 0
  fi
  local failed=0
  if ! rc2_release_guard_retry rc2_release_guard_restore_object_once \
    "$RC2_RELEASE_LATEST_KEY" latest application/x-apple-diskimage
  then
    echo "release guard: failed to restore latest artifact" >&2
    failed=1
  fi
  if ! rc2_release_guard_retry rc2_release_guard_restore_object_once \
    "$RC2_RELEASE_APPCAST_KEY" appcast 'application/xml; charset=utf-8'
  then
    echo "release guard: failed to restore appcast" >&2
    failed=1
  fi
  if [ "${RC2_RELEASE_GUARD_RELEASE_CREATED:-0}" = "1" ]; then
    if ! rc2_release_guard_retry rc2_release_guard_delete_release_once; then
      echo "release guard: failed to delete partial GitLab release" >&2
      failed=1
    fi
  fi
  if ! rc2_release_guard_retry rc2_release_guard_invalidate_once; then
    echo "release guard: failed to invalidate restored paths" >&2
    failed=1
  fi
  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  RC2_RELEASE_GUARD_MUTATED=0
  export RC2_RELEASE_GUARD_MUTATED
  echo "release guard: restored prior mutable publication state"
}
