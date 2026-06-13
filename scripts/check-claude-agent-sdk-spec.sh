#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/Sources/AgentRuntime/ClaudeAgentSDKBridgeAdapter.swift"

spec="$(sed -n 's/.*defaultSDKPackageSpec = "\([^"]*\)".*/\1/p' "$source_file" | head -n 1)"
if [[ -z "$spec" ]]; then
  echo "FAIL: defaultSDKPackageSpec not found in $source_file" >&2
  exit 1
fi

package="${spec%@*}"
pinned_version="${spec##*@}"
if [[ -z "$package" || "$package" == "$spec" || -z "$pinned_version" ]]; then
  echo "FAIL: unsupported npm package spec: $spec" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pushd "$tmpdir" >/dev/null
npm init -y >/dev/null
npm install --ignore-scripts --no-audit --no-fund "$spec" >/dev/null
popd >/dev/null

latest_version="$(npm view "$package" version)"
pinned_major="${pinned_version%%.*}"
latest_major="${latest_version%%.*}"

echo "PASS: installed $spec"
echo "INFO: latest $package version is $latest_version"

if [[ "$latest_major" =~ ^[0-9]+$ && "$pinned_major" =~ ^[0-9]+$ && "$latest_major" -gt "$pinned_major" ]]; then
  echo "::warning title=Claude Agent SDK major available::$package pinned at $pinned_version; latest is $latest_version"
fi
