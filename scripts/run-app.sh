#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run -c debug RemoteCode2
