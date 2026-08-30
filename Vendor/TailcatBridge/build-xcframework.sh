#!/bin/sh
set -eu

TAILCAT_SHA="88929418b1a3f3c74904a3136d6a9e87b1b5b9bb"
GO_VERSION="go1.26.5"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:-"$SCRIPT_DIR/Artifacts/RCTailcat.xcframework"}
GO_BIN=${RCTAILCAT_GO:-$(command -v go || true)}

if [ -z "$GO_BIN" ] || [ "$($GO_BIN version | awk '{print $3}')" != "$GO_VERSION" ]; then
  echo "RCTailcat requires $GO_VERSION; set RCTAILCAT_GO to that binary." >&2
  exit 1
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rctailcat-build.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

mkdir -p "$WORK_DIR/src" "$WORK_DIR/bridge-smoke" "$WORK_DIR/build"
git clone --quiet https://github.com/tailscale/tailcat.git "$WORK_DIR/src/tailcat"
git -C "$WORK_DIR/src/tailcat" checkout --quiet --detach "$TAILCAT_SHA"
git -C "$WORK_DIR/src/tailcat" apply "$SCRIPT_DIR/patches/tailcat-88929418-rcpatch1.patch"
cp "$SCRIPT_DIR/Bridge/main.go" "$SCRIPT_DIR/Bridge/main_test.go" "$SCRIPT_DIR/Bridge/go.mod" "$SCRIPT_DIR/Bridge/go.sum" "$WORK_DIR/bridge-smoke/"

(
  cd "$WORK_DIR/bridge-smoke"
  "$GO_BIN" test ./...
)

build_slice() {
  name=$1
  sdk=$2
  min_flag=$3
  slice_dir="$WORK_DIR/build/$name"
  mkdir -p "$slice_dir/Headers"
  sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
  cc=$(xcrun --sdk "$sdk" --find clang)
  goos=darwin
  if [ "$sdk" != "macosx" ]; then
    goos=ios
  fi
  (
    cd "$WORK_DIR/bridge-smoke"
    env CGO_ENABLED=1 GOOS="$goos" GOARCH=arm64 CC="$cc" \
      CGO_CFLAGS="-isysroot $sdk_path $min_flag -arch arm64" \
      CGO_LDFLAGS="-isysroot $sdk_path $min_flag -arch arm64" \
      "$GO_BIN" build -trimpath -buildmode=c-archive -ldflags=-buildid= \
      -o "$slice_dir/libRCTailcat.a" .
  )
  mv "$slice_dir/libRCTailcat.h" "$slice_dir/Headers/RCTailcat.h"
  ZERO_AR_DATE=1 xcrun ranlib "$slice_dir/libRCTailcat.a"
  printf 'module RCTailcat {\n  header "RCTailcat.h"\n  export *\n}\n' > "$slice_dir/Headers/module.modulemap"
}

build_slice macos-arm64 macosx -mmacosx-version-min=14.0
build_slice ios-arm64 iphoneos -miphoneos-version-min=18.0
build_slice ios-arm64-simulator iphonesimulator -mios-simulator-version-min=18.0

rm -rf "$OUTPUT"
mkdir -p "$(dirname -- "$OUTPUT")"
xcodebuild -create-xcframework \
  -library "$WORK_DIR/build/macos-arm64/libRCTailcat.a" -headers "$WORK_DIR/build/macos-arm64/Headers" \
  -library "$WORK_DIR/build/ios-arm64/libRCTailcat.a" -headers "$WORK_DIR/build/ios-arm64/Headers" \
  -library "$WORK_DIR/build/ios-arm64-simulator/libRCTailcat.a" -headers "$WORK_DIR/build/ios-arm64-simulator/Headers" \
  -output "$OUTPUT"

plutil -replace AvailableLibraries -json '[{"BinaryPath":"libRCTailcat.a","HeadersPath":"Headers","LibraryIdentifier":"macos-arm64","LibraryPath":"libRCTailcat.a","SupportedArchitectures":["arm64"],"SupportedPlatform":"macos"},{"BinaryPath":"libRCTailcat.a","HeadersPath":"Headers","LibraryIdentifier":"ios-arm64","LibraryPath":"libRCTailcat.a","SupportedArchitectures":["arm64"],"SupportedPlatform":"ios"},{"BinaryPath":"libRCTailcat.a","HeadersPath":"Headers","LibraryIdentifier":"ios-arm64-simulator","LibraryPath":"libRCTailcat.a","SupportedArchitectures":["arm64"],"SupportedPlatform":"ios","SupportedPlatformVariant":"simulator"}]' "$OUTPUT/Info.plist"
plutil -convert xml1 "$OUTPUT/Info.plist"

echo "Built $OUTPUT"
