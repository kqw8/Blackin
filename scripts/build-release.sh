#!/usr/bin/env bash
#
# Build a universal binary (arm64 + x86_64) for distribution, plus checksums and a tarball.
#
# Why not `swift build --arch arm64 --arch x86_64`: that path needs full Xcode's xcbuild,
# which a Command-Line-Tools-only machine doesn't have. Instead we cross-compile each arch
# separately and merge with lipo, which works on both CLT and full Xcode.
#
# Usage:
#   scripts/build-release.sh [version]      # version defaults to "dev"
#
# To cut a release (first bump `duskVersion` in Sources/dusk/main.swift to match the tag):
#   scripts/build-release.sh v0.1.1
#   gh release create v0.1.1 release/dusk-v0.1.1-universal.tar.gz release/checksums.txt \
#     --title "Dusk v0.1.1" --notes "..."
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-dev}"
NAME="dusk"
DEPLOY="13.0"
OUT="release"

build_arch() {  # $1 = arch (arm64 | x86_64)
  local arch="$1"
  local scratch=".build-$arch"
  local triple="$arch-apple-macosx$DEPLOY"
  rm -rf "$scratch"
  swift build -c release --scratch-path "$scratch" --triple "$triple" >/dev/null
  swift build -c release --scratch-path "$scratch" --triple "$triple" --show-bin-path
}

echo "▸ Building arm64 ..."
ARM64_DIR="$(build_arch arm64)" || exit 1
echo "▸ Building x86_64 ..."
X86_DIR="$(build_arch x86_64)" || exit 1

rm -rf "$OUT"; mkdir -p "$OUT"
echo "▸ Merging into a universal binary with lipo ..."
lipo -create -output "$OUT/$NAME" "$ARM64_DIR/$NAME" "$X86_DIR/$NAME"

# lipo invalidates SwiftPM's ad-hoc signature; Apple Silicon requires re-signing to run.
codesign --force --sign - "$OUT/$NAME"

echo "▸ Architectures: $(lipo -archs "$OUT/$NAME")"
TARBALL="$NAME-$VERSION-universal.tar.gz"
tar -czf "$OUT/$TARBALL" -C "$OUT" "$NAME"
( cd "$OUT" && shasum -a 256 "$NAME" "$TARBALL" > checksums.txt )

echo "✅ Done. Artifacts in $OUT/:"
ls -1 "$OUT"
echo ""
echo "Checksums:"
cat "$OUT/checksums.txt"
