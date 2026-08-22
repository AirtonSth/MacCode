#!/usr/bin/env bash
# Single-flight guard for macOS Harness / bounded UI automation.
# The lock is shared across worktrees because CGEvent posting is host-global.
set -euo pipefail

lease_root="${RC_MACOS_UI_LEASE_DIR:-/tmp/remotecode-macos-ui-lease.lock}"
lease_dir="$lease_root/owner"
allow_input=0

usage() {
  cat >&2 <<'EOF'
usage: scripts/macos-ui-lease.sh [--allow-input] -- command [args...]

Runs one bounded UI harness command under a host-wide single-flight lease.
Input-posting code is rejected unless --allow-input is explicit.
EOF
}

command=()
while (($#)); do
  case "$1" in
    --allow-input)
      allow_input=1
      shift
      ;;
    --)
      shift
      command=("$@")
      break
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

((${#command[@]} > 0)) || { usage; exit 64; }

input_pattern='mac\.(key|type|click|drag|scroll|move|script)|mac\.ax\.perform|sky\.(click|type_text|press_key|drag|scroll|set_value)'
if ((allow_input == 0)) && printf '%s\n' "${command[@]}" | rg -n -q "$input_pattern"; then
  echo "macOS UI lease: input action requires explicit --allow-input" >&2
  exit 64
fi

if [[ "${command[0]}" == "macos-harness" && "${command[1]:-}" == "repl" ]]; then
  echo "macOS UI lease: persistent repl sessions are not allowed; use one bounded command" >&2
  exit 64
fi

mkdir -p "$lease_root"
if ! mkdir "$lease_dir" 2>/dev/null; then
  owner_pid=""
  if [[ -r "$lease_dir/pid" ]]; then
    owner_pid="$(<"$lease_dir/pid")"
  fi
  echo "macOS UI lease: busy pid=${owner_pid:-unknown} (shared lock $lease_root)" >&2
  exit 75
fi

cleanup() {
  rm -rf "$lease_dir"
}
trap cleanup EXIT INT TERM

printf '%s\n' "$$" > "$lease_dir/pid"
printf '%s\n' "$(date -u +%FT%TZ)" > "$lease_dir/started_at"
printf '%s\n' "${PWD}" > "$lease_dir/cwd"
printf '%s\n' "$allow_input" > "$lease_dir/input_allowed"
printf '%s\n' "${command[*]}" > "$lease_dir/command"

input_file=""
if [[ ! -t 0 ]]; then
  input_file="$(mktemp "${TMPDIR:-/tmp}/remotecode-macos-ui-input.XXXXXX")"
  trap 'rm -f "$input_file"; cleanup' EXIT INT TERM
  cat > "$input_file"
  if ((allow_input == 0)) && rg -n -q "$input_pattern" "$input_file"; then
    echo "macOS UI lease: input action requires explicit --allow-input" >&2
    exit 64
  fi
fi

export RC_MACOS_UI_INPUT_LEASE="$allow_input"
export RC_MACOS_UI_ALLOW_INPUT="$allow_input"
if [[ -n "$input_file" ]]; then
  command "${command[@]}" < "$input_file"
else
  command "${command[@]}"
fi
