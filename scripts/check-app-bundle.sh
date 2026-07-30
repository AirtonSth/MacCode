#!/usr/bin/env bash
# QA-mac:71 -- structural validation of a packaged RemoteCode.app bundle (T026).
#
# WHY: package-app.sh runs `codesign --verify` only when a human packages locally,
# so a malformed bundle (9-byte PkgInfo, missing executable, invalid Info.plist,
# CFBundleExecutable not matching the binary) can ship from CI unnoticed. This
# asserts the structural invariants that must hold for the bundle to launch and be
# discoverable, independent of codesigning.
#
# Usage: check-app-bundle.sh /path/to/RemoteCode.app
# Exit 0 = all structural checks pass; exit 1 = at least one failed.
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "FAIL: app bundle path missing or not a directory: '$APP'" >&2
  exit 1
fi

PLIST="$APP/Contents/Info.plist"
PKGINFO="$APP/Contents/PkgInfo"
fails=0
note() { echo "  - $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
json_lint() {
  swift -e 'import Foundation; let url = URL(fileURLWithPath: CommandLine.arguments[1]); _ = try JSONSerialization.jsonObject(with: Data(contentsOf: url))' "$1" >/dev/null 2>&1
}
pet_manifest_contract() {
  swift - "$1" >/dev/null 2>&1 <<'SWIFT'
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
      object["schemaVersion"] as? Int == 3,
      let dimensions = object["dimensions"] as? [String: Any],
      dimensions["width"] as? Int == 1_536,
      dimensions["height"] as? Int == 7_072,
      let grid = object["grid"] as? [String: Any],
      grid["columns"] as? Int == 8,
      grid["rows"] as? Int == 34,
      grid["frameWidth"] as? Int == 192,
      grid["frameHeight"] as? Int == 208,
      let rows = object["rows"] as? [[String: Any]],
      rows.count == 34,
      rows.allSatisfy({ $0["frames"] as? Int == 8 }),
      Set(rows.compactMap { $0["state"] as? String }).count == 34 else {
    exit(1)
}
SWIFT
}

# 1. Info.plist exists and is valid.
if [ ! -f "$PLIST" ]; then
  fail "missing Info.plist at $PLIST"
elif ! plutil -lint "$PLIST" >/dev/null; then
  fail "Info.plist failed plutil -lint"
else
  note "Info.plist present and lint-clean"
fi

# Helper: read a top-level Info.plist string key (empty if absent).
plist_get() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || true; }

# 2. Package type must be APPL.
PKGTYPE="$(plist_get CFBundlePackageType)"
[ "$PKGTYPE" = "APPL" ] && note "CFBundlePackageType=APPL" || fail "CFBundlePackageType must be APPL (got '$PKGTYPE')"

# 3. CFBundleExecutable must name a real Mach-O executable under Contents/MacOS.
EXEC_NAME="$(plist_get CFBundleExecutable)"
if [ -z "$EXEC_NAME" ]; then
  fail "CFBundleExecutable is empty"
else
  EXEC_PATH="$APP/Contents/MacOS/$EXEC_NAME"
  if [ ! -f "$EXEC_PATH" ]; then
    fail "CFBundleExecutable '$EXEC_NAME' has no file at $EXEC_PATH"
  elif ! file "$EXEC_PATH" | grep -q "Mach-O"; then
    fail "executable '$EXEC_NAME' is not a Mach-O binary"
  elif [ ! -x "$EXEC_PATH" ]; then
    fail "executable '$EXEC_NAME' is not marked executable"
  else
    note "CFBundleExecutable '$EXEC_NAME' is an executable Mach-O binary"
  fi
fi

# 3b. The `remote-code agent-app` middleware dispatches to a co-located rc2
# executable. A bundle without it can launch normally but every managed
# cross-provider Agent App delegation fails with exit 127.
RC2_CLI_PATH="$APP/Contents/MacOS/rc2"
if [ ! -f "$RC2_CLI_PATH" ]; then
  fail "missing bundled rc2 at $RC2_CLI_PATH (required by remote-code agent-app)"
elif ! file "$RC2_CLI_PATH" | grep -q "Mach-O"; then
  fail "bundled rc2 is not a Mach-O binary"
elif [ ! -x "$RC2_CLI_PATH" ]; then
  fail "bundled rc2 is not marked executable"
else
  note "bundled rc2 is an executable Mach-O binary"
fi

# 4. Identifier and version must be non-empty (version drives the Bonjour TXT field).
[ -n "$(plist_get CFBundleIdentifier)" ] && note "CFBundleIdentifier present" || fail "CFBundleIdentifier is empty"
[ -n "$(plist_get CFBundleShortVersionString)" ] && note "CFBundleShortVersionString present" || fail "CFBundleShortVersionString is empty"

# 4b. Files and Folders TCC purpose strings (package-app.sh must ship these so
# macOS can show durable, honest grant dialogs for Desktop/Documents/Downloads/
# network volumes/removable volumes).
for privacy_key in \
  NSNetworkVolumesUsageDescription \
  NSRemovableVolumesUsageDescription \
  NSDesktopFolderUsageDescription \
  NSDocumentsFolderUsageDescription \
  NSDownloadsFolderUsageDescription
do
  if [ -n "$(plist_get "$privacy_key")" ]; then
    note "$privacy_key present"
  else
    fail "$privacy_key is missing or empty (TCC purpose string required)"
  fi
done

# 5. Scheduled Tasks requires an embedded LaunchAgent with a bundle-relative
# program, headless mode flag, and matching Mach service. This is the process
# that keeps schedules running after the foreground app exits.
BUNDLE_ID="$(plist_get CFBundleIdentifier)"
SCHEDULED_SERVICE="${BUNDLE_ID}.scheduled-tasks"
SCHEDULED_PLIST="$APP/Contents/Library/LaunchAgents/${SCHEDULED_SERVICE}.plist"
if [ ! -f "$SCHEDULED_PLIST" ]; then
  fail "missing Scheduled Tasks LaunchAgent at $SCHEDULED_PLIST"
elif ! plutil -lint "$SCHEDULED_PLIST" >/dev/null; then
  fail "Scheduled Tasks LaunchAgent failed plutil -lint"
else
  SCHEDULED_LABEL="$(plutil -extract Label raw -o - "$SCHEDULED_PLIST" 2>/dev/null || true)"
  SCHEDULED_PROGRAM="$(plutil -extract BundleProgram raw -o - "$SCHEDULED_PLIST" 2>/dev/null || true)"
  SCHEDULED_EXECUTABLE="$APP/$SCHEDULED_PROGRAM"
  SCHEDULED_ARGUMENT="$(plutil -extract ProgramArguments.1 raw -o - "$SCHEDULED_PLIST" 2>/dev/null || true)"
  # PlistBuddy treats the dotted service label as one dictionary key; plutil's
  # key-path parser would split it at every dot and report a false negative.
  SCHEDULED_MACH="$(/usr/libexec/PlistBuddy -c "Print :MachServices:${SCHEDULED_SERVICE}" "$SCHEDULED_PLIST" 2>/dev/null || true)"
  [ "$SCHEDULED_LABEL" = "$SCHEDULED_SERVICE" ] || fail "Scheduled Tasks Label must match bundle identifier"
  [ "$SCHEDULED_PROGRAM" = "Contents/Resources/RemoteCodeScheduledTaskAgent" ] || fail "Scheduled Tasks BundleProgram must use the supplemental agent executable"
  [ -x "$SCHEDULED_EXECUTABLE" ] || fail "Scheduled Tasks agent executable is missing"
  [ "$SCHEDULED_ARGUMENT" = "--scheduled-task-agent" ] || fail "Scheduled Tasks headless argument is missing"
  [ "$SCHEDULED_MACH" = "true" ] || fail "Scheduled Tasks Mach service is missing"
  note "Scheduled Tasks LaunchAgent is packaged and structurally valid"
fi

# 6. PkgInfo must be EXACTLY the 8 bytes "APPL????" (the QA-mac:70 bug class: a
#    heredoc trailing newline made it 9 bytes, which some validators reject).
if [ ! -f "$PKGINFO" ]; then
  fail "missing PkgInfo"
else
  SIZE="$(wc -c < "$PKGINFO" | tr -d ' ')"
  CONTENT="$(cat "$PKGINFO")"
  if [ "$SIZE" != "8" ]; then
    fail "PkgInfo must be exactly 8 bytes (got $SIZE -- a trailing newline is the classic regression)"
  elif [ "$CONTENT" != "APPL????" ]; then
    fail "PkgInfo content must be 'APPL????' (got '$CONTENT')"
  else
    note "PkgInfo is exactly 8 bytes 'APPL????'"
  fi
fi

# 7. The pet art must ship inside the real AppShell resource bundle. SwiftPM tests
# can resolve Bundle.module even when the packaging script forgets to copy it, so
# this structural check protects the distributable .app boundary.
#
# Canonical path used by AppShellResourceBundle:
#   Contents/Resources/RemoteCode_AppShell.bundle
# Do NOT require an app-root copy: codesign rejects unsealed root contents, and
# production code must not use SPM Bundle.module (it fatalErrors for customers).
CLAUDE_SDK_BRIDGE="$APP/Contents/Resources/ClaudeAgentSDKBridge.mjs"
if [ ! -f "$CLAUDE_SDK_BRIDGE" ]; then
  fail "missing Claude Agent SDK bridge at $CLAUDE_SDK_BRIDGE (Claude provider fails on customer machines without it)"
else
  note "Claude Agent SDK bridge present under Contents/Resources"
fi

PET_DIR="$APP/Contents/Resources/RemoteCode_AppShell.bundle/Pet"
PET_ATLAS="$PET_DIR/remote-code-black-cat-atlas.png"
PET_MANIFEST="$PET_DIR/remote-code-black-cat-atlas-v3.json"
PET_MICRO_MANIFEST="$PET_DIR/remote-code-black-cat-idle-microactions.json"
PET_EXPECTED_RESOURCE_COUNT=40
if [ ! -d "$PET_DIR" ]; then
  fail "missing AppShell pet resources at $PET_DIR (launch crash class without AppShellResourceBundle)"
else
  note "AppShell resource bundle present under Contents/Resources"
  [ -f "$PET_ATLAS" ] || fail "missing pet atlas"
  if [ -f "$PET_ATLAS" ]; then
    PET_WIDTH="$(sips -g pixelWidth "$PET_ATLAS" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
    PET_HEIGHT="$(sips -g pixelHeight "$PET_ATLAS" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
    PET_ALPHA="$(sips -g hasAlpha "$PET_ATLAS" 2>/dev/null | awk '/hasAlpha:/ { print $2 }')"
    if [ "$PET_WIDTH" = "1536" ] && [ "$PET_HEIGHT" = "7072" ] && [ "$PET_ALPHA" = "yes" ]; then
      note "pet atlas is 1536x7072 RGBA"
    else
      fail "pet atlas must be 1536x7072 with alpha (got ${PET_WIDTH}x${PET_HEIGHT}, alpha=$PET_ALPHA)"
    fi
  fi
  if [ ! -f "$PET_MANIFEST" ]; then
    fail "missing pet atlas manifest"
  elif ! json_lint "$PET_MANIFEST" || ! pet_manifest_contract "$PET_MANIFEST"; then
    fail "pet atlas manifest does not satisfy the v3 34-row contract"
  else
    note "pet atlas manifest satisfies the v3 34-row contract"
  fi

  PET_STATES="idle listening thinking coding editing terminal search gitReview success approval question waiting failed interrupted reconnecting sleeping idleBall idleScratch idleGroom idleStretch idleBox idleButterfly eating drinking purring playing comfort notificationPounce workingMouse workingBug workingEngineer celebrateTreat idleYawn pickedUp"
  for state in $PET_STATES; do
    [ -f "$PET_DIR/remote-code-black-cat-$state.png" ] || fail "missing pet state row: $state"
  done

  for action in idle-blink idle-tail idle-ears; do
    [ -f "$PET_DIR/remote-code-black-cat-$action.png" ] || fail "missing pet micro-action row: $action"
  done
  if [ ! -f "$PET_MICRO_MANIFEST" ]; then
    fail "missing pet micro-action manifest"
  elif ! json_lint "$PET_MICRO_MANIFEST"; then
    fail "pet micro-action manifest is not valid JSON"
  else
    note "pet micro-action manifest is valid JSON"
  fi

  PET_RESOURCE_COUNT="$(find "$PET_DIR" -type f -name 'remote-code-black-cat-*' | wc -l | tr -d ' ')"
  if [ "$PET_RESOURCE_COUNT" = "$PET_EXPECTED_RESOURCE_COUNT" ]; then
    note "pet resource set contains all $PET_EXPECTED_RESOURCE_COUNT v3 files"
  else
    fail "pet resource set must contain $PET_EXPECTED_RESOURCE_COUNT files (got $PET_RESOURCE_COUNT)"
  fi
fi

# 7b. The remote-code-orchestrate skill must ship inside the AgentRuntime
# resource bundle. Same launch crash class as the pet atlas: SwiftPM tests
# resolve local .build products even when packaging forgets the bundle, so only
# this structural check protects the distributable .app (v2.0.85–v2.0.87
# shipped without it and aborted every launch via SPM Bundle.module).
AGENT_RUNTIME_BUNDLE="$APP/Contents/Resources/RemoteCode_AgentRuntime.bundle"
ORCHESTRATE_ROOT="$AGENT_RUNTIME_BUNDLE/remote-code-orchestrate"
ORCHESTRATE_SKILL="$AGENT_RUNTIME_BUNDLE/remote-code-orchestrate/SKILL.md"
ORCHESTRATE_EXPECTED_TREE_SHA256="b5e06a22bf885038f9c339f5c6499671aab202d54fd7a41ac75c2007e296b75b"
ORCHESTRATE_ALLOWED_PATHS=(
  "SKILL.md"
  "agents/openai.yaml"
  "references/host-runtime-matrix.md"
  "references/output-contract.md"
  "references/prompt-contract.md"
  "references/routing-policy.md"
  "scripts/test_orchestration_harness.py"
  "scripts/validate_orchestration.py"
)
if [ ! -d "$AGENT_RUNTIME_BUNDLE" ]; then
  fail "missing AgentRuntime resources at $AGENT_RUNTIME_BUNDLE (launch crash class without AgentRuntimeResourceBundle)"
elif [ ! -f "$ORCHESTRATE_SKILL" ]; then
  fail "missing orchestrate skill at $ORCHESTRATE_SKILL (reconcile fails on every customer machine without it)"
else
  note "AgentRuntime resource bundle ships remote-code-orchestrate"
  # Pinned source validation rejects any non-allowlisted entry, so a stray
  # .DS_Store inside the bundle silently kills the skill install for customers.
  if find "$AGENT_RUNTIME_BUNDLE" -name '.DS_Store' -print -quit | grep -q .; then
    fail "AgentRuntime bundle contains .DS_Store (pinned source validation rejects unexpected entries)"
  else
    note "AgentRuntime bundle contains no .DS_Store"
  fi

  # Mirror AgentSkillInstaller's compiled package pin: exactly eight regular
  # files, the three expected directories, no symlinks/special entries, and the
  # same canonical path/byte-count/file-digest tree hash.
  ORCHESTRATE_TREE_SHAPE_VALID=1
  for relative_path in "${ORCHESTRATE_ALLOWED_PATHS[@]}"; do
    if [ ! -f "$ORCHESTRATE_ROOT/$relative_path" ] \
      || [ -L "$ORCHESTRATE_ROOT/$relative_path" ]; then
      fail "orchestrate bundle missing pinned regular file: $relative_path"
      ORCHESTRATE_TREE_SHAPE_VALID=0
    fi
  done
  ORCHESTRATE_FILE_COUNT="$(find "$ORCHESTRATE_ROOT" -type f | wc -l | tr -d ' ')"
  ORCHESTRATE_DIRECTORY_COUNT="$(find "$ORCHESTRATE_ROOT" -mindepth 1 -type d | wc -l | tr -d ' ')"
  ORCHESTRATE_NON_REGULAR_COUNT="$(
    find "$ORCHESTRATE_ROOT" -mindepth 1 ! -type d ! -type f | wc -l | tr -d ' '
  )"
  if [ "$ORCHESTRATE_FILE_COUNT" != "${#ORCHESTRATE_ALLOWED_PATHS[@]}" ] \
    || [ "$ORCHESTRATE_DIRECTORY_COUNT" != "3" ] \
    || [ "$ORCHESTRATE_NON_REGULAR_COUNT" != "0" ] \
    || [ ! -d "$ORCHESTRATE_ROOT/agents" ] \
    || [ ! -d "$ORCHESTRATE_ROOT/references" ] \
    || [ ! -d "$ORCHESTRATE_ROOT/scripts" ]; then
    fail "orchestrate bundle must contain only the exact eight pinned files and three directories"
    ORCHESTRATE_TREE_SHAPE_VALID=0
  else
    note "orchestrate bundle contains the exact eight-file pinned tree"
  fi

  if [ "$ORCHESTRATE_TREE_SHAPE_VALID" != "1" ]; then
    fail "cannot verify orchestrate tree digest until the pinned tree shape is restored"
  elif ! command -v shasum >/dev/null 2>&1; then
    fail "cannot verify orchestrate tree digest: shasum unavailable"
  else
    ORCHESTRATE_ACTUAL_TREE_SHA256="$(
      for relative_path in "${ORCHESTRATE_ALLOWED_PATHS[@]}"; do
        resource_path="$ORCHESTRATE_ROOT/$relative_path"
        if resource_bytes="$(stat -f '%z' "$resource_path" 2>/dev/null)"; then
          :
        else
          resource_bytes="$(stat -c '%s' "$resource_path")"
        fi
        resource_sha256="$(shasum -a 256 "$resource_path" | awk '{print $1}')"
        printf '%s\t%s\t%s\n' "$relative_path" "$resource_bytes" "$resource_sha256"
      done | shasum -a 256 | awk '{print $1}'
    )"
    if [ "$ORCHESTRATE_ACTUAL_TREE_SHA256" = "$ORCHESTRATE_EXPECTED_TREE_SHA256" ]; then
      note "orchestrate bundle matches compiled v5 tree digest"
    else
      fail "orchestrate bundle tree digest mismatch (expected $ORCHESTRATE_EXPECTED_TREE_SHA256, got $ORCHESTRATE_ACTUAL_TREE_SHA256)"
    fi
  fi
fi

# 7c. Surfaces resources (ghostty) must ship too; the copy is glob-driven in
# package-app.sh, so presence is asserted here rather than at copy time.
SURFACES_BUNDLE="$APP/Contents/Resources/RemoteCode_Surfaces.bundle"
if [ ! -d "$SURFACES_BUNDLE" ]; then
  fail "missing Surfaces resources at $SURFACES_BUNDLE"
else
  note "Surfaces resource bundle present under Contents/Resources"
fi

# 6b. Forbid app-root resource bundles (codesign: "unsealed contents present
# in the bundle root"). Packaging must never reintroduce them.
for root_bundle in RemoteCode_AppShell.bundle RemoteCode_Surfaces.bundle RemoteCode_AgentRuntime.bundle; do
  if [ -e "$APP/$root_bundle" ]; then
    fail "forbidden unsealed app-root bundle $APP/$root_bundle (breaks codesign; use Contents/Resources only)"
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "FAIL: $fails structural check(s) failed for $APP" >&2
  exit 1
fi
echo "OK: $APP passed all structural checks"
