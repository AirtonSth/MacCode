#!/usr/bin/env bash
# Isolated macOS sandbox for agent build/test/run.
# Source of truth for identity: debug bundle, own App Support, HTTP 18218.
# Never quits io.remotecode.desktop and never pkill -x RemoteCode.
set -euo pipefail

STABLE_BUNDLE_ID="io.remotecode.desktop"
BUNDLE_ID="${RC2_SANDBOX_BUNDLE_ID:-io.remotecode.desktop.debug}"
CHANNEL="${RC2_SANDBOX_CHANNEL:-debug}"
HTTP_PORT="${RC2_SANDBOX_HTTP_PORT:-18218}"
CONFIG="${RC2_CONFIG:-debug}"

die() {
  echo "[sandbox] $*" >&2
  exit 2
}

usage() {
  cat <<'EOF' >&2
usage: scripts/isolated-sandbox.sh <command>

  identity   print sandbox identity (KEY=value)
  status     identity plus primary/cwd/worktree
  ensure     create (or reuse) a linked git worktree; print its path
  test       swift test in the current linked worktree
  build      package dist/RemoteCodeDebug.app with debug identity
  run        build and launch only the debug app
  stop       stop only this worktree's debug executable

Environment:
  RC2_SANDBOX_BUNDLE_ID   default io.remotecode.desktop.debug
  RC2_SANDBOX_CHANNEL     default debug
  RC2_SANDBOX_HTTP_PORT   default 18218
  RC2_SANDBOX_REF         git ref for ensure (default HEAD)
  RC2_SANDBOX_HOME        debug process home (default <worktree>/.sandbox-state/home)
  RC2_SANDBOX_ALLOW_PRIMARY=1  allow test/build/run in the primary checkout
  RC2_SANDBOX_FETCH=1     fetch origin production before ensure

SwiftPM tests also receive a sandbox-private CFFIXED_USER_HOME beneath App
Support and bypass cfprefsd so UserDefaults.standard cannot collide with
another worktree.
EOF
  exit 2
}

[ "${1:-}" != "" ] || usage
COMMAND="$1"
shift

if [ "$BUNDLE_ID" = "$STABLE_BUNDLE_ID" ]; then
  die "refusing bundle id $BUNDLE_ID (would share identity with the user's host app)"
fi
[ "$CHANNEL" != "stable" ] || die "refusing RC2_SANDBOX_CHANNEL=stable"

require_git() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"
}

repo_root() {
  git rev-parse --show-toplevel
}

abs_git_dir() {
  (cd "$(git rev-parse --absolute-git-dir)" && pwd -P)
}

abs_git_common_dir() {
  (cd "$(git rev-parse --git-common-dir)" && pwd -P)
}

is_linked_worktree() {
  [ "$(abs_git_dir)" != "$(abs_git_common_dir)" ]
}

primary_worktree() {
  git worktree list --porcelain | awk '/^worktree / { print $2; exit }'
}

ensure_developer_dir() {
  if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
}

app_path() {
  echo "$(repo_root)/dist/RemoteCodeDebug.app"
}

app_support_dir() {
  echo "${RC2_SANDBOX_APP_SUPPORT:-$(repo_root)/.sandbox-state/Application Support/RemoteCodeDebug}"
}

sandbox_home_dir() {
  echo "${RC2_SANDBOX_HOME:-$(repo_root)/.sandbox-state/home}"
}

test_user_home_dir() {
  echo "$(app_support_dir)/TestUserHome"
}

app_executable() {
  echo "$(app_path)/Contents/MacOS/RemoteCode"
}

script_dir() {
  cd "$(dirname "$0")" && pwd -P
}

exact_pids() {
  local executable="$1"
  local awk_file
  awk_file="$(script_dir)/exact-executable-pids.awk"
  [ -f "$awk_file" ] || die "missing $awk_file"
  [ -e "$executable" ] || return 0
  local abs_exec
  abs_exec="$(cd "$(dirname "$executable")" && pwd -P)/$(basename "$executable")"
  ps -axo pid=,command= | awk -v executable="$abs_exec" -f "$awk_file"
}

require_product_tree() {
  [ -f "$(repo_root)/Package.swift" ] || die "Package.swift not found in $(repo_root)"
  [ -x "$(repo_root)/scripts/package-app.sh" ] || die "scripts/package-app.sh missing"
}

require_sandbox_tree() {
  require_git
  if is_linked_worktree; then
    return 0
  fi
  if [ "${RC2_SANDBOX_ALLOW_PRIMARY:-0}" = "1" ]; then
    echo "[sandbox] RC2_SANDBOX_ALLOW_PRIMARY=1: using primary checkout $(repo_root)" >&2
    return 0
  fi
  die "refusing $COMMAND in the primary checkout $(repo_root). Run: cd \"\$(scripts/isolated-sandbox.sh ensure)\"  (set RC2_SANDBOX_ALLOW_PRIMARY=1 only for a dedicated clone)"
}

# Vendor .a archives are LFS-tracked build inputs. This repo's local git config
# installs LFS with --skip-smudge, so every checkout (git worktree add included)
# writes the 133-byte pointer file instead of the archive and the build fails.
lfs_pointer_paths() {
  local target="$1" path tracked
  command -v git-lfs >/dev/null 2>&1 || return 0
  tracked="$(git -C "$target" lfs ls-files -n 2>/dev/null || true)"
  [ -n "$tracked" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -f "$target/$path" ] || continue
    if head -c 64 "$target/$path" 2>/dev/null | grep -q "git-lfs.github.com/spec"; then
      printf '%s\n' "$path"
    fi
  done <<<"$tracked"
}

materialize_lfs() {
  local target="$1" pointers
  pointers="$(lfs_pointer_paths "$target")"
  [ -n "$pointers" ] || return 0
  echo "[sandbox] materializing $(printf '%s\n' "$pointers" | wc -l | tr -d ' ') LFS pointer file(s) in $target" >&2
  git -C "$target" lfs fetch --all >&2
  git -C "$target" lfs checkout >&2
  pointers="$(lfs_pointer_paths "$target")"
  [ -z "$pointers" ] || die "LFS objects still missing after fetch/checkout: $(printf '%s' "$pointers" | tr '\n' ' ')"
  echo "[sandbox] LFS artifacts ready" >&2
}

print_identity() {
  require_git
  cat <<EOF
bundle_id=$BUNDLE_ID
channel=$CHANNEL
http_port=$HTTP_PORT
config=$CONFIG
cwd=$(pwd -P)
repo_root=$(repo_root)
primary_worktree=$(primary_worktree)
linked_worktree=$(is_linked_worktree && echo yes || echo no)
app_path=$(app_path)
app_support=$(app_support_dir)
sandbox_home=$(sandbox_home_dir)
test_user_home=$(test_user_home_dir)
stable_bundle_id=$STABLE_BUNDLE_ID
EOF
}

cmd_ensure() {
  require_git
  local root
  root="$(repo_root)"
  if is_linked_worktree; then
    echo "[sandbox] already in linked worktree" >&2
    materialize_lfs "$(pwd -P)"
    pwd -P
    return 0
  fi
  if [ "${RC2_SANDBOX_FETCH:-0}" = "1" ]; then
    git fetch origin production
  fi
  local ref="${RC2_SANDBOX_REF:-HEAD}"
  git rev-parse --verify "$ref" >/dev/null 2>&1 || die "ref not found: $ref"
  local stamp branch wt
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  branch="sandbox/isolated-${stamp}"
  wt="${RC2_SANDBOX_WORKTREE:-$root/.sandbox-worktrees/$stamp}"
  mkdir -p "$(dirname "$wt")"
  git worktree add -b "$branch" "$wt" "$ref" >&2
  echo "[sandbox] created $wt from $ref on $branch" >&2
  echo "[sandbox] edit/test/run only inside this path" >&2
  materialize_lfs "$wt"
  (cd "$wt" && pwd -P)
}

cmd_test() {
  require_sandbox_tree
  require_product_tree
  ensure_developer_dir
  local root support test_user_home
  root="$(repo_root)"
  materialize_lfs "$root"
  support="$(app_support_dir)"
  test_user_home="$(test_user_home_dir)"
  mkdir -p "$support" "$test_user_home/Library/Preferences"
  cd "$root"
  export CFFIXED_USER_HOME="$test_user_home"
  export __CFPREFERENCES_AVOID_DAEMON=1
  export RC2_BUNDLE_ID="$BUNDLE_ID"
  export RC2_CHANNEL="$CHANNEL"
  export RC2_HTTP_PORT="$HTTP_PORT"
  export RC2_APP_SUPPORT="$support"
  export RC2_DB_PATH="$support/remotecode.sqlite"
  if [ "$#" -eq 0 ]; then
    exec ./scripts/test-unit.sh
  fi
  exec swift test "$@"
}

cmd_build() {
  require_sandbox_tree
  require_product_tree
  ensure_developer_dir
  local root output
  root="$(repo_root)"
  materialize_lfs "$root"
  output="$(app_path)"
  cd "$root"
  RC2_BUNDLE_ID="$BUNDLE_ID" \
    RC2_CHANNEL="$CHANNEL" \
    RC2_CONFIG="$CONFIG" \
    RC2_PACKAGE_APP_OUTPUT="$output" \
    RC2_REPLACE_RUNNING_APP=1 \
    ./scripts/package-app.sh
  echo "[sandbox] packaged $output" >&2
  echo "[sandbox] bundle $BUNDLE_ID channel $CHANNEL port $HTTP_PORT" >&2
}

cmd_stop() {
  require_git
  local executable pid
  executable="$(app_executable)"
  for pid in $(exact_pids "$executable"); do
    kill "$pid" 2>/dev/null || true
  done
  # The app holds a single-instance lock on its App Support until it exits;
  # wait (bounded) so an immediate relaunch is not refused as a second instance.
  for _ in $(seq 1 50); do
    [ -z "$(exact_pids "$executable")" ] && break
    sleep 0.1
  done
  echo "[sandbox] stopped $executable"
}

cmd_run() {
  cmd_build
  local executable support home log pid
  executable="$(app_executable)"
  [ -x "$executable" ] || die "missing executable $executable"
  support="$(app_support_dir)"
  home="$(sandbox_home_dir)"
  mkdir -p "$support" "$home/.codex" "$home/.claude" "$home/.grok" "$(repo_root)/.sandbox-state"
  log="$(repo_root)/.sandbox-state/RemoteCodeDebug.log"
  cmd_stop >/dev/null
  HOME="$home" \
    CFFIXED_USER_HOME="$home" \
    CODEX_HOME="$home/.codex" \
    RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1 \
  RC2_CHANNEL="$CHANNEL" \
    RC2_HTTP_PORT="$HTTP_PORT" \
    RC2_APP_SUPPORT="$support" \
    RC2_DB_PATH="$support/remotecode.sqlite" \
    nohup "$executable" >>"$log" 2>&1 &
  pid=$!
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    die "debug app exited immediately; see $log"
  fi
  echo "[sandbox] running pid $pid"
  echo "[sandbox] executable $executable"
  echo "[sandbox] app-support $support"
  echo "[sandbox] home $home"
  echo "[sandbox] http-port $HTTP_PORT"
  echo "[sandbox] log $log"
}

case "$COMMAND" in
  identity) print_identity ;;
  status) print_identity ;;
  ensure) cmd_ensure ;;
  worktree) cmd_ensure ;;
  test) cmd_test "$@" ;;
  build) cmd_build ;;
  run) cmd_run ;;
  stop) cmd_stop ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
