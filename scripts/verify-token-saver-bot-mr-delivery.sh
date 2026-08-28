#!/usr/bin/env bash
set -euo pipefail

readonly PRODUCTION_BASE="5eef3d881c90c70183a7b570bcf5f6120d9b8ee6"

die() {
  echo "[token-saver-bot-mr-delivery] $*" >&2
  exit 2
}

usage() {
  echo "usage: $0 --checkpoint S-00N --expected-head SHA --expected-base SHA --source-branch BRANCH --target-branch production --title TITLE --description-file FILE [--expected-existing-iid IID] --out DIR" >&2
  exit 2
}

sha_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

checkpoint=""
expected_head=""
expected_base=""
source_branch=""
target_branch=""
title=""
description_file=""
expected_existing_iid=""
out=""

while test "$#" -gt 0; do
  test "$#" -ge 2 || usage
  case "$1" in
    --checkpoint) test -z "$checkpoint" || die "duplicate --checkpoint"; checkpoint="$2" ;;
    --expected-head) test -z "$expected_head" || die "duplicate --expected-head"; expected_head="$2" ;;
    --expected-base) test -z "$expected_base" || die "duplicate --expected-base"; expected_base="$2" ;;
    --source-branch) test -z "$source_branch" || die "duplicate --source-branch"; source_branch="$2" ;;
    --target-branch) test -z "$target_branch" || die "duplicate --target-branch"; target_branch="$2" ;;
    --title) test -z "$title" || die "duplicate --title"; title="$2" ;;
    --description-file) test -z "$description_file" || die "duplicate --description-file"; description_file="$2" ;;
    --expected-existing-iid) test -z "$expected_existing_iid" || die "duplicate --expected-existing-iid"; expected_existing_iid="$2" ;;
    --out) test -z "$out" || die "duplicate --out"; out="$2" ;;
    *) usage ;;
  esac
  shift 2
done

case "$checkpoint" in S-001|S-002|S-003|S-004|S-005|S-006) ;; *) usage ;; esac
test -n "$expected_head" || die "expected head is empty"
test "$expected_base" = "$PRODUCTION_BASE" || die "expected base differs from the frozen production source"
test -n "$source_branch" || die "source branch is empty"
test "$target_branch" = "production" || die "target branch must be production"
test -n "$title" || die "title is empty"
test -n "$out" || die "output directory is empty"
test -s "$description_file" || die "description file is missing or empty"
description="$(<"$description_file")"
test -n "$description" || die "description file resolves to empty content"
description_sha256="$(sha_file "$description_file")"

if test "$checkpoint" = "S-001"; then
  test -z "$expected_existing_iid" || die "S-001 must not accept an existing IID"
else
  case "$expected_existing_iid" in *[!0-9]*|'') die "$checkpoint requires a numeric --expected-existing-iid" ;; esac
fi

s006_prepush_manifest=""
if test "$checkpoint" = "S-006"; then
  plan_root="$(dirname "$(dirname "$out")")"
  s006_prepush_manifest="$plan_root/receipts/S-006/prepush-manifest.json"
  test -f "$s006_prepush_manifest" || die "S-006 requires its local prepush manifest"
  test "$(jq -r '.step_id // empty' "$s006_prepush_manifest")" = "PREPUSH" \
    || die "S-006 prepush manifest step mismatch"
  test "$(jq -r '.s006_checkpoint_sha // empty' "$s006_prepush_manifest")" = "$expected_head" \
    || die "S-006 prepush manifest checkpoint mismatch"
  test "$(jq -r '.stable_mr_iid // empty' "$s006_prepush_manifest")" = "$expected_existing_iid" \
    || die "S-006 prepush manifest stable IID mismatch"
fi

test "$(git rev-parse --show-toplevel)" = "$PWD" || die "run from the repository root"
test "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" \
  || die "linked isolated worktree required"
test "$(git rev-parse HEAD)" = "$expected_head" || die "HEAD differs from --expected-head"
test "$(git rev-parse origin/production)" = "$expected_base" \
  || die "origin/production drift requires a brand-new worktree and full replay"
status_file="$(mktemp "${TMPDIR:-/tmp}/t016-publication-status.XXXXXX")"
trap 'rm -f -- "$status_file"; test -z "${tmp:-}" || rm -rf -- "$tmp"' EXIT
git status --porcelain=v1 -z > "$status_file"
test ! -s "$status_file" || die "checkpoint worktree is not clean"

for tool in glab git jq shasum awk sed grep mktemp sync find; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

mkdir -p "$out"
for artifact in mr-list.json mr-state.json mr-selected.json mr-create.stdout mr-update.stdout \
  mr-readback.json branch-readback.json closure.json receipt.json; do
  test ! -e "$out/$artifact" || die "delivery artifact already exists: $out/$artifact"
done
tmp="$(mktemp -d "$(dirname "$out")/.${out##*/}.mr-delivery.XXXXXX")"

# Exactly one list snapshot and one jq -e decision happen before mutation.
glab mr list -F json -s "$source_branch" -t "$target_branch" > "$tmp/mr-list.raw.json"
jq -e \
  --arg checkpoint "$checkpoint" \
  --arg expected_iid "$expected_existing_iid" '
  if type != "array" then error("MR list response is not an array")
  elif $checkpoint == "S-001" and length == 0 then {cardinality:0,iid:null}
  elif $checkpoint != "S-001" and length == 1
    and (.[0].iid|type)=="number" and (.[0].iid|tostring)==$expected_iid
    then {cardinality:1,iid:.[0].iid}
  elif $checkpoint == "S-001" then error("S-001 requires zero matching merge requests")
  else error("checkpoint requires exactly one matching merge request with the frozen IID")
  end
' "$tmp/mr-list.raw.json" > "$tmp/mr-state.json"

cardinality_before="$(jq -r '.cardinality' "$tmp/mr-state.json")"
iid="$(jq -r '.iid // empty' "$tmp/mr-state.json")"
jq '[.[] | {iid,source_branch,target_branch,sha:(.sha // .diff_refs.head_sha // null),web_url:(.web_url // null),pipeline_state:(.head_pipeline.status // null)}]' \
  "$tmp/mr-list.raw.json" > "$tmp/mr-list.json"
sync
mv "$tmp/mr-list.json" "$out/mr-list.json"
mv "$tmp/mr-state.json" "$out/mr-state.json"

if test "$checkpoint" = "S-001"; then
  glab mr create \
    --source-branch "$source_branch" \
    --target-branch "$target_branch" \
    --title "$title" \
    --description "$description" \
    --yes > "$tmp/mr-create.raw.stdout"
  grep -Eo '/merge_requests/[0-9]+' "$tmp/mr-create.raw.stdout" \
    | sed 's#.*/##' > "$tmp/create-iids.txt" || true
  test "$(wc -l < "$tmp/create-iids.txt" | tr -d ' ')" -eq 1 \
    || die "create output must contain exactly one merge request IID URL"
  iid="$(sed -n '1p' "$tmp/create-iids.txt")"
  case "$iid" in *[!0-9]*|'') die "created IID is not numeric" ;; esac
  action="create"
  cardinality_after=1
else
  glab mr update "$iid" \
    --title "$title" \
    --description "$description" \
    --yes > "$tmp/mr-update.raw.stdout"
  action="update"
  cardinality_after=1
fi

jq -n \
  --arg checkpoint "$checkpoint" \
  --argjson snapshot_cardinality "$cardinality_before" \
  --argjson cardinality_after "$cardinality_after" \
  --argjson iid "$iid" \
  --arg source_branch "$source_branch" \
  --arg action "$action" \
  '{checkpoint:$checkpoint,snapshot_cardinality:$snapshot_cardinality,cardinality_after:$cardinality_after,iid:$iid,source_branch:$source_branch,action:$action}' \
  > "$tmp/mr-selected.json"

glab mr view "$iid" -F json > "$tmp/mr-readback.raw.json"
encoded_branch="$(jq -rn --arg value "$source_branch" '$value|@uri')"
test -n "$encoded_branch" || die "source branch URL encoding failed"
glab api "projects/:id/repository/branches/$encoded_branch" > "$tmp/branch-readback.raw.json"

read_iid="$(jq -r '.iid // empty' "$tmp/mr-readback.raw.json")"
read_source="$(jq -r '.source_branch // empty' "$tmp/mr-readback.raw.json")"
read_target="$(jq -r '.target_branch // empty' "$tmp/mr-readback.raw.json")"
read_sha="$(jq -r '.sha // .diff_refs.head_sha // empty' "$tmp/mr-readback.raw.json")"
read_url="$(jq -r '.web_url // empty' "$tmp/mr-readback.raw.json")"
read_title="$(jq -r '.title // empty' "$tmp/mr-readback.raw.json")"
read_description="$(jq -r '.description // empty' "$tmp/mr-readback.raw.json")"
pipeline_state="$(jq -r '.head_pipeline.status // "none"' "$tmp/mr-readback.raw.json")"
branch_name="$(jq -r '.name // empty' "$tmp/branch-readback.raw.json")"
branch_sha="$(jq -r '.commit.id // empty' "$tmp/branch-readback.raw.json")"

test "$read_iid" = "$iid" || die "MR IID readback mismatch"
test "$read_source" = "$source_branch" || die "MR source branch readback mismatch"
test "$read_target" = "$target_branch" || die "MR target branch readback mismatch"
test "$read_sha" = "$expected_head" || die "MR source SHA differs from the checkpoint"
test "$read_title" = "$title" || die "MR title readback mismatch"
test "$read_description" = "$description" || die "MR description readback mismatch"
test "$branch_name" = "$source_branch" || die "encoded branch readback name mismatch"
test "$branch_sha" = "$expected_head" || die "remote branch SHA differs from the checkpoint"
test -n "$read_url" || die "MR readback lacks its URL"

jq -n --argjson iid "$iid" --arg web_url "$read_url" --arg source_branch "$read_source" \
  --arg target_branch "$read_target" --arg source_sha "$read_sha" --arg title "$read_title" \
  --arg description_sha256 "$description_sha256" --arg pipeline_state "$pipeline_state" \
  '{iid:$iid,web_url:$web_url,source_branch:$source_branch,target_branch:$target_branch,source_sha:$source_sha,title:$title,description_sha256:$description_sha256,pipeline_state:$pipeline_state}' \
  > "$tmp/mr-readback.json"
jq -n --arg name "$branch_name" --arg sha "$branch_sha" '{name:$name,sha:$sha}' \
  > "$tmp/branch-readback.json"
jq -n \
  --arg checkpoint "$checkpoint" --arg expected_head "$expected_head" --arg expected_base "$expected_base" \
  --argjson iid "$iid" --arg mr_url "$read_url" --arg source_branch "$read_source" \
  --arg source_sha "$read_sha" --arg target_branch "$read_target" --arg remote_branch_sha "$branch_sha" \
  --arg pipeline_state "$pipeline_state" \
  '{checkpoint:$checkpoint,expected_head:$expected_head,expected_base:$expected_base,mr_iid:$iid,mr_url:$mr_url,mr_source_branch:$source_branch,mr_source_sha:$source_sha,mr_target_branch:$target_branch,remote_branch_sha:$remote_branch_sha,mr_pipeline_state:$pipeline_state}' \
  > "$tmp/closure.json"

checkpoint_tree_sha="$(git rev-parse "$expected_head^{tree}")"
glab_version="$(glab version | sed -n '1p')"
s006_previous_publication_receipt_sha256=""
s006_local_prepush_manifest_sha256=""
s006_review_receipt_sha256=""
s006_council_receipt_sha256=""
s006_optional_demo_receipt_sha256=""
s006_origin_production_exact_frozen_base_sha256=""
s006_candidate_source_sha=""
s006_candidate_tree_sha=""
s006_s004_checkpoint_sha=""
s006_s005_checkpoint_sha=""
s006_parent_sha=""
s006_tree_sha=""
s006_checkpoint_publication_chain_sha256=""
s006_all_checkpoint_cardinality_sha256=""
s006_all_checkpoint_source_sha_readback_sha256=""
if test "$checkpoint" = "S-006"; then
  s006_previous_publication_receipt_sha256="$(jq -r '.previous_publication_receipt_sha256' "$s006_prepush_manifest")"
  s006_local_prepush_manifest_sha256="$(sha_file "$s006_prepush_manifest")"
  s006_review_receipt_sha256="$(jq -r '.review_receipt_sha256' "$s006_prepush_manifest")"
  s006_council_receipt_sha256="$(jq -r '.council_receipt_sha256' "$s006_prepush_manifest")"
  s006_optional_demo_receipt_sha256="$(jq -r '.optional_demo_receipt_sha256 // empty' "$s006_prepush_manifest")"
  s006_origin_production_exact_frozen_base_sha256="$(jq -r '.origin_production_exact_frozen_base_sha256' "$s006_prepush_manifest")"
  s006_candidate_source_sha="$(jq -r '.candidate_source_sha' "$s006_prepush_manifest")"
  s006_candidate_tree_sha="$(jq -r '.candidate_tree_sha' "$s006_prepush_manifest")"
  s006_s004_checkpoint_sha="$(jq -r '.s004_checkpoint_sha' "$s006_prepush_manifest")"
  s006_s005_checkpoint_sha="$(jq -r '.s005_checkpoint_sha' "$s006_prepush_manifest")"
  s006_parent_sha="$(jq -r '.s006_parent_sha' "$s006_prepush_manifest")"
  s006_tree_sha="$(jq -r '.s006_tree_sha' "$s006_prepush_manifest")"
  s006_checkpoint_publication_chain_sha256="$(jq -r '.checkpoint_publication_chain_sha256' "$s006_prepush_manifest")"
  s006_all_checkpoint_cardinality_sha256="$(jq -r '.all_checkpoint_cardinality_sha256' "$s006_prepush_manifest")"
  s006_all_checkpoint_source_sha_readback_sha256="$(jq -r '.all_checkpoint_source_sha_readback_sha256' "$s006_prepush_manifest")"
fi
jq -n \
  --arg step_id "$checkpoint" --arg checkpoint "$checkpoint" \
  --arg checkpoint_commit_sha "$expected_head" --arg checkpoint_tree_sha "$checkpoint_tree_sha" \
  --arg production_source_base_sha "$expected_base" --arg fetched_production_sha_before_push "$expected_base" \
  --arg source_branch "$source_branch" --arg target_branch "$target_branch" \
  --argjson mr_list_cardinality_before "$cardinality_before" --argjson mr_list_cardinality_after "$cardinality_after" \
  --argjson mr_iid "$iid" --arg previous_mr_iid "$expected_existing_iid" \
  --arg mr_url "$read_url" --arg mr_source_sha "$read_sha" --arg mr_target_branch "$read_target" \
  --arg remote_branch_sha "$branch_sha" --arg mr_pipeline_state "$pipeline_state" \
  --arg mr_list_snapshot_sha256 "$(sha_file "$out/mr-list.json")" \
  --arg mr_readback_sha256 "$(sha_file "$tmp/mr-readback.json")" \
  --arg branch_readback_sha256 "$(sha_file "$tmp/branch-readback.json")" \
  --arg description_sha256 "$description_sha256" --arg glab_version "$glab_version" \
  --arg previous_publication_receipt_sha256 "$s006_previous_publication_receipt_sha256" \
  --arg s006_local_prepush_manifest_sha256 "$s006_local_prepush_manifest_sha256" \
  --arg review_receipt_sha256 "$s006_review_receipt_sha256" --arg council_receipt_sha256 "$s006_council_receipt_sha256" \
  --arg optional_demo_receipt_sha256 "$s006_optional_demo_receipt_sha256" \
  --arg origin_production_exact_frozen_base_sha256 "$s006_origin_production_exact_frozen_base_sha256" \
  --arg candidate_source_sha "$s006_candidate_source_sha" --arg candidate_tree_sha "$s006_candidate_tree_sha" \
  --arg s004_checkpoint_sha "$s006_s004_checkpoint_sha" --arg s005_checkpoint_sha "$s006_s005_checkpoint_sha" \
  --arg s006_checkpoint_sha "$expected_head" --arg s006_parent_sha "$s006_parent_sha" --arg s006_tree_sha "$s006_tree_sha" \
  --arg stable_mr_iid "$expected_existing_iid" \
  --arg checkpoint_publication_chain_sha256 "$s006_checkpoint_publication_chain_sha256" \
  --arg all_checkpoint_cardinality_sha256 "$s006_all_checkpoint_cardinality_sha256" \
  --arg all_checkpoint_source_sha_readback_sha256 "$s006_all_checkpoint_source_sha_readback_sha256" \
  '{step_id:$step_id,checkpoint:$checkpoint,checkpoint_commit_sha:$checkpoint_commit_sha,checkpoint_tree_sha:$checkpoint_tree_sha,production_source_base_sha:$production_source_base_sha,fetched_production_sha_before_push:$fetched_production_sha_before_push,fetched_production_sha:$fetched_production_sha_before_push,source_branch:$source_branch,target_branch:$target_branch,remote_branch_sha:$remote_branch_sha,mr_list_cardinality_before:$mr_list_cardinality_before,mr_list_cardinality_after:$mr_list_cardinality_after,mr_list_cardinality:$mr_list_cardinality_after,mr_iid:$mr_iid,previous_mr_iid:(if $previous_mr_iid=="" then null else ($previous_mr_iid|tonumber) end),mr_url:$mr_url,mr_source_branch:$source_branch,mr_source_sha:$mr_source_sha,mr_target_branch:$mr_target_branch,mr_pipeline_state:$mr_pipeline_state,mr_list_snapshot_sha256:$mr_list_snapshot_sha256,mr_readback_sha256:$mr_readback_sha256,mr_update_readback_sha256:$mr_readback_sha256,branch_readback_sha256:$branch_readback_sha256,description_sha256:$description_sha256,glab_version:$glab_version,previous_publication_receipt_sha256:(if $previous_publication_receipt_sha256=="" then null else $previous_publication_receipt_sha256 end),s006_local_prepush_manifest_sha256:(if $s006_local_prepush_manifest_sha256=="" then null else $s006_local_prepush_manifest_sha256 end),review_receipt_sha256:(if $review_receipt_sha256=="" then null else $review_receipt_sha256 end),council_receipt_sha256:(if $council_receipt_sha256=="" then null else $council_receipt_sha256 end),optional_demo_receipt_sha256:(if $optional_demo_receipt_sha256=="" then null else $optional_demo_receipt_sha256 end),origin_production_exact_frozen_base_sha256:(if $origin_production_exact_frozen_base_sha256=="" then null else $origin_production_exact_frozen_base_sha256 end),candidate_source_sha:(if $candidate_source_sha=="" then null else $candidate_source_sha end),candidate_tree_sha:(if $candidate_tree_sha=="" then null else $candidate_tree_sha end),s004_checkpoint_sha:(if $s004_checkpoint_sha=="" then null else $s004_checkpoint_sha end),s005_checkpoint_sha:(if $s005_checkpoint_sha=="" then null else $s005_checkpoint_sha end),s006_checkpoint_sha:(if $checkpoint=="S-006" then $s006_checkpoint_sha else null end),s006_parent_sha:(if $s006_parent_sha=="" then null else $s006_parent_sha end),s006_tree_sha:(if $s006_tree_sha=="" then null else $s006_tree_sha end),stable_mr_iid:(if $stable_mr_iid=="" then null else ($stable_mr_iid|tonumber) end),checkpoint_publication_chain_sha256:(if $checkpoint_publication_chain_sha256=="" then null else $checkpoint_publication_chain_sha256 end),all_checkpoint_cardinality_sha256:(if $all_checkpoint_cardinality_sha256=="" then null else $all_checkpoint_cardinality_sha256 end),all_checkpoint_source_sha_readback_sha256:(if $all_checkpoint_source_sha_readback_sha256=="" then null else $all_checkpoint_source_sha_readback_sha256 end)}' \
  > "$tmp/receipt.json"

sync
for artifact in mr-selected.json mr-readback.json branch-readback.json closure.json; do
  mv "$tmp/$artifact" "$out/$artifact"
done
if test -f "$tmp/mr-create.raw.stdout"; then
  printf '%s\n' "created MR IID $iid" > "$out/mr-create.stdout"
fi
if test -f "$tmp/mr-update.raw.stdout"; then
  printf '%s\n' "updated MR IID $iid" > "$out/mr-update.stdout"
fi
mv "$tmp/receipt.json" "$out/receipt.json"
trap - EXIT
rm -f -- "$status_file"
rm -rf -- "$tmp"
