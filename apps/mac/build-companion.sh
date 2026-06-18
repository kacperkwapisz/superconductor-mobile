#!/usr/bin/env bash
set -euo pipefail

# Build + install Superconductor Mobile Companion to /Applications.
#
# Usage (from repo root):
#   bash apps/mac/build-companion.sh
#   INSTALL_DIR=~/Applications bash apps/mac/build-companion.sh   # override destination
#
# Requires: bun, xcodebuild

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPANION_DIR="$SCRIPT_DIR/SuperconductorMobileCompanion"
BRIDGE_OUT="$SCRIPT_DIR/bridge-server"
DERIVED="$REPO_ROOT/.build/companion-derived"
APP_NAME="Superconductor Mobile.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/$APP_NAME"

echo "==> Building standalone bridge server (bun compile)"
cd "$REPO_ROOT"
bun build apps/bridge/src/server.ts \
  --compile \
  --target=bun-darwin-arm64 \
  --outfile "$BRIDGE_OUT"
chmod +x "$BRIDGE_OUT"

echo "==> Building companion app (Release)"
cd "$COMPANION_DIR"
xcodebuild \
  -scheme SuperconductorMobileCompanion \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  build \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" \
  | tail -5

BUILT_APP="$DERIVED/Build/Products/Release/SuperconductorMobileCompanion.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: expected app at $BUILT_APP" >&2
  exit 1
fi

echo "==> Embedding bridge-server in app bundle"
mkdir -p "$BUILT_APP/Contents/Resources"
cp -f "$BRIDGE_OUT" "$BUILT_APP/Contents/Resources/bridge-server"
chmod +x "$BUILT_APP/Contents/Resources/bridge-server"

echo "==> Installing to $DEST"
mkdir -p "$INSTALL_DIR"
# Quit running copy so ditto can replace the bundle
pkill -x SuperconductorMobileCompanion 2>/dev/null || true
sleep 0.3
ditto "$BUILT_APP" "$DEST"

echo "==> Done: $DEST"
echo "    Launch from Finder or: open -a \"$DEST\""