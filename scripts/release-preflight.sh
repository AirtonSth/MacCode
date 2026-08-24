#!/usr/bin/env bash
set -euo pipefail

require_value() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "release preflight: $name is required" >&2
    exit 1
  fi
}

for name in \
  RELEASE_TAG \
  CI_COMMIT_TAG \
  CI_COMMIT_SHA \
  CI_PIPELINE_ID \
  CI_API_V4_URL \
  CI_PROJECT_ID \
  CI_JOB_TOKEN \
  RC2_VALIDATED_PIPELINE_ID \
  RC2_VALIDATED_JOB_ID \
  RC2_ACCEPTANCE_MANIFEST_BASE64 \
  RC2_ACCEPTANCE_MANIFEST_SHA256
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
if ! [[ "$RC2_VALIDATED_PIPELINE_ID" =~ ^[0-9]+$ ]]; then
  echo "release preflight: RC2_VALIDATED_PIPELINE_ID must be numeric" >&2
  exit 1
fi
if ! [[ "$RC2_VALIDATED_JOB_ID" =~ ^[0-9]+$ ]]; then
  echo "release preflight: RC2_VALIDATED_JOB_ID must be numeric" >&2
  exit 1
fi
if [ "$RC2_VALIDATED_PIPELINE_ID" = "$CI_PIPELINE_ID" ]; then
  echo "release preflight: validation and release pipelines must be distinct" >&2
  exit 1
fi
if ! [[ "$RC2_ACCEPTANCE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "release preflight: RC2_ACCEPTANCE_MANIFEST_SHA256 must be lowercase SHA-256" >&2
  exit 1
fi

for command in git curl jq shasum base64; do
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

work_dir="$(mktemp -d)"
cleanup_preflight() {
  rm -rf "$work_dir"
}
trap cleanup_preflight EXIT

manifest="$work_dir/acceptance-manifest.json"
printf '%s' "$RC2_ACCEPTANCE_MANIFEST_BASE64" | base64 --decode > "$manifest"
manifest_digest="$(shasum -a 256 "$manifest" | awk '{print $1}')"
if [ "$manifest_digest" != "$RC2_ACCEPTANCE_MANIFEST_SHA256" ]; then
  echo "release preflight: acceptance manifest digest mismatch" >&2
  exit 1
fi

required_gates='["focused-tests","full-swift-suite","package-signing","real-app-e2e","e2e-inventory","release-guard"]'
if ! jq -e \
  --arg sha "$CI_COMMIT_SHA" \
  --arg validation_pipeline_id "$RC2_VALIDATED_PIPELINE_ID" \
  --arg validation_job_id "$RC2_VALIDATED_JOB_ID" \
  --argjson required "$required_gates" \
  '
    .schema_version == 1
    and .commit_sha == $sha
    and ((.validation_pipeline_id | tostring) == $validation_pipeline_id)
    and ((.validation_job_id | tostring) == $validation_job_id)
    and (.gates | type == "array")
    and (all(.gates[]; .status == "PASS"))
    and (($required - [.gates[].id]) | length == 0)
  ' "$manifest" >/dev/null
then
  echo "release preflight: acceptance manifest is not an all-PASS exact-SHA receipt" >&2
  exit 1
fi

api_base="$CI_API_V4_URL/projects/$CI_PROJECT_ID"
validation_receipt="$work_dir/release-validation-receipt.json"
curl --fail --location --silent --show-error \
  --header "JOB-TOKEN: $CI_JOB_TOKEN" \
  "$api_base/jobs/$RC2_VALIDATED_JOB_ID/artifacts/release-validation-receipt.json" \
  > "$validation_receipt"

required_jobs='["lint_scripts","pr_unit_tests","package_bundle_check"]'
if ! jq -e \
  --arg sha "$CI_COMMIT_SHA" \
  --arg pipeline_id "$RC2_VALIDATED_PIPELINE_ID" \
  --arg job_id "$RC2_VALIDATED_JOB_ID" \
  --argjson required "$required_jobs" \
  '
    .schema_version == 1
    and .commit_sha == $sha
    and .ref == "production"
    and ((.pipeline_id | tostring) == $pipeline_id)
    and ((.validation_job_id | tostring) == $job_id)
    and .run_all_macos_ci == "1"
    and .prior_stages_status == "success"
    and (.required_jobs | type == "array")
    and (all(.required_jobs[]; .status == "PASS"))
    and (($required - [.required_jobs[].id]) | length == 0)
  ' "$validation_receipt" >/dev/null
then
  echo "release preflight: validation receipt does not prove a successful exact-SHA RUN_ALL pipeline" >&2
  exit 1
fi

echo "release preflight: PASS tag=$RELEASE_TAG sha=$CI_COMMIT_SHA validation_pipeline=$RC2_VALIDATED_PIPELINE_ID validation_job=$RC2_VALIDATED_JOB_ID"
