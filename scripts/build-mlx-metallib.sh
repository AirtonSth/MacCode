#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT="${1:-.build/mlx.metallib}"
METAL_DIR=".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
WORK_DIR=".build/mlx-metallib"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if [ ! -d "$METAL_DIR" ]; then
  echo "[mlx-metallib] missing $METAL_DIR; run swift build first" >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$(dirname "$OUTPUT")"

AIR_FILES=()
while IFS= read -r metal_file; do
  name="$(basename "$metal_file" .metal)"
  air_file="$WORK_DIR/$name.air"
  xcrun -sdk macosx metal \
    -x metal \
    -Wall \
    -Wextra \
    -fno-fast-math \
    -Wno-c++17-extensions \
    -Wno-c++20-extensions \
    -mmacosx-version-min=14.0 \
    -I"$METAL_DIR" \
    -c "$metal_file" \
    -o "$air_file"
  AIR_FILES+=("$air_file")
done < <(find "$METAL_DIR" -maxdepth 1 -name '*.metal' -print | sort)

if [ "${#AIR_FILES[@]}" -eq 0 ]; then
  echo "[mlx-metallib] no Metal kernels found in $METAL_DIR" >&2
  exit 1
fi

xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$OUTPUT"
echo "[mlx-metallib] built $OUTPUT"
