#!/usr/bin/env bash
set -euo pipefail

require_value() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "release preflight: $name is required" >&2
    exit 1
  fi
}

export RELEASE_TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"

for name in \
  RELEASE_TAG \
  GITHUB_REF_TYPE \
  GITHUB_REF_NAME \
  GITHUB_SHA \
  GITHUB_RUN_ID \
  GITHUB_API_URL \
  GITHUB_REPOSITORY \
  GITHUB_TOKEN
do
  require_value "$name"
done

if [ "$GITHUB_REF_TYPE" != "tag" ]; then
  echo "release preflight: GITHUB_REF_TYPE must be tag" >&2
  exit 1
fi
if [ "$RELEASE_TAG" != "$GITHUB_REF_NAME" ]; then
  echo "release preflight: RELEASE_TAG must equal GITHUB_REF_NAME" >&2
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
if [ "$tag_sha" != "$GITHUB_SHA" ]; then
  echo "release preflight: tag does not peel to GITHUB_SHA" >&2
  exit 1
fi

echo "release preflight: PASS tag=$RELEASE_TAG sha=$GITHUB_SHA run=$GITHUB_RUN_ID"
