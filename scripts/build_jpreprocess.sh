#!/bin/bash
# Explicit native build; the ordinary Xcode build only validates these outputs.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
native_root="$repo_root/native/japanese-pronunciation"
asset_root="$repo_root/CatRobot/LocalAssets/JPreprocess"
manifest="$repo_root/CatRobot/Resources/jpreprocess-manifest.json"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$repo_root/.build/jpreprocess}"
export IPHONEOS_DEPLOYMENT_TARGET=27.0
export PYTHONDONTWRITEBYTECODE=1
command -v cargo >/dev/null || { echo 'error: Install Rust 1.90.0 and add cargo to PATH' >&2; exit 1; }
cd "$native_root"
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    rustup target list --installed | grep -Fxq "$target" || {
        echo "error: Run rustup target add --toolchain 1.90.0 $target" >&2
        exit 1
    }
    cargo build --release --locked --target "$target"
done
mkdir -p "$repo_root/.build" "$asset_root"
package_dir="$(mktemp -d "$repo_root/.build/jpreprocess-package.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir -p "$package_dir/simulator"
xcrun lipo -create "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libcjp_pronunciation.a" \
    "$CARGO_TARGET_DIR/x86_64-apple-ios/release/libcjp_pronunciation.a" \
    -output "$package_dir/simulator/libcjp_pronunciation.a"
/usr/bin/python3 - "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libcjp_pronunciation.a" "$package_dir/simulator/libcjp_pronunciation.a" <<'PYARCH'
import subprocess
import sys
for library, expected in zip(sys.argv[1:], [{"arm64"}, {"arm64", "x86_64"}]):
    actual = set(subprocess.check_output(["xcrun", "lipo", library, "-archs"], text=True).split())
    if actual != expected:
        raise SystemExit("error: wrong native architectures: " + str(actual))
PYARCH
xcodebuild -create-xcframework \
    -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libcjp_pronunciation.a" -headers "$native_root/include" \
    -library "$package_dir/simulator/libcjp_pronunciation.a" -headers "$native_root/include" \
    -output "$package_dir/CJPPronunciation.xcframework"
/usr/bin/python3 - "$package_dir/CJPPronunciation.xcframework" "$asset_root/CJPPronunciation.xcframework" <<'PY'
from pathlib import Path
import shutil
import sys
source, target = map(Path, sys.argv[1:])
if target.exists():
    shutil.rmtree(target)
source.rename(target)
PY
/usr/bin/python3 "$repo_root/scripts/validate_jpreprocess_assets.py" --root "$asset_root" --manifest "$manifest" --write-receipt
