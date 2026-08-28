#!/usr/bin/env bash
set -euo pipefail

require_value() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "release preflight: $name is required" >&2
    exit 1
  fi
}

export RELEASE_TAG="${RELEASE_TAG:-${CI_COMMIT_TAG:-}}"

for name in \
  RELEASE_TAG \
  CI_COMMIT_TAG \
  CI_COMMIT_SHA \
  CI_PIPELINE_ID \
  CI_API_V4_URL \
  CI_PROJECT_ID \
  CI_JOB_TOKEN
do
  require_value "$name"
done

if [ "$RELEASE_TAG" != "$CI_COMMIT_TAG" ]; then
  echo "release preflight: RELEASE_TAG must equal CI_COMMIT_TAG" >&2
  exit 1
fi
if ! [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release preflight: RELEASE_TAG must be a stable semantic version" >&2
  exit 1
fi

for command in git curl jq; do
  command -v "$command" >/dev/null || {
    echo "release preflight: missing command $command" >&2
    exit 1
  }
done

tag_sha="$(git rev-parse "$RELEASE_TAG^{commit}")"
if [ "$tag_sha" != "$CI_COMMIT_SHA" ]; then
  echo "release preflight: tag does not peel to CI_COMMIT_SHA" >&2
  exit 1
fi

echo "release preflight: PASS tag=$RELEASE_TAG sha=$CI_COMMIT_SHA pipeline=$CI_PIPELINE_ID"
