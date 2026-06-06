#!/usr/bin/env bash
#
# One-line install (no Homebrew, no Xcode required):
#
#   curl -fsSL https://raw.githubusercontent.com/kqw8/Dusk/main/scripts/install.sh | bash
#
# It fetches the latest universal binary (arm64+x86_64) from GitHub Releases, verifies its
# sha256, strips the Gatekeeper quarantine flag, and installs it to /usr/local/bin.
# Override via env vars:
#   DUSK_REPO=owner/repo    use a different repo
#   DUSK_BINDIR=/some/bin   install to a different directory
#
set -euo pipefail

REPO="${DUSK_REPO:-kqw8/Dusk}"
NAME="dusk"
BINDIR="${DUSK_BINDIR:-/usr/local/bin}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "✗ This tool only supports macOS." >&2
  exit 1
fi

echo "▸ Looking up the latest release ..."
# Separate "couldn't reach GitHub / rate limited" from "the repo genuinely has no release", so a
# transient 403/429/network error doesn't masquerade as a missing release.
API="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" || {
  echo "✗ Couldn't reach GitHub (network error or API rate limit). Try again shortly, or set DUSK_REPO=owner/repo." >&2
  exit 1
}
TAG="$(printf '%s' "$API" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name" *: *"([^"]+)".*/\1/')"
if [ -z "${TAG:-}" ]; then
  echo "✗ No published release found for $REPO." >&2
  exit 1
fi

TARBALL="$NAME-$TAG-universal.tar.gz"
BASE="https://github.com/$REPO/releases/download/$TAG"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Downloading $TAG ..."
curl -fsSL "$BASE/$TARBALL" -o "$TMP/$TARBALL"

# sha256 verification, fail-closed: the checksums file must download, and it must contain a
# matching entry for this tarball. Any failure aborts — never install + de-quarantine an
# unverified, unsigned binary.
if ! curl -fsSL "$BASE/checksums.txt" -o "$TMP/checksums.txt"; then
  echo "✗ Could not download checksums.txt; aborting." >&2
  exit 1
fi
EXPECTED="$(grep " $TARBALL\$" "$TMP/checksums.txt" | awk '{print $1}')"
if [ -z "${EXPECTED:-}" ]; then
  echo "✗ No checksum entry for $TARBALL; aborting." >&2
  exit 1
fi
ACTUAL="$(shasum -a 256 "$TMP/$TARBALL" | awk '{print $1}')"
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "✗ Checksum mismatch; aborting." >&2
  exit 1
fi
echo "▸ Checksum OK"

tar -xzf "$TMP/$TARBALL" -C "$TMP"
chmod +x "$TMP/$NAME"
# Drop the "downloaded from the internet" quarantine flag, or Gatekeeper blocks the
# un-notarized binary.
xattr -dr com.apple.quarantine "$TMP/$NAME" 2>/dev/null || true

echo "▸ Installing to $BINDIR ..."
# The target dir may not exist (e.g. a fresh Apple Silicon Mac without Homebrew has no
# /usr/local/bin): create it first.
mkdir -p "$BINDIR" 2>/dev/null || sudo mkdir -p "$BINDIR"
if [ -w "$BINDIR" ]; then
  mv "$TMP/$NAME" "$BINDIR/$NAME"
else
  echo "  (sudo needed to write to $BINDIR)"
  sudo mv "$TMP/$NAME" "$BINDIR/$NAME"
fi

echo ""
echo "✅ Installed: $BINDIR/$NAME ($TAG)"
echo ""
echo "Next:"
echo "  $NAME install      # start the background service (autostart off by default)"
echo "  $NAME login on     # (optional) enable start-at-login"
echo "  $NAME status       # show status"
