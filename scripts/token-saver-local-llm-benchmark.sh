#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
corpus_path="${repo_root}/Tests/Fixtures/TokenSaverLocalLLM/corpus.json"
protocol_path="${repo_root}/docs/benchmarks/token-saver-local-llm/PROTOCOL.md"
expected_corpus_sha256="e520d7c4f4149684b3dafa14c796a6965ed7dc8073ae2bbd7e09e347fc6d4646"

die() {
  echo "token-saver-local-llm-benchmark: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/token-saver-local-llm-benchmark.sh verify-protocol
  scripts/token-saver-local-llm-benchmark.sh capture <baseline|candidate|final> <report.json>
  scripts/token-saver-local-llm-benchmark.sh verify-baseline <baseline.json>
  scripts/token-saver-local-llm-benchmark.sh verify-improvement <baseline.json> <candidate-or-final.json>
  scripts/token-saver-local-llm-benchmark.sh verify-integrity <report.json>
  scripts/token-saver-local-llm-benchmark.sh verify-quality <report.json>
  scripts/token-saver-local-llm-benchmark.sh verify-iterations <iterations.json>
  scripts/token-saver-local-llm-benchmark.sh verify-all <baseline.json> <candidate-or-final.json> <iterations.json>

Live capture requires these environment variables (the auth value is inherited, never printed):
  RC_TOKEN_SAVER_BENCHMARK_BASE_URL=http://127.0.0.1:8000/v1
  RC_TOKEN_SAVER_BENCHMARK_MODEL=<exact model id>
  RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION=<immutable model revision>
  RC_TOKEN_SAVER_BENCHMARK_AUTH_TOKEN=<optional bearer token>
USAGE
  exit 2
}

require_tools() {
  command -v jq >/dev/null 2>&1 || die "jq is required for benchmark verification"
  command -v shasum >/dev/null 2>&1 || die "shasum is required for benchmark verification"
}

require_file() {
  [[ -f "$1" ]] || die "missing file: $1"
}

corpus_sha256() {
  shasum -a 256 "${corpus_path}" | awk '{print $1}'
}

verify_protocol() {
  require_tools
  require_file "${corpus_path}"
  require_file "${protocol_path}"
  local actual_sha
  actual_sha="$(corpus_sha256)"
  [[ "${actual_sha}" == "${expected_corpus_sha256}" ]] || die "corpus SHA mismatch: ${actual_sha}"
  grep -Fq "${expected_corpus_sha256}" "${protocol_path}" || die "protocol does not pin the corpus SHA"
  jq -e '
    .schema_version == 1 and
    .corpus_id == "token-saver-local-llm-v1" and
    (.cases | length >= 24) and
    ([.cases[].id] | length == (unique | length)) and
    ([.cases[].cohort] | unique | length >= 12) and
    all(.cases[];
      . as $case |
      (.id | test("^TSLLM-[0-9]{3}$")) and
      (.cohort | type == "string" and length > 0) and
      (.input | type == "string" and length > 0) and
      (.question | type == "string" and length > 0) and
      (.next_action | type == "string" and length > 0) and
      (.required_literals | type == "array" and length > 0) and
      all(.required_literals[]; . as $literal | ($literal | type == "string" and length > 0) and ($case.input | contains($literal)))
    )
  ' "${corpus_path}" >/dev/null || die "corpus schema, IDs, diversity, or quality pins are invalid"
  echo "protocol ok corpus_sha256=${actual_sha} cases=$(jq '.cases | length' "${corpus_path}")"
}

verify_integrity() {
  require_tools
  local report="${1:-}"
  [[ -n "${report}" ]] || usage
  require_file "${report}"
  jq -e --arg expected_sha "${expected_corpus_sha256}" '
    . as $report |
    .schema_version == 1 and
    (.capture_kind == "baseline" or .capture_kind == "candidate" or .capture_kind == "final") and
    (.captured_at | type == "string" and length > 0) and
    .token_count_source == "omlx:/v1/messages/count_tokens" and
    (.model.id | type == "string" and length > 0) and
    (.model.revision | type == "string" and length > 0) and
    .model.server == "oMLX" and
    .corpus.id == "token-saver-local-llm-v1" and
    .corpus.sha256 == $expected_sha and
    .corpus.case_count == (.cases | length) and
    .corpus.case_count >= 24 and
    ([.cases[].id] | length == (unique | length)) and
    (.protocol.warmup_runs >= 1) and
    (.protocol.measured_runs_per_case >= 1) and
    (.protocol.max_output_characters >= 128) and
    (.aggregate.case_count == (.cases | length)) and
    (.aggregate.input_tokens == ([.cases[].input_tokens] | add)) and
    (.aggregate.output_tokens_before_handle == ([.cases[].output_tokens_before_handle] | add)) and
    (.aggregate.final_output_tokens == ([.cases[].final_output_tokens] | add)) and
    (.aggregate.handle_overhead_tokens == ([.cases[].handle_overhead_tokens] | add)) and
    (.aggregate.net_tokens_saved == (.aggregate.input_tokens - .aggregate.final_output_tokens)) and
    (.aggregate.next_action_ready_cases == ([.cases[] | select(.next_action_ready == true)] | length)) and
    (.aggregate.quality_passed_cases == ([.cases[] | select(.quality_passed == true)] | length)) and
    (.aggregate.changed_cases == ([.cases[] | select(.output_changed == true)] | length)) and
    (.aggregate.recovery_readback_verified_cases == ([.cases[] | select(.recovery_readback_verified == true)] | length)) and
    all(.cases[];
      . as $case |
      (.id | test("^TSLLM-[0-9]{3}$")) and
      (.route == "deterministic" or .route == "encoder_bert" or .route == "llm_mlx" or .route == "verbatim") and
      (.route_stable | type == "boolean") and
      (.output_stable | type == "boolean") and
      (.recovery_readback_verified | type == "boolean") and
      (.measured_runs == $report.protocol.measured_runs_per_case) and
      (.latency_ms | length == .measured_runs) and
      (.input_tokens >= 0) and
      (.output_tokens_before_handle >= 0) and
      (.final_output_tokens >= 0) and
      (.handle_overhead_tokens == ([.final_output_tokens - .output_tokens_before_handle, 0] | max)) and
      (.net_tokens_saved == (.input_tokens - .final_output_tokens)) and
      (if .output_changed then
         (.handle_marker | test("^\\[\\[rc:rcv1\\.[0-9a-f]{24}\\]\\]$")) and
         (.recovery_readback_verified == true) and
         (.final_envelope | endswith($case.handle_marker))
       else
         .handle_marker == null and .recovery_readback_verified == false and .final_envelope == .output
       end)
    )
  ' "${report}" >/dev/null || die "report integrity failed: ${report}"
  echo "integrity ok report=${report}"
}

verify_quality() {
  require_tools
  local report="${1:-}"
  [[ -n "${report}" ]] || usage
  require_file "${report}"
  jq -e '
    .aggregate.quality_passed_cases == .aggregate.case_count and
    all(.cases[];
      (.quality_passed == true) and
      (.missing_required_literals | type == "array") and
      (if .next_action_ready then (.missing_required_literals | length == 0)
       else (.missing_required_literals | length > 0) and (.handle_marker != null) and (.recovery_readback_verified == true)
       end)
    )
  ' "${report}" >/dev/null || die "quality gate failed: ${report}"
  echo "quality ok report=${report} direct=$(jq -r '.aggregate.next_action_ready_cases | tostring' "${report}")/$(jq -r '.aggregate.case_count | tostring' "${report}")"
}

verify_baseline() {
  local report="${1:-}"
  [[ -n "${report}" ]] || usage
  verify_integrity "${report}"
  verify_quality "${report}"
  jq -e '
    .capture_kind == "baseline" and
    .aggregate.input_tokens > 0 and
    .aggregate.final_output_tokens < .aggregate.input_tokens and
    .aggregate.net_tokens_saved > 0
  ' "${report}" >/dev/null || die "baseline did not prove positive exact-token savings"
  echo "baseline ok saved=$(jq -r '.aggregate.net_tokens_saved' "${report}") exact_tokens"
}

verify_improvement() {
  require_tools
  local baseline="${1:-}"
  local final_report="${2:-}"
  [[ -n "${baseline}" && -n "${final_report}" ]] || usage
  verify_baseline "${baseline}"
  verify_integrity "${final_report}"
  verify_quality "${final_report}"
  jq -n -e --slurpfile baseline "${baseline}" --slurpfile final "${final_report}" '
    ($baseline[0]) as $b |
    ($final[0]) as $f |
    ($f.capture_kind == "candidate" or $f.capture_kind == "final") and
    $b.token_count_source == $f.token_count_source and
    $b.model.id == $f.model.id and
    $b.model.revision == $f.model.revision and
    $b.corpus.sha256 == $f.corpus.sha256 and
    $b.protocol == $f.protocol and
    ($b.cases | map(.id)) == ($f.cases | map(.id)) and
    ($b.cases | map(.input_tokens)) == ($f.cases | map(.input_tokens)) and
    $f.aggregate.next_action_ready_cases >= $b.aggregate.next_action_ready_cases and
    $f.aggregate.final_output_tokens < $b.aggregate.final_output_tokens and
    $f.aggregate.net_tokens_saved > $b.aggregate.net_tokens_saved
  ' >/dev/null || die "candidate is incomparable, regresses action quality, or saves no additional exact tokens"
  local delta
  delta="$(jq -n -r --slurpfile baseline "${baseline}" --slurpfile final "${final_report}" '$final[0].aggregate.net_tokens_saved - $baseline[0].aggregate.net_tokens_saved')"
  echo "improvement ok additional_exact_tokens=${delta}"
}

verify_iterations() {
  require_tools
  local iterations="${1:-}"
  [[ -n "${iterations}" ]] || usage
  require_file "${iterations}"
  jq -e '
    .schema_version == 1 and
    (.iterations | type == "array" and length >= 1) and
    all(.iterations[];
      (.id | type == "string" and length > 0) and
      (.technique | type == "string" and length > 0) and
      (.status == "accepted" or .status == "rejected") and
      (.reason | type == "string" and length > 0) and
      (.measured_additional_tokens | type == "number") and
      (.quality_regressions | type == "number" and . >= 0)
    ) and
    .terminal.status == "no_improvement" and
    (.terminal.reason | type == "string" and length > 0)
  ' "${iterations}" >/dev/null || die "iteration ledger lacks measured decisions or a terminal no_improvement pass"
  echo "iterations ok attempts=$(jq '.iterations | length' "${iterations}") terminal=no_improvement"
}

capture() {
  local kind="${1:-}"
  local report="${2:-}"
  [[ "${kind}" == "baseline" || "${kind}" == "candidate" || "${kind}" == "final" ]] || usage
  [[ -n "${report}" ]] || usage
  : "${RC_TOKEN_SAVER_BENCHMARK_BASE_URL:?set RC_TOKEN_SAVER_BENCHMARK_BASE_URL}"
  : "${RC_TOKEN_SAVER_BENCHMARK_MODEL:?set RC_TOKEN_SAVER_BENCHMARK_MODEL}"
  : "${RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION:?set RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION}"
  verify_protocol
  RC_TOKEN_SAVER_LOCAL_LLM_BENCHMARK=1 \
  RC_TOKEN_SAVER_BENCHMARK_CAPTURE_KIND="${kind}" \
  RC_TOKEN_SAVER_BENCHMARK_OUTPUT="${report}" \
    "${repo_root}/scripts/isolated-sandbox.sh" test \
      --filter TokenSaverLocalLLMBenchmarkTests/test_liveCaptureAgainstOMLXWithExactTokenizer
  verify_integrity "${report}"
  verify_quality "${report}"
  if [[ "${kind}" == "baseline" ]]; then
    verify_baseline "${report}"
  fi
  echo "capture ok kind=${kind} report=${report} auth=$([[ -n "${RC_TOKEN_SAVER_BENCHMARK_AUTH_TOKEN:-}" ]] && echo set || echo empty)"
}

verify_all() {
  local baseline="${1:-}"
  local final_report="${2:-}"
  local iterations="${3:-}"
  [[ -n "${baseline}" && -n "${final_report}" && -n "${iterations}" ]] || usage
  verify_protocol
  verify_improvement "${baseline}" "${final_report}"
  verify_iterations "${iterations}"
  echo "all benchmark gates passed"
}

command_name="${1:-}"
shift || true
case "${command_name}" in
  verify-protocol) verify_protocol "$@" ;;
  capture) capture "$@" ;;
  verify-baseline) verify_baseline "$@" ;;
  verify-improvement) verify_improvement "$@" ;;
  verify-integrity) verify_integrity "$@" ;;
  verify-quality) verify_quality "$@" ;;
  verify-iterations) verify_iterations "$@" ;;
  verify-all) verify_all "$@" ;;
  *) usage ;;
esac
