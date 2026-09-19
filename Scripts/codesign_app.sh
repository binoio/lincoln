#!/bin/zsh
#
# codesign_app.sh: Sign Lincoln.app inside-out (never --deep) with hardened
# runtime and the app's network entitlements. Sparkle's helpers are signed
# individually; its XPC services keep their shipped entitlements.
#
# Usage: Scripts/codesign_app.sh <path/to/Lincoln.app> <signing-identity>

set -euo pipefail

APP_BUNDLE="${1:?usage: codesign_app.sh <app> <identity>}"
IDENTITY="${2:?usage: codesign_app.sh <app> <identity>}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/Lincoln/Lincoln.entitlements"

CODESIGN_FLAGS=(--force --options runtime --timestamp -s "$IDENTITY")

SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Step 1/3: Signing Sparkle.framework..."
    codesign "${CODESIGN_FLAGS[@]}" "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
    codesign "${CODESIGN_FLAGS[@]}" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
    codesign "${CODESIGN_FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
    codesign "${CODESIGN_FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
    codesign "${CODESIGN_FLAGS[@]}" "$SPARKLE_FRAMEWORK"
else
    echo "Step 1/3: No Sparkle.framework embedded; skipping."
fi

HELPER="$APP_BUNDLE/Contents/MacOS/lincoln-askpass"
if [[ -f "$HELPER" ]]; then
    echo "Step 2/3: Signing lincoln-askpass helper..."
    codesign "${CODESIGN_FLAGS[@]}" "$HELPER"
fi

echo "Step 3/3: Signing app bundle with entitlements..."
codesign "${CODESIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

echo "Code signing complete (inner-to-outer)."
