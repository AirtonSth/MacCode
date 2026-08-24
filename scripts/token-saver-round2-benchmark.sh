#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
fixture_rel="Tests/Fixtures/TokenSaverLocalLLMRound2/envelope-question.json"
fixture_sha="2f7f815fa8efa3891809c1b66cbcc1b495c016d848401cf78d628cd836c00749"
profile="${RC_TOKEN_SAVER_ROUND2_PROFILE:-question-elision-v1}"
case "${profile}" in
  question-elision-v1) technique_id="librarian-success-fallback-question-elision-v1" ;;
  envelope-slashes-v1) technique_id="librarian-envelope-unescaped-slashes-v1" ;;
  *) echo "token-saver-round2-benchmark: unknown Round-2 profile: ${profile}" >&2; exit 1 ;;
esac
catalog_test_diff_sha="adcd7491dc68ec0cf3654b3321e3964f1dcb0e4289b3aa195fc9b6ed51ad14f3"
slash_regression_added_sha="be4366df08a6ed418992c3ff7cac97067f8db314fec00ecbdb1f0da624fa7232"

die() { echo "token-saver-round2-benchmark: $*" >&2; exit 1; }
sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
require_file() { [[ -f "$1" ]] || die "missing file: $1"; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/token-saver-round2-benchmark.sh capture-arm <baseline|candidate> <exact-git-sha> <arm-output-dir>
  scripts/token-saver-round2-benchmark.sh verify-arm <arm-dir>
  scripts/token-saver-round2-benchmark.sh verify-pair <package-dir>
  scripts/token-saver-round2-benchmark.sh verify-suite <package-dir>
  scripts/token-saver-round2-benchmark.sh verify-report-metadata <report.json>
  scripts/token-saver-round2-benchmark.sh verify-source-materialization <exact-git-sha>
  scripts/token-saver-round2-benchmark.sh verify-envelope-hash <provider-body> <expected-sha256>
  scripts/token-saver-round2-benchmark.sh verify-model-catalog-pair <baseline-response> <candidate-response>
  scripts/token-saver-round2-slash-benchmark.sh verify-slash-bytes <provider|emitted> <baseline-file> <candidate-file>
  scripts/token-saver-round2-slash-benchmark.sh verify-slash-deltas <baseline-report> <candidate-report>
  scripts/token-saver-round2-slash-benchmark.sh verify-slash-product-files <baseline-source> <candidate-source>
  scripts/token-saver-round2-slash-benchmark.sh verify-slash-zero-bytes <baseline-file> <candidate-file>

Required live environment (Authorization stays in process memory):
  RC_TOKEN_SAVER_ROUND2_BASE_URL=http://127.0.0.1:8000/v1
  RC_TOKEN_SAVER_ROUND2_MODEL=<exact /v1/models id>
  RC_TOKEN_SAVER_ROUND2_MODEL_SNAPSHOT=<.../Models/repo/40-hex-revision>
  RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN=<optional bearer; never persisted>

Candidate capture also requires:
  RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR=<verified baseline arm-dir>

Each arm must run this script from its own detached, clean checkout at the exact
SHA supplied. A package directory contains baseline/, candidate/, pair-report.json,
and suite-manifest.json.
USAGE
  exit 2
}

materialized_parent=""
materialized_worktree=""

cleanup_materialized_source() {
  local failed=0
  if [[ -n "${materialized_worktree}" && -d "${materialized_worktree}" ]]; then
    find "${materialized_worktree}" ! -type l -exec chmod u+w {} + || failed=1
    git -C "${repo_root}" worktree remove --force "${materialized_worktree}" || failed=1
  fi
  if [[ -n "${materialized_parent}" && -d "${materialized_parent}" ]]; then
    rmdir "${materialized_parent}" || failed=1
  fi
  materialized_worktree=""
  materialized_parent=""
  return "${failed}"
}

cleanup_scratch() {
  local scratch="$1"
  [[ -n "${scratch}" && -d "${scratch}" ]] || return 0
  find "${scratch}" ! -type l -exec chmod u+w {} +
  rm -rf -- "${scratch}"
}

materialize_source() {
  local expected_sha="$1" expected_tree source_status
  expected_tree="$(git -C "${repo_root}" rev-parse "${expected_sha}^{tree}")"
  materialized_parent="$(mktemp -d "${TMPDIR:-/tmp}/token-saver-r2-source.XXXXXX")"
  materialized_parent="$(cd "${materialized_parent}" && pwd -P)"
  materialized_worktree="${materialized_parent}/checkout"
  git -C "${repo_root}" worktree add --detach "${materialized_worktree}" "${expected_sha}" >/dev/null
  materialized_worktree="$(cd "${materialized_worktree}" && pwd -P)"
  [[ "$(git -C "${materialized_worktree}" rev-parse HEAD)" == "${expected_sha}" ]] || die "materialized worktree HEAD mismatch"
  [[ "$(git -C "${materialized_worktree}" rev-parse 'HEAD^{tree}')" == "${expected_tree}" ]] || die "materialized worktree tree mismatch"
  source_status="$(git -C "${materialized_worktree}" status --porcelain=v1 --untracked-files=all)" || die "failed to inspect materialized worktree status"
  [[ -z "${source_status}" ]] || die "materialized worktree is dirty"
  find "${materialized_worktree}" ! -type l -exec chmod a-w {} +
  [[ ! -w "${materialized_worktree}" && ! -w "${materialized_worktree}/Package.swift" ]] || die "materialized source is still writable"
}

require_tools() {
  command -v git >/dev/null || die "git is required"
  command -v jq >/dev/null || die "jq is required"
  command -v perl >/dev/null || die "perl is required"
  command -v realpath >/dev/null || die "realpath is required"
  command -v shasum >/dev/null || die "shasum is required"
  command -v swift >/dev/null || die "swift is required"
}

verify_fixture() {
  require_file "${repo_root}/${fixture_rel}"
  [[ "$(sha256_file "${repo_root}/${fixture_rel}")" == "${fixture_sha}" ]] || die "fixture SHA mismatch"
  jq -e --arg technique "librarian-success-fallback-question-elision-v1" '
    .schema_version == 1 and .technique_id == $technique and
    .counter == "anthropic-v1-shipping-episode" and
    (.cases | length == 24) and
    ([.cases[].id] | length == (unique | length)) and
    all(.cases[];
      . as $case |
      ($case.question | type == "string" and length > 0) and
      ($case.source | contains($case.span)) and
      ($case.required_literals | length > 0) and
      all($case.forbidden_literals[]; . as $forbidden | ($case.answer | contains($forbidden) | not))
    )
  ' "${repo_root}/${fixture_rel}" >/dev/null || die "fixture contract invalid"
}

shipping_envelope_text() {
  jq -jr '[
    .messages[].content[]?
    | select(.type=="tool_result")
    | .content[]?
    | select(.type=="text")
    | select((try (.text | fromjson | .status) catch null) == "ok")
    | .text
  ][0] // empty' "$1"
}

verify_envelope_hash() {
  require_tools
  local body="${1:-}" expected="${2:-}" actual
  require_file "${body}"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "expected envelope SHA must be 64 lowercase hex"
  actual="$(shipping_envelope_text "${body}" | shasum -a 256 | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || die "raw shipping envelope hash mismatch"
  echo "verify-envelope-hash ok sha256=${actual}"
}

validate_models_response() {
  jq -se '
    length == 1 and
    (.[0] |
      (keys | sort) == ["data","object"] and
      .object == "list" and
      (.data | type) == "array" and (.data | length) > 0 and
      ([.data[].id] | length) == ([.data[].id] | unique | length) and
      all(.data[];
        (keys | sort) == ["created","id","max_model_len","object","owned_by"] and
        (.created | type) == "number" and .created == (.created | floor) and
        (.id | type) == "string" and (.id | length) > 0 and
        .object == "model" and
        (.owned_by | type) == "string" and (.owned_by | length) > 0 and
        (
          .max_model_len == null or
          ((.max_model_len | type) == "number" and .max_model_len > 0 and
           .max_model_len == (.max_model_len | floor))
        )
      )
    )
  ' "$1" >/dev/null
}

models_response_identity() {
  validate_models_response "$1" || return 1
  jq -cS '.data |= map(del(.created))' "$1"
}

verify_model_catalog_pair() {
  require_tools
  local baseline="${1:-}" candidate="${2:-}" baseline_identity candidate_identity
  require_file "${baseline}"
  require_file "${candidate}"
  baseline_identity="$(models_response_identity "${baseline}")" || die "baseline /v1/models contract invalid"
  candidate_identity="$(models_response_identity "${candidate}")" || die "candidate /v1/models contract invalid"
  [[ "${baseline_identity}" == "${candidate_identity}" ]] || die "/v1/models stable identity changed between responses"
  echo "verify-model-catalog-pair ok"
}

capture_arm() {
  require_tools
  verify_fixture
  local arm="${1:-}" expected_sha="${2:-}" output="${3:-}" initial_tree seed_dir="" output_parent output_name source_status
  [[ "${arm}" == baseline || "${arm}" == candidate ]] || usage
  [[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || die "expected SHA must be 40 lowercase hex"
  [[ -n "${output}" ]] || usage
  [[ ! -e "${output}" ]] || die "arm output already exists"
  output_parent="$(dirname -- "${output}")"
  [[ -d "${output_parent}" ]] || die "arm output parent does not exist: ${output_parent}"
  output_parent="$(cd "${output_parent}" && pwd -P)" || die "arm output parent cannot be resolved: ${output_parent}"
  output_name="$(basename -- "${output}")" || die "arm output name cannot be resolved"
  output="${output_parent}/${output_name}"
  [[ -z "$(git -C "${repo_root}" symbolic-ref -q HEAD || true)" ]] || die "capture requires a detached temporary worktree"
  [[ "$(git -C "${repo_root}" rev-parse HEAD)" == "${expected_sha}" ]] || die "HEAD is not the requested arm SHA"
  initial_tree="$(git -C "${repo_root}" rev-parse 'HEAD^{tree}')"
  source_status="$(git -C "${repo_root}" status --porcelain --untracked-files=all)" || die "failed to inspect capture arm status"
  [[ -z "${source_status}" ]] || die "capture arm checkout is dirty"
  case "${output}" in
    "${repo_root}"|"${repo_root}"/*) die "arm output must be outside its source checkout" ;;
  esac
  [[ -n "${RC_TOKEN_SAVER_ROUND2_BASE_URL:-}" ]] || die "missing RC_TOKEN_SAVER_ROUND2_BASE_URL"
  [[ -n "${RC_TOKEN_SAVER_ROUND2_MODEL:-}" ]] || die "missing RC_TOKEN_SAVER_ROUND2_MODEL"
  [[ -n "${RC_TOKEN_SAVER_ROUND2_MODEL_SNAPSHOT:-}" ]] || die "missing RC_TOKEN_SAVER_ROUND2_MODEL_SNAPSHOT"
  if [[ -n "${RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN:-}" && ${#RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN} -lt 8 ]]; then
    die "nonempty auth token must contain at least 8 characters for exact artifact scanning"
  fi
  if [[ "${arm}" == candidate ]]; then
    [[ -n "${RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR:-}" ]] || die "candidate requires baseline recovery seed"
    "$0" verify-arm "${RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR}"
    [[ "$(jq -r '.arm' "${RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR}/report.json")" == baseline ]] || die "candidate seed is not a baseline arm"
    seed_dir="$(cd "${RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR}" && pwd -P)"
  fi

  if [[ "${RC_TOKEN_SAVER_ROUND2_MATERIALIZED_SOURCE:-0}" != 1 ]]; then
    trap 'cleanup_materialized_source || true' EXIT
    materialize_source "${expected_sha}"
    (
      cd "${materialized_worktree}"
      RC_TOKEN_SAVER_ROUND2_MATERIALIZED_SOURCE=1 \
      RC_TOKEN_SAVER_ROUND2_MATERIALIZED_PATH="${materialized_worktree}" \
      RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR="${seed_dir}" \
      "${materialized_worktree}/scripts/token-saver-round2-benchmark.sh" \
        capture-arm "${arm}" "${expected_sha}" "${output}"
    )
    cleanup_materialized_source || die "failed to remove materialized source worktree"
    trap - EXIT
    return
  fi
  [[ "$(cd "${repo_root}" && pwd -P)" == "${RC_TOKEN_SAVER_ROUND2_MATERIALIZED_PATH:-}" ]] || die "materialized source path mismatch"
  [[ ! -w "${repo_root}" && ! -w "${repo_root}/Package.swift" ]] || die "materialized source is not write-protected"

  local scratch
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/token-saver-r2-build.XXXXXX")"
  trap 'cleanup_scratch "${scratch}"' EXIT
  RC_TOKEN_SAVER_ROUND2_CAPTURE=1 \
  RC_TOKEN_SAVER_ROUND2_ARM="${arm}" \
  RC_TOKEN_SAVER_ROUND2_EXPECTED_GIT_SHA="${expected_sha}" \
  RC_TOKEN_SAVER_ROUND2_OUTPUT_DIR="${output}" \
  scripts/isolated-sandbox.sh test \
    --scratch-path "${scratch}" \
    --filter TokenSaverRound2BenchmarkTests/test_captureArmAgainstOMLX

  local executable
  executable="$(find "${scratch}" -type f -path '*.xctest/Contents/MacOS/RemoteCodePackageTests' -print -quit)"
  [[ -n "${executable}" ]] || die "compiled XCTest executable not found"
  [[ "$(sha256_file "${executable}")" == "$(jq -r '.source.executable_sha256' "${output}/report.json")" ]] || die "captured executable hash mismatch"
  [[ "$(git -C "${repo_root}" rev-parse HEAD)" == "${expected_sha}" ]] || die "capture checkout HEAD changed during build/test"
  [[ "$(git -C "${repo_root}" rev-parse 'HEAD^{tree}')" == "${initial_tree}" ]] || die "capture checkout tree changed during build/test"
  source_status="$(git -C "${repo_root}" status --porcelain=v1 --untracked-files=all)" || die "failed to re-inspect capture checkout status"
  [[ -z "${source_status}" ]] || die "capture checkout became dirty during build/test"
  "$0" verify-arm "${output}"
  cleanup_scratch "${scratch}"
  trap - EXIT
  echo "capture-arm ok arm=${arm} git_sha=${expected_sha} output=${output}"
}

verify_source_materialization() {
  require_tools
  local expected_sha="${1:-}" expected_tree scratch source_status
  [[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || die "expected SHA must be 40 lowercase hex"
  expected_tree="$(git -C "${repo_root}" rev-parse "${expected_sha}^{tree}")"
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/token-saver-r2-dry-build.XXXXXX")"
  trap 'cleanup_materialized_source || true; cleanup_scratch "${scratch}"' EXIT
  materialize_source "${expected_sha}"
  (
    cd "${materialized_worktree}"
    scripts/isolated-sandbox.sh test \
      --scratch-path "${scratch}" \
      --quiet \
      --filter TokenSaverRound2BenchmarkTests/test_fixtureFreezesTwentyFourAdversarialShippingCases
  )
  [[ "$(git -C "${materialized_worktree}" rev-parse HEAD)" == "${expected_sha}" ]] || die "dry materialized HEAD changed"
  [[ "$(git -C "${materialized_worktree}" rev-parse 'HEAD^{tree}')" == "${expected_tree}" ]] || die "dry materialized tree changed"
  source_status="$(git -C "${materialized_worktree}" status --porcelain=v1 --untracked-files=all)" || die "failed to re-inspect dry materialized source status"
  [[ -z "${source_status}" ]] || die "dry materialized source became dirty"
  cleanup_materialized_source || die "failed to remove dry materialized worktree"
  cleanup_scratch "${scratch}"
  trap - EXIT
  echo "verify-source-materialization ok git_sha=${expected_sha}"
}

verify_manifest() {
  local arm_dir="$1" manifest="${1}/manifest.json"
  [[ ! -L "${arm_dir}" ]] || die "artifact root must not be a symlink"
  require_file "${manifest}"
  [[ -z "$(find "${arm_dir}" -type l -print -quit)" ]] || die "artifact tree contains a symlink"
  jq -e '.schema_version == 1 and .manifest_excludes_self == true and (.files | length > 0) and ([.files[].path] | length == (unique | length))' "${manifest}" >/dev/null || die "invalid manifest"
  while IFS=$'\t' read -r path bytes digest; do
    [[ -n "${path}" && "${path}" != /* && "${path}" != *../* && "${path}" != ../* ]] || die "unsafe manifest path"
    require_file "${arm_dir}/${path}"
    [[ ! -L "${arm_dir}/${path}" ]] || die "manifest file is a symlink: ${path}"
    [[ "$(wc -c < "${arm_dir}/${path}" | tr -d ' ')" == "${bytes}" ]] || die "manifest byte mismatch: ${path}"
    [[ "$(sha256_file "${arm_dir}/${path}")" == "${digest}" ]] || die "manifest hash mismatch: ${path}"
  done < <(jq -r '.files[] | [.path, (.bytes|tostring), .sha256] | @tsv' "${manifest}")
  local listed actual
  listed="$(jq -r '.files[].path' "${manifest}" | LC_ALL=C sort)"
  actual="$(cd "${arm_dir}" && find . -type f ! -path './manifest.json' -print | sed 's#^./##' | LC_ALL=C sort)"
  [[ "${listed}" == "${actual}" ]] || die "manifest does not enumerate every artifact file"
}

expected_source_bindings() {
  jq -cn --arg profile "${profile}" '
    [
      "Sources/DistillCore/Librarian/LibrarianEnvelope.swift",
      "Sources/DistillCore/Librarian/LibrarianHandlers.swift",
      "Sources/DistillCore/ManagedRetrieveMCP.swift",
      "Tests/DistillCoreTests/TokenSaverRound2BenchmarkTests.swift",
      "Tests/Fixtures/TokenSaverLocalLLMRound2/envelope-question.json",
      "docs/benchmarks/token-saver-local-llm/round-2/PROTOCOL.md",
      "scripts/token-saver-round2-benchmark.sh"
    ] +
    if $profile == "envelope-slashes-v1" then [
      "docs/benchmarks/token-saver-local-llm/round-2/envelope-slashes/PROTOCOL.md",
      "scripts/token-saver-round2-slash-benchmark.sh"
    ] else [] end
  '
}

expected_report_metadata() {
  if [[ "${profile}" == envelope-slashes-v1 ]]; then
    jq -cn --arg technique "${technique_id}" '{
      technique_id:$technique,
      scenarios:[
        {id:"S0",expected_delta:"nonnegative_per_case_positive_aggregate"},
        {id:"S2",expected_delta:"nonnegative_per_case_positive_aggregate"},
        {id:"S4",expected_delta:"not_applicable_zero"},
        {id:"S6",expected_delta:"nonnegative_per_case_positive_aggregate"}
      ],
      not_applicable:[
        {id:"S1",reason:"slash unescaping applies only to serialized successful envelopes; no catalog lookup is required"},
        {id:"S3",reason:"slash escaping does not change generation, parsing, or retry behavior"},
        {id:"S5",reason:"S1 and S3 are source-bound not applicable for this slash-unescaping technique"}
      ]
    }'
  else
    jq -cn --arg technique "${technique_id}" '{
      technique_id:$technique,
      scenarios:[
        {id:"S0",expected_delta:"positive"},
        {id:"S2",expected_delta:"positive"},
        {id:"S4",expected_delta:"zero"},
        {id:"S6",expected_delta:"positive"}
      ],
      not_applicable:[
        {id:"S1",reason:"ask_handle is a hot declared tool; no catalog lookup is required"},
        {id:"S3",reason:"field elision does not change generation, parsing, or retry behavior"},
        {id:"S5",reason:"S1 and S3 are source-bound not applicable for this field-only technique"}
      ]
    }'
  fi
}

verify_report_metadata() {
  local report="${1:-}" expected
  [[ -n "${report}" ]] || usage
  require_file "${report}"
  expected="$(expected_report_metadata)"
  jq -e --argjson expected "${expected}" '
    .technique_id == $expected.technique_id and
    (.cases | type == "array" and length > 0) and
    all(.cases[];
      ([.scenarios[] | {id,expected_delta}] | sort_by(.id)) == $expected.scenarios and
      .not_applicable == $expected.not_applicable
    )
  ' "${report}" >/dev/null || die "report metadata does not match the exact ${profile} contract"
}

verify_arm() {
  require_tools
  local arm_dir="${1:-}" report expected_bindings
  [[ -n "${arm_dir}" ]] || usage
  if [[ -n "${RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN:-}" && ${#RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN} -lt 8 ]]; then
    die "nonempty auth token must contain at least 8 characters for exact artifact scanning"
  fi
  report="${arm_dir}/report.json"
  require_file "${report}"
  verify_manifest "${arm_dir}"
  expected_bindings="$(expected_source_bindings)"

  jq -e --arg fixture "${fixture_sha}" --arg technique "${technique_id}" --argjson expected_bindings "${expected_bindings}" '
    . as $report |
    .schema_version == 1 and .technique_id == $technique and
    (.arm == "baseline" or .arm == "candidate") and
    .counter == "anthropic-v1-shipping-episode" and
    .token_count_source == "omlx:/v1/messages/count_tokens" and
    .source.dirty == false and
    (.source.git_sha | test("^[0-9a-f]{40}$")) and
    (.source.tree_sha | test("^[0-9a-f]{40}$")) and
    (.source.executable_sha256 | test("^[0-9a-f]{64}$")) and
    (.source.capture_checks | keys | sort) == ["initial","pre_report"] and
    all(.source.capture_checks[];
      .git_sha == $report.source.git_sha and
      .tree_sha == $report.source.tree_sha and
      .status_porcelain == ""
    ) and
    ([.source.bindings[].path] | sort) == ($expected_bindings | sort) and
    all(.source.bindings[];
      (.blob_sha1 | test("^[0-9a-f]{40}$")) and
      (.sha256 | test("^[0-9a-f]{64}$")) and .bytes > 0
    ) and
    .fixture.sha256 == $fixture and .fixture.case_count == 24 and
    .model.server == "oMLX" and (.model.server_version | length > 0) and
    (.model.served_model_path | type == "string" and length > 0) and
    (.model.revision | test("^[0-9a-f]{40}$")) and
    (.model.manifest_sha256 | test("^[0-9a-f]{64}$")) and
    (.model.models_status_before_sha256 | test("^[0-9a-f]{64}$")) and
    (.model.models_status_after_sha256 | test("^[0-9a-f]{64}$")) and
    all(.model.files[];
      (.path | type == "string" and length > 0) and
      (.sha256 | test("^[0-9a-f]{64}$")) and .bytes >= 0 and
      ((.kind == "regular" and .link_target == null) or
       (.kind == "symlink" and (.link_target | type == "string" and length > 0)))
    ) and
    ([.model.files[].path] | index("config.json") != null) and
    ([.model.files[].path] | index("tokenizer.json") != null) and
    ([.model.files[].path] | index("tokenizer_config.json") != null) and
    any(.model.files[]; .path | endswith(".safetensors")) and
    (.cases | length == 24) and ([.cases[].id] | length == (unique | length)) and
    all(.cases[];
      .quality_passed == true and .durable_readback_exact == true and
      .delivery_confirmed == true and .recovery_mode == "token_saver_scoped_persistence" and
      ([.scenarios[].id] | sort) == ["S0","S2","S4","S6"] and
      ([.not_applicable[].id] | sort) == ["S1","S3","S5"] and
      all(.not_applicable[]; (.reason | type == "string" and length > 20)) and
      all(.scenarios[]; .count_replay_verified == true and .input_tokens > 0)
    ) and
    .aggregate.case_count == 24 and .aggregate.quality_passed_cases == 24 and
    .aggregate.measured_scenarios == ["S0","S2","S4","S6"] and
    .aggregate.not_applicable_scenarios == ["S1","S3","S5"] and
    .auth_persisted == false
  ' "${report}" >/dev/null || die "arm report contract invalid"
  verify_report_metadata "${report}"

  local git_sha tree_sha
  git_sha="$(jq -r '.source.git_sha' "${report}")"
  tree_sha="$(jq -r '.source.tree_sha' "${report}")"
  git -C "${repo_root}" cat-file -e "${git_sha}^{commit}" 2>/dev/null || die "source commit unavailable"
  [[ "$(git -C "${repo_root}" rev-parse "${git_sha}^{tree}")" == "${tree_sha}" ]] || die "source tree mismatch"
  while IFS=$'\t' read -r path blob digest bytes; do
    [[ "$(git -C "${repo_root}" rev-parse "${git_sha}:${path}" 2>/dev/null)" == "${blob}" ]] || die "source blob mismatch: ${path}"
    local temporary
    temporary="$(mktemp "${TMPDIR:-/tmp}/token-saver-r2-blob.XXXXXX")"
    git -C "${repo_root}" show "${git_sha}:${path}" > "${temporary}"
    [[ "$(wc -c < "${temporary}" | tr -d ' ')" == "${bytes}" && "$(sha256_file "${temporary}")" == "${digest}" ]] || { rm -f "${temporary}"; die "source content mismatch: ${path}"; }
    rm -f "${temporary}"
  done < <(jq -r '.source.bindings[] | [.path,.blob_sha1,.sha256,(.bytes|tostring)] | @tsv' "${report}")

  local snapshot revision model_id snapshot_physical snapshots_dir models_root served_model_path
  snapshot="$(jq -r '.model.snapshot_path' "${report}")"
  revision="$(jq -r '.model.revision' "${report}")"
  model_id="$(jq -r '.model.id' "${report}")"
  served_model_path="$(jq -r '.model.served_model_path' "${report}")"
  [[ -d "${snapshot}" && ! -L "${snapshot}" ]] || die "model snapshot root is unavailable or a symlink"
  snapshot_physical="$(cd "${snapshot}" && pwd -P)"
  [[ "${snapshot}" == "${snapshot_physical}" && "$(basename "${snapshot_physical}")" == "${revision}" ]] || die "model snapshot/revision is not canonical"
  snapshots_dir="$(dirname "${snapshot_physical}")"
  models_root="$(dirname "${snapshots_dir}")"
  [[ "$(basename "${snapshots_dir}")" == snapshots && "$(basename "${models_root}")" == models--* ]] || die "model snapshot is not inside models--repo/snapshots"
  while IFS=$'\t' read -r path kind link_target bytes digest; do
    [[ "${path}" != /* && "${path}" != *../* ]] || die "unsafe model path"
    case "${kind}" in
      regular)
        [[ -f "${snapshot}/${path}" && ! -L "${snapshot}/${path}" && -z "${link_target}" ]] || die "regular model entry mismatch: ${path}"
        ;;
      symlink)
        [[ -L "${snapshot}/${path}" && ! -d "${snapshot}/${path}" ]] || die "model symlink is missing or resolves to a directory: ${path}"
        [[ "$(readlink "${snapshot}/${path}")" == "${link_target}" ]] || die "model symlink target changed: ${path}"
        local resolved_target
        resolved_target="$(realpath "${snapshot}/${path}")"
        [[ -f "${resolved_target}" && "${resolved_target}" == "${models_root}"/* ]] || die "model symlink escapes its models--repo root: ${path}"
        ;;
      *) die "unknown model entry kind: ${path}" ;;
    esac
    [[ "$(wc -c < "${snapshot}/${path}" | tr -d ' ')" == "${bytes}" && "$(sha256_file "${snapshot}/${path}")" == "${digest}" ]] || die "model file mismatch: ${path}"
  done < <(jq -r '.model.files[] | [.path,.kind,(.link_target // ""),(.bytes|tostring),.sha256] | @tsv' "${report}")
  local listed_model_files actual_model_files
  listed_model_files="$(jq -r '.model.files[].path' "${report}" | LC_ALL=C sort)"
  actual_model_files="$(cd "${snapshot}" && find . \( -type f -o -type l \) -print | sed 's#^./##' | LC_ALL=C sort)"
  [[ "${listed_model_files}" == "${actual_model_files}" ]] || die "model manifest does not enumerate every regular or symlink leaf"
  [[ "$(printf '%s' "$(jq -cS '.model.files' "${report}")" | shasum -a 256 | awk '{print $1}')" == "$(jq -r '.model.manifest_sha256' "${report}")" ]] || die "model manifest mismatch"
  require_file "${arm_dir}/models-response.json"
  require_file "${arm_dir}/models-status-before.json"
  require_file "${arm_dir}/models-status-after.json"
  require_file "${arm_dir}/server-openapi.json"
  [[ "$(sha256_file "${arm_dir}/models-response.json")" == "$(jq -r '.model.models_response_sha256' "${report}")" ]] || die "models response hash mismatch"
  validate_models_response "${arm_dir}/models-response.json" || die "/v1/models response contract invalid"
  [[ "$(sha256_file "${arm_dir}/models-status-before.json")" == "$(jq -r '.model.models_status_before_sha256' "${report}")" ]] || die "models status-before hash mismatch"
  [[ "$(sha256_file "${arm_dir}/models-status-after.json")" == "$(jq -r '.model.models_status_after_sha256' "${report}")" ]] || die "models status-after hash mismatch"
  [[ "$(sha256_file "${arm_dir}/server-openapi.json")" == "$(jq -r '.model.openapi_response_sha256' "${report}")" ]] || die "openapi response hash mismatch"
  [[ "$(jq --arg model "${model_id}" '[.data[].id | select(. == $model)] | length' "${arm_dir}/models-response.json")" == 1 ]] || die "selected model not bound by /v1/models"
  local status_file status_model_path
  for status_file in models-status-before.json models-status-after.json; do
    jq -e --arg model "${model_id}" --arg path "${served_model_path}" '
      [.models[] | select(.id == $model)] as $selected |
      ($selected | length) == 1 and $selected[0].loaded == true and $selected[0].model_path == $path
    ' "${arm_dir}/${status_file}" >/dev/null || die "selected model is not uniquely loaded at the bound path: ${status_file}"
    status_model_path="$(jq -r --arg model "${model_id}" '.models[] | select(.id == $model) | .model_path' "${arm_dir}/${status_file}")"
    [[ ! -L "${status_model_path}" && "$(realpath "${status_model_path}")" == "${snapshot}" ]] || die "served model_path does not resolve exactly to the bound snapshot"
  done

  local arm case_id scenario turn body response replay expected_body expected_emit
  arm="$(jq -r '.arm' "${report}")"
  while IFS= read -r case_id; do
    while IFS=$'\t' read -r scenario turn expected_body expected_emit; do
      body="${arm_dir}/envelopes/${case_id}/${scenario}/${turn}.json"
      response="${arm_dir}/tokenizer-responses/${case_id}/${scenario}/${turn}.json"
      replay="${arm_dir}/tokenizer-responses/${case_id}/${scenario}/${turn}-replay.json"
      require_file "${body}"; require_file "${response}"; require_file "${replay}"
      [[ "$(sha256_file "${body}")" == "${expected_body}" ]] || die "body hash mismatch: ${case_id}/${scenario}"
      [[ "$(printf '%s' "$(jq -cS . "${body}")" | shasum -a 256 | awk '{print $1}')" == "${expected_body}" ]] || die "body is not canonical JSON: ${case_id}/${scenario}"
      jq -e --arg model "${model_id}" '.model == $model' "${body}" >/dev/null || die "provider body model is not the selected model: ${case_id}/${scenario}"
      [[ "$(jq -r '.input_tokens' "${response}")" == "$(jq -r '.input_tokens' "${replay}")" ]] || die "tokenizer replay mismatch: ${case_id}/${scenario}"
      [[ "$(jq -r --arg id "${case_id}" --arg s "${scenario}" '.cases[]|select(.id==$id)|.scenarios[]|select(.id==$s)|.input_tokens' "${report}")" == "$(jq -r '.input_tokens' "${response}")" ]] || die "reported tokens mismatch"
      [[ "$(sha256_file "${arm_dir}/emitted/${case_id}/${scenario}.bin")" == "${expected_emit}" ]] || die "emitted hash mismatch"
    done < <(jq -r --arg id "${case_id}" '.cases[]|select(.id==$id)|.scenarios[]|[.id,.turn,.body_sha256,.emitted_sha256]|@tsv' "${report}")

    local expected_question question_state scenario_turn shipped_envelope
    expected_question="$(jq -r --arg id "${case_id}" '.cases[]|select(.id==$id)|.question' "${repo_root}/${fixture_rel}")"
    for scenario_turn in 'S0/turn-1' 'S2/turn-1' 'S6/turn-2'; do
      shipped_envelope="$(shipping_envelope_text "${arm_dir}/envelopes/${case_id}/${scenario_turn}.json")"
      question_state="$(jq -r '.fallback | has("question")' <<<"${shipped_envelope}")"
      if [[ "${profile}" == envelope-slashes-v1 ]]; then
        [[ "${question_state}" == false ]] || die "slash profile restored fallback.question: ${case_id}/${scenario_turn}"
      elif [[ "${arm}" == baseline ]]; then
        [[ "${question_state}" == true && "$(jq -r '.fallback.question' <<<"${shipped_envelope}")" == "${expected_question}" ]] || die "baseline fallback.question mismatch: ${case_id}/${scenario_turn}"
      else
        [[ "${question_state}" == false ]] || die "candidate retained fallback.question: ${case_id}/${scenario_turn}"
      fi
      jq -e '
        [.messages[].content[]? | select(.type=="tool_use" and .name=="rc_ask") | (.input|keys|sort)][0]
          == ["handle","op","question"]
      ' "${arm_dir}/envelopes/${case_id}/${scenario_turn}.json" >/dev/null || die "rc_ask is not handle-only: ${case_id}/${scenario_turn}"
    done
    [[ "$(printf '%s' "${shipped_envelope}" | shasum -a 256 | awk '{print $1}')" == "$(jq -r --arg id "${case_id}" '.cases[]|select(.id==$id)|.envelope_sha256' "${report}")" ]] || die "reported envelope hash mismatch: ${case_id}"
    [[ "$(sha256_file "${arm_dir}/emitted/${case_id}/S0.bin")" == "$(jq -r --arg id "${case_id}" '.cases[]|select(.id==$id)|.emitted_sha256' "${report}")" ]] || die "reported S0 emitted hash mismatch: ${case_id}"
    jq -e --arg id "${case_id}" --slurpfile fixture "${repo_root}/${fixture_rel}" '
      [.messages[].content[]? | select(.type=="tool_result")][-1] as $retrieve |
      $retrieve.is_error == false and
      ($retrieve.content | length) == 1 and $retrieve.content[0].type == "text" and
      $retrieve.content[0].text == ($fixture[0].cases[]|select(.id==$id)|.source)
    ' "${arm_dir}/envelopes/${case_id}/S2/turn-1.json" >/dev/null || die "S2 retrieve is not byte-exact text: ${case_id}"
    sed -n '2p' "${arm_dir}/emitted/${case_id}/S2.bin" | jq -e --arg id "${case_id}" --slurpfile fixture "${repo_root}/${fixture_rel}" '
      .result.isError == false and
      (.result.content | length) == 1 and .result.content[0].type == "text" and
      .result.content[0].text == ($fixture[0].cases[]|select(.id==$id)|.source)
    ' >/dev/null || die "S2 actual MCP retrieve failed or changed bytes: ${case_id}"
    jq -e '[.messages[].content[]? | select(.type=="tool_result") | .content[]? | select(.type=="text") | (try (.text|fromjson) catch {}) | select(.status=="unavailable") | .fallback | has("question")][0] == false' "${arm_dir}/envelopes/${case_id}/S4/turn-1.json" >/dev/null || die "S4 changed fail-open envelope"
  done < <(jq -r '.cases[].id' "${report}")

  if [[ -n "${RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN:-}" && ${#RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN} -ge 8 ]]; then
    ! grep -R -F -l -- "${RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN}" "${arm_dir}" >/dev/null || die "authorization token persisted"
  fi
  ! grep -R -E -i -l -- 'Authorization:[[:space:]]*Bearer|"authorization"[[:space:]]*:|api[_-]?key[[:space:]]*[:=]' "${arm_dir}" >/dev/null || die "secret/auth material detected"
  echo "verify-arm ok arm=${arm} git_sha=${git_sha} cases=24"
}

escaped_question_fragment() {
  local question="$1" question_json fragment_json
  question_json="$(jq -cn --arg question "${question}" '$question')"
  fragment_json="$(jq -cn --arg fragment ",\"question\":${question_json}" '$fragment')"
  printf '%s' "${fragment_json:1:${#fragment_json}-2}"
}

compare_question_elision_bytes() {
  local baseline_file="$1" candidate_file="$2" question="$3" expected_removals="$4" temporary fragment
  temporary="$(mktemp "${TMPDIR:-/tmp}/token-saver-r2-compare.XXXXXX")"
  fragment="$(escaped_question_fragment "${question}")"
  QUESTION_FRAGMENT="${fragment}" EXPECTED_REMOVALS="${expected_removals}" perl -0pe '
    BEGIN { $needle = $ENV{"QUESTION_FRAGMENT"}; $count = 0; }
    $count += s/\Q$needle\E//g;
    END { die "unexpected fallback.question occurrence count\n" unless $count == $ENV{"EXPECTED_REMOVALS"}; }
  ' "${baseline_file}" > "${temporary}" || { rm -f "${temporary}"; die "could not isolate fallback.question"; }
  cmp -s "${temporary}" "${candidate_file}" || { rm -f "${temporary}"; die "bytes differ outside fallback.question"; }
  rm -f "${temporary}"
}

successful_envelope_text() {
  local file="$1" kind="$2"
  case "${kind}" in
    provider) shipping_envelope_text "${file}" ;;
    emitted)
      jq -jr '[
        .result.content[]?
        | select(.type=="text")
        | select((try (.text | fromjson | .status) catch null) == "ok")
        | .text
      ][0] // empty' "${file}"
      ;;
    *) die "unknown slash comparison kind: ${kind}" ;;
  esac
}

compare_successful_slash_bytes() {
  local baseline_file="$1" candidate_file="$2" kind="$3"
  local baseline_envelope candidate_envelope transformed_envelope baseline_string candidate_string temporary
  require_file "${baseline_file}"
  require_file "${candidate_file}"
  baseline_envelope="$(successful_envelope_text "${baseline_file}" "${kind}")"
  candidate_envelope="$(successful_envelope_text "${candidate_file}" "${kind}")"
  [[ -n "${baseline_envelope}" && -n "${candidate_envelope}" ]] || die "successful envelope unavailable for slash comparison"
  [[ "$(printf '%s' "${baseline_envelope}" | jq -cS .)" == "$(printf '%s' "${candidate_envelope}" | jq -cS .)" ]] || die "slash candidate changed envelope semantics"

  temporary="$(mktemp "${TMPDIR:-/tmp}/token-saver-r2-slash-inner.XXXXXX")"
  perl -0pe '$count += s{\\/}{/}g; END { print STDERR "$count\n"; }' \
    <<<"${baseline_envelope}" > "${temporary}" 2> "${temporary}.count"
  transformed_envelope="$(sed -n '1p' "${temporary}")"
  [[ "${transformed_envelope}" == "${candidate_envelope}" ]] || { rm -f "${temporary}" "${temporary}.count"; die "candidate bytes are not slash-unescaped envelope bytes"; }

  baseline_string="$(jq -Rn --arg text "${baseline_envelope}" '$text')"
  candidate_string="$(jq -Rn --arg text "${candidate_envelope}" '$text')"
  if [[ "${kind}" == emitted ]]; then
    # ManagedRetrieveMCP's outer JSONSerialization escapes every slash. Encode
    # the exact inner-string needles with that same wire representation.
    baseline_string="$(printf '%s' "${baseline_string}" | perl -0pe 's{/}{\\/}g')"
    candidate_string="$(printf '%s' "${candidate_string}" | perl -0pe 's{/}{\\/}g')"
  fi
  BASELINE_ENVELOPE_STRING="${baseline_string}" CANDIDATE_ENVELOPE_STRING="${candidate_string}" perl -0pe '
    BEGIN { $needle = $ENV{"BASELINE_ENVELOPE_STRING"}; $replacement = $ENV{"CANDIDATE_ENVELOPE_STRING"}; $count = 0; }
    $count += s/\Q$needle\E/$replacement/g;
    END { die "successful envelope JSON string occurrence count is not one\n" unless $count == 1; }
  ' "${baseline_file}" > "${temporary}" || { rm -f "${temporary}" "${temporary}.count"; die "could not isolate successful envelope JSON string"; }
  cmp -s "${temporary}" "${candidate_file}" || { rm -f "${temporary}" "${temporary}.count"; die "bytes differ outside the successful envelope slash escaping"; }
  cat "${temporary}.count"
  rm -f "${temporary}" "${temporary}.count"
}

validate_slash_output_formatting_lines() {
  local removed_lines="$1" added_lines="$2"
  [[ "${removed_lines}" == '        e.outputFormatting = [.sortedKeys]' ]] || die "slash candidate removed unexpected product source"
  [[ "${added_lines}" == '        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]' ]] || die "slash candidate is not the exact one-line outputFormatting transformation"
}

verify_slash_product_files() {
  local baseline_file="$1" candidate_file="$2" removed_lines added_lines
  require_file "${baseline_file}"
  require_file "${candidate_file}"
  [[ ! -x "${baseline_file}" && ! -x "${candidate_file}" ]] || die "slash product source mode changed"
  removed_lines="$(diff --unified=0 "${baseline_file}" "${candidate_file}" | sed -n -e '/^--- /d' -e '/^-/s/^-//p' || true)"
  added_lines="$(diff --unified=0 "${baseline_file}" "${candidate_file}" | sed -n -e '/^+++ /d' -e '/^+/s/^+//p' || true)"
  validate_slash_output_formatting_lines "${removed_lines}" "${added_lines}"
}

verify_slash_source_diff() {
  local bsha="$1" csha="$2" changed_paths expected_changed_paths envelope_path test_path
  local removed_lines added_lines test_removed test_added test_added_sha declaration_count path baseline_mode candidate_mode
  changed_paths="$(git -C "${repo_root}" diff --name-only "${bsha}" "${csha}" | LC_ALL=C sort)"
  expected_changed_paths=$'Sources/DistillCore/Librarian/LibrarianEnvelope.swift\nTests/DistillCoreTests/LibrarianCatalogTests.swift'
  [[ "${changed_paths}" == "${expected_changed_paths}" ]] || die "slash candidate path set is not exactly envelope plus focused regression test"
  while IFS= read -r path; do
    baseline_mode="$(git -C "${repo_root}" ls-tree "${bsha}" -- "${path}" | awk '{print $1}')"
    candidate_mode="$(git -C "${repo_root}" ls-tree "${csha}" -- "${path}" | awk '{print $1}')"
    [[ "${baseline_mode}" == 100644 && "${candidate_mode}" == 100644 ]] || die "slash candidate changed source mode: ${path}"
  done <<<"${expected_changed_paths}"

  envelope_path="Sources/DistillCore/Librarian/LibrarianEnvelope.swift"
  removed_lines="$(git -C "${repo_root}" diff --no-ext-diff --unified=0 "${bsha}" "${csha}" -- "${envelope_path}" | sed -n -e '/^--- /d' -e '/^-/s/^-//p')"
  added_lines="$(git -C "${repo_root}" diff --no-ext-diff --unified=0 "${bsha}" "${csha}" -- "${envelope_path}" | sed -n -e '/^+++ /d' -e '/^+/s/^+//p')"
  validate_slash_output_formatting_lines "${removed_lines}" "${added_lines}"

  test_path="Tests/DistillCoreTests/LibrarianCatalogTests.swift"
  test_removed="$(git -C "${repo_root}" diff --no-ext-diff --unified=0 "${bsha}" "${csha}" -- "${test_path}" | sed -n -e '/^--- /d' -e '/^-/s/^-//p')"
  test_added="$(git -C "${repo_root}" diff --no-ext-diff --unified=0 "${bsha}" "${csha}" -- "${test_path}" | sed -n -e '/^+++ /d' -e '/^+/s/^+//p')"
  [[ -z "${test_removed}" ]] || die "slash focused regression diff removes existing test source"
  test_added_sha="$(printf '%s\n' "${test_added}" | shasum -a 256 | awk '{print $1}')"
  [[ "${test_added_sha}" == "${slash_regression_added_sha}" ]] || die "slash focused regression is not the exact frozen additive diff"
  declaration_count="$(printf '%s\n' "${test_added}" | grep -Fxc '    func test_librarianEnvelopeShippingJSONDoesNotEscapeSlashes() throws {' || true)"
  [[ "${declaration_count}" -eq 1 ]] || die "slash candidate omitted the required focused regression test"
}

verify_slash_deltas() {
  local baseline_report="$1" candidate_report="$2"
  require_file "${baseline_report}"
  require_file "${candidate_report}"
  jq -e --slurpfile candidate "${candidate_report}" '
    def token($report;$id;$scenario):
      [$report.cases[]|select(.id==$id)|.scenarios[]|select(.id==$scenario)|.input_tokens] as $tokens |
      if ($tokens|length)==1 then $tokens[0] else error("scenario identity mismatch") end;
    . as $baseline | $candidate[0] as $candidate |
    ([.cases[].id]|sort) == ([$candidate.cases[].id]|sort) and
    ([.cases[].id]|length) == ([.cases[].id]|unique|length) and
    all(.cases[];
      . as $case |
      ([.scenarios[].id]|sort)==["S0","S2","S4","S6"] and
      all(.scenarios[];
        . as $scenario |
        (.input_tokens|type)=="number" and .input_tokens>0 and .input_tokens==(.input_tokens|floor) and
        (token($candidate;$case.id;$scenario.id)|type)=="number" and
        (if .id=="S4"
         then .input_tokens == token($candidate;$case.id;.id)
         else .input_tokens >= token($candidate;$case.id;.id)
         end)
      )
    ) and
    all(["S0","S2","S6"][];
      . as $scenario |
      ([$baseline.cases[].id as $id | token($baseline;$id;$scenario)-token($candidate;$id;$scenario)] | add) > 0
    )
  ' "${baseline_report}" >/dev/null || die "slash token deltas violate per-case, aggregate, or S4 contract"
}

pair_checks() {
  local package="$1" baseline="${1}/baseline" candidate="${1}/candidate"
  verify_arm "${baseline}" >/dev/null
  verify_arm "${candidate}" >/dev/null
  local bsha csha
  bsha="$(jq -r '.source.git_sha' "${baseline}/report.json")"
  csha="$(jq -r '.source.git_sha' "${candidate}/report.json")"
  [[ "${bsha}" != "${csha}" ]] || die "baseline and candidate SHAs are identical"
  [[ "$(git -C "${repo_root}" rev-list --parents -n 1 "${csha}" | awk '{print NF}')" -eq 2 ]] || die "candidate must have exactly one parent"
  [[ "$(git -C "${repo_root}" rev-parse "${csha}^1")" == "${bsha}" ]] || die "candidate is not the direct child of baseline"
  [[ "$(jq -r '.fixture.sha256' "${baseline}/report.json")" == "$(jq -r '.fixture.sha256' "${candidate}/report.json")" ]] || die "fixture changed between arms"
  [[ "$(jq -r '.model.manifest_sha256' "${baseline}/report.json")" == "$(jq -r '.model.manifest_sha256' "${candidate}/report.json")" ]] || die "model/tokenizer changed between arms"
  [[ "$(jq -r '.model.id' "${baseline}/report.json")" == "$(jq -r '.model.id' "${candidate}/report.json")" ]] || die "model id changed between arms"
  [[ "$(jq -r '.model.served_model_path' "${baseline}/report.json")" == "$(jq -r '.model.served_model_path' "${candidate}/report.json")" ]] || die "served model path changed between arms"
  [[ "$(jq -r '.model.snapshot_path' "${baseline}/report.json")" == "$(jq -r '.model.snapshot_path' "${candidate}/report.json")" ]] || die "canonical model snapshot changed between arms"
  [[ "$(jq -r '.model.revision' "${baseline}/report.json")" == "$(jq -r '.model.revision' "${candidate}/report.json")" ]] || die "model revision changed between arms"
  [[ "$(jq -r '.model.server_version' "${baseline}/report.json")" == "$(jq -r '.model.server_version' "${candidate}/report.json")" ]] || die "oMLX server version changed between arms"
  verify_model_catalog_pair "${baseline}/models-response.json" "${candidate}/models-response.json" >/dev/null
  [[ "$(jq -r '.model.openapi_response_sha256' "${baseline}/report.json")" == "$(jq -r '.model.openapi_response_sha256' "${candidate}/report.json")" ]] || die "oMLX server response changed between arms"
  local bound_path baseline_blob candidate_blob
  while IFS= read -r bound_path; do
    if [[ "${profile}" == envelope-slashes-v1 ]]; then
      [[ "${bound_path}" == "Sources/DistillCore/Librarian/LibrarianEnvelope.swift" ]] && continue
    else
      [[ "${bound_path}" == "Sources/DistillCore/Librarian/LibrarianHandlers.swift" ]] && continue
    fi
    baseline_blob="$(jq -r --arg path "${bound_path}" '.source.bindings[]|select(.path==$path)|.blob_sha1' "${baseline}/report.json")"
    candidate_blob="$(jq -r --arg path "${bound_path}" '.source.bindings[]|select(.path==$path)|.blob_sha1' "${candidate}/report.json")"
    [[ "${baseline_blob}" == "${candidate_blob}" ]] || die "harness/protocol source changed between arms: ${bound_path}"
  done < <(jq -r '.source.bindings[].path' "${baseline}/report.json")
  if [[ "${profile}" == envelope-slashes-v1 ]]; then
    verify_slash_source_diff "${bsha}" "${csha}"
  else
  local changed_paths expected_changed_paths
  changed_paths="$(git -C "${repo_root}" diff --name-only "${bsha}" "${csha}" | LC_ALL=C sort)"
  expected_changed_paths=$'Sources/DistillCore/Librarian/LibrarianHandlers.swift\nTests/DistillCoreTests/LibrarianCatalogTests.swift'
  [[ "${changed_paths}" == "${expected_changed_paths}" ]] || die "candidate path set is not exactly product line plus focused regression test"
  local handler_path removed_lines added_lines expected_removed expected_added
  handler_path="Sources/DistillCore/Librarian/LibrarianHandlers.swift"
  expected_removed='            fallback: LibrarianFallback(recommended: "retrieve", handle: resolved.handle, question: request.question)'
  expected_added='            fallback: LibrarianFallback(recommended: "retrieve", handle: resolved.handle)'
  removed_lines="$(git -C "${repo_root}" diff --no-ext-diff --unified=0 "${bsha}" "${csha}" -- "${handler_path}" | sed -n '/^-[^-]/s/^-//p')"
  added_lines="$(git -C "${repo_root}" diff --no-ext-diff --unified=0 "${bsha}" "${csha}" -- "${handler_path}" | sed -n '/^+[^+]/s/^+//p')"
  [[ "${removed_lines}" == "${expected_removed}" && "${added_lines}" == "${expected_added}" ]] || die "candidate is not the exact one-line fallback.question transformation"
  local catalog_path catalog_diff_sha catalog_removed catalog_added regression_declaration_count
  catalog_path="Tests/DistillCoreTests/LibrarianCatalogTests.swift"
  catalog_diff_sha="$(git -C "${repo_root}" diff --no-ext-diff --unified=0 "${bsha}" "${csha}" -- "${catalog_path}" | shasum -a 256 | awk '{print $1}')"
  [[ "${catalog_diff_sha}" == "${catalog_test_diff_sha}" ]] || die "focused regression is not the exact frozen additive diff"
  catalog_removed="$(git -C "${repo_root}" diff --no-ext-diff --unified=0 "${bsha}" "${csha}" -- "${catalog_path}" | sed -n '/^-[^-]/s/^-//p')"
  catalog_added="$(git -C "${repo_root}" diff --no-ext-diff --unified=0 "${bsha}" "${csha}" -- "${catalog_path}" | sed -n '/^+[^+]/s/^+//p')"
  [[ -z "${catalog_removed}" ]] || die "focused regression diff removes existing test source"
  regression_declaration_count="$(printf '%s\n' "${catalog_added}" | grep -Fxc '    func test_askHandle_successEnvelopeDoesNotRepeatToolQuestion() async throws {' || true)"
  [[ "${regression_declaration_count}" -eq 1 ]] || die "candidate omitted the required focused Librarian regression test"
  fi

  local case_id scenario turn bt ct question expected_removals slash_removals
  while IFS= read -r case_id; do
    question="$(jq -r --arg id "${case_id}" '.cases[]|select(.id==$id)|.question' "${repo_root}/${fixture_rel}")"
    for scenario in S0 S2 S4 S6; do
      turn="turn-1"; [[ "${scenario}" == S6 ]] && turn="turn-2"
      if [[ "${profile}" == envelope-slashes-v1 ]]; then
        if [[ "${scenario}" == S4 ]]; then
          cmp -s "${baseline}/envelopes/${case_id}/${scenario}/${turn}.json" "${candidate}/envelopes/${case_id}/${scenario}/${turn}.json" || die "S4 provider body drifted: ${case_id}"
          cmp -s "${baseline}/emitted/${case_id}/${scenario}.bin" "${candidate}/emitted/${case_id}/${scenario}.bin" || die "S4 MCP bytes drifted: ${case_id}"
        else
          slash_removals="$(compare_successful_slash_bytes "${baseline}/envelopes/${case_id}/${scenario}/${turn}.json" "${candidate}/envelopes/${case_id}/${scenario}/${turn}.json" provider)"
          [[ "${slash_removals}" =~ ^[0-9]+$ ]] || die "invalid provider slash removal count: ${case_id}/${scenario}"
          slash_removals="$(compare_successful_slash_bytes "${baseline}/emitted/${case_id}/${scenario}.bin" "${candidate}/emitted/${case_id}/${scenario}.bin" emitted)"
          [[ "${slash_removals}" =~ ^[0-9]+$ ]] || die "invalid MCP slash removal count: ${case_id}/${scenario}"
        fi
      else
        expected_removals=1; [[ "${scenario}" == S4 ]] && expected_removals=0
        compare_question_elision_bytes "${baseline}/envelopes/${case_id}/${scenario}/${turn}.json" "${candidate}/envelopes/${case_id}/${scenario}/${turn}.json" "${question}" "${expected_removals}" || die "non-question body difference: ${case_id}/${scenario}"
        compare_question_elision_bytes "${baseline}/emitted/${case_id}/${scenario}.bin" "${candidate}/emitted/${case_id}/${scenario}.bin" "${question}" "${expected_removals}" || die "non-question emitted difference: ${case_id}/${scenario}"
      fi
      bt="$(jq -r --arg id "${case_id}" --arg s "${scenario}" '.cases[]|select(.id==$id)|.scenarios[]|select(.id==$s)|.input_tokens' "${baseline}/report.json")"
      ct="$(jq -r --arg id "${case_id}" --arg s "${scenario}" '.cases[]|select(.id==$id)|.scenarios[]|select(.id==$s)|.input_tokens' "${candidate}/report.json")"
      if [[ "${scenario}" == S4 ]]; then
        [[ "${bt}" -eq "${ct}" ]] || die "S4 fail-open delta is not zero: ${case_id}"
      elif [[ "${profile}" == envelope-slashes-v1 ]]; then
        [[ "${bt}" -ge "${ct}" ]] || die "negative slash candidate delta: ${case_id}/${scenario}"
      else
        [[ "${bt}" -gt "${ct}" ]] || die "non-positive candidate delta: ${case_id}/${scenario}"
      fi
    done
  done < <(jq -r '.cases[].id' "${baseline}/report.json")
  if [[ "${profile}" == envelope-slashes-v1 ]]; then
    verify_slash_deltas "${baseline}/report.json" "${candidate}/report.json"
  fi
}

verify_pair() {
  require_tools
  local package="${1:-}"
  [[ -n "${package}" ]] || usage
  pair_checks "${package}"
  local report="${package}/pair-report.json" suite="${package}/suite-manifest.json"
  jq -n --slurpfile baseline "${package}/baseline/report.json" --slurpfile candidate "${package}/candidate/report.json" '
    def token($report;$id;$scenario): $report.cases[]|select(.id==$id)|.scenarios[]|select(.id==$scenario)|.input_tokens;
    {
      schema_version:1,
      technique_id:$baseline[0].technique_id,
      counter:$baseline[0].counter,
      baseline_git_sha:$baseline[0].source.git_sha,
      candidate_git_sha:$candidate[0].source.git_sha,
      cases:[ $baseline[0].cases[].id as $id | {
        id:$id,
        scenarios:["S0","S2","S4","S6"] | map(. as $s | {
          id:$s,
          baseline_tokens:token($baseline[0];$id;$s),
          candidate_tokens:token($candidate[0];$id;$s),
          delta:(token($baseline[0];$id;$s)-token($candidate[0];$id;$s))
        })
      }],
      claim:"exact local-tokenizer input tokens on canonical shipping episodes",
      billing_claimed:false,
      decision:"accepted"
    }
  ' > "${report}"
  jq -n \
    --arg baseline_manifest "$(sha256_file "${package}/baseline/manifest.json")" \
    --arg candidate_manifest "$(sha256_file "${package}/candidate/manifest.json")" \
    --arg pair_report "$(sha256_file "${report}")" \
    '{schema_version:1,baseline_manifest_sha256:$baseline_manifest,candidate_manifest_sha256:$candidate_manifest,pair_report_sha256:$pair_report}' > "${suite}"
  verify_suite "${package}"
  echo "verify-pair ok package=${package}"
}

verify_suite() {
  require_tools
  local package="${1:-}" report suite
  [[ -n "${package}" ]] || usage
  report="${package}/pair-report.json"; suite="${package}/suite-manifest.json"
  require_file "${report}"; require_file "${suite}"
  pair_checks "${package}"
  [[ "$(jq -r '.baseline_manifest_sha256' "${suite}")" == "$(sha256_file "${package}/baseline/manifest.json")" ]] || die "suite baseline manifest hash mismatch"
  [[ "$(jq -r '.candidate_manifest_sha256' "${suite}")" == "$(sha256_file "${package}/candidate/manifest.json")" ]] || die "suite candidate manifest hash mismatch"
  [[ "$(jq -r '.pair_report_sha256' "${suite}")" == "$(sha256_file "${report}")" ]] || die "suite pair report hash mismatch"
  jq -e --arg profile "${profile}" --slurpfile baseline "${package}/baseline/report.json" --slurpfile candidate "${package}/candidate/report.json" '
    def token($report;$id;$scenario): $report.cases[]|select(.id==$id)|.scenarios[]|select(.id==$scenario)|.input_tokens;
    .schema_version == 1 and
    .technique_id == $baseline[0].technique_id and
    .counter == $baseline[0].counter and
    .baseline_git_sha == $baseline[0].source.git_sha and
    .candidate_git_sha == $candidate[0].source.git_sha and
    .billing_claimed == false and .decision == "accepted" and
    (.cases|length==24) and
    ([.cases[].id]|sort) == ([$baseline[0].cases[].id]|sort) and
    all(.cases[];
      . as $case |
      ([.scenarios[].id]|sort)==["S0","S2","S4","S6"] and
      all(.scenarios[];
        . as $scenario |
        .baseline_tokens == token($baseline[0];$case.id;$scenario.id) and
        .candidate_tokens == token($candidate[0];$case.id;$scenario.id) and
        .delta == (.baseline_tokens - .candidate_tokens) and
        (if .id=="S4" then .delta==0
         elif $profile=="envelope-slashes-v1" then .delta>=0
         else .delta>0 end)
      )
    ) and
    (if $profile=="envelope-slashes-v1" then
      . as $report |
      all(["S0","S2","S6"][];
        . as $scenario |
        ([$report.cases[].scenarios[]|select(.id==$scenario)|.delta] | add) > 0
      )
     else true end)
  ' "${report}" >/dev/null || die "pair report arithmetic/decision mismatch"
  echo "verify-suite ok package=${package}"
}

command="${1:-}"; shift || true
case "${command}" in
  capture-arm) capture_arm "$@" ;;
  verify-arm) verify_arm "$@" ;;
  verify-pair) verify_pair "$@" ;;
  verify-suite) verify_suite "$@" ;;
  verify-report-metadata)
    [[ "$#" -eq 1 ]] || usage
    verify_report_metadata "$1"
    echo "verify-report-metadata ok profile=${profile}"
    ;;
  verify-source-materialization) verify_source_materialization "$@" ;;
  verify-envelope-hash) verify_envelope_hash "$@" ;;
  verify-model-catalog-pair) verify_model_catalog_pair "$@" ;;
  verify-slash-bytes)
    [[ "${profile}" == envelope-slashes-v1 ]] || die "verify-slash-bytes requires the slash profile"
    [[ "$#" -eq 3 ]] || usage
    compare_successful_slash_bytes "$2" "$3" "$1" >/dev/null
    echo "verify-slash-bytes ok kind=$1"
    ;;
  verify-slash-deltas)
    [[ "${profile}" == envelope-slashes-v1 ]] || die "verify-slash-deltas requires the slash profile"
    [[ "$#" -eq 2 ]] || usage
    verify_slash_deltas "$1" "$2"
    echo "verify-slash-deltas ok"
    ;;
  verify-slash-product-files)
    [[ "${profile}" == envelope-slashes-v1 ]] || die "verify-slash-product-files requires the slash profile"
    [[ "$#" -eq 2 ]] || usage
    verify_slash_product_files "$1" "$2"
    echo "verify-slash-product-files ok"
    ;;
  verify-slash-zero-bytes)
    [[ "${profile}" == envelope-slashes-v1 ]] || die "verify-slash-zero-bytes requires the slash profile"
    [[ "$#" -eq 2 ]] || usage
    require_file "$1"; require_file "$2"
    cmp -s "$1" "$2" || die "zero-delta slash bytes drifted"
    echo "verify-slash-zero-bytes ok"
    ;;
  *) usage ;;
esac
