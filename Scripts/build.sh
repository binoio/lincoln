#!/bin/zsh
#
# build.sh: Build Lincoln.app.
#
# Usage: Scripts/build.sh [--release]
#   Debug build by default. --release builds the Release configuration.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="Debug"
if [[ "${1:-}" == "--release" ]]; then
    CONFIGURATION="Release"
fi

DERIVED_DATA="build/DerivedData"

echo "==> Building Lincoln ($CONFIGURATION)"
xcodebuild \
    -project Lincoln.xcodeproj \
    -scheme Lincoln \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=macOS' \
    build

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/Lincoln.app"
echo "==> Built $APP"
