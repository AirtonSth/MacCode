#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
fixture_path="${repo_root}/Tests/Fixtures/TokenSaverLocalLLM/technique-corpus.json"
protocol_path="${repo_root}/docs/benchmarks/token-saver-local-llm/TECHNIQUE-PROTOCOL.md"
expected_fixture_sha256="183f33c9d25fc5ac7d07631dd99f9e03bb141464ce22d0816a03107763cb3143"

die() {
  echo "token-saver-technique-benchmark: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/token-saver-technique-benchmark.sh verify-protocol
  scripts/token-saver-technique-benchmark.sh capture <A|B|C> <baseline-git-sha> <candidate-git-sha> <artifact.json>
  scripts/token-saver-technique-benchmark.sh verify <artifact.json>
  scripts/token-saver-technique-benchmark.sh verify-d <technique-D.json>
  scripts/token-saver-technique-benchmark.sh verify-terminal-candidates <terminal-candidates.json>
  scripts/token-saver-technique-benchmark.sh verify-iterations <iterations.json>
  scripts/token-saver-technique-benchmark.sh assemble <A.json> <B.json> <C.json> <iterations.json> <suite.json>
  scripts/token-saver-technique-benchmark.sh verify-suite <suite.json>

Live capture reuses the general runner environment:
  RC_TOKEN_SAVER_BENCHMARK_BASE_URL=http://127.0.0.1:8000/v1
  RC_TOKEN_SAVER_BENCHMARK_MODEL=<exact model id>
  RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION=<40-hex immutable revision>
  RC_TOKEN_SAVER_BENCHMARK_AUTH_TOKEN=<optional bearer token; never printed>

Dirty capture is refused. RC_TOKEN_SAVER_TECHNIQUE_ALLOW_DIRTY=1 permits only a
local diagnostic artifact; verify intentionally rejects every dirty artifact.
USAGE
  exit 2
}

require_tools() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v shasum >/dev/null 2>&1 || die "shasum is required"
  command -v git >/dev/null 2>&1 || die "git is required"
}

require_file() {
  [[ -f "$1" ]] || die "missing file: $1"
}

file_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_protocol() {
  require_tools
  require_file "${fixture_path}"
  require_file "${protocol_path}"
  local actual_sha
  actual_sha="$(file_sha256 "${fixture_path}")"
  [[ "${actual_sha}" == "${expected_fixture_sha256}" ]] || die "fixture SHA mismatch: ${actual_sha}"
  grep -Fq "${expected_fixture_sha256}" "${protocol_path}" || die "protocol does not pin the fixture SHA"
  jq -e '
    .schema_version == 1 and
    .corpus_id == "token-saver-techniques-v1" and
    .technique_a.expected_catalog == {
      "total": 188,
      "baseline_exposed": 169,
      "enabled": 168,
      "forbidden": 19,
      "disabled": 1,
      "hot_hints": 8
    } and
    ([.technique_a.episodes[].id] | sort) == ["A-COLD", "A-HOT"] and
    ([.technique_a.episodes[].kind] | sort) == ["cold", "hot"] and
    ([.technique_b.episodes[].id] | sort) == ["B-NO-RETRIEVE", "B-WITH-RETRIEVE"] and
    ([.technique_b.episodes[].requires_retrieve] | sort) == [false, true] and
    ([.technique_c.cases[].id] | sort) == ["C-HEAD", "C-MIDDLE", "C-TAIL"] and
    ([.technique_c.cases[].evidence_position] | sort) == ["head", "middle", "tail"] and
    .technique_c.budget_bytes == 6000 and
    all(.technique_c.cases[];
      .line_count >= 300 and
      .evidence_line >= 0 and .evidence_line < .line_count and
      (.required_literals | length >= 1) and
      all(.required_literals[]; type == "string" and length > 0)
    )
  ' "${fixture_path}" >/dev/null || die "fixture schema or locked quality contract is invalid"
  echo "protocol ok fixture_sha256=${actual_sha} techniques=A,B,C"
}

verify_artifact() {
  require_tools
  local artifact="${1:-}"
  [[ -n "${artifact}" ]] || usage
  require_file "${artifact}"
  verify_protocol >/dev/null

  jq -e --arg fixture_sha "${expected_fixture_sha256}" '
    def pctl($fraction):
      sort |
      if length == 0 then 0
      else .[((length * $fraction | ceil) - 1) | if . < 0 then 0 else . end]
      end;
    . as $report |
    .schema_version == 1 and
    .suite_id == "token-saver-techniques-v1" and
    (.technique == "A" or .technique == "B" or .technique == "C") and
    (.captured_at | type == "string" and length > 0) and
    .token_count_source == "omlx:/v1/messages/count_tokens" and
    (.source.git_head | test("^[0-9a-f]{40}$")) and
    (.source.tree_sha | test("^[0-9a-f]{40}$")) and
    .source.dirty == false and
    (.comparison.baseline_git_sha | test("^[0-9a-f]{40}$")) and
    (.comparison.candidate_git_sha | test("^[0-9a-f]{40}$")) and
    .fixture.id == "token-saver-techniques-v1" and
    .fixture.sha256 == $fixture_sha and
    (.model.id | type == "string" and length > 0) and
    (.model.revision | test("^[0-9a-f]{40}$")) and
    .model.server == "oMLX" and
    (.model.server_version | type == "string" and length > 0 and . != "unreported") and
    (.cases | type == "array" and length > 0) and
    ([.cases[].id] | length == (unique | length)) and
    all(.cases[];
      . as $case |
      (.id | type == "string" and length > 0) and
      (.surfaces | type == "array" and length >= 2) and
      all(.surfaces[];
        (.name | type == "string" and length > 0) and
        (.surface | type == "string" and startswith("anthropic.")) and
        (.canonical_body_sha256 | test("^[0-9a-f]{64}$")) and
        (.canonical_body_bytes | type == "number" and . > 0) and
        (.account_to == "baseline" or .account_to == "candidate" or .account_to == "none") and
        (.debit == "none" or .debit == "lookup" or .debit == "retrieve") and
        ((has("scenario_side") | not) or .scenario_side == "baseline" or .scenario_side == "candidate") and
        (.input_tokens | type == "number" and . >= 0) and
        (.count_latency_ms | type == "number" and . >= 0) and
        ((has("generation_latency_ms") | not) or (.generation_latency_ms | type == "number" and . >= 0))
      ) and
      .baseline_tokens == ([.surfaces[] | select(.account_to == "baseline") | .input_tokens] | add // 0) and
      .candidate_tokens == ([.surfaces[] | select(.account_to == "candidate") | .input_tokens] | add // 0) and
      .lookup_debit_tokens == ([.surfaces[] | select(.debit == "lookup") | .input_tokens] | add // 0) and
      .retrieve_debit_tokens == ([.surfaces[] | select(.debit == "retrieve") | .input_tokens] | add // 0) and
      .net_tokens_saved == (.baseline_tokens - .candidate_tokens) and
      .p50_latency_ms == ([.surfaces[].count_latency_ms] | pctl(0.50)) and
      .p95_latency_ms == ([.surfaces[].count_latency_ms] | pctl(0.95)) and
      (.quality_passed | type == "boolean") and
      (.quality | type == "object")
    ) and
    .aggregate.case_count == (.cases | length) and
    .aggregate.baseline_tokens == ([.cases[].baseline_tokens] | add) and
    .aggregate.candidate_tokens == ([.cases[].candidate_tokens] | add) and
    .aggregate.lookup_debit_tokens == ([.cases[].lookup_debit_tokens] | add) and
    .aggregate.retrieve_debit_tokens == ([.cases[].retrieve_debit_tokens] | add) and
    .aggregate.net_tokens_saved == (.aggregate.baseline_tokens - .aggregate.candidate_tokens) and
    .aggregate.quality_passed_cases == ([.cases[] | select(.quality_passed == true)] | length) and
    .aggregate.baseline_success_regressions == ([.cases[] | select(.quality.baseline_success_regression == true)] | length) and
    .aggregate.p50_latency_ms == ([.cases[].p50_latency_ms] | pctl(0.50)) and
    .aggregate.p95_latency_ms == ([.cases[].p50_latency_ms] | pctl(0.95)) and
    (.decision == "accepted" or .decision == "rejected") and
    (.decision_reason | type == "string" and length > 0) and
    (if .decision == "accepted" then
       .aggregate.net_tokens_saved > 0 and
       .aggregate.quality_passed_cases == .aggregate.case_count and
       .aggregate.baseline_success_regressions == 0
     else
       .aggregate.net_tokens_saved <= 0 or
       .aggregate.quality_passed_cases < .aggregate.case_count or
       .aggregate.baseline_success_regressions > 0
     end) and
    (if .technique == "A" then
       ([.cases[].id] | sort) == ["A-COLD", "A-HOT"] and
       all(.cases[];
         .quality.catalog_total == 188 and
         .quality.catalog_enabled == 168 and
         .quality.catalog_forbidden == 19 and
         .quality.catalog_disabled == 1 and
         .quality.forbidden_hidden == true and
         .quality.disabled_hidden == true and
         .quality.operation_reachable == true
       ) and
       ([.cases[].lookup_debit_tokens] | add) > 0
     elif .technique == "B" then
       ([.cases[].id] | sort) == ["B-NO-RETRIEVE"] and
       all(.cases[];
         .quality.marker_wire_format_valid == true and
         .quality.marker_in_production_notice == true and
         .quality.source_duplicate_equal == true and
         .quality.scoped_prepare_readback_verified == true and
         .quality.fail_open_verified == true and
         .quality.capture_mode == "shipping_persistence_in_memory" and
         .quality.requires_retrieve == false and
         .quality.retrieve_exact_readback_verified == false and
         .retrieve_debit_tokens == 0
       ) and
       ([.sensitivity_cases[].id] | sort) == ["B-WITH-RETRIEVE"] and
       all(.sensitivity_cases[];
         . as $case |
         .accounting_mode == "sensitivity_only" and
         (.surfaces | type == "array" and length >= 3) and
         all(.surfaces[];
           .account_to == "none" and
           (.scenario_side == "baseline" or .scenario_side == "candidate") and
           (.canonical_body_sha256 | test("^[0-9a-f]{64}$")) and
           (.input_tokens | type == "number" and . >= 0) and
           (.count_latency_ms | type == "number" and . >= 0)
         ) and
         .scenario_baseline_tokens == ([.surfaces[] | select(.scenario_side == "baseline") | .input_tokens] | add) and
         .scenario_candidate_tokens == ([.surfaces[] | select(.scenario_side == "candidate") | .input_tokens] | add) and
         .retrieve_debit_tokens == ([.surfaces[] | select(.debit == "retrieve") | .input_tokens] | add) and
         .scenario_net_tokens_saved == (.scenario_baseline_tokens - .scenario_candidate_tokens) and
         .p50_latency_ms == ([.surfaces[].count_latency_ms] | pctl(0.50)) and
         .p95_latency_ms == ([.surfaces[].count_latency_ms] | pctl(0.95)) and
         .quality_passed == true and
         .quality.requires_retrieve == true and
         .quality.marker_wire_format_valid == true and
         .quality.marker_in_production_notice == true and
         .quality.source_duplicate_equal == true and
         .quality.scoped_prepare_readback_verified == true and
         .quality.retrieve_exact_readback_verified == true and
         .quality.fail_open_verified == true and
         .quality.capture_mode == "shipping_persistence_in_memory" and
         .retrieve_debit_tokens > 0
       ) and
       .aggregate.sensitivity_case_count == (.sensitivity_cases | length) and
       .aggregate.sensitivity_retrieve_debit_tokens == ([.sensitivity_cases[].retrieve_debit_tokens] | add)
     else
       ([.cases[].id] | sort) == ["C-HEAD", "C-MIDDLE", "C-TAIL"] and
       all(.cases[];
         .quality.source_bytes > 6000 and
         .quality.budget_bytes == 6000 and
         (.quality.evidence_position == "head" or .quality.evidence_position == "middle" or .quality.evidence_position == "tail") and
         .quality.baseline_success_regression == false and
         .quality.ranked_pack_verbatim == true and
         .quality.ranked_pack_contains_required == true and
         .quality.recovery_mode == "in_process_synthetic" and
         .quality.production_recovery_claimed == false and
         .quality.synthetic_retrieve_payload_exact == true and
         (.quality.baseline_output_sha256 | test("^[0-9a-f]{64}$")) and
         (.quality.candidate_output_sha256 | test("^[0-9a-f]{64}$"))
       )
     end)
  ' "${artifact}" >/dev/null || die "artifact schema, accounting, quality, or decision verification failed: ${artifact}"

  local baseline_sha candidate_sha capture_sha expected_tree
  baseline_sha="$(jq -r '.comparison.baseline_git_sha' "${artifact}")"
  candidate_sha="$(jq -r '.comparison.candidate_git_sha' "${artifact}")"
  capture_sha="$(jq -r '.source.git_head' "${artifact}")"
  git -C "${repo_root}" cat-file -e "${baseline_sha}^{commit}" 2>/dev/null || die "baseline commit is unavailable: ${baseline_sha}"
  git -C "${repo_root}" cat-file -e "${candidate_sha}^{commit}" 2>/dev/null || die "candidate commit is unavailable: ${candidate_sha}"
  git -C "${repo_root}" cat-file -e "${capture_sha}^{commit}" 2>/dev/null || die "capture commit is unavailable: ${capture_sha}"
  expected_tree="$(git -C "${repo_root}" rev-parse "${capture_sha}^{tree}")"
  [[ "$(jq -r '.source.tree_sha' "${artifact}")" == "${expected_tree}" ]] || die "capture source tree mismatch"
  [[ "$(file_sha256 "${fixture_path}")" == "${expected_fixture_sha256}" ]] || die "live fixture no longer matches artifact"
  echo "artifact ok technique=$(jq -r '.technique' "${artifact}") decision=$(jq -r '.decision' "${artifact}") net=$(jq -r '.aggregate.net_tokens_saved' "${artifact}") exact_tokens"
}

verify_d() {
  require_tools
  local artifact="${1:-}"
  [[ -n "${artifact}" ]] || usage
  require_file "${artifact}"
  jq -e '
    . as $report |
    .schema_version == 1 and
    .suite_id == "token-saver-exact-dedupe-v1" and
    .technique == "D" and
    .token_count_source == "omlx:/v1/messages/count_tokens" and
    (.claim_scope | type == "string" and contains("not provider billing")) and
    (.captured_at | type == "string" and length > 0) and
    (.source.git_head | test("^[0-9a-f]{40}$")) and
    (.source.tree_sha | test("^[0-9a-f]{40}$")) and
    .source.dirty == false and
    (.comparison.baseline_git_sha | test("^[0-9a-f]{40}$")) and
    (.comparison.candidate_git_sha | test("^[0-9a-f]{40}$")) and
    .source.git_head == .comparison.candidate_git_sha and
    (.comparison.baseline_variant | type == "string" and length > 0) and
    (.comparison.candidate_variant | type == "string" and length > 0) and
    .model.server == "oMLX" and
    (.model.id | type == "string" and length > 0) and
    (.model.revision | test("^[0-9a-f]{40}$")) and
    (.model.server_version | type == "string" and length > 0 and . != "unreported") and
    .fixture.id == "token-saver-exact-dedupe-v1" and
    (.fixture.sha256 | test("^[0-9a-f]{64}$")) and
    (.fixture.input_bytes | type == "number" and . > 0) and
    (.fixture.exact_block_bytes | type == "number" and . > 0 and . < $report.fixture.input_bytes) and
    (.fixture.non_empty_lines | type == "number" and . > 0) and
    all([.gross_transform_diagnostic.raw, .gross_transform_diagnostic.pointer,
         .incremental_provider_facing.baseline, .incremental_provider_facing.candidate][];
      (.canonical_body_bytes | type == "number" and . > 0) and
      (.canonical_body_sha256 | test("^[0-9a-f]{64}$")) and
      (.count_latency_ms | type == "number" and . >= 0) and
      (.input_tokens | type == "number" and . >= 0)
    ) and
    .gross_transform_diagnostic.tokens_saved ==
      (.gross_transform_diagnostic.raw.input_tokens - .gross_transform_diagnostic.pointer.input_tokens) and
    .gross_transform_diagnostic.tokens_saved > 0 and
    .incremental_provider_facing.baseline_tokens == .incremental_provider_facing.baseline.input_tokens and
    .incremental_provider_facing.candidate_tokens == .incremental_provider_facing.candidate.input_tokens and
    .incremental_provider_facing.net_tokens_saved ==
      (.incremental_provider_facing.baseline_tokens - .incremental_provider_facing.candidate_tokens) and
    .incremental_provider_facing.net_tokens_saved <= 0 and
    .decision == "rejected" and
    (.decision_reason | type == "string" and length > 0) and
    .quality.quality_passed == true and
    .quality.baseline_success_regression == false and
    .quality.exact_reconstruction == true and
    .quality.first_block_inline == true and
    .quality.pass_fail_near_blocks_untouched == true and
    .quality.pointer_order_preserved == true and
    .quality.baseline_reached_real_local_llm == true and
    .quality.candidate_resolved_deterministically == true and
    .recovery.capability_format == "rcv1.<22-base64url>" and
    (.recovery.capability_sha256 | test("^[0-9a-f]{64}$")) and
    .recovery.same_capability_both_arms == true and
    .recovery.scoped_readback_verified == true and
    .delivery.baseline_cli_byte_gate_admitted == true and
    .delivery.candidate_cli_byte_gate_admitted == true and
    .delivery.baseline_receipt_verified == true and
    .delivery.candidate_receipt_verified == true and
    (.runtime.baseline_output_sha256 | test("^[0-9a-f]{64}$")) and
    (.runtime.candidate_output_sha256 | test("^[0-9a-f]{64}$")) and
    .runtime.baseline_route_stage == "llm_mlx" and
    .runtime.candidate_route_stage == "deterministic" and
    (.runtime.baseline_latency_ms | type == "number" and . >= 0) and
    (.runtime.candidate_latency_ms | type == "number" and . >= 0)
  ' "${artifact}" >/dev/null || die "technique D schema, accounting, recovery, or rejected decision failed: ${artifact}"

  local baseline_sha candidate_sha capture_sha expected_tree
  baseline_sha="$(jq -r '.comparison.baseline_git_sha' "${artifact}")"
  candidate_sha="$(jq -r '.comparison.candidate_git_sha' "${artifact}")"
  capture_sha="$(jq -r '.source.git_head' "${artifact}")"
  git -C "${repo_root}" cat-file -e "${baseline_sha}^{commit}" 2>/dev/null || die "D baseline commit is unavailable: ${baseline_sha}"
  git -C "${repo_root}" cat-file -e "${candidate_sha}^{commit}" 2>/dev/null || die "D candidate commit is unavailable: ${candidate_sha}"
  git -C "${repo_root}" cat-file -e "${capture_sha}^{commit}" 2>/dev/null || die "D capture commit is unavailable: ${capture_sha}"
  expected_tree="$(git -C "${repo_root}" rev-parse "${capture_sha}^{tree}")"
  [[ "$(jq -r '.source.tree_sha' "${artifact}")" == "${expected_tree}" ]] || die "D capture source tree mismatch"
  echo "artifact ok technique=D decision=rejected net=$(jq -r '.incremental_provider_facing.net_tokens_saved' "${artifact}") exact_tokens"
}

verify_terminal_candidates() {
  require_tools
  local artifact="${1:-}"
  [[ -n "${artifact}" ]] || usage
  require_file "${artifact}"
  jq -e '
    . as $report |
    .schema_version == 1 and
    .suite_id == "token-saver-terminal-candidates-v1" and
    .token_count_source == "omlx:/v1/messages/count_tokens" and
    (.claim_scope | type == "string" and contains("not provider delivery or billing claims")) and
    (.source.git_head | test("^[0-9a-f]{40}$")) and
    .source.dirty == false and
    .model.server == "oMLX" and
    (.model.id | type == "string" and length > 0) and
    (.model.revision | test("^[0-9a-f]{40}$")) and
    (.model.server_version | type == "string" and length > 0 and . != "unreported") and
    .measurement_protocol.endpoint == "http://127.0.0.1:8000/v1/messages/count_tokens" and
    (.measurements | type == "array" and length > 0) and
    ([.measurements[].id] | length == (unique | length)) and
    all(.measurements[];
      (.id | type == "string" and length > 0) and
      (.input_bytes | type == "number" and . > 0) and
      (.input_sha256 | test("^[0-9a-f]{64}$")) and
      (.request_body_bytes | type == "number" and . > 0) and
      (.request_body_sha256 | test("^[0-9a-f]{64}$")) and
      (.response_sha256 | test("^[0-9a-f]{64}$")) and
      (.input_tokens | type == "number" and . >= 0)
    ) and
    (.candidates | type == "array" and length > 0) and
    ([.candidates[].id] | length == (unique | length)) and
    all(.candidates[];
      . as $candidate |
      (.id | type == "string" and length > 0) and
      (.measurement_status == "exact_local_tokenizer" or
       .measurement_status == "not_run_no_safe_delivery_surface") and
      .quality_passed == false and
      .decision == "rejected" and
      (.reason | type == "string" and length > 0) and
      (if .measurement_status == "exact_local_tokenizer" then
         (.measured_tokens_saved | type == "number") and
         (.baseline_measurement | type == "string" and length > 0) and
         (.candidate_measurement | type == "string" and length > 0) and
         ([$report.measurements[] | select(.id == $candidate.baseline_measurement)] | length) == 1 and
         ([$report.measurements[] | select(.id == $candidate.candidate_measurement)] | length) == 1 and
         .measured_tokens_saved ==
           (([$report.measurements[] | select(.id == $candidate.baseline_measurement) | .input_tokens][0]) -
            ([$report.measurements[] | select(.id == $candidate.candidate_measurement) | .input_tokens][0]))
       else
         .measured_tokens_saved == null and
         (has("baseline_measurement") | not) and
         (has("candidate_measurement") | not)
       end)
    ) and
    (.source_evidence | type == "array" and length > 0) and
    all(.source_evidence[];
      (.path | type == "string" and length > 0 and startswith("Sources/") and (contains("..") | not)) and
      (.git_blob | test("^[0-9a-f]{40}$")) and
      (.sha256 | test("^[0-9a-f]{64}$")) and
      (.supports | type == "array" and length > 0) and
      all(.supports[]; . as $id | any($report.candidates[]; .id == $id))
    ) and
    ([$report.candidates[].id] - ([$report.source_evidence[].supports[]] | unique) | length) == 0 and
    .terminal.status == "no_improvement" and
    .terminal.remaining_safe_candidates == 0 and
    (.terminal.reason | type == "string" and length > 0)
  ' "${artifact}" >/dev/null || die "terminal candidate schema, measurements, or rejected decisions failed: ${artifact}"

  local source_sha evidence_row evidence_path expected_blob expected_sha actual_blob actual_sha
  source_sha="$(jq -r '.source.git_head' "${artifact}")"
  git -C "${repo_root}" cat-file -e "${source_sha}^{commit}" 2>/dev/null || die "terminal candidate source commit is unavailable: ${source_sha}"
  while IFS= read -r evidence_row; do
    evidence_path="$(jq -r '.path' <<<"${evidence_row}")"
    expected_blob="$(jq -r '.git_blob' <<<"${evidence_row}")"
    expected_sha="$(jq -r '.sha256' <<<"${evidence_row}")"
    [[ "${evidence_path}" == Sources/* && "${evidence_path}" != *..* ]] || die "unsafe terminal evidence path: ${evidence_path}"
    git -C "${repo_root}" cat-file -e "${expected_blob}^{blob}" 2>/dev/null \
      || die "terminal evidence Git blob is unavailable: ${evidence_path}"
    git -C "${repo_root}" cat-file -e "${source_sha}:${evidence_path}" 2>/dev/null \
      || die "terminal evidence path is unavailable at source commit: ${evidence_path}"
    actual_blob="$(git -C "${repo_root}" rev-parse "${source_sha}:${evidence_path}")"
    [[ "${actual_blob}" == "${expected_blob}" ]] || die "terminal evidence source-path blob mismatch: ${evidence_path}"
    actual_sha="$(git -C "${repo_root}" cat-file blob "${expected_blob}" | shasum -a 256 | awk '{print $1}')"
    [[ "${actual_sha}" == "${expected_sha}" ]] || die "terminal evidence SHA-256 mismatch: ${evidence_path}"
  done < <(jq -c '.source_evidence[]' "${artifact}")
  echo "terminal candidates ok rejected=$(jq '.candidates | length' "${artifact}") terminal=no_improvement"
}

verify_iterations() {
  require_tools
  local iterations="${1:-}"
  [[ -n "${iterations}" ]] || usage
  require_file "${iterations}"
  jq -e '
    . as $report |
    .schema_version == 1 and
    .suite_id == "token-saver-techniques-v1" and
    (.iterations | type == "array" and length >= 3) and
    ([.iterations[].id] | length == (unique | length)) and
    all(["A", "B", "C", "D"][];
      . as $technique |
      ([$report.iterations[] | select(.technique == $technique)] | length) == 1
    ) and
    ([$report.iterations[] |
       select((.technique == "A" or .technique == "B" or .technique == "C" or .technique == "D") | not) |
       .artifact_path] | unique) == ["docs/benchmarks/token-saver-local-llm/terminal-candidates.json"] and
    all(.iterations[];
      (.id | type == "string" and length > 0) and
      (.technique | type == "string" and length > 0) and
      (.baseline_git_sha | test("^[0-9a-f]{40}$")) and
      (.candidate_git_sha | test("^[0-9a-f]{40}$")) and
      (.artifact_path | type == "string" and
        startswith("docs/benchmarks/token-saver-local-llm/") and
        endswith(".json") and
        (contains("..") | not)) and
      (.artifact_sha256 | test("^[0-9a-f]{64}$")) and
      (.decision == "accepted" or .decision == "rejected") and
      .status == .decision and
      (.measurement_status == "exact_local_tokenizer" or
       .measurement_status == "not_run_no_safe_delivery_surface") and
      (if .measurement_status == "exact_local_tokenizer" then
         (.net_tokens_saved | type == "number") and
         (.measured_additional_tokens | type == "number") and
         .measured_additional_tokens == .net_tokens_saved
       else
         .decision == "rejected" and
         .net_tokens_saved == null and
         .measured_additional_tokens == null
       end) and
      (.quality_regressions | type == "number" and . >= 0) and
      (.reason | type == "string" and length > 0)
    ) and
    .terminal.status == "no_improvement" and
    .terminal.remaining_safe_candidates == 0 and
    (.terminal.reason | type == "string" and length > 0)
  ' "${iterations}" >/dev/null || die "iterations ledger is incomplete or lacks terminal no_improvement evidence"

  local row technique measurement_status artifact_relative artifact_path artifact_hash baseline_sha candidate_sha decision net regressions
  local last_verified_path=""
  while IFS= read -r row; do
    technique="$(jq -r '.technique' <<<"${row}")"
    measurement_status="$(jq -r '.measurement_status' <<<"${row}")"
    artifact_relative="$(jq -r '.artifact_path' <<<"${row}")"
    artifact_hash="$(jq -r '.artifact_sha256' <<<"${row}")"
    baseline_sha="$(jq -r '.baseline_git_sha' <<<"${row}")"
    candidate_sha="$(jq -r '.candidate_git_sha' <<<"${row}")"
    decision="$(jq -r '.decision' <<<"${row}")"
    net="$(jq -r '.net_tokens_saved' <<<"${row}")"
    regressions="$(jq -r '.quality_regressions' <<<"${row}")"
    [[ "${artifact_relative}" == docs/benchmarks/token-saver-local-llm/*.json && "${artifact_relative}" != *..* ]] \
      || die "unsafe iteration artifact path: ${artifact_relative}"
    artifact_path="${repo_root}/${artifact_relative}"
    require_file "${artifact_path}"
    [[ "$(file_sha256 "${artifact_path}")" == "${artifact_hash}" ]] \
      || die "iteration artifact hash mismatch: ${artifact_relative}"

    if [[ "${artifact_path}" != "${last_verified_path}" ]]; then
      case "${technique}" in
        A|B|C) verify_artifact "${artifact_path}" >/dev/null ;;
        D) verify_d "${artifact_path}" >/dev/null ;;
        *) verify_terminal_candidates "${artifact_path}" >/dev/null ;;
      esac
      last_verified_path="${artifact_path}"
    fi

    case "${technique}" in
      A|B|C)
        jq -e --arg technique "${technique}" --arg baseline "${baseline_sha}" \
          --arg candidate "${candidate_sha}" --arg decision "${decision}" --argjson net "${net}" '
            .technique == $technique and
            .comparison.baseline_git_sha == $baseline and
            .comparison.candidate_git_sha == $candidate and
            .decision == $decision and
            .aggregate.net_tokens_saved == $net
          ' "${artifact_path}" >/dev/null || die "iteration does not reconcile technique ${technique} artifact"
        ;;
      D)
        jq -e --arg baseline "${baseline_sha}" --arg candidate "${candidate_sha}" \
          --arg decision "${decision}" --argjson net "${net}" '
            .technique == "D" and
            .comparison.baseline_git_sha == $baseline and
            .comparison.candidate_git_sha == $candidate and
            .decision == $decision and
            .incremental_provider_facing.net_tokens_saved == $net
          ' "${artifact_path}" >/dev/null || die "iteration does not reconcile technique D artifact"
        ;;
      *)
        jq -e --arg technique "${technique}" --arg measurement_status "${measurement_status}" \
          --arg baseline "${baseline_sha}" \
          --arg candidate "${candidate_sha}" --arg decision "${decision}" \
          --argjson net "${net}" --argjson regressions "${regressions}" '
            .source.git_head == $baseline and
            .source.git_head == $candidate and
            any(.candidates[];
              .id == $technique and
              .measurement_status == $measurement_status and
              .decision == $decision and
              .measured_tokens_saved == $net and
              (if .quality_passed then $regressions == 0 else $regressions > 0 end)
            )
          ' "${artifact_path}" >/dev/null || die "iteration does not reconcile terminal candidate ${technique}"
        ;;
    esac
  done < <(jq -c '.iterations[]' "${iterations}")

  local terminal_relative terminal_path
  while IFS= read -r terminal_relative; do
    terminal_path="${repo_root}/${terminal_relative}"
    jq -n -e --arg artifact_path "${terminal_relative}" \
      --slurpfile iterations "${iterations}" --slurpfile artifact "${terminal_path}" '
        ([$iterations[0].iterations[] | select(.artifact_path == $artifact_path) | .technique] | sort) ==
        ([$artifact[0].candidates[].id] | sort)
      ' >/dev/null || die "terminal artifact candidates are not fully reconciled: ${terminal_relative}"
  done < <(jq -r '.iterations[] | select(.technique != "A" and .technique != "B" and .technique != "C" and .technique != "D") | .artifact_path' "${iterations}" | sort -u)
  echo "iterations ok attempts=$(jq '.iterations | length' "${iterations}") terminal=no_improvement"
}

capture() {
  require_tools
  local technique="${1:-}" baseline_sha="${2:-}" candidate_sha="${3:-}" artifact="${4:-}"
  [[ "${technique}" == "A" || "${technique}" == "B" || "${technique}" == "C" ]] || usage
  [[ "${baseline_sha}" =~ ^[0-9a-f]{40}$ && "${candidate_sha}" =~ ^[0-9a-f]{40}$ && -n "${artifact}" ]] || usage
  : "${RC_TOKEN_SAVER_BENCHMARK_BASE_URL:?set RC_TOKEN_SAVER_BENCHMARK_BASE_URL}"
  : "${RC_TOKEN_SAVER_BENCHMARK_MODEL:?set RC_TOKEN_SAVER_BENCHMARK_MODEL}"
  : "${RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION:?set RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION}"
  [[ "${RC_TOKEN_SAVER_BENCHMARK_MODEL_REVISION}" =~ ^[0-9a-f]{40}$ ]] || die "model revision must be immutable 40-hex"
  verify_protocol >/dev/null
  git -C "${repo_root}" cat-file -e "${baseline_sha}^{commit}" 2>/dev/null || die "baseline commit is unavailable"
  git -C "${repo_root}" cat-file -e "${candidate_sha}^{commit}" 2>/dev/null || die "candidate commit is unavailable"
  local dirty=0
  if [[ -n "$(git -C "${repo_root}" status --porcelain --untracked-files=all)" ]]; then
    dirty=1
    [[ "${RC_TOKEN_SAVER_TECHNIQUE_ALLOW_DIRTY:-0}" == "1" ]] || die "capture refused a dirty worktree"
  fi

  if [[ "${technique}" == "A" ]]; then
    git -C "${repo_root}" grep -Fq '"enum": LibrarianCatalog.implementedIDs' "${baseline_sha}" \
      -- Sources/DistillCore/ManagedRetrieveMCP.swift \
      || die "A baseline SHA does not expose the historical eager enum"
    git -C "${repo_root}" grep -Fq 'Self.catalogToolName' "${candidate_sha}" \
      -- Sources/DistillCore/ManagedRetrieveMCP.swift \
      || die "A candidate SHA does not contain rc_catalog"
  elif [[ "${technique}" == "B" ]]; then
    if git -C "${repo_root}" grep -Fq 'request.verifiedRecoveryHandle == handle' "${baseline_sha}" \
      -- Sources/DistillCore/Librarian/LibrarianHandlers.swift; then
      die "B baseline SHA already contains verified duplicate compaction"
    fi
    git -C "${repo_root}" grep -Fq 'request.verifiedRecoveryHandle == handle' "${candidate_sha}" \
      -- Sources/DistillCore/Librarian/LibrarianHandlers.swift \
      || die "B candidate SHA does not contain verified duplicate compaction"
  elif [[ "${technique}" == "C" ]]; then
    if git -C "${repo_root}" cat-file -e "${baseline_sha}:Sources/DistillCore/Librarian/LibrarianEvidencePack.swift" 2>/dev/null; then
      die "C baseline SHA already contains the ranked evidence pack"
    fi
    git -C "${repo_root}" cat-file -e "${candidate_sha}:Sources/DistillCore/Librarian/LibrarianEvidencePack.swift" 2>/dev/null \
      || die "C candidate SHA does not contain the ranked evidence pack"
  fi

  RC_TOKEN_SAVER_TECHNIQUE_BENCHMARK=1 \
  RC_TOKEN_SAVER_TECHNIQUE="${technique}" \
  RC_TOKEN_SAVER_TECHNIQUE_BASELINE_SHA="${baseline_sha}" \
  RC_TOKEN_SAVER_TECHNIQUE_CANDIDATE_SHA="${candidate_sha}" \
  RC_TOKEN_SAVER_TECHNIQUE_SOURCE_GIT_SHA="$(git -C "${repo_root}" rev-parse HEAD)" \
  RC_TOKEN_SAVER_TECHNIQUE_SOURCE_TREE_SHA="$(git -C "${repo_root}" rev-parse HEAD^{tree})" \
  RC_TOKEN_SAVER_TECHNIQUE_SOURCE_DIRTY="${dirty}" \
  RC_TOKEN_SAVER_TECHNIQUE_OUTPUT="${artifact}" \
    "${repo_root}/scripts/isolated-sandbox.sh" test \
      --filter TokenSaverTechniqueBenchmarkTests/test_liveCaptureAgainstOMLX

  if [[ "${dirty}" == "0" ]]; then
    verify_artifact "${artifact}"
  else
    echo "local dirty capture written; verify will reject it: ${artifact}"
  fi
  echo "capture complete technique=${technique} auth=$([[ -n "${RC_TOKEN_SAVER_BENCHMARK_AUTH_TOKEN:-}" ]] && echo set || echo empty)"
}

assemble() {
  require_tools
  local artifact_a="${1:-}" artifact_b="${2:-}" artifact_c="${3:-}" iterations="${4:-}" output="${5:-}"
  [[ -n "${artifact_a}" && -n "${artifact_b}" && -n "${artifact_c}" && -n "${iterations}" && -n "${output}" ]] || usage
  verify_artifact "${artifact_a}" >/dev/null
  verify_artifact "${artifact_b}" >/dev/null
  verify_artifact "${artifact_c}" >/dev/null
  verify_iterations "${iterations}" >/dev/null
  [[ "$(jq -r '.technique' "${artifact_a}")" == "A" ]] || die "first artifact must be technique A"
  [[ "$(jq -r '.technique' "${artifact_b}")" == "B" ]] || die "second artifact must be technique B"
  [[ "$(jq -r '.technique' "${artifact_c}")" == "C" ]] || die "third artifact must be technique C"

  local path artifact_hash technique decision net baseline candidate
  for path in "${artifact_a}" "${artifact_b}" "${artifact_c}"; do
    artifact_hash="$(file_sha256 "${path}")"
    technique="$(jq -r '.technique' "${path}")"
    decision="$(jq -r '.decision' "${path}")"
    net="$(jq -r '.aggregate.net_tokens_saved' "${path}")"
    baseline="$(jq -r '.comparison.baseline_git_sha' "${path}")"
    candidate="$(jq -r '.comparison.candidate_git_sha' "${path}")"
    jq -e --arg technique "${technique}" --arg hash "${artifact_hash}" --arg decision "${decision}" \
      --argjson net "${net}" --arg baseline "${baseline}" --arg candidate "${candidate}" '
        any(.iterations[];
          .technique == $technique and
          .artifact_sha256 == $hash and
          .decision == $decision and
          .net_tokens_saved == $net and
          .baseline_git_sha == $baseline and
          .candidate_git_sha == $candidate
        )
      ' "${iterations}" >/dev/null || die "iterations do not reconcile technique ${technique} artifact"
  done

  local temporary
  temporary="$(mktemp "${TMPDIR:-/tmp}/token-saver-technique-suite.XXXXXX")"
  trap 'rm -f "${temporary}"' EXIT
  jq -n \
    --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg a_path "${artifact_a}" --arg a_sha "$(file_sha256 "${artifact_a}")" \
    --arg b_path "${artifact_b}" --arg b_sha "$(file_sha256 "${artifact_b}")" \
    --arg c_path "${artifact_c}" --arg c_sha "$(file_sha256 "${artifact_c}")" \
    --arg iterations_path "${iterations}" --arg iterations_sha "$(file_sha256 "${iterations}")" \
    --slurpfile a "${artifact_a}" --slurpfile b "${artifact_b}" --slurpfile c "${artifact_c}" --slurpfile iterations "${iterations}" '
      {
        schema_version: 1,
        suite_id: "token-saver-techniques-v1",
        assembled_at: $captured_at,
        artifacts: [
          {technique: "A", path: $a_path, sha256: $a_sha, decision: $a[0].decision, net_tokens_saved: $a[0].aggregate.net_tokens_saved},
          {technique: "B", path: $b_path, sha256: $b_sha, decision: $b[0].decision, net_tokens_saved: $b[0].aggregate.net_tokens_saved},
          {technique: "C", path: $c_path, sha256: $c_sha, decision: $c[0].decision, net_tokens_saved: $c[0].aggregate.net_tokens_saved}
        ],
        aggregate_net_tokens_saved: ($a[0].aggregate.net_tokens_saved + $b[0].aggregate.net_tokens_saved + $c[0].aggregate.net_tokens_saved),
        iterations: {path: $iterations_path, sha256: $iterations_sha, terminal: $iterations[0].terminal}
      }
    ' >"${temporary}"
  mkdir -p "$(dirname "${output}")"
  mv "${temporary}" "${output}"
  trap - EXIT
  verify_suite "${output}"
}

verify_suite() {
  require_tools
  local suite="${1:-}"
  [[ -n "${suite}" ]] || usage
  require_file "${suite}"
  jq -e '
    .schema_version == 1 and
    .suite_id == "token-saver-techniques-v1" and
    ([.artifacts[].technique] | sort) == ["A", "B", "C"] and
    all(.artifacts[];
      (.path | type == "string" and length > 0) and
      (.sha256 | test("^[0-9a-f]{64}$")) and
      (.decision == "accepted" or .decision == "rejected") and
      (.net_tokens_saved | type == "number")
    ) and
    .aggregate_net_tokens_saved == ([.artifacts[].net_tokens_saved] | add) and
    .iterations.terminal.status == "no_improvement" and
    .iterations.terminal.remaining_safe_candidates == 0 and
    (.iterations.terminal.reason | type == "string" and length > 0)
  ' "${suite}" >/dev/null || die "suite manifest failed"
  local row path technique decision net
  while IFS= read -r row; do
    path="$(jq -r '.path' <<<"${row}")"
    technique="$(jq -r '.technique' <<<"${row}")"
    decision="$(jq -r '.decision' <<<"${row}")"
    net="$(jq -r '.net_tokens_saved' <<<"${row}")"
    require_file "${path}"
    [[ "$(file_sha256 "${path}")" == "$(jq -r '.sha256' <<<"${row}")" ]] || die "suite artifact hash mismatch: ${path}"
    verify_artifact "${path}" >/dev/null || die "suite artifact verification failed: ${path}"
    jq -e --arg technique "${technique}" --arg decision "${decision}" --argjson net "${net}" '
      .technique == $technique and
      .decision == $decision and
      .aggregate.net_tokens_saved == $net
    ' "${path}" >/dev/null || die "suite manifest does not reconcile artifact: ${path}"
  done < <(jq -c '.artifacts[]' "${suite}")
  require_file "$(jq -r '.iterations.path' "${suite}")"
  [[ "$(file_sha256 "$(jq -r '.iterations.path' "${suite}")")" == "$(jq -r '.iterations.sha256' "${suite}")" ]] \
    || die "suite iterations hash mismatch"
  verify_iterations "$(jq -r '.iterations.path' "${suite}")" >/dev/null
  echo "suite ok net=$(jq -r '.aggregate_net_tokens_saved' "${suite}") exact_tokens terminal=no_improvement"
}

command_name="${1:-}"
shift || true
case "${command_name}" in
  verify-protocol) verify_protocol "$@" ;;
  capture) capture "$@" ;;
  verify) verify_artifact "$@" ;;
  verify-d) verify_d "$@" ;;
  verify-terminal-candidates) verify_terminal_candidates "$@" ;;
  verify-iterations) verify_iterations "$@" ;;
  assemble) assemble "$@" ;;
  verify-suite) verify_suite "$@" ;;
  *) usage ;;
esac
