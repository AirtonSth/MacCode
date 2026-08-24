#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RC_TOKEN_SAVER_ROUND2_PROFILE="envelope-slashes-v1"
exec "${script_dir}/token-saver-round2-benchmark.sh" "$@"
