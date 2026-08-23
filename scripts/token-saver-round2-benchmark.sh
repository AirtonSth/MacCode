#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
fixture_rel="Tests/Fixtures/TokenSaverLocalLLMRound2/envelope-question.json"
fixture_sha="2f7f815fa8efa3891809c1b66cbcc1b495c016d848401cf78d628cd836c00749"
technique_id="librarian-success-fallback-question-elision-v1"

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

require_tools() {
  command -v git >/dev/null || die "git is required"
  command -v jq >/dev/null || die "jq is required"
  command -v shasum >/dev/null || die "shasum is required"
  command -v swift >/dev/null || die "swift is required"
}

verify_fixture() {
  require_file "${repo_root}/${fixture_rel}"
  [[ "$(sha256_file "${repo_root}/${fixture_rel}")" == "${fixture_sha}" ]] || die "fixture SHA mismatch"
  jq -e --arg technique "${technique_id}" '
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

capture_arm() {
  require_tools
  verify_fixture
  local arm="${1:-}" expected_sha="${2:-}" output="${3:-}"
  [[ "${arm}" == baseline || "${arm}" == candidate ]] || usage
  [[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || die "expected SHA must be 40 lowercase hex"
  [[ -n "${output}" ]] || usage
  [[ "$(git -C "${repo_root}" rev-parse HEAD)" == "${expected_sha}" ]] || die "HEAD is not the requested arm SHA"
  [[ -z "$(git -C "${repo_root}" status --porcelain --untracked-files=all)" ]] || die "capture arm checkout is dirty"
  [[ ! -e "${output}" ]] || die "arm output already exists"
  case "$(cd "$(dirname "${output}")" && pwd -P)/$(basename "${output}")" in
    "${repo_root}"|"${repo_root}"/*) die "arm output must be outside its source checkout" ;;
  esac
  [[ -n "${RC_TOKEN_SAVER_ROUND2_BASE_URL:-}" ]] || die "missing RC_TOKEN_SAVER_ROUND2_BASE_URL"
  [[ -n "${RC_TOKEN_SAVER_ROUND2_MODEL:-}" ]] || die "missing RC_TOKEN_SAVER_ROUND2_MODEL"
  [[ -n "${RC_TOKEN_SAVER_ROUND2_MODEL_SNAPSHOT:-}" ]] || die "missing RC_TOKEN_SAVER_ROUND2_MODEL_SNAPSHOT"
  if [[ "${arm}" == candidate ]]; then
    [[ -n "${RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR:-}" ]] || die "candidate requires baseline recovery seed"
    "$0" verify-arm "${RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR}"
    [[ "$(jq -r '.arm' "${RC_TOKEN_SAVER_ROUND2_RECOVERY_SEED_DIR}/report.json")" == baseline ]] || die "candidate seed is not a baseline arm"
  fi

  local scratch
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/token-saver-r2-build.XXXXXX")"
  trap 'rm -rf -- "${scratch}"' RETURN
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
  "$0" verify-arm "${output}"
  echo "capture-arm ok arm=${arm} git_sha=${expected_sha} output=${output}"
}

verify_manifest() {
  local arm_dir="$1" manifest="${1}/manifest.json"
  require_file "${manifest}"
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
  actual="$(cd "${arm_dir}" && find . -type f ! -name manifest.json -print | sed 's#^./##' | LC_ALL=C sort)"
  [[ "${listed}" == "${actual}" ]] || die "manifest does not enumerate every artifact file"
}

verify_arm() {
  require_tools
  local arm_dir="${1:-}" report
  [[ -n "${arm_dir}" ]] || usage
  report="${arm_dir}/report.json"
  require_file "${report}"
  verify_manifest "${arm_dir}"

  jq -e --arg fixture "${fixture_sha}" --arg technique "${technique_id}" '
    .schema_version == 1 and .technique_id == $technique and
    (.arm == "baseline" or .arm == "candidate") and
    .counter == "anthropic-v1-shipping-episode" and
    .token_count_source == "omlx:/v1/messages/count_tokens" and
    .source.dirty == false and
    (.source.git_sha | test("^[0-9a-f]{40}$")) and
    (.source.tree_sha | test("^[0-9a-f]{40}$")) and
    (.source.executable_sha256 | test("^[0-9a-f]{64}$")) and
    ([.source.bindings[].path] | sort) == [
      "Sources/DistillCore/Librarian/LibrarianEnvelope.swift",
      "Sources/DistillCore/Librarian/LibrarianHandlers.swift",
      "Sources/DistillCore/ManagedRetrieveMCP.swift",
      "Tests/DistillCoreTests/TokenSaverRound2BenchmarkTests.swift",
      "Tests/Fixtures/TokenSaverLocalLLMRound2/envelope-question.json",
      "docs/benchmarks/token-saver-local-llm/round-2/PROTOCOL.md",
      "scripts/token-saver-round2-benchmark.sh"
    ] and
    all(.source.bindings[];
      (.blob_sha1 | test("^[0-9a-f]{40}$")) and
      (.sha256 | test("^[0-9a-f]{64}$")) and .bytes > 0
    ) and
    .fixture.sha256 == $fixture and .fixture.case_count == 24 and
    .model.server == "oMLX" and (.model.server_version | length > 0) and
    (.model.revision | test("^[0-9a-f]{40}$")) and
    (.model.manifest_sha256 | test("^[0-9a-f]{64}$")) and
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

  local snapshot revision model_id
  snapshot="$(jq -r '.model.snapshot_path' "${report}")"
  revision="$(jq -r '.model.revision' "${report}")"
  model_id="$(jq -r '.model.id' "${report}")"
  [[ -d "${snapshot}" && "$(basename "$(cd "${snapshot}" && pwd -P)")" == "${revision}" ]] || die "model snapshot/revision is unbound"
  while IFS=$'\t' read -r path bytes digest; do
    [[ "${path}" != /* && "${path}" != *../* ]] || die "unsafe model path"
    require_file "${snapshot}/${path}"
    [[ "$(wc -c < "${snapshot}/${path}" | tr -d ' ')" == "${bytes}" && "$(sha256_file "${snapshot}/${path}")" == "${digest}" ]] || die "model file mismatch: ${path}"
  done < <(jq -r '.model.files[] | [.path,(.bytes|tostring),.sha256] | @tsv' "${report}")
  [[ "$(printf '%s' "$(jq -cS '.model.files' "${report}")" | shasum -a 256 | awk '{print $1}')" == "$(jq -r '.model.manifest_sha256' "${report}")" ]] || die "model manifest mismatch"
  [[ "$(sha256_file "${arm_dir}/models-response.json")" == "$(jq -r '.model.models_response_sha256' "${report}")" ]] || die "models response hash mismatch"
  [[ "$(sha256_file "${arm_dir}/server-openapi.json")" == "$(jq -r '.model.openapi_response_sha256' "${report}")" ]] || die "openapi response hash mismatch"
  [[ "$(jq --arg model "${model_id}" '[.data[].id | select(. == $model)] | length' "${arm_dir}/models-response.json")" == 1 ]] || die "selected model not bound by /v1/models"

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
      [[ "$(jq -r '.input_tokens' "${response}")" == "$(jq -r '.input_tokens' "${replay}")" ]] || die "tokenizer replay mismatch: ${case_id}/${scenario}"
      [[ "$(jq -r --arg id "${case_id}" --arg s "${scenario}" '.cases[]|select(.id==$id)|.scenarios[]|select(.id==$s)|.input_tokens' "${report}")" == "$(jq -r '.input_tokens' "${response}")" ]] || die "reported tokens mismatch"
      [[ "$(sha256_file "${arm_dir}/emitted/${case_id}/${scenario}.bin")" == "${expected_emit}" ]] || die "emitted hash mismatch"
    done < <(jq -r --arg id "${case_id}" '.cases[]|select(.id==$id)|.scenarios[]|[.id,.turn,.body_sha256,.emitted_sha256]|@tsv' "${report}")

    local expected_question question_state scenario_turn shipped_envelope
    expected_question="$(jq -r --arg id "${case_id}" '.cases[]|select(.id==$id)|.question' "${repo_root}/${fixture_rel}")"
    for scenario_turn in 'S0/turn-1' 'S2/turn-1' 'S6/turn-2'; do
      shipped_envelope="$(jq -c '[.messages[].content[]? | select(.type=="tool_result") | .content[]? | select(.type=="text") | (try (.text|fromjson) catch {}) | select(.status=="ok")][0]' "${arm_dir}/envelopes/${case_id}/${scenario_turn}.json")"
      question_state="$(jq -r '.fallback | has("question")' <<<"${shipped_envelope}")"
      if [[ "${arm}" == baseline ]]; then
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
      [.messages[].content[]? | select(.type=="tool_result") | .content[]? | select(.type=="text") | .text][-1]
        == ($fixture[0].cases[]|select(.id==$id)|.source)
    ' "${arm_dir}/envelopes/${case_id}/S2/turn-1.json" >/dev/null || die "S2 retrieve is not byte-exact text: ${case_id}"
    jq -e '[.messages[].content[]? | select(.type=="tool_result") | .content[]? | select(.type=="text") | (try (.text|fromjson) catch {}) | select(.status=="unavailable") | .fallback | has("question")][0] == false' "${arm_dir}/envelopes/${case_id}/S4/turn-1.json" >/dev/null || die "S4 changed fail-open envelope"
  done < <(jq -r '.cases[].id' "${report}")

  if [[ -n "${RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN:-}" && ${#RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN} -ge 8 ]]; then
    ! grep -R -F -l -- "${RC_TOKEN_SAVER_ROUND2_AUTH_TOKEN}" "${arm_dir}" >/dev/null || die "authorization token persisted"
  fi
  ! grep -R -E -i -l -- 'Authorization:[[:space:]]*Bearer|"authorization"[[:space:]]*:|api[_-]?key[[:space:]]*[:=]' "${arm_dir}" >/dev/null || die "secret/auth material detected"
  echo "verify-arm ok arm=${arm} git_sha=${git_sha} cases=24"
}

normalize_body() {
  jq -cS '
    def stripq:
      . as $s | (try ($s|fromjson) catch null) as $j |
      if ($j|type)=="object" and ($j|has("fallback")) then ($j|del(.fallback.question)|tojson) else $s end;
    (.messages[].content[]? | select(.type=="tool_result") | .content[]? | select(.type=="text") | .text) |= stripq
  ' "$1"
}

normalize_emitted() {
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line}" | jq -cS '
      def stripq:
        . as $s | (try ($s|fromjson) catch null) as $j |
        if ($j|type)=="object" and ($j|has("fallback")) then ($j|del(.fallback.question)|tojson) else $s end;
      (.result.content[]? | select(.type=="text") | .text) |= stripq
    '
  done < "$1"
}

pair_checks() {
  local package="$1" baseline="${1}/baseline" candidate="${1}/candidate"
  verify_arm "${baseline}" >/dev/null
  verify_arm "${candidate}" >/dev/null
  local bsha csha
  bsha="$(jq -r '.source.git_sha' "${baseline}/report.json")"
  csha="$(jq -r '.source.git_sha' "${candidate}/report.json")"
  [[ "${bsha}" != "${csha}" ]] || die "baseline and candidate SHAs are identical"
  [[ "$(git -C "${repo_root}" rev-parse "${csha}^")" == "${bsha}" ]] || die "candidate is not the direct child of baseline"
  [[ "$(jq -r '.fixture.sha256' "${baseline}/report.json")" == "$(jq -r '.fixture.sha256' "${candidate}/report.json")" ]] || die "fixture changed between arms"
  [[ "$(jq -r '.model.manifest_sha256' "${baseline}/report.json")" == "$(jq -r '.model.manifest_sha256' "${candidate}/report.json")" ]] || die "model/tokenizer changed between arms"
  [[ "$(jq -r '.model.models_response_sha256' "${baseline}/report.json")" == "$(jq -r '.model.models_response_sha256' "${candidate}/report.json")" ]] || die "/v1/models response changed between arms"
  [[ "$(jq -r '.model.openapi_response_sha256' "${baseline}/report.json")" == "$(jq -r '.model.openapi_response_sha256' "${candidate}/report.json")" ]] || die "oMLX server response changed between arms"
  local bound_path baseline_blob candidate_blob
  while IFS= read -r bound_path; do
    [[ "${bound_path}" == "Sources/DistillCore/Librarian/LibrarianHandlers.swift" ]] && continue
    baseline_blob="$(jq -r --arg path "${bound_path}" '.source.bindings[]|select(.path==$path)|.blob_sha1' "${baseline}/report.json")"
    candidate_blob="$(jq -r --arg path "${bound_path}" '.source.bindings[]|select(.path==$path)|.blob_sha1' "${candidate}/report.json")"
    [[ "${baseline_blob}" == "${candidate_blob}" ]] || die "harness/protocol source changed between arms: ${bound_path}"
  done < <(jq -r '.source.bindings[].path' "${baseline}/report.json")
  local changed_path saw_handler=false
  while IFS= read -r changed_path; do
    case "${changed_path}" in
      Sources/DistillCore/Librarian/LibrarianHandlers.swift) saw_handler=true ;;
      Tests/DistillCoreTests/LibrarianCatalogTests.swift) ;;
      *) die "candidate commit contains an unrelated path: ${changed_path}" ;;
    esac
  done < <(git -C "${repo_root}" diff --name-only "${bsha}" "${csha}")
  [[ "${saw_handler}" == true ]] || die "candidate commit does not contain the technique source change"

  local case_id scenario turn bt ct
  while IFS= read -r case_id; do
    for scenario in S0 S2 S4 S6; do
      turn="turn-1"; [[ "${scenario}" == S6 ]] && turn="turn-2"
      [[ "$(normalize_body "${baseline}/envelopes/${case_id}/${scenario}/${turn}.json")" == "$(normalize_body "${candidate}/envelopes/${case_id}/${scenario}/${turn}.json")" ]] || die "non-question body difference: ${case_id}/${scenario}"
      [[ "$(normalize_emitted "${baseline}/emitted/${case_id}/${scenario}.bin")" == "$(normalize_emitted "${candidate}/emitted/${case_id}/${scenario}.bin")" ]] || die "non-question emitted difference: ${case_id}/${scenario}"
      bt="$(jq -r --arg id "${case_id}" --arg s "${scenario}" '.cases[]|select(.id==$id)|.scenarios[]|select(.id==$s)|.input_tokens' "${baseline}/report.json")"
      ct="$(jq -r --arg id "${case_id}" --arg s "${scenario}" '.cases[]|select(.id==$id)|.scenarios[]|select(.id==$s)|.input_tokens' "${candidate}/report.json")"
      if [[ "${scenario}" == S4 ]]; then
        [[ "${bt}" -eq "${ct}" ]] || die "S4 fail-open delta is not zero: ${case_id}"
      else
        [[ "${bt}" -gt "${ct}" ]] || die "non-positive candidate delta: ${case_id}/${scenario}"
      fi
    done
  done < <(jq -r '.cases[].id' "${baseline}/report.json")
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
  jq -e --slurpfile baseline "${package}/baseline/report.json" --slurpfile candidate "${package}/candidate/report.json" '
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
        (if .id=="S4" then .delta==0 else .delta>0 end)
      )
    )
  ' "${report}" >/dev/null || die "pair report arithmetic/decision mismatch"
  echo "verify-suite ok package=${package}"
}

command="${1:-}"; shift || true
case "${command}" in
  capture-arm) capture_arm "$@" ;;
  verify-arm) verify_arm "$@" ;;
  verify-pair) verify_pair "$@" ;;
  verify-suite) verify_suite "$@" ;;
  *) usage ;;
esac
