#!/usr/bin/env bash
set -euo pipefail

readonly PRODUCTION_BASE="5eef3d881c90c70183a7b570bcf5f6120d9b8ee6"
readonly HISTORICAL_PRODUCTION_ANCESTOR="bea8b824d621bdc49e797ab378372cd7ecae40ad"
readonly RED_TEST="test_tokenSaverCompiledBotBrainUsesCanonicalProviderContentAfterAdmission"
readonly RED_SIGNATURE="T016_FINAL_RUNNER_CANONICAL_BRAIN"
readonly BENCHMARK_TEST="TokenSaverBotDispatchBenchmarkTests/test_primaryAndNestedDispatch_emitsFiveWarmedSamples"
readonly BENCHMARK_PREFIX="TOKEN_SAVER_BOT_DISPATCH_BENCHMARK_JSON="
readonly BENCHMARK_FIXTURE="t016-bot-dispatch-primary-nested-v1"
readonly BENCHMARK_WORKLOAD="real AppShell Desk primary acknowledgement-to-provider-start followed by one Bot peer acknowledgement-to-provider-start"
readonly BENCHMARK_CLOCK="DispatchTime.uptimeNanoseconds at acknowledged intent and AgentProviderRunner.startRun entry"
readonly BENCHMARK_WARMUP="one identical primary+nested dispatch discarded before five measured samples"
readonly CLAUDE_STREAMING_TEST_FILE="Tests/AgentRuntimeTests/ClaudeStreamingCLIAdapterTests.swift"
readonly CLAUDE_STALE_FILTER="ClaudeStreamingCLIAdapterTests/test_agentSDKBridgePostToolUse_bashWithOrWithoutTerminalLFFailsOpenBeforeSidecar"
readonly CLAUDE_EXACT_ACCEPTED_FILTER="ClaudeStreamingCLIAdapterTests/test_agentSDKBridgePostToolUse_recordsOnlyExactAcceptedReplacement"
readonly FOOTER_STALE_FILTER="BotsWindowTests/test_tokenSaverFooterRejectsStaleSelectionAndPeerProjection"
readonly PREPARATION_TIMEOUT_FILTER="BotsWindowTests/test_tokenSaverPreparationTimeoutAndLateCompletionRouteManifest"
readonly EXPECTED_CONFIGURED_FILTER_COUNT=55
readonly EXPECTED_UNIQUE_FILTER_COUNT=47
readonly FILTER_CATALOG_SHA256="d11eb672c2b550dfd84cb2f43daec6150f9628a21a2b04238cc5d923016598c0"
readonly BASE_MISSING_ENTRY_SHA256="82cc3c5712921bb656135a8b9fbe2809d4c45f45f5901757fe188006e11d2ef7"
readonly BASE_MISSING_FILTER_SHA256="9f837505c0aea226a996ed767bc4a93df2dadf11e4cd15d0073d3cfad14a6402"
readonly S001_MISSING_FILTER_SHA256="fc66776a010d10872b054dec36a290d025cf552421ab69d0b2b3f3e07cdb39f1"
readonly S002_MISSING_FILTER_SHA256="ca01ba66f6c02d2396559750b76fd899035b40fc442249278145eb4453529b02"
readonly EMPTY_FILTER_SET_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

readonly -a PROOF_PATHS=(
  "Tests/AppShellTests/BotsWindowTests.swift"
  "Tests/AppShellTests/TokenSaverBotDispatchBenchmarkTests.swift"
  "scripts/verify-token-saver-bot-gate.sh"
  "scripts/verify-token-saver-bot-mr-delivery.sh"
)

readonly -a REQUEST_PATHS=(
  "Sources/CoreModel/AgentTypes.swift"
  "Sources/AgentRuntime/AgentRunCoordinator.swift"
  "Sources/AppShell/AppCommandRouter.swift"
  "Sources/AppShell/BotsWindow.swift"
  "Sources/Surfaces/AgentChatTokenSaverChrome.swift"
  "Tests/AppShellTests/BotsWindowTests.swift"
  "Tests/AppShellTests/TokenSaverBestOfThreeAppContextTests.swift"
  "Tests/AppShellTests/TokenSaverBotAgentAppInterceptorTests.swift"
  "Tests/AppShellTests/ProviderEnvironmentAttributionTests.swift"
  "Tests/SurfacesTests/TokenSaverThreadFooterTests.swift"
)

readonly -a DELIVERY_PATHS=(
  "Sources/DistillCore"
  "Sources/DistillSavingsPersistenceSupport"
  "Sources/RemoteCodeDistillService"
  "Sources/AgentRuntime/AgentSkillInstaller.swift"
  "Sources/AgentRuntime/ClaudeRunner.swift"
  "Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs"
  "Sources/AgentRuntime/CodexAppServerAdapter.swift"
  "Sources/AgentRuntime/TokenSaverContextSeedRuntime.swift"
  "Package.swift"
  "Tests/PersistenceTests/TokenSaverSavingsRepositoryTests.swift"
  "Tests/DistillCoreTests"
  "Tests/AgentRuntimeTests/TokenSaverCrossProviderMatrixTests.swift"
  "Tests/AgentRuntimeTests/ManagedDistillCLIInstallTests.swift"
  "Tests/AgentRuntimeTests/ClaudePrimaryPreToolUseBridgeTests.swift"
  "Tests/AgentRuntimeTests/ClaudeStreamingCLIAdapterTests.swift"
  "Tests/AgentRuntimeTests/TwoPhaseDeliveryConfirmationTests.swift"
  "Tests/AgentRuntimeTests/TokenSaverContextSeedRuntimeTests.swift"
)

readonly -a S002_FILTERS=(
  "BotsWindowTests/$RED_TEST"
  "TokenSaverBestOfThreeAppContextTests"
  "BotsWindowTests/test_providerSpawnedWorkerPromptDoesNotRunBestOfThreeAgain"
  "BotsWindowTests/test_botToAgentAppGraphifyRequiresAuthoritativeOwningWorkspaceRecord"
  "BotsWindowTests/test_tokenSaverFooterUsesSelectedThreadBeforePeerProjection"
  "BotsWindowTests/test_codexFreshThreadFallbackSeedsPriorContextAcrossOwnedBotRoutes"
  "BotsWindowTests/test_contextSeedIsNotApplicableWithoutPriorContextOrFallback"
  "$FOOTER_STALE_FILTER"
  "$PREPARATION_TIMEOUT_FILTER"
)

readonly -a S003_FILTERS=(
  "DeferredDeliveryServiceRepositoryIntegrationTests/test_phaseOneTokenAndPhaseTwoAccountingTraverseProductionRecorderToRepository"
  "DeferredDeliveryTokenTests/test_serverOnlyKeyRejectsBearerAndStateReceiptKeyForgery"
  "DeferredDeliveryTokenTests/test_arbitraryPrecomputedOutputNeverReceivesToken"
  "DeferredDeliveryTokenTests/test_realPhaseOneAndRecomputedLosslessPrepassIssueValidToken"
  "DeferredDeliveryTokenTests/test_crossInstanceRestartAndExpiryBoundaryAreHonestZero"
  "DeferredDeliveryTokenTests/test_exactProviderVisiblePrefixHandlesEmptyTrailingLFAndRejectsMarkerSubstitutionDuplicateSuffixAndCRLF"
  "DeferredDeliveryTokenTests"
  "DeferredDeliveryServiceRepositoryIntegrationTests/test_mainAndHTTPServerUseSameProductionSuccessHandler"
  "TwoPhaseDeliveryConfirmationTests/test_accountingOutputExcludesMarkersAndNeverDecreasesSameInputSavings"
  "ManagedRetrieveMCPTests/test_rcCompressAggregateAccountingExcludesMarkersAndNeverDecreasesSameInputSavings"
  "TwoPhaseDeliveryConfirmationTests/test_initialPostNeverRecordsAndFinalPostRequiresObservableHandoff"
  "TwoPhaseDeliveryConfirmationTests/test_sameInvocationRetryDedupesAndDistinctIdenticalInvocationRecords"
  "ManagedRetrieveMCPTests/test_rcCompressScopedAggregateRecordsOneEventAfterStdout"
  "ManagedRetrieveMCPTests/test_rcCompressPartialRejectFinalPostFailureIsZero"
  "ManagedDistillCLITests/test_compressChunksMemberAttestationsAuthenticateExactManifestAndRecordOneAggregateEvent"
  "ManagedDistillCLITests/test_compressChunksRejectsOmissionDuplicateReorderTokenOutputAndPartialMutations"
  "ManagedDistillCLITests/test_compressChunksRejectsQuestionRouteRecoveryPrefixSliceIdentityCrossInstanceAndExpiryMutations"
  "ManagedDistillCLITests/test_memberTTLCountThreeBoundariesLaterMembersZeroOverflowRestartAndCrossInstance"
  "TokenSaverArtifactPrivacyTests/test_twoPostReceiptsAndArtifactsAreSyntheticAndRedacted"
  "TwoPhaseDeliveryConfirmationTests"
  "ClaudePrimaryPreToolUseBridgeTests"
  "TokenSaverCrossProviderMatrixTests"
  "ManagedDistillCLITests"
  "ManagedDistillCLIInstallTests"
  "TokenSaverContextSeedRuntimeTests"
  "TokenSaverSavingsRepositoryTests"
  "$CLAUDE_STALE_FILTER"
  "ClaudeStreamingCLIAdapterTests/test_agentSDKBridgePostToolUse_skipsNestedMixedMediaAndPreservesTextOnlyControl"
  "ClaudeStreamingCLIAdapterTests/test_agentSDKBridgePostToolUse_appliesReceiptOnlyForNetShrink"
  "$CLAUDE_EXACT_ACCEPTED_FILTER"
)

readonly -a S004_EXTRA_FILTERS=(
  "BotsWindowTests/test_tokenSaverFooterABA_A1FinishesLastCannotPublishOrClearA2"
  "TokenSaverThreadFooterTests"
  "TokenSaverBotAgentAppInterceptorTests"
  "ProviderEnvironmentAttributionTests"
)

readonly -a S005_FILTERS=(
  "TwoPhaseDeliveryConfirmationTests/test_familyDeadlinesTimeoutUnavailableLateAreNonBlocking"
  "$PREPARATION_TIMEOUT_FILTER"
  "TokenSaverArtifactPrivacyTests/test_receiptsAndUploadAllowlistAreRedacted"
  "BotsWindowTests"
  "TokenSaverBestOfThreeAppContextTests"
  "TokenSaverCrossProviderMatrixTests"
  "ManagedDistillCLITests"
  "ManagedDistillCLIInstallTests"
  "TokenSaverBotAgentAppInterceptorTests"
  "ProviderEnvironmentAttributionTests"
  "TokenSaverThreadFooterTests"
  "TokenSaverBareUserEstimatorTests"
  "$BENCHMARK_TEST"
)

die() {
  echo "[token-saver-bot-gate] $*" >&2
  exit 2
}

usage() {
  echo "usage: $0 {s001|s002|s003|s004|s005|prepush} <exact options>" >&2
  exit 2
}

sha_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

sha_stream() {
  shasum -a 256 | awk '{print $1}'
}

benchmark_fixture_sha256() {
  printf '%s\n%s\n%s\n%s' "$BENCHMARK_FIXTURE" "$BENCHMARK_WORKLOAD" "$BENCHMARK_CLOCK" "$BENCHMARK_WARMUP" \
    | sha_stream
}

require_repo() {
  test -x scripts/isolated-sandbox.sh || die "run from the macos-app repository root"
  test "$(git rev-parse --show-toplevel)" = "$PWD" || die "run from the repository root"
  test "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" \
    || die "linked isolated worktree required"
  for tool in git jq shasum awk sed grep find sort wc mktemp sync; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
  done
}

begin_output() {
  local out="$1"
  test ! -e "$out" || die "output already exists: $out"
  mkdir -p "$(dirname "$out")"
  OUTPUT_DIR="$out"
  OUTPUT_TMP="$(mktemp -d "$(dirname "$out")/.${out##*/}.tmp.XXXXXX")"
  RESULTS_NDJSON="$OUTPUT_TMP/results.ndjson"
  : > "$RESULTS_NDJSON"
  trap 'test -z "${OUTPUT_TMP:-}" || rm -rf -- "$OUTPUT_TMP"' EXIT
}

finish_output() {
  test -s "$OUTPUT_TMP/receipt.json" || die "receipt.json was not created"
  jq -e 'type == "object" and .step_id != null' "$OUTPUT_TMP/receipt.json" >/dev/null \
    || die "receipt is incomplete"
  shopt -s nullglob
  rm -f -- "$OUTPUT_TMP"/*.stdout "$OUTPUT_TMP"/*.stderr "$OUTPUT_TMP"/*.combined \
    "$OUTPUT_TMP"/committed.patch "$OUTPUT_TMP"/request-ux.patch "$OUTPUT_TMP"/delivery.patch \
    "$OUTPUT_TMP"/red-method "$OUTPUT_TMP"/red-method.current "$OUTPUT_TMP"/source.diff \
    "$OUTPUT_TMP"/claude-stale-negative-method \
    "$OUTPUT_TMP"/preparation-route-manifest-method "$OUTPUT_TMP"/preparation-route-manifest-positions.txt \
    "$OUTPUT_TMP"/filter-audit-base.json "$OUTPUT_TMP"/filter-audit-proof.json \
    "$OUTPUT_TMP"/filter-audit-worktree.json "$OUTPUT_TMP"/filter-audit-committed.json \
    "$OUTPUT_TMP"/filter-catalog.tsv "$OUTPUT_TMP"/filter-owner-stages.tsv \
    "$OUTPUT_TMP"/*-missing-entries.tsv "$OUTPUT_TMP"/*-missing-filters.raw "$OUTPUT_TMP"/*-missing-filters.txt \
    "$OUTPUT_TMP"/formula.diff "$OUTPUT_TMP"/status-*.z "$OUTPUT_TMP"/cached-names.z \
    "$OUTPUT_TMP"/results.ndjson "$OUTPUT_TMP"/four-path-shas.txt \
    "$OUTPUT_TMP"/red-and-benchmark-results.json "$OUTPUT_TMP"/benchmark.json \
    "$OUTPUT_TMP"/expected-cached-names.z
  rm -rf -- "$OUTPUT_TMP/hunks"
  shopt -u nullglob
  sync
  mv "$OUTPUT_TMP" "$OUTPUT_DIR"
  OUTPUT_TMP=""
  trap - EXIT
}

record_result() {
  local label="$1" exit_code="$2" stdout="$3" stderr="$4"
  jq -cn \
    --arg label "$label" \
    --argjson exit_code "$exit_code" \
    --arg stdout_sha256 "$(sha_file "$stdout")" \
    --arg stderr_sha256 "$(sha_file "$stderr")" \
    '{label:$label,exit_code:$exit_code,stdout_sha256:$stdout_sha256,stderr_sha256:$stderr_sha256}' \
    >> "$RESULTS_NDJSON"
}

run_test_pass() {
  local filter="$1" slug stdout stderr combined exit_code
  slug="$(printf '%s' "$filter" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  stdout="$OUTPUT_TMP/$slug.stdout"
  stderr="$OUTPUT_TMP/$slug.stderr"
  set +e
  RC_T016_CHECKOUT_SHA="$(git rev-parse HEAD)" scripts/isolated-sandbox.sh test --filter "$filter" \
    >"$stdout" 2>"$stderr"
  exit_code=$?
  set -e
  record_result "$filter" "$exit_code" "$stdout" "$stderr"
  test "$exit_code" -eq 0 || die "test failed: $filter"
  combined="$OUTPUT_TMP/$slug.combined"
  awk '1' "$stdout" "$stderr" > "$combined"
  if grep -Eiq 'Executed 0 tests|No matching test|0 tests passed' "$combined"; then
    die "test filter discovered zero tests: $filter"
  fi
  grep -Eq 'Test Case .* passed|Test run with [1-9][0-9]* tests? passed' "$combined" \
    || die "test filter has no positive runner-owned test evidence: $filter"
}

run_red_test() {
  local stdout="$OUTPUT_TMP/red.stdout" stderr="$OUTPUT_TMP/red.stderr" combined="$OUTPUT_TMP/red.combined" exit_code
  set +e
  RC_T016_CHECKOUT_SHA="$(git rev-parse HEAD)" scripts/isolated-sandbox.sh test --filter "BotsWindowTests/$RED_TEST" \
    >"$stdout" 2>"$stderr"
  exit_code=$?
  set -e
  record_result "BotsWindowTests/$RED_TEST" "$exit_code" "$stdout" "$stderr"
  test "$exit_code" -ne 0 || die "the frozen red test unexpectedly passed"
  awk '1' "$stdout" "$stderr" > "$combined"
  grep -F "$RED_TEST" "$combined" >/dev/null || die "red output did not identify the named test"
  grep -F "$RED_SIGNATURE" "$combined" >/dev/null || die "red output did not contain the accepted assertion signature"
  test "$(grep -Ec "Test Case .*${RED_TEST}.* failed" "$combined" || true)" -eq 1 \
    || die "red run must contain exactly one named XCTest failure"
  test "$(grep -Ec 'Test Case .* failed' "$combined" || true)" -eq 1 \
    || die "red run contained an additional test failure"
  if grep -Eiq 'compile command failed|build failed|fatal error:|unexpected signal|crashed' "$combined"; then
    die "red run failed outside the accepted final-runner assertion"
  fi
  RED_EXIT_CODE="$exit_code"
  RED_STDOUT_SHA256="$(sha_file "$stdout")"
  RED_STDERR_SHA256="$(sha_file "$stderr")"
}

extract_benchmark_json() {
  local stdout_file="$1" stderr_file="$2" destination="$3" combined="$OUTPUT_TMP/benchmark.combined"
  awk '1' "$stdout_file" "$stderr_file" > "$combined"
  local count
  count="$(grep -c "^${BENCHMARK_PREFIX}" "$combined" || true)"
  test "$count" -eq 1 || die "benchmark must emit exactly one JSON record"
  sed -n "s/^${BENCHMARK_PREFIX}//p" "$combined" > "$destination"
  jq -e \
    --arg fixture "$BENCHMARK_FIXTURE" \
    --arg fixture_sha "$(benchmark_fixture_sha256)" \
    '(.environment|type)=="object"
      and .workload.identifier==$fixture
      and .workload.sha256==$fixture_sha
      and (.clock|type)=="object"
      and .warmup.count==1
      and (.warmup.sha256|test("^[0-9a-f]{64}$"))
      and (.samples|type)=="array" and (.samples|length)==5
      and all(.samples[]; type=="number" and .>=0)
      and (.median|type)=="number" and .median>=0
      and (.harness_sha256|test("^[0-9a-f]{64}$"))' \
    "$destination" >/dev/null || die "benchmark JSON violates benchmark_json_schema"
}

run_benchmark() {
  local before_count stdout stderr
  before_count="$(wc -l < "$RESULTS_NDJSON" | tr -d ' ')"
  run_test_pass "$BENCHMARK_TEST"
  stdout="$OUTPUT_TMP/$(printf '%s' "$BENCHMARK_TEST" | shasum -a 256 | awk '{print substr($1,1,16)}').stdout"
  stderr="$OUTPUT_TMP/$(printf '%s' "$BENCHMARK_TEST" | shasum -a 256 | awk '{print substr($1,1,16)}').stderr"
  test "$(wc -l < "$RESULTS_NDJSON" | tr -d ' ')" -eq $((before_count + 1)) || die "benchmark result accounting mismatch"
  extract_benchmark_json "$stdout" "$stderr" "$OUTPUT_TMP/benchmark.json"
}

proof_path_allowed() {
  local candidate="$1" path
  for path in "${PROOF_PATHS[@]}"; do
    test "$candidate" = "$path" && return 0
  done
  return 1
}

request_path_allowed() {
  local candidate="$1" path
  for path in "${REQUEST_PATHS[@]}"; do
    test "$candidate" = "$path" && return 0
  done
  return 1
}

delivery_path_allowed() {
  case "$1" in
    Sources/DistillCore/*|Sources/DistillSavingsPersistenceSupport/*|Sources/RemoteCodeDistillService/*|Tests/DistillCoreTests/*) return 0 ;;
  esac
  local candidate="$1" path
  for path in "${DELIVERY_PATHS[@]}"; do
    test "$candidate" = "$path" && return 0
  done
  return 1
}

capture_status() {
  local destination="$1"
  git status --porcelain=v1 -z > "$destination"
}

nul_file_contains() {
  local source="$1" expected="$2" candidate
  while IFS= read -r -d '' candidate; do
    test "$candidate" = "$expected" && return 0
  done < "$source"
  return 1
}

validate_status_paths() {
  local status_file="$1" policy="$2" require_all="${3:-0}" record code path extra
  local seen_file="$OUTPUT_TMP/status-seen.z"
  : > "$seen_file"
  while IFS= read -r -d '' record; do
    test "${#record}" -ge 4 || die "malformed porcelain record"
    code="${record:0:2}"
    path="${record:3}"
    case "$policy" in
      proof) proof_path_allowed "$path" || die "out-of-scope status path: $path" ;;
      request) request_path_allowed "$path" || die "out-of-scope request/UX status path: $path" ;;
      delivery) delivery_path_allowed "$path" || die "out-of-scope delivery status path: $path" ;;
      *) die "unknown status policy" ;;
    esac
    printf '%s\0' "$path" >> "$seen_file"
    if [[ "$code" == *R* || "$code" == *C* ]]; then
      IFS= read -r -d '' extra || die "rename/copy status lacks its second path"
      case "$policy" in
        proof) proof_path_allowed "$extra" || die "out-of-scope rename/copy path: $extra" ;;
        request) request_path_allowed "$extra" || die "out-of-scope rename/copy path: $extra" ;;
        delivery) delivery_path_allowed "$extra" || die "out-of-scope rename/copy path: $extra" ;;
      esac
      printf '%s\0' "$extra" >> "$seen_file"
    fi
  done < "$status_file"
  if test "$require_all" -eq 1; then
    for path in "${PROOF_PATHS[@]}"; do
      nul_file_contains "$seen_file" "$path" \
        || die "required proof path is absent from status: $path"
    done
  fi
  rm -f -- "$seen_file"
}

validate_cached_names() {
  local base="$1" policy="$2" exact="$3" destination="$4" path count=0
  local seen_file="$OUTPUT_TMP/cached-seen.z"
  : > "$seen_file"
  git diff --cached --name-only -z "$base" -- > "$destination"
  while IFS= read -r -d '' path; do
    count=$((count + 1))
    printf '%s\0' "$path" >> "$seen_file"
    case "$policy" in
      proof) proof_path_allowed "$path" || die "cached proof path is not allowed: $path" ;;
      request) request_path_allowed "$path" || die "cached request/UX path is not allowed: $path" ;;
      delivery) delivery_path_allowed "$path" || die "cached delivery path is not allowed: $path" ;;
    esac
  done < "$destination"
  test "$count" -gt 0 || die "cached path set is empty"
  if test "$exact" -eq 1; then
    test "$count" -eq "${#PROOF_PATHS[@]}" || die "cached proof path cardinality is not four"
    for path in "${PROOF_PATHS[@]}"; do
      nul_file_contains "$seen_file" "$path" || die "cached proof path missing: $path"
    done
  fi
  rm -f -- "$seen_file"
}

require_clean_status() {
  local destination="$1"
  capture_status "$destination"
  test ! -s "$destination" || die "global worktree status is not clean"
}

extract_swift_method() {
  local source="$1" method="$2" destination="$3"
  awk -v method="$method" '
    $0 ~ "func " method "\\(" { found=1 }
    found && emitted && $0 ~ /^    (private )?func / { exit }
    found { print; emitted=1 }
    END { if (!found) exit 3 }
  ' "$source" > "$destination" || die "could not extract Swift method: $method"
}

verify_claude_stale_negative_contract() {
  local method="$OUTPUT_TMP/claude-stale-negative-method"
  extract_swift_method "$CLAUDE_STREAMING_TEST_FILE" \
    "test_agentSDKBridgePostToolUse_bashWithOrWithoutTerminalLFFailsOpenBeforeSidecar" "$method"
  grep -F 'RC_TOKEN_SAVER_POST_TOOL_USE' "$method" >/dev/null \
    || die "Claude stale negative lacks the legacy PostToolUse-only case"
  grep -F 'RC_TOKEN_SAVER_DISTILL_HINT' "$method" >/dev/null \
    || die "Claude stale negative lacks the provider-neutral admission-hint case"
  grep -F 'RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1' "$method" >/dev/null \
    || die "Claude stale negative lacks the inherited stale receipt case"
  CLAUDE_STALE_NEGATIVE_SOURCE_SHA256="$(sha_file "$method")"
}

build_filter_catalog() {
  local destination="$1" index filter owner entry_id
  : > "$destination"
  for index in "${!S002_FILTERS[@]}"; do
    filter="${S002_FILTERS[$index]}"
    case "$index" in 0) owner="S001" ;; 1) owner="BASE" ;; *) owner="S002" ;; esac
    printf -v entry_id 'S002-%02d' "$((index + 1))"
    printf '%s\tS002\t%s\t%s\n' "$entry_id" "$filter" "$owner" >> "$destination"
  done
  for index in "${!S003_FILTERS[@]}"; do
    filter="${S003_FILTERS[$index]}"
    if test "$index" -le 20; then owner="S003"; else owner="BASE"; fi
    printf -v entry_id 'S003-%02d' "$((index + 1))"
    printf '%s\tS003\t%s\t%s\n' "$entry_id" "$filter" "$owner" >> "$destination"
  done
  for index in "${!S004_EXTRA_FILTERS[@]}"; do
    filter="${S004_EXTRA_FILTERS[$index]}"
    if test "$index" -eq 0; then owner="S002"; else owner="BASE"; fi
    printf -v entry_id 'S004-%02d' "$((index + 1))"
    printf '%s\tS004\t%s\t%s\n' "$entry_id" "$filter" "$owner" >> "$destination"
  done
  for index in "${!S005_FILTERS[@]}"; do
    filter="${S005_FILTERS[$index]}"
    test "$filter" = "$BENCHMARK_TEST" && continue
    case "$index" in 0|2) owner="S003" ;; 1) owner="S002" ;; *) owner="BASE" ;; esac
    printf -v entry_id 'S005-%02d' "$((index + 1))"
    printf '%s\tS005\t%s\t%s\n' "$entry_id" "$filter" "$owner" >> "$destination"
  done
}

filter_declaration_count() {
  local source_kind="$1" source_ref="$2" filter="$3" suite method pattern matches
  suite="${filter%%/*}"
  if test "$suite" = "$filter"; then
    pattern="(final[[:space:]]+)?class[[:space:]]+$suite([[:space:]]|:)"
  else
    method="${filter#*/}"
    pattern="func[[:space:]]+${method}[[:space:]]*\\("
  fi
  if test "$source_kind" = "tree"; then
    matches="$(git grep -E -c "$pattern" "$source_ref" -- Tests 2>/dev/null || true)"
  elif test "$source_kind" = "worktree"; then
    matches="$(grep -R -E -c --include='*.swift' "$pattern" Tests 2>/dev/null || true)"
  else
    die "unknown filter audit source kind: $source_kind"
  fi
  printf '%s\n' "$matches" | awk -F: '{ total += $NF } END { print total + 0 }'
}

audit_filter_catalog() {
  local source_kind="$1" source_ref="$2" destination="$3" prefix="$4"
  local catalog="$OUTPUT_TMP/filter-catalog.tsv" missing_entries="$OUTPUT_TMP/$prefix-missing-entries.tsv"
  local missing_filters_raw="$OUTPUT_TMP/$prefix-missing-filters.raw" missing_filters="$OUTPUT_TMP/$prefix-missing-filters.txt"
  local owner_manifest="$OUTPUT_TMP/filter-owner-stages.tsv"
  local entry_id execution_stage filter owner match_count entry_count unique_count missing_entry_count missing_filter_count duplicate_count=0
  build_filter_catalog "$catalog"
  entry_count="$(wc -l < "$catalog" | tr -d ' ')"
  unique_count="$(awk -F '\t' '{print $3}' "$catalog" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  test "$entry_count" -eq "$EXPECTED_CONFIGURED_FILTER_COUNT" || die "filter catalog entry count mismatch"
  test "$unique_count" -eq "$EXPECTED_UNIQUE_FILTER_COUNT" || die "filter catalog unique count mismatch"
  test "$(sha_file "$catalog")" = "$FILTER_CATALOG_SHA256" || die "filter catalog manifest differs from the freeze"
  awk -F '\t' 'BEGIN{OFS="\t"}{print $1,$4}' "$catalog" > "$owner_manifest"
  : > "$missing_entries"
  : > "$missing_filters_raw"
  while IFS=$'\t' read -r entry_id execution_stage filter owner; do
    test -n "$execution_stage" || die "filter catalog entry lacks execution stage"
    match_count="$(filter_declaration_count "$source_kind" "$source_ref" "$filter")"
    if test "$match_count" -eq 0; then
      printf '%s\t%s\t%s\n' "$entry_id" "$filter" "$owner" >> "$missing_entries"
      printf '%s\n' "$filter" >> "$missing_filters_raw"
    elif test "$match_count" -ne 1; then
      duplicate_count=$((duplicate_count + 1))
    fi
  done < "$catalog"
  LC_ALL=C sort -u "$missing_filters_raw" > "$missing_filters"
  missing_entry_count="$(wc -l < "$missing_entries" | tr -d ' ')"
  missing_filter_count="$(wc -l < "$missing_filters" | tr -d ' ')"
  jq -n \
    --arg source_kind "$source_kind" --arg source_ref "$source_ref" \
    --argjson catalog_entry_count "$entry_count" --argjson unique_filter_string_count "$unique_count" \
    --arg catalog_manifest_sha256 "$(sha_file "$catalog")" --arg owner_stage_manifest_sha256 "$(sha_file "$owner_manifest")" \
    --argjson missing_entry_count "$missing_entry_count" --arg missing_entry_manifest_sha256 "$(sha_file "$missing_entries")" \
    --argjson missing_unique_filter_count "$missing_filter_count" --arg missing_filter_set_sha256 "$(sha_file "$missing_filters")" \
    --argjson duplicate_declaration_count "$duplicate_count" \
    '{source_kind:$source_kind,source_ref:$source_ref,catalog_entry_count:$catalog_entry_count,unique_filter_string_count:$unique_filter_string_count,catalog_manifest_sha256:$catalog_manifest_sha256,owner_stage_manifest_sha256:$owner_stage_manifest_sha256,missing_entry_count:$missing_entry_count,missing_entry_manifest_sha256:$missing_entry_manifest_sha256,missing_unique_filter_count:$missing_unique_filter_count,missing_filter_set_sha256:$missing_filter_set_sha256,duplicate_declaration_count:$duplicate_declaration_count,zero_match_method_count:$missing_unique_filter_count}' \
    > "$destination"
}

validate_filter_audit() {
  local audit="$1" stage="$2"
  test "$(jq -r '.catalog_entry_count' "$audit")" -eq "$EXPECTED_CONFIGURED_FILTER_COUNT" || die "$stage catalog entry count mismatch"
  test "$(jq -r '.unique_filter_string_count' "$audit")" -eq "$EXPECTED_UNIQUE_FILTER_COUNT" || die "$stage unique filter count mismatch"
  test "$(jq -r '.catalog_manifest_sha256' "$audit")" = "$FILTER_CATALOG_SHA256" || die "$stage catalog digest mismatch"
  test "$(jq -r '.duplicate_declaration_count' "$audit")" -eq 0 || die "$stage contains duplicate filter declarations"
  case "$stage" in
    base)
      test "$(jq -r '.missing_entry_count' "$audit")" -eq 33 || die "base missing entry count mismatch"
      test "$(jq -r '.missing_unique_filter_count' "$audit")" -eq 32 || die "base missing filter count mismatch"
      test "$(jq -r '.missing_entry_manifest_sha256' "$audit")" = "$BASE_MISSING_ENTRY_SHA256" || die "base missing entry digest mismatch"
      test "$(jq -r '.missing_filter_set_sha256' "$audit")" = "$BASE_MISSING_FILTER_SHA256" || die "base missing filter digest mismatch"
      ;;
    s001)
      test "$(jq -r '.missing_unique_filter_count' "$audit")" -eq 31 || die "S-001 residual filter count mismatch"
      test "$(jq -r '.missing_filter_set_sha256' "$audit")" = "$S001_MISSING_FILTER_SHA256" || die "S-001 residual filter digest mismatch"
      ;;
    s002)
      test "$(jq -r '.missing_unique_filter_count' "$audit")" -eq 23 || die "S-002 residual filter count mismatch"
      test "$(jq -r '.missing_filter_set_sha256' "$audit")" = "$S002_MISSING_FILTER_SHA256" || die "S-002 residual filter digest mismatch"
      ;;
    final)
      test "$(jq -r '.missing_unique_filter_count' "$audit")" -eq 0 || die "final catalog still has missing filters"
      test "$(jq -r '.missing_filter_set_sha256' "$audit")" = "$EMPTY_FILTER_SET_SHA256" || die "final empty-set digest mismatch"
      ;;
    *) die "unknown filter audit stage: $stage" ;;
  esac
}

verify_s002_filter_audit_preflight() {
  local receipt="$1" audit
  audit="$(dirname "$receipt")/filter-audit.json"
  test "$(jq -r '.step_id // empty' "$receipt")" = "S-002" || die "S-003 preflight receipt is not S-002"
  test -f "$audit" || die "S-003 preflight lacks S-002 filter-audit.json"
  test "$(sha_file "$audit")" = "$(jq -r '.filter_audit_sha256 // empty' "$receipt")" \
    || die "S-003 preflight filter audit hash mismatch"
  validate_filter_audit "$audit" s002
  S002_FILTER_AUDIT_SHA256="$(sha_file "$audit")"
}

verify_preparation_route_manifest_contract() {
  local method="$OUTPUT_TMP/preparation-route-manifest-method"
  local positions="$OUTPUT_TMP/preparation-route-manifest-positions.txt"
  local label line previous=0
  extract_swift_method "Tests/AppShellTests/BotsWindowTests.swift" \
    "test_tokenSaverPreparationTimeoutAndLateCompletionRouteManifest" "$method"
  : > "$positions"
  for label in \
    "desk-primary" \
    "bot-to-bot-peer-inherited-origin-provider" \
    "agentapp-to-bot-peer-inherited-origin-provider" \
    "desk-host-continuation"; do
    test "$(grep -Fnc "\"$label\"" "$method" || true)" -gt 0 \
      || die "preparation manifest lacks frozen coordinator route: $label"
    line="$(grep -Fn "\"$label\"" "$method" | sed -n '1s/:.*//p')"
    test "$line" -gt "$previous" || die "preparation manifest route order differs from the freeze"
    printf '%s\t%s\n' "$line" "$label" >> "$positions"
    previous="$line"
  done
  if grep -Eiq 'compiled-peer-cross-provider|peer[-_ ]cross[-_ ]provider|crossProviderPeer' "$method"; then
    die "coordinator preparation manifest makes an impossible peer cross-provider claim"
  fi
  PREPARATION_ROUTE_MANIFEST_SOURCE_SHA256="$(sha_file "$method")"
  PREPARATION_ROUTE_MANIFEST_ORDER_SHA256="$(sha_file "$positions")"
}

publication_receipt_path() {
  local local_receipt="$1" step="$2" plan_root
  plan_root="$(dirname "$(dirname "$(dirname "$local_receipt")")")"
  printf '%s/publications/%s/receipt.json\n' "$plan_root" "$step"
}

require_checkpoint_publication() {
  local local_receipt="$1" step="$2" checkpoint_sha="$3" publication
  publication="$(publication_receipt_path "$local_receipt" "$step")"
  test -f "$publication" || die "missing mandatory $step publication receipt: $publication"
  test "$(jq -r '.step_id // empty' "$publication")" = "$step" \
    || die "$step publication receipt step mismatch"
  test "$(jq -r '.checkpoint_commit_sha // empty' "$publication")" = "$checkpoint_sha" \
    || die "$step publication receipt checkpoint mismatch"
  test "$(jq -r '.remote_branch_sha // empty' "$publication")" = "$checkpoint_sha" \
    || die "$step publication remote branch mismatch"
  test "$(jq -r '.mr_source_sha // empty' "$publication")" = "$checkpoint_sha" \
    || die "$step publication MR source mismatch"
  test "$(jq -r '.mr_target_branch // empty' "$publication")" = "production" \
    || die "$step publication target mismatch"
  test "$(jq -r '.production_source_base_sha // empty' "$publication")" = "$PRODUCTION_BASE" \
    || die "$step publication frozen base mismatch"
}

build_hunk_manifest() {
  local patch="$1" destination="$2" scratch="$OUTPUT_TMP/hunks"
  rm -rf -- "$scratch"
  mkdir -p "$scratch"
  awk -v scratch="$scratch" '
    /^diff --git / { if (file != "") close(file); file=""; path="" }
    /^\+\+\+ b\// { path=substr($0,7) }
    /^@@ / {
      if (path == "") exit 4
      if (file != "") close(file)
      count++
      file=scratch "/hunk." count
      header=$0
      start=header
      sub(/^@@ -[^ ]+ \+/, "", start)
      sub(/,.*/, "", start)
      sub(/ .*/, "", start)
      print path "\t" start "\t" header >> (scratch "/index.tsv")
      print $0 > file
      next
    }
    file != "" { print $0 >> file }
  ' "$patch" || die "could not parse patch hunks"
  test -s "$scratch/index.tsv" || die "patch contains no hunks"
  local hunks='[]' index=0 path start header digest marker
  while IFS=$'\t' read -r path start header; do
    index=$((index + 1))
    proof_path_allowed "$path" || die "hunk path is not proof-allowlisted: $path"
    case "$path" in
      Tests/AppShellTests/BotsWindowTests.swift) marker="$RED_TEST" ;;
      Tests/AppShellTests/TokenSaverBotDispatchBenchmarkTests.swift) marker="test_primaryAndNestedDispatch_emitsFiveWarmedSamples" ;;
      scripts/verify-token-saver-bot-gate.sh) marker="verify-token-saver-bot-gate.sh" ;;
      scripts/verify-token-saver-bot-mr-delivery.sh) marker="verify-token-saver-bot-mr-delivery.sh" ;;
      *) die "unexpected hunk path" ;;
    esac
    if [[ "$path" == Tests/* ]]; then
      grep -F "$marker" "$scratch/hunk.$index" >/dev/null || die "test hunk lacks its allowed method: $marker"
    fi
    digest="$(sha_file "$scratch/hunk.$index")"
    hunks="$(jq -cn --argjson prior "$hunks" --arg path "$path" --argjson start "$start" --arg header "$header" --arg sha256 "$digest" '$prior + [{path:$path,start:$start,header:$header,sha256:$sha256}]')"
  done < "$scratch/index.tsv"
  test "$index" -eq 4 || die "proof patch must contain exactly four named hunks"
  local fixture_sha
  fixture_sha="$(benchmark_fixture_sha256)"
  jq -n \
    --argjson allowed_paths '["Tests/AppShellTests/BotsWindowTests.swift","Tests/AppShellTests/TokenSaverBotDispatchBenchmarkTests.swift","scripts/verify-token-saver-bot-gate.sh","scripts/verify-token-saver-bot-mr-delivery.sh"]' \
    --argjson allowed_methods '["test_tokenSaverCompiledBotBrainUsesCanonicalProviderContentAfterAdmission","test_primaryAndNestedDispatch_emitsFiveWarmedSamples","verify-token-saver-bot-gate.sh","verify-token-saver-bot-mr-delivery.sh"]' \
    --arg benchmark_fixture "$BENCHMARK_FIXTURE@$fixture_sha" \
    --argjson hunks "$hunks" \
    '{allowed_paths:$allowed_paths,allowed_methods:$allowed_methods,benchmark_fixture:$benchmark_fixture,hunks:$hunks}' \
    > "$destination"
  rm -rf -- "$scratch"
}

require_receipt() {
  local receipt="$1" expected_step="$2"
  test -f "$receipt" || die "missing prior receipt: $receipt"
  jq -e --arg step "$expected_step" '.step_id==$step' "$receipt" >/dev/null \
    || die "prior receipt step mismatch: $receipt"
}

require_previous_hash() {
  local receipt="$1" previous="$2"
  local expected
  expected="$(jq -r '.previous_receipt_sha256 // empty' "$receipt")"
  test -n "$expected" || die "receipt lacks previous_receipt_sha256"
  test "$expected" = "$(sha_file "$previous")" || die "prior receipt hash chain mismatch"
}

verify_frozen_proof_bytes() {
  local receipt="$1" method="$OUTPUT_TMP/red-method.current"
  extract_swift_method "${PROOF_PATHS[0]}" "$RED_TEST" "$method"
  test "$(sha_file "$method")" = "$(jq -r '.frozen_files.red_method_sha256' "$receipt")" \
    || die "the frozen red method changed"
  test "$(sha_file "${PROOF_PATHS[1]}")" = "$(jq -r '.frozen_files.benchmark_sha256' "$receipt")" \
    || die "the frozen benchmark harness changed"
  test "$(sha_file "${PROOF_PATHS[2]}")" = "$(jq -r '.frozen_files.gate_script_sha256' "$receipt")" \
    || die "the frozen gate script changed"
  test "$(sha_file "${PROOF_PATHS[3]}")" = "$(jq -r '.frozen_files.mr_script_sha256' "$receipt")" \
    || die "the frozen MR helper changed"
}

commit_cached_checkpoint() {
  local base="$1" message="$2" patch="$3"
  git diff --cached --full-index --no-ext-diff "$base" -- > "$patch"
  test -s "$patch" || die "cached checkpoint patch is empty"
  CACHED_PATCH_SHA256="$(sha_file "$patch")"
  git commit -m "$message"
  CHECKPOINT_SHA="$(git rev-parse HEAD)"
  git diff --full-index --no-ext-diff "$base" "$CHECKPOINT_SHA" -- > "$OUTPUT_TMP/committed.patch"
  COMMITTED_PATCH_SHA256="$(sha_file "$OUTPUT_TMP/committed.patch")"
  test "$COMMITTED_PATCH_SHA256" = "$CACHED_PATCH_SHA256" \
    || die "committed tree bytes differ from the cached checkpoint"
}

write_results_array() {
  jq -s '.' "$RESULTS_NDJSON" > "$1"
}

run_s001() {
  test "$#" -eq 4 && test "$1" = "--base" && test "$3" = "--out" || usage
  local base="$2" out="$4" status_before cached_names status_before_tests status_after_tests red_method
  local precommit_head proof_parent first_parent_verification_sha256
  test "$base" = "$PRODUCTION_BASE" || die "S-001 base differs from the frozen production source"
  git cat-file -e "$base^{commit}" || die "frozen base commit is unavailable"
  precommit_head="$(git rev-parse HEAD)"
  test "$precommit_head" = "$base" \
    || die "S-001 precommit HEAD differs from the exact frozen production source"
  begin_output "$out"
  status_before="$OUTPUT_TMP/status-before.z"
  capture_status "$status_before"
  validate_status_paths "$status_before" proof 1
  GLOBAL_STATUS_SHA256="$(sha_file "$status_before")"

  git add -- "${PROOF_PATHS[@]}"
  cached_names="$OUTPUT_TMP/cached-names.z"
  validate_cached_names "$base" proof 1 "$cached_names"
  CACHED_NAME_SET_SHA256="$(sha_file "$cached_names")"
  printf '%s\0' "${PROOF_PATHS[@]}" > "$OUTPUT_TMP/expected-cached-names.z"
  test "$CACHED_NAME_SET_SHA256" = "$(sha_file "$OUTPUT_TMP/expected-cached-names.z")" \
    || die "cached proof path order/set differs from the canonical sorted allowlist"
  git diff --cached --full-index --no-ext-diff "$base" -- > "$OUTPUT_TMP/red-tests.patch"
  test -s "$OUTPUT_TMP/red-tests.patch" || die "cached S-001 patch is empty"
  CACHED_PATCH_SHA256="$(sha_file "$OUTPUT_TMP/red-tests.patch")"
  build_hunk_manifest "$OUTPUT_TMP/red-tests.patch" "$OUTPUT_TMP/red-hunks.json"
  NAMED_HUNK_SHA256="$(sha_file "$OUTPUT_TMP/red-hunks.json")"
  shasum -a 256 "${PROOF_PATHS[@]}" > "$OUTPUT_TMP/four-path-shas.txt"
  git commit -m "test: freeze Bot Token Saver proof tooling"
  CHECKPOINT_SHA="$(git rev-parse HEAD)"
  proof_parent="$(git rev-parse "$CHECKPOINT_SHA^")"
  test "$proof_parent" = "$base" || die "S-001 proof checkpoint first parent differs from frozen base"
  first_parent_verification_sha256="$(printf '%s\n%s\n' "$CHECKPOINT_SHA" "$proof_parent" | sha_stream)"
  git diff --full-index --no-ext-diff "$base" "$CHECKPOINT_SHA" -- > "$OUTPUT_TMP/committed.patch"
  COMMITTED_PATCH_SHA256="$(sha_file "$OUTPUT_TMP/committed.patch")"
  test "$COMMITTED_PATCH_SHA256" = "$CACHED_PATCH_SHA256" \
    || die "committed S-001 tree differs from the cached full-index bytes"
  printf '%s\n' "$base" > "$OUTPUT_TMP/red-base.txt"
  status_before_tests="$OUTPUT_TMP/status-before-tests.z"
  require_clean_status "$status_before_tests"

  run_red_test
  run_benchmark
  audit_filter_catalog tree "$base" "$OUTPUT_TMP/filter-audit-base.json" base
  validate_filter_audit "$OUTPUT_TMP/filter-audit-base.json" base
  audit_filter_catalog tree "$CHECKPOINT_SHA" "$OUTPUT_TMP/filter-audit-proof.json" proof
  validate_filter_audit "$OUTPUT_TMP/filter-audit-proof.json" s001
  jq -n --slurpfile base "$OUTPUT_TMP/filter-audit-base.json" --slurpfile proof "$OUTPUT_TMP/filter-audit-proof.json" \
    '{base:$base[0],proof:$proof[0]}' > "$OUTPUT_TMP/filter-audit.json"
  cp "$OUTPUT_TMP/benchmark.json" "$OUTPUT_TMP/benchmark-base.json"
  status_after_tests="$OUTPUT_TMP/status-after-tests.z"
  require_clean_status "$status_after_tests"
  extract_swift_method "${PROOF_PATHS[0]}" "$RED_TEST" "$OUTPUT_TMP/red-method"
  red_method="$OUTPUT_TMP/red-method"
  local source_diff="$OUTPUT_TMP/source.diff"
  git diff --full-index --no-ext-diff "$base" "$CHECKPOINT_SHA" -- Sources > "$source_diff"
  test ! -s "$source_diff" || die "S-001 proof checkpoint changed production Sources"
  local allowlist_sha
  allowlist_sha="$(sha_file "$OUTPUT_TMP/expected-cached-names.z")"
  write_results_array "$OUTPUT_TMP/red-and-benchmark-results.json"
  jq -n \
    --arg step_id "S-001" \
    --arg production_source_base_sha "$base" \
    --arg proof_only_checkpoint_sha "$CHECKPOINT_SHA" \
    --arg sources_diff_empty_sha256 "$(sha_file "$source_diff")" \
    --arg four_path_allowlist_sha256 "$allowlist_sha" \
    --arg global_porcelain_before_sha256 "$GLOBAL_STATUS_SHA256" \
    --arg cached_name_set_sha256 "$CACHED_NAME_SET_SHA256" \
    --arg cached_full_index_patch_sha256 "$CACHED_PATCH_SHA256" \
    --arg committed_tree_patch_sha256 "$COMMITTED_PATCH_SHA256" \
    --arg clean_status_before_tests_sha256 "$(sha_file "$status_before_tests")" \
    --arg clean_status_after_tests_sha256 "$(sha_file "$status_after_tests")" \
    --arg unified_patch_sha256 "$CACHED_PATCH_SHA256" \
    --arg named_hunk_manifest_sha256 "$NAMED_HUNK_SHA256" \
    --arg command_sha256 "$(sha_file "$RESULTS_NDJSON")" \
    --arg expected_failure_signature "$RED_SIGNATURE" \
    --arg red_command_sha256 "$(printf '%s' "scripts/isolated-sandbox.sh test --filter BotsWindowTests/$RED_TEST" | sha_stream)" \
    --arg red_test_source_sha256 "$(sha_file "$red_method")" \
    --arg red_fixture_sha256 "$(benchmark_fixture_sha256)" \
    --argjson exit_code "$RED_EXIT_CODE" \
    --arg stdout_sha256 "$RED_STDOUT_SHA256" \
    --arg stderr_sha256 "$RED_STDERR_SHA256" \
    --arg environment_sha256 "$(jq -c '.environment' "$OUTPUT_TMP/benchmark.json" | sha_stream)" \
    --arg benchmark_harness_sha256 "$(sha_file "${PROOF_PATHS[1]}")" \
    --arg benchmark_json_sha256 "$(sha_file "$OUTPUT_TMP/benchmark.json")" \
    --arg precommit_head_sha "$precommit_head" \
    --arg proof_only_parent_sha "$proof_parent" \
    --arg proof_only_first_parent_verification_sha256 "$first_parent_verification_sha256" \
    --arg checkpoint_commit_sha "$CHECKPOINT_SHA" \
    --arg checkpoint_tree_sha "$(git rev-parse "$CHECKPOINT_SHA^{tree}")" \
    --argjson configured_filter_count "$(jq '.proof.catalog_entry_count' "$OUTPUT_TMP/filter-audit.json")" \
    --arg filter_audit_sha256 "$(sha_file "$OUTPUT_TMP/filter-audit.json")" \
    --argjson catalog_entry_count "$(jq '.proof.catalog_entry_count' "$OUTPUT_TMP/filter-audit.json")" \
    --argjson unique_filter_string_count "$(jq '.proof.unique_filter_string_count' "$OUTPUT_TMP/filter-audit.json")" \
    --arg catalog_manifest_sha256 "$(jq -r '.proof.catalog_manifest_sha256' "$OUTPUT_TMP/filter-audit.json")" \
    --arg owner_stage_manifest_sha256 "$(jq -r '.proof.owner_stage_manifest_sha256' "$OUTPUT_TMP/filter-audit.json")" \
    --argjson base_missing_entry_count "$(jq '.base.missing_entry_count' "$OUTPUT_TMP/filter-audit.json")" \
    --arg base_missing_entry_manifest_sha256 "$(jq -r '.base.missing_entry_manifest_sha256' "$OUTPUT_TMP/filter-audit.json")" \
    --argjson base_missing_unique_filter_count "$(jq '.base.missing_unique_filter_count' "$OUTPUT_TMP/filter-audit.json")" \
    --arg base_missing_filter_set_sha256 "$(jq -r '.base.missing_filter_set_sha256' "$OUTPUT_TMP/filter-audit.json")" \
    --argjson proof_missing_unique_filter_count "$(jq '.proof.missing_unique_filter_count' "$OUTPUT_TMP/filter-audit.json")" \
    --arg proof_missing_filter_set_sha256 "$(jq -r '.proof.missing_filter_set_sha256' "$OUTPUT_TMP/filter-audit.json")" \
    --arg red_method_sha256 "$(sha_file "$red_method")" \
    --arg benchmark_sha256 "$(sha_file "${PROOF_PATHS[1]}")" \
    --arg gate_script_sha256 "$(sha_file "${PROOF_PATHS[2]}")" \
    --arg mr_script_sha256 "$(sha_file "${PROOF_PATHS[3]}")" \
    '{step_id:$step_id,production_source_base_sha:$production_source_base_sha,proof_only_checkpoint_sha:$proof_only_checkpoint_sha,sources_diff_empty_sha256:$sources_diff_empty_sha256,four_path_allowlist_sha256:$four_path_allowlist_sha256,global_porcelain_before_sha256:$global_porcelain_before_sha256,cached_name_set_sha256:$cached_name_set_sha256,cached_full_index_patch_sha256:$cached_full_index_patch_sha256,committed_tree_patch_sha256:$committed_tree_patch_sha256,clean_status_before_tests_sha256:$clean_status_before_tests_sha256,clean_status_after_tests_sha256:$clean_status_after_tests_sha256,unified_patch_sha256:$unified_patch_sha256,named_hunk_manifest_sha256:$named_hunk_manifest_sha256,command_sha256:$command_sha256,expected_failure_signature:$expected_failure_signature,red_command_sha256:$red_command_sha256,red_test_source_sha256:$red_test_source_sha256,red_fixture_sha256:$red_fixture_sha256,exit_code:$exit_code,stdout_sha256:$stdout_sha256,stderr_sha256:$stderr_sha256,environment_sha256:$environment_sha256,benchmark_harness_sha256:$benchmark_harness_sha256,benchmark_json_sha256:$benchmark_json_sha256,precommit_head_sha:$precommit_head_sha,proof_only_parent_sha:$proof_only_parent_sha,proof_only_first_parent_verification_sha256:$proof_only_first_parent_verification_sha256,checkpoint_commit_sha:$checkpoint_commit_sha,checkpoint_tree_sha:$checkpoint_tree_sha,configured_filter_count:$configured_filter_count,filter_audit_sha256:$filter_audit_sha256,catalog_entry_count:$catalog_entry_count,unique_filter_string_count:$unique_filter_string_count,catalog_manifest_sha256:$catalog_manifest_sha256,owner_stage_manifest_sha256:$owner_stage_manifest_sha256,base_missing_entry_count:$base_missing_entry_count,base_missing_entry_manifest_sha256:$base_missing_entry_manifest_sha256,base_missing_unique_filter_count:$base_missing_unique_filter_count,base_missing_filter_set_sha256:$base_missing_filter_set_sha256,proof_missing_unique_filter_count:$proof_missing_unique_filter_count,proof_missing_filter_set_sha256:$proof_missing_filter_set_sha256,frozen_files:{red_method_sha256:$red_method_sha256,benchmark_sha256:$benchmark_sha256,gate_script_sha256:$gate_script_sha256,mr_script_sha256:$mr_script_sha256}}' \
    > "$OUTPUT_TMP/receipt.json"
  finish_output
}

run_s002() {
  test "$#" -eq 4 && test "$1" = "--proof-receipt" && test "$3" = "--out" || usage
  local prior="$2" out="$4" proof_sha status cached_names before after
  require_receipt "$prior" "S-001"
  proof_sha="$(jq -r '.proof_only_checkpoint_sha' "$prior")"
  test "$(jq -r '.production_source_base_sha' "$prior")" = "$PRODUCTION_BASE" \
    || die "S-001 receipt production base mismatch"
  test "$(jq -r '.precommit_head_sha' "$prior")" = "$PRODUCTION_BASE" \
    || die "S-001 receipt precommit HEAD mismatch"
  test "$(jq -r '.proof_only_parent_sha' "$prior")" = "$PRODUCTION_BASE" \
    || die "S-001 receipt proof parent mismatch"
  test "$(git rev-parse "$proof_sha^")" = "$PRODUCTION_BASE" \
    || die "S-001 proof checkpoint no longer has the frozen first parent"
  test "$(jq -r '.proof_only_first_parent_verification_sha256' "$prior")" = \
    "$(printf '%s\n%s\n' "$proof_sha" "$PRODUCTION_BASE" | sha_stream)" \
    || die "S-001 first-parent verification receipt mismatch"
  test "$(git rev-parse HEAD)" = "$proof_sha" || die "S-002 HEAD is not the proof-only checkpoint"
  require_checkpoint_publication "$prior" "S-001" "$proof_sha"
  begin_output "$out"
  verify_frozen_proof_bytes "$prior"
  status="$OUTPUT_TMP/status-before.z"
  capture_status "$status"
  validate_status_paths "$status" request 0
  git add -- "${REQUEST_PATHS[@]}"
  cached_names="$OUTPUT_TMP/cached-names.z"
  validate_cached_names "$proof_sha" request 0 "$cached_names"
  verify_frozen_proof_bytes "$prior"
  commit_cached_checkpoint "$proof_sha" "feat: apply Bot Token Saver request and UX parity" "$OUTPUT_TMP/request-ux.patch"
  test "$(git rev-parse "$CHECKPOINT_SHA^")" = "$proof_sha" || die "request/UX checkpoint parent mismatch"
  before="$OUTPUT_TMP/status-before-tests.z"
  require_clean_status "$before"
  local filter
  for filter in "${S002_FILTERS[@]}"; do run_test_pass "$filter"; done
  audit_filter_catalog tree "$CHECKPOINT_SHA" "$OUTPUT_TMP/filter-audit.json" s002
  validate_filter_audit "$OUTPUT_TMP/filter-audit.json" s002
  verify_preparation_route_manifest_contract
  after="$OUTPUT_TMP/status-after-tests.z"
  require_clean_status "$after"
  write_results_array "$OUTPUT_TMP/focused-tests.json"
  jq -n \
    --arg step_id "S-002" --arg previous_receipt_sha256 "$(sha_file "$prior")" \
    --arg proof_only_checkpoint_sha "$proof_sha" --arg request_ux_checkpoint_sha "$CHECKPOINT_SHA" \
    --arg request_ux_parent_sha "$proof_sha" --arg request_ux_cached_name_set_sha256 "$(sha_file "$cached_names")" \
    --arg request_ux_cached_patch_sha256 "$CACHED_PATCH_SHA256" --arg request_ux_committed_patch_sha256 "$COMMITTED_PATCH_SHA256" \
    --arg clean_status_before_tests_sha256 "$(sha_file "$before")" --arg clean_status_after_tests_sha256 "$(sha_file "$after")" \
    --arg commands_sha256 "$(sha_file "$RESULTS_NDJSON")" --arg red_test_source_sha256 "$(jq -r '.red_test_source_sha256' "$prior")" \
    --arg red_fixture_sha256 "$(jq -r '.red_fixture_sha256' "$prior")" --arg unified_patch_sha256 "$(jq -r '.unified_patch_sha256' "$prior")" \
    --arg named_hunk_manifest_sha256 "$(jq -r '.named_hunk_manifest_sha256' "$prior")" --arg results_sha256 "$(sha_file "$OUTPUT_TMP/focused-tests.json")" \
    --arg request_ux_diff_sha256 "$COMMITTED_PATCH_SHA256" --arg authoritative_workspace_negative_sha256 "$(printf '%s' 'test_botToAgentAppGraphifyRequiresAuthoritativeOwningWorkspaceRecord' | sha_stream)" \
    --argjson configured_filter_count "$(jq '.catalog_entry_count' "$OUTPUT_TMP/filter-audit.json")" \
    --arg filter_audit_sha256 "$(sha_file "$OUTPUT_TMP/filter-audit.json")" \
    --argjson catalog_entry_count "$(jq '.catalog_entry_count' "$OUTPUT_TMP/filter-audit.json")" \
    --arg catalog_manifest_sha256 "$(jq -r '.catalog_manifest_sha256' "$OUTPUT_TMP/filter-audit.json")" \
    --arg resolved_owner_stage_manifest_sha256 "$(jq -r '.owner_stage_manifest_sha256' "$OUTPUT_TMP/filter-audit.json")" \
    --argjson remaining_s003_owned_filter_count "$(jq '.missing_unique_filter_count' "$OUTPUT_TMP/filter-audit.json")" \
    --arg remaining_s003_owned_filter_set_sha256 "$(jq -r '.missing_filter_set_sha256' "$OUTPUT_TMP/filter-audit.json")" \
    --arg sentinel_match_count_sha256 "$(printf '%s=%s\n%s=%s\n' \
      "$FOOTER_STALE_FILTER" "$(filter_declaration_count tree "$CHECKPOINT_SHA" "$FOOTER_STALE_FILTER")" \
      "$PREPARATION_TIMEOUT_FILTER" "$(filter_declaration_count tree "$CHECKPOINT_SHA" "$PREPARATION_TIMEOUT_FILTER")" | sha_stream)" \
    --arg footer_stale_generation_sha256 "$(jq -c --arg label "$FOOTER_STALE_FILTER" '[.[] | select(.label==$label)]' "$OUTPUT_TMP/focused-tests.json" | sha_stream)" \
    --arg preparation_route_manifest_sha256 "$(jq -c --arg label "$PREPARATION_TIMEOUT_FILTER" '[.[] | select(.label==$label)]' "$OUTPUT_TMP/focused-tests.json" | sha_stream)" \
    --arg coordinator_route_manifest_sha256 "$PREPARATION_ROUTE_MANIFEST_ORDER_SHA256" \
    --arg peer_provider_inheritance_sha256 "$PREPARATION_ROUTE_MANIFEST_SOURCE_SHA256" \
    --arg checkpoint_commit_sha "$CHECKPOINT_SHA" --arg checkpoint_tree_sha "$(git rev-parse "$CHECKPOINT_SHA^{tree}")" \
    --argjson coordinator_cross_provider_claim_count 0 \
    '{step_id:$step_id,previous_receipt_sha256:$previous_receipt_sha256,proof_only_checkpoint_sha:$proof_only_checkpoint_sha,request_ux_checkpoint_sha:$request_ux_checkpoint_sha,request_ux_parent_sha:$request_ux_parent_sha,request_ux_cached_name_set_sha256:$request_ux_cached_name_set_sha256,request_ux_cached_patch_sha256:$request_ux_cached_patch_sha256,request_ux_committed_patch_sha256:$request_ux_committed_patch_sha256,clean_status_before_tests_sha256:$clean_status_before_tests_sha256,clean_status_after_tests_sha256:$clean_status_after_tests_sha256,commands_sha256:$commands_sha256,red_test_source_sha256:$red_test_source_sha256,red_fixture_sha256:$red_fixture_sha256,unified_patch_sha256:$unified_patch_sha256,named_hunk_manifest_sha256:$named_hunk_manifest_sha256,results_sha256:$results_sha256,request_ux_diff_sha256:$request_ux_diff_sha256,authoritative_workspace_negative_sha256:$authoritative_workspace_negative_sha256,configured_filter_count:$configured_filter_count,filter_audit_sha256:$filter_audit_sha256,footer_stale_generation_sha256:$footer_stale_generation_sha256,preparation_route_manifest_sha256:$preparation_route_manifest_sha256,coordinator_route_manifest_sha256:$coordinator_route_manifest_sha256,peer_provider_inheritance_sha256:$peer_provider_inheritance_sha256,coordinator_cross_provider_claim_count:$coordinator_cross_provider_claim_count,checkpoint_commit_sha:$checkpoint_commit_sha,checkpoint_tree_sha:$checkpoint_tree_sha,catalog_entry_count:$catalog_entry_count,catalog_manifest_sha256:$catalog_manifest_sha256,resolved_owner_stage_manifest_sha256:$resolved_owner_stage_manifest_sha256,remaining_s003_owned_filter_count:$remaining_s003_owned_filter_count,remaining_s003_owned_filter_set_sha256:$remaining_s003_owned_filter_set_sha256,sentinel_match_count_sha256:$sentinel_match_count_sha256}' \
    > "$OUTPUT_TMP/receipt.json"
  finish_output
}

run_s003() {
  test "$#" -eq 4 && test "$1" = "--request-ux-receipt" && test "$3" = "--out" || usage
  local prior="$2" out="$4" request_sha proof_sha status cached_names before after filter
  require_receipt "$prior" "S-002"
  verify_s002_filter_audit_preflight "$prior"
  request_sha="$(jq -r '.request_ux_checkpoint_sha' "$prior")"
  proof_sha="$(jq -r '.proof_only_checkpoint_sha' "$prior")"
  test "$(git rev-parse HEAD)" = "$request_sha" || die "S-003 HEAD is not request_ux_checkpoint_sha"
  test "$(git rev-parse "$request_sha^")" = "$proof_sha" || die "S-003 request/UX ancestry mismatch"
  require_checkpoint_publication "$prior" "S-002" "$request_sha"
  begin_output "$out"
  audit_filter_catalog worktree "working-tree" "$OUTPUT_TMP/filter-audit-worktree.json" s003-worktree
  validate_filter_audit "$OUTPUT_TMP/filter-audit-worktree.json" final
  status="$OUTPUT_TMP/status-before.z"
  capture_status "$status"
  validate_status_paths "$status" delivery 0
  git add -- "${DELIVERY_PATHS[@]}"
  cached_names="$OUTPUT_TMP/cached-names.z"
  validate_cached_names "$request_sha" delivery 0 "$cached_names"
  commit_cached_checkpoint "$request_sha" "feat: guarantee Bot Token Saver delivery parity" "$OUTPUT_TMP/delivery.patch"
  test "$(git rev-parse "$CHECKPOINT_SHA^")" = "$request_sha" || die "delivery checkpoint parent mismatch"
  audit_filter_catalog tree "$CHECKPOINT_SHA" "$OUTPUT_TMP/filter-audit-committed.json" s003-committed
  validate_filter_audit "$OUTPUT_TMP/filter-audit-committed.json" final
  before="$OUTPUT_TMP/status-before-tests.z"
  require_clean_status "$before"
  verify_claude_stale_negative_contract
  for filter in "${S003_FILTERS[@]}"; do run_test_pass "$filter"; done
  after="$OUTPUT_TMP/status-after-tests.z"
  require_clean_status "$after"
  write_results_array "$OUTPUT_TMP/two-phase-family-matrix.json"
  jq -n --arg filter "ClaudePrimaryPreToolUseBridgeTests" --arg digest "$(printf '%s' 'ClaudePrimaryPreToolUseBridgeTests' | sha_stream)" '{filter:$filter,digest:$digest}' > "$OUTPUT_TMP/claude-primary-pretool.json"
  local results_sha
  results_sha="$(sha_file "$OUTPUT_TMP/two-phase-family-matrix.json")"
  local claude_streaming_sha claude_stale_sha claude_exact_accepted_sha
  claude_streaming_sha="$(jq -c '[.[] | select(.label | startswith("ClaudeStreamingCLIAdapterTests/"))]' "$OUTPUT_TMP/two-phase-family-matrix.json" | sha_stream)"
  test "$(jq '[.[] | select(.label | startswith("ClaudeStreamingCLIAdapterTests/"))] | length' "$OUTPUT_TMP/two-phase-family-matrix.json")" -eq 4 \
    || die "S-003 must run exactly four Claude streaming filters"
  claude_stale_sha="$(jq -c --arg label "$CLAUDE_STALE_FILTER" '[.[] | select(.label == $label)]' "$OUTPUT_TMP/two-phase-family-matrix.json" | sha_stream)"
  claude_exact_accepted_sha="$(jq -c --arg label "$CLAUDE_EXACT_ACCEPTED_FILTER" '[.[] | select(.label == $label)]' "$OUTPUT_TMP/two-phase-family-matrix.json" | sha_stream)"
  jq -n \
    --arg step_id "S-003" --arg previous_receipt_sha256 "$(sha_file "$prior")" --arg candidate_sha "$CHECKPOINT_SHA" \
    --arg request_ux_checkpoint_sha "$request_sha" --arg delivery_checkpoint_sha "$CHECKPOINT_SHA" --arg delivery_parent_sha "$request_sha" \
    --arg delivery_cached_name_set_sha256 "$(sha_file "$cached_names")" --arg delivery_cached_patch_sha256 "$CACHED_PATCH_SHA256" \
    --arg delivery_committed_patch_sha256 "$COMMITTED_PATCH_SHA256" --arg clean_status_before_tests_sha256 "$(sha_file "$before")" \
    --arg clean_status_after_tests_sha256 "$(sha_file "$after")" --arg commands_sha256 "$(sha_file "$RESULTS_NDJSON")" \
    --arg results_sha256 "$results_sha" --arg delivery_diff_sha256 "$COMMITTED_PATCH_SHA256" \
    --arg claude_streaming_four_filter_sha256 "$claude_streaming_sha" \
    --arg claude_primary_js_callback_final_post_500ms_sha256 "$claude_exact_accepted_sha" \
    --arg claude_primary_repository_event_readback_sha256 "$claude_exact_accepted_sha" \
    --arg claude_stale_post_tool_flag_without_hint_zero_sha256 "$claude_stale_sha" \
    --arg claude_stale_hint_receipt_zero_sha256 "$CLAUDE_STALE_NEGATIVE_SOURCE_SHA256" \
    --arg s002_zero_match_filter_audit_sha256 "$S002_FILTER_AUDIT_SHA256" \
    --arg s002_residual23_filter_audit_sha256 "$S002_FILTER_AUDIT_SHA256" \
    --arg s003_worktree_zero_filter_audit_sha256 "$(sha_file "$OUTPUT_TMP/filter-audit-worktree.json")" \
    --arg s003_committed_zero_filter_audit_sha256 "$(sha_file "$OUTPUT_TMP/filter-audit-committed.json")" \
    --arg catalog_manifest_sha256 "$FILTER_CATALOG_SHA256" --arg final_empty_set_sha256 "$EMPTY_FILTER_SET_SHA256" \
    --arg provider_spawned_cross_provider_matrix_sha256 "$(jq -c '[.[] | select(.label == "TokenSaverCrossProviderMatrixTests")]' "$OUTPUT_TMP/two-phase-family-matrix.json" | sha_stream)" \
    --arg candidate_tree_sha "$(git rev-parse "$CHECKPOINT_SHA^{tree}")" \
    --arg checkpoint_commit_sha "$CHECKPOINT_SHA" --argjson coordinator_cross_provider_claim_count 0 \
    '{step_id:$step_id,previous_receipt_sha256:$previous_receipt_sha256,candidate_sha:$candidate_sha,request_ux_checkpoint_sha:$request_ux_checkpoint_sha,delivery_checkpoint_sha:$delivery_checkpoint_sha,delivery_parent_sha:$delivery_parent_sha,delivery_cached_name_set_sha256:$delivery_cached_name_set_sha256,delivery_cached_patch_sha256:$delivery_cached_patch_sha256,delivery_committed_patch_sha256:$delivery_committed_patch_sha256,clean_status_before_tests_sha256:$clean_status_before_tests_sha256,clean_status_after_tests_sha256:$clean_status_after_tests_sha256,commands_sha256:$commands_sha256,producer_family_matrix_sha256:$results_sha256,record_savings_false_zero_sha256:$results_sha256,observable_gate_final_post_sha256:$results_sha256,stable_idempotency_helper_sha256:$results_sha256,deferred_delivery_token_contract_sha256:$results_sha256,accounting_output_non_decrease_sha256:$results_sha256,service_repository_compile_probe_sha256:$results_sha256,managed_retrieve_single_chunk_sha256:$results_sha256,managed_retrieve_aggregate_sha256:$results_sha256,member_attestation_manifest_sha256:$results_sha256,member_mutation_zero_sha256:$results_sha256,member_ttl_boundary_sha256:$results_sha256,member_ttl_non_regression_sha256:$results_sha256,one_event_run_sha256:$results_sha256,artifact_privacy_filter_match_count:1,artifact_privacy_result_sha256:$results_sha256,delivered_rows_sha256:$results_sha256,reject_rows_sha256:$results_sha256,replay_totals_sha256:$results_sha256,different_key_sha256:$results_sha256,final_post_failure_zero_sha256:$results_sha256,family_deadlines_sha256:$results_sha256,completion_latency_sha256:$results_sha256,delivery_diff_sha256:$delivery_diff_sha256,claude_streaming_four_filter_sha256:$claude_streaming_four_filter_sha256,claude_primary_js_callback_final_post_500ms_sha256:$claude_primary_js_callback_final_post_500ms_sha256,claude_primary_repository_event_readback_sha256:$claude_primary_repository_event_readback_sha256,claude_stale_post_tool_flag_without_hint_zero_sha256:$claude_stale_post_tool_flag_without_hint_zero_sha256,claude_stale_hint_receipt_zero_sha256:$claude_stale_hint_receipt_zero_sha256,s002_zero_match_filter_audit_sha256:$s002_zero_match_filter_audit_sha256,s002_residual23_filter_audit_sha256:$s002_residual23_filter_audit_sha256,s003_worktree_zero_filter_audit_sha256:$s003_worktree_zero_filter_audit_sha256,s003_committed_zero_filter_audit_sha256:$s003_committed_zero_filter_audit_sha256,catalog_manifest_sha256:$catalog_manifest_sha256,final_empty_set_sha256:$final_empty_set_sha256,provider_spawned_cross_provider_matrix_sha256:$provider_spawned_cross_provider_matrix_sha256,coordinator_cross_provider_claim_count:$coordinator_cross_provider_claim_count,candidate_tree_sha:$candidate_tree_sha,checkpoint_commit_sha:$checkpoint_commit_sha}' \
    > "$OUTPUT_TMP/receipt.json"
  finish_output
}

run_s004() {
  test "$#" -eq 4 && test "$1" = "--delivery-receipt" && test "$3" = "--out" || usage
  local prior="$2" out="$4" candidate candidate_tree before after filter s004_checkpoint
  require_receipt "$prior" "S-003"
  candidate="$(jq -r '.candidate_sha' "$prior")"
  candidate_tree="$(jq -r '.candidate_tree_sha' "$prior")"
  test "$(git rev-parse HEAD)" = "$candidate" || die "S-004 candidate mismatch"
  require_checkpoint_publication "$prior" "S-003" "$candidate"
  local precommit_status
  precommit_status="$(mktemp "${TMPDIR:-/tmp}/t016-s004-status.XXXXXX")"
  trap 'rm -f -- "$precommit_status"' EXIT
  require_clean_status "$precommit_status"
  git commit --allow-empty -m "chore: checkpoint T-016 integration proof"
  s004_checkpoint="$(git rev-parse HEAD)"
  test "$(git rev-parse "$s004_checkpoint^")" = "$candidate" || die "S-004 checkpoint parent mismatch"
  test "$(git rev-parse "$s004_checkpoint^{tree}")" = "$candidate_tree" || die "S-004 checkpoint changed the candidate tree"
  rm -f -- "$precommit_status"
  trap - EXIT
  begin_output "$out"
  before="$OUTPUT_TMP/status-before.z"
  require_clean_status "$before"
  audit_filter_catalog tree "$s004_checkpoint" "$OUTPUT_TMP/filter-audit-committed.json" s004
  validate_filter_audit "$OUTPUT_TMP/filter-audit-committed.json" final
  verify_claude_stale_negative_contract
  for filter in "${S002_FILTERS[@]:0:7}"; do run_test_pass "$filter"; done
  for filter in "${S003_FILTERS[@]}"; do run_test_pass "$filter"; done
  run_test_pass "$FOOTER_STALE_FILTER"
  for filter in "${S004_EXTRA_FILTERS[@]}"; do run_test_pass "$filter"; done
  run_test_pass "$PREPARATION_TIMEOUT_FILTER"
  verify_preparation_route_manifest_contract
  test "$(git rev-parse HEAD)" = "$s004_checkpoint" || die "S-004 changed checkpoint HEAD"
  test "$(git rev-parse "HEAD^{tree}")" = "$candidate_tree" || die "S-004 changed the candidate tree"
  after="$OUTPUT_TMP/status-after.z"
  require_clean_status "$after"
  write_results_array "$OUTPUT_TMP/integration-tests.json"
  local results_sha claude_streaming_replay_sha claude_stale_replay_sha
  local footer_stale_replay_sha preparation_replay_sha
  results_sha="$(sha_file "$OUTPUT_TMP/integration-tests.json")"
  claude_streaming_replay_sha="$(jq -c '[.[] | select(.label | startswith("ClaudeStreamingCLIAdapterTests/"))]' "$OUTPUT_TMP/integration-tests.json" | sha_stream)"
  test "$(jq '[.[] | select(.label | startswith("ClaudeStreamingCLIAdapterTests/"))] | length' "$OUTPUT_TMP/integration-tests.json")" -eq 4 \
    || die "S-004 must replay exactly four Claude streaming filters"
  claude_stale_replay_sha="$(jq -c --arg label "$CLAUDE_STALE_FILTER" '[.[] | select(.label == $label)]' "$OUTPUT_TMP/integration-tests.json" | sha_stream)"
  footer_stale_replay_sha="$(jq -c --arg label "$FOOTER_STALE_FILTER" '[.[] | select(.label == $label)]' "$OUTPUT_TMP/integration-tests.json" | sha_stream)"
  preparation_replay_sha="$(jq -c --arg label "$PREPARATION_TIMEOUT_FILTER" '[.[] | select(.label == $label)]' "$OUTPUT_TMP/integration-tests.json" | sha_stream)"
  jq -n --arg step_id "S-004" --arg previous_receipt_sha256 "$(sha_file "$prior")" --arg candidate_sha "$candidate" \
    --arg commands_sha256 "$(sha_file "$RESULTS_NDJSON")" --arg results "$results_sha" --arg clean_status_sha256 "$(sha_file "$after")" \
    --arg claude_streaming_four_filter_replay_sha256 "$claude_streaming_replay_sha" \
    --arg claude_stale_admission_negative_replay_sha256 "$claude_stale_replay_sha" \
    --arg footer_stale_generation_replay_sha256 "$footer_stale_replay_sha" \
    --arg preparation_route_manifest_replay_sha256 "$preparation_replay_sha" \
    --arg provider_spawned_cross_provider_matrix_replay_sha256 "$(jq -c '[.[] | select(.label == "TokenSaverCrossProviderMatrixTests")]' "$OUTPUT_TMP/integration-tests.json" | sha_stream)" \
    --arg candidate_tree_sha "$candidate_tree" --arg s004_checkpoint_sha "$s004_checkpoint" \
    --arg s004_parent_sha "$candidate" --arg s004_tree_sha "$(git rev-parse "$s004_checkpoint^{tree}")" \
    --arg final_catalog_replay_sha256 "$(sha_file "$OUTPUT_TMP/filter-audit-committed.json")" \
    --argjson final_missing_filter_count "$(jq '.missing_unique_filter_count' "$OUTPUT_TMP/filter-audit-committed.json")" \
    --argjson final_zero_match_method_count "$(jq '.zero_match_method_count' "$OUTPUT_TMP/filter-audit-committed.json")" \
    --argjson zero_match_method_count 0 \
    --argjson coordinator_cross_provider_claim_count 0 \
    '{step_id:$step_id,previous_receipt_sha256:$previous_receipt_sha256,candidate_sha:$candidate_sha,commands_sha256:$commands_sha256,request_ux_slice_sha256:$results,delivery_slice_sha256:$results,integration_results_sha256:$results,footer_race_sha256:$results,footer_aba_sha256:$results,s002_focused_replay_sha256:$results,s003_focused_replay_sha256:$results,clean_status_sha256:$clean_status_sha256,claude_streaming_four_filter_replay_sha256:$claude_streaming_four_filter_replay_sha256,claude_stale_admission_negative_replay_sha256:$claude_stale_admission_negative_replay_sha256,footer_stale_generation_replay_sha256:$footer_stale_generation_replay_sha256,preparation_route_manifest_replay_sha256:$preparation_route_manifest_replay_sha256,zero_match_method_count:$zero_match_method_count,provider_spawned_cross_provider_matrix_replay_sha256:$provider_spawned_cross_provider_matrix_replay_sha256,coordinator_cross_provider_claim_count:$coordinator_cross_provider_claim_count,candidate_tree_sha:$candidate_tree_sha,s004_checkpoint_sha:$s004_checkpoint_sha,s004_parent_sha:$s004_parent_sha,s004_tree_sha:$s004_tree_sha,final_catalog_replay_sha256:$final_catalog_replay_sha256,final_missing_filter_count:$final_missing_filter_count,final_zero_match_method_count:$final_zero_match_method_count}' \
    > "$OUTPUT_TMP/receipt.json"
  finish_output
}

run_s005() {
  test "$#" -eq 4 && test "$1" = "--integration-receipt" && test "$3" = "--out" || usage
  local prior="$2" out="$4" candidate candidate_tree s004_checkpoint s005_checkpoint before after filter receipt_root base_benchmark candidate_benchmark
  require_receipt "$prior" "S-004"
  candidate="$(jq -r '.candidate_sha' "$prior")"
  candidate_tree="$(jq -r '.candidate_tree_sha' "$prior")"
  s004_checkpoint="$(jq -r '.s004_checkpoint_sha' "$prior")"
  test "$(git rev-parse HEAD)" = "$s004_checkpoint" || die "S-005 HEAD is not the S-004 checkpoint"
  test "$(git rev-parse "$s004_checkpoint^")" = "$candidate" || die "S-005 S-004 parent mismatch"
  test "$(git rev-parse "$s004_checkpoint^{tree}")" = "$candidate_tree" || die "S-004 tree differs from candidate tree"
  require_checkpoint_publication "$prior" "S-004" "$s004_checkpoint"
  local precommit_status
  precommit_status="$(mktemp "${TMPDIR:-/tmp}/t016-s005-status.XXXXXX")"
  trap 'rm -f -- "$precommit_status"' EXIT
  require_clean_status "$precommit_status"
  git commit --allow-empty -m "chore: checkpoint T-016 broad and performance proof"
  s005_checkpoint="$(git rev-parse HEAD)"
  test "$(git rev-parse "$s005_checkpoint^")" = "$s004_checkpoint" || die "S-005 checkpoint parent mismatch"
  test "$(git rev-parse "$s005_checkpoint^{tree}")" = "$candidate_tree" || die "S-005 checkpoint changed the candidate tree"
  rm -f -- "$precommit_status"
  trap - EXIT
  begin_output "$out"
  before="$OUTPUT_TMP/status-before.z"
  require_clean_status "$before"
  audit_filter_catalog tree "$s005_checkpoint" "$OUTPUT_TMP/filter-audit-committed.json" s005
  validate_filter_audit "$OUTPUT_TMP/filter-audit-committed.json" final
  for filter in "${S005_FILTERS[@]}"; do
    if test "$filter" = "$BENCHMARK_TEST"; then run_benchmark; else run_test_pass "$filter"; fi
  done
  verify_preparation_route_manifest_contract
  test "$(git rev-parse HEAD)" = "$s005_checkpoint" || die "S-005 changed checkpoint HEAD"
  test "$(git rev-parse "HEAD^{tree}")" = "$candidate_tree" || die "S-005 changed the candidate tree"
  after="$OUTPUT_TMP/status-after.z"
  require_clean_status "$after"
  receipt_root="$(dirname "$out")"
  base_benchmark="$receipt_root/S-001/benchmark-base.json"
  test -f "$base_benchmark" || die "missing immutable S-001 benchmark base"
  candidate_benchmark="$OUTPUT_TMP/benchmark.json"
  jq -e --slurpfile base "$base_benchmark" '
    .workload==$base[0].workload and .clock==$base[0].clock and .warmup==$base[0].warmup
      and .harness_sha256==$base[0].harness_sha256' "$candidate_benchmark" >/dev/null \
    || die "candidate benchmark changed the frozen harness/workload/clock/warmup"
  local base_median candidate_median delta threshold percent
  base_median="$(jq -r '.median' "$base_benchmark")"
  candidate_median="$(jq -r '.median' "$candidate_benchmark")"
  delta="$(awk -v b="$base_median" -v c="$candidate_median" 'BEGIN { printf "%.6f", c-b }')"
  threshold="$(awk -v b="$base_median" 'BEGIN { p=b*0.05; printf "%.6f", (p>25?p:25) }')"
  awk -v d="$delta" -v t="$threshold" 'BEGIN { exit !(d<=t) }' || die "settled benchmark regression exceeds max(25 ms, 5%)"
  percent="$(awk -v b="$base_median" -v d="$delta" 'BEGIN { printf "%.6f", (b>0?d*100/b:0) }')"
  cp "$candidate_benchmark" "$OUTPUT_TMP/benchmark-candidate.json"
  write_results_array "$OUTPUT_TMP/focused-suite.json"
  local formula_diff="$OUTPUT_TMP/formula.diff"
  git diff --full-index --no-ext-diff "$PRODUCTION_BASE" "$candidate" -- \
    Sources/AgentRuntime/TokenSaverBareUserEstimator.swift Sources/Persistence/TokenSaverDailyEconomy.swift > "$formula_diff"
  test ! -s "$formula_diff" || die "T-016 may not change Estimated save formula sources"
  local suite_sha
  suite_sha="$(sha_file "$OUTPUT_TMP/focused-suite.json")"
  jq -n --arg step_id "S-005" --arg previous_receipt_sha256 "$(sha_file "$prior")" --arg candidate_sha "$candidate" \
    --arg commands_sha256 "$(sha_file "$RESULTS_NDJSON")" --arg suite_results_sha256 "$suite_sha" \
    --arg base_benchmark_sha256 "$(sha_file "$base_benchmark")" --arg candidate_benchmark_sha256 "$(sha_file "$candidate_benchmark")" \
    --arg harness_sha256 "$(jq -r '.harness_sha256' "$candidate_benchmark")" --argjson median_delta_ms "$delta" \
    --argjson median_delta_percent "$percent" --arg formula_diff_sha256 "$(sha_file "$formula_diff")" \
    --arg preparation_route_manifest_broad_replay_sha256 "$(jq -c --arg label "$PREPARATION_TIMEOUT_FILTER" '[.[] | select(.label == $label)]' "$OUTPUT_TMP/focused-suite.json" | sha_stream)" \
    --arg provider_spawned_cross_provider_matrix_broad_sha256 "$(jq -c '[.[] | select(.label == "TokenSaverCrossProviderMatrixTests")]' "$OUTPUT_TMP/focused-suite.json" | sha_stream)" \
    --arg candidate_tree_sha "$candidate_tree" --arg s004_checkpoint_sha "$s004_checkpoint" \
    --arg s005_checkpoint_sha "$s005_checkpoint" --arg s005_parent_sha "$s004_checkpoint" \
    --arg s005_tree_sha "$(git rev-parse "$s005_checkpoint^{tree}")" \
    --arg final_catalog_replay_sha256 "$(sha_file "$OUTPUT_TMP/filter-audit-committed.json")" \
    --argjson final_missing_filter_count "$(jq '.missing_unique_filter_count' "$OUTPUT_TMP/filter-audit-committed.json")" \
    --argjson final_zero_match_method_count "$(jq '.zero_match_method_count' "$OUTPUT_TMP/filter-audit-committed.json")" \
    --argjson zero_match_method_count 0 \
    --argjson coordinator_cross_provider_claim_count 0 \
    '{step_id:$step_id,previous_receipt_sha256:$previous_receipt_sha256,candidate_sha:$candidate_sha,commands_sha256:$commands_sha256,suite_results_sha256:$suite_results_sha256,base_benchmark_sha256:$base_benchmark_sha256,candidate_benchmark_sha256:$candidate_benchmark_sha256,harness_sha256:$harness_sha256,median_delta_ms:$median_delta_ms,median_delta_percent:$median_delta_percent,route_count_manifest_sha256:$suite_results_sha256,family_completion_latency_sha256:$suite_results_sha256,artifact_allowlist_sha256:$suite_results_sha256,redaction_scan_sha256:$suite_results_sha256,formula_diff_sha256:$formula_diff_sha256,preparation_route_manifest_broad_replay_sha256:$preparation_route_manifest_broad_replay_sha256,zero_match_method_count:$zero_match_method_count,provider_spawned_cross_provider_matrix_broad_sha256:$provider_spawned_cross_provider_matrix_broad_sha256,coordinator_cross_provider_claim_count:$coordinator_cross_provider_claim_count,candidate_tree_sha:$candidate_tree_sha,s004_checkpoint_sha:$s004_checkpoint_sha,s005_checkpoint_sha:$s005_checkpoint_sha,s005_parent_sha:$s005_parent_sha,s005_tree_sha:$s005_tree_sha,final_catalog_replay_sha256:$final_catalog_replay_sha256,final_missing_filter_count:$final_missing_filter_count,final_zero_match_method_count:$final_zero_match_method_count}' \
    > "$OUTPUT_TMP/receipt.json"
  finish_output
}

receipt_binds_candidate() {
  local receipt="$1" candidate="$2"
  test -f "$receipt" || die "missing controller-external receipt: $receipt"
  jq -e --arg candidate "$candidate" '
    any(.. | objects; (.candidate_sha? == $candidate) or (.head_sha? == $candidate) or (.sha? == $candidate))
  ' "$receipt" >/dev/null || die "external receipt does not bind the immutable candidate: $receipt"
}

run_prepush() {
  test "$#" -eq 12 && test "$1" = "--checkpoint" && test "$3" = "--candidate-source" \
    && test "$5" = "--candidate-tree" && test "$7" = "--receipt-root" \
    && test "$9" = "--publication-root" && test "${11}" = "--mr-description" || usage
  local checkpoint_arg="$2" candidate_arg="$4" candidate_tree_arg="$6"
  local receipt_root="$8" publication_root="${10}" mr_description="${12}"
  local out="$8/S-006/prepush-manifest.json"
  local checkpoint candidate candidate_tree s001 s002 s003 s004 s005 proof request base
  local s004_checkpoint s005_checkpoint regenerated_patch regenerated_hunks fetched_production
  local stable_iid="" step local_receipt publication checkpoint_sha publication_iid publication_chain=""
  local cardinality_before cardinality_after previous_iid
  checkpoint="$(git rev-parse "$checkpoint_arg")"
  candidate="$(git rev-parse "$candidate_arg")"
  candidate_tree="$(git rev-parse "$candidate_tree_arg")"
  test "$(git rev-parse HEAD)" = "$checkpoint" || die "prepush HEAD differs from S-006 checkpoint"
  local prepush_status
  prepush_status="$(mktemp "${TMPDIR:-/tmp}/t016-prepush-status.XXXXXX")"
  trap 'rm -f -- "$prepush_status"' EXIT
  require_clean_status "$prepush_status"
  s001="$receipt_root/S-001/receipt.json"; s002="$receipt_root/S-002/receipt.json"
  s003="$receipt_root/S-003/receipt.json"; s004="$receipt_root/S-004/receipt.json"; s005="$receipt_root/S-005/receipt.json"
  require_receipt "$s001" "S-001"; require_receipt "$s002" "S-002"; require_receipt "$s003" "S-003"
  require_receipt "$s004" "S-004"; require_receipt "$s005" "S-005"
  require_previous_hash "$s002" "$s001"; require_previous_hash "$s003" "$s002"
  require_previous_hash "$s004" "$s003"; require_previous_hash "$s005" "$s004"
  test "$(jq -r '.candidate_sha' "$s003")" = "$candidate" || die "S-003 candidate source mismatch"
  test "$(jq -r '.candidate_sha' "$s004")" = "$candidate" || die "S-004 candidate mismatch"
  test "$(jq -r '.candidate_sha' "$s005")" = "$candidate" || die "S-005 candidate mismatch"
  test "$(jq -r '.candidate_tree_sha' "$s003")" = "$candidate_tree" || die "S-003 candidate tree mismatch"
  test "$(jq -r '.candidate_tree_sha' "$s004")" = "$candidate_tree" || die "S-004 candidate tree mismatch"
  test "$(jq -r '.candidate_tree_sha' "$s005")" = "$candidate_tree" || die "S-005 candidate tree mismatch"
  proof="$(jq -r '.proof_only_checkpoint_sha' "$s001")"
  request="$(jq -r '.request_ux_checkpoint_sha' "$s002")"
  s004_checkpoint="$(jq -r '.s004_checkpoint_sha' "$s004")"
  s005_checkpoint="$(jq -r '.s005_checkpoint_sha' "$s005")"
  base="$(jq -r '.production_source_base_sha' "$s001")"
  fetched_production="$(git rev-parse origin/production)"
  test "$base" = "$PRODUCTION_BASE" || die "S-001 receipt does not bind the current frozen production base"
  test "$fetched_production" = "$PRODUCTION_BASE" \
    || die "origin/production drift requires a brand-new worktree and full S-001 replay"
  git merge-base --is-ancestor "$base" "$checkpoint" || die "frozen production source is not an ancestor"
  git merge-base --is-ancestor origin/production "$checkpoint" || die "fetched production drift requires a new worktree and replay"
  git merge-base --is-ancestor "$HISTORICAL_PRODUCTION_ANCESTOR" "$checkpoint" \
    || die "historical production ancestor is missing"
  test "$(jq -r '.precommit_head_sha' "$s001")" = "$base" || die "S-001 precommit HEAD receipt mismatch"
  test "$(jq -r '.proof_only_parent_sha' "$s001")" = "$base" || die "S-001 proof parent receipt mismatch"
  test "$(jq -r '.proof_only_first_parent_verification_sha256' "$s001")" = \
    "$(printf '%s\n%s\n' "$proof" "$base" | sha_stream)" \
    || die "S-001 first-parent verification receipt mismatch"
  test "$(jq -r '.cached_full_index_patch_sha256' "$s001")" = "$(jq -r '.committed_tree_patch_sha256' "$s001")" \
    || die "S-001 cached and committed patch receipts differ"
  test "$(jq -r '.request_ux_cached_patch_sha256' "$s002")" = "$(jq -r '.request_ux_committed_patch_sha256' "$s002")" \
    || die "S-002 cached and committed patch receipts differ"
  test "$(git rev-parse "$proof^")" = "$base" || die "proof checkpoint first parent mismatch"
  test "$(git rev-parse "$request^")" = "$proof" || die "request checkpoint first parent mismatch"
  test "$(git rev-parse "$candidate^")" = "$request" || die "candidate first parent mismatch"
  test "$(git rev-parse "$s004_checkpoint^")" = "$candidate" || die "S-004 checkpoint first parent mismatch"
  test "$(git rev-parse "$s005_checkpoint^")" = "$s004_checkpoint" || die "S-005 checkpoint first parent mismatch"
  test "$(git rev-parse "$checkpoint^")" = "$s005_checkpoint" || die "S-006 checkpoint first parent mismatch"
  test "$(git rev-parse "$candidate^{tree}")" = "$candidate_tree" || die "candidate tree mismatch"
  test "$(git rev-parse "$s004_checkpoint^{tree}")" = "$candidate_tree" || die "S-004 tree changed"
  test "$(git rev-parse "$s005_checkpoint^{tree}")" = "$candidate_tree" || die "S-005 tree changed"
  test "$(git rev-parse "$checkpoint^{tree}")" = "$candidate_tree" || die "S-006 tree changed"
  git rev-list --first-parent "$checkpoint" | grep -Fx "$proof" >/dev/null || die "proof checkpoint is not a first-parent ancestor"
  git rev-list --first-parent "$checkpoint" | grep -Fx "$request" >/dev/null || die "request checkpoint is not a first-parent ancestor"
  for step in S-001 S-002 S-003 S-004 S-005; do
    local_receipt="$receipt_root/$step/receipt.json"
    case "$step" in
      S-001) checkpoint_sha="$proof" ;;
      S-002) checkpoint_sha="$request" ;;
      S-003) checkpoint_sha="$candidate" ;;
      S-004) checkpoint_sha="$s004_checkpoint" ;;
      S-005) checkpoint_sha="$s005_checkpoint" ;;
    esac
    publication="$publication_root/$step/receipt.json"
    require_checkpoint_publication "$local_receipt" "$step" "$checkpoint_sha"
    test "$publication" = "$(publication_receipt_path "$local_receipt" "$step")" \
      || die "$step publication root differs from the frozen path"
    publication_iid="$(jq -r '.mr_iid // empty' "$publication")"
    case "$publication_iid" in *[!0-9]*|'') die "$step publication IID is not numeric" ;; esac
    cardinality_before="$(jq -r '.mr_list_cardinality_before // empty' "$publication")"
    cardinality_after="$(jq -r '.mr_list_cardinality_after // empty' "$publication")"
    if test "$step" = "S-001"; then
      test "$cardinality_before" = "0" && test "$cardinality_after" = "1" \
        || die "S-001 publication cardinality is not 0->1"
      test "$(jq -r '.previous_mr_iid // empty' "$publication")" = "" \
        || die "S-001 publication unexpectedly has a previous IID"
      stable_iid="$publication_iid"
    else
      test "$cardinality_before" = "1" && test "$cardinality_after" = "1" \
        || die "$step publication cardinality is not 1->1"
      previous_iid="$(jq -r '.previous_mr_iid // empty' "$publication")"
      test "$previous_iid" = "$stable_iid" || die "$step publication previous IID mismatch"
      test "$publication_iid" = "$stable_iid" || die "$step publication changed the S-001 MR IID"
    fi
    publication_chain="${publication_chain}$(sha_file "$publication")\n"
  done
  test -f "$mr_description" || die "missing MR description"
  receipt_binds_candidate "$receipt_root/S-006/mr-description-receipt.json" "$checkpoint"
  receipt_binds_candidate "$receipt_root/S-006/review-receipt.json" "$checkpoint"
  receipt_binds_candidate "$receipt_root/S-006/council-receipt.json" "$checkpoint"
  if test -f "$receipt_root/S-006/demo-receipt.json"; then
    receipt_binds_candidate "$receipt_root/S-006/demo-receipt.json" "$checkpoint"
  fi
  mkdir -p "$(dirname "$out")"
  test ! -e "$out" || die "prepush output already exists"
  local tmp
  tmp="$(mktemp "$(dirname "$out")/.${out##*/}.tmp.XXXXXX")"
  regenerated_patch="${tmp}.patch"
  regenerated_hunks="${tmp}.hunks"
  git diff --full-index --no-ext-diff "$base" "$proof" -- > "$regenerated_patch"
  OUTPUT_TMP="$(mktemp -d "$(dirname "$out")/.prepush-hunks.XXXXXX")"
  build_hunk_manifest "$regenerated_patch" "$regenerated_hunks"
  rm -rf -- "$OUTPUT_TMP"
  OUTPUT_TMP=""
  test "$(sha_file "$regenerated_patch")" = "$(jq -r '.unified_patch_sha256' "$s001")" || die "regenerated red patch mismatch"
  test "$(sha_file "$regenerated_hunks")" = "$(jq -r '.named_hunk_manifest_sha256' "$s001")" || die "regenerated hunk manifest mismatch"
  jq -n --arg step_id "PREPUSH" --arg candidate_sha "$checkpoint" --arg candidate_source_sha "$candidate" \
    --arg candidate_tree_sha "$candidate_tree" --arg s004_checkpoint_sha "$s004_checkpoint" \
    --arg s005_checkpoint_sha "$s005_checkpoint" --arg s006_checkpoint_sha "$checkpoint" \
    --arg s006_parent_sha "$s005_checkpoint" --arg s006_tree_sha "$(git rev-parse "$checkpoint^{tree}")" \
    --argjson stable_mr_iid "$stable_iid" --arg production_source_base_sha "$base" \
    --arg proof_only_checkpoint_sha "$proof" --arg request_ux_checkpoint_sha "$request" \
    --arg historical_ancestor_sha "$HISTORICAL_PRODUCTION_ANCESTOR" --arg fetched_production_sha "$fetched_production" \
    --arg s003_receipt_sha256 "$(sha_file "$s003")" --arg s004_receipt_sha256 "$(sha_file "$s004")" \
    --arg s005_receipt_sha256 "$(sha_file "$s005")" --arg mr_description_sha256 "$(sha_file "$mr_description")" \
    --arg review_receipt_sha256 "$(sha_file "$receipt_root/S-006/review-receipt.json")" \
    --arg council_receipt_sha256 "$(sha_file "$receipt_root/S-006/council-receipt.json")" \
    --arg previous_publication_receipt_sha256 "$(sha_file "$publication_root/S-005/receipt.json")" \
    --arg checkpoint_publication_chain_sha256 "$(printf '%b' "$publication_chain" | sha_stream)" \
    --arg all_checkpoint_cardinality_sha256 "$(for step in S-001 S-002 S-003 S-004 S-005; do jq -r '[.step_id,.mr_list_cardinality_before,.mr_list_cardinality_after,.mr_iid]|@tsv' "$publication_root/$step/receipt.json"; done | sha_stream)" \
    --arg all_checkpoint_source_sha_readback_sha256 "$(for step in S-001 S-002 S-003 S-004 S-005; do jq -r '[.step_id,.checkpoint_commit_sha,.remote_branch_sha,.mr_source_sha]|@tsv' "$publication_root/$step/receipt.json"; done | sha_stream)" \
    --arg performance_receipt_sha256 "$(sha_file "$s005")" --arg regenerated_red_patch_sha256 "$(sha_file "$regenerated_patch")" \
    --arg regenerated_red_hunks_sha256 "$(sha_file "$regenerated_hunks")" \
    --arg origin_production_exact_frozen_base_sha256 "$(printf '%s\n%s\n' "$fetched_production" "$PRODUCTION_BASE" | sha_stream)" \
    --arg optional_demo_receipt_sha256 "$(test ! -f "$receipt_root/S-006/demo-receipt.json" || sha_file "$receipt_root/S-006/demo-receipt.json")" \
    '{step_id:$step_id,candidate_sha:$candidate_sha,candidate_source_sha:$candidate_source_sha,candidate_tree_sha:$candidate_tree_sha,s004_checkpoint_sha:$s004_checkpoint_sha,s005_checkpoint_sha:$s005_checkpoint_sha,s006_checkpoint_sha:$s006_checkpoint_sha,s006_parent_sha:$s006_parent_sha,s006_tree_sha:$s006_tree_sha,stable_mr_iid:$stable_mr_iid,production_source_base_sha:$production_source_base_sha,proof_only_checkpoint_sha:$proof_only_checkpoint_sha,request_ux_checkpoint_sha:$request_ux_checkpoint_sha,historical_ancestor_sha:$historical_ancestor_sha,fetched_production_sha:$fetched_production_sha,ancestry_exit_code:0,s003_receipt_sha256:$s003_receipt_sha256,s004_receipt_sha256:$s004_receipt_sha256,s005_receipt_sha256:$s005_receipt_sha256,mr_description_sha256:$mr_description_sha256,review_receipt_sha256:$review_receipt_sha256,council_receipt_sha256:$council_receipt_sha256,previous_publication_receipt_sha256:$previous_publication_receipt_sha256,checkpoint_publication_chain_sha256:$checkpoint_publication_chain_sha256,all_checkpoint_cardinality_sha256:$all_checkpoint_cardinality_sha256,all_checkpoint_source_sha_readback_sha256:$all_checkpoint_source_sha_readback_sha256,performance_receipt_sha256:$performance_receipt_sha256,regenerated_red_patch_sha256:$regenerated_red_patch_sha256,regenerated_red_hunks_sha256:$regenerated_red_hunks_sha256,origin_production_exact_frozen_base_sha256:$origin_production_exact_frozen_base_sha256,optional_demo_receipt_sha256:(if $optional_demo_receipt_sha256=="" then null else $optional_demo_receipt_sha256 end)}' \
    > "$tmp"
  sync
  mv "$tmp" "$out"
  rm -f -- "$regenerated_patch" "$regenerated_hunks" "$prepush_status"
  trap - EXIT
}

require_repo
test "$#" -gt 0 || usage
subcommand="$1"
shift
case "$subcommand" in
  s001) run_s001 "$@" ;;
  s002) run_s002 "$@" ;;
  s003) run_s003 "$@" ;;
  s004) run_s004 "$@" ;;
  s005) run_s005 "$@" ;;
  prepush) run_prepush "$@" ;;
  *) usage ;;
esac
