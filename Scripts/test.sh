#!/bin/zsh
#
# test.sh: Run the Lincoln test suites.
#
# Usage: Scripts/test.sh [--ui] [--core]
#   Runs the LincolnCore package tests (swift test) and the LincolnTests unit
#   suite by default; --ui also runs LincolnUITests; --core runs only the
#   package tests (what the Dockerfile / CI executes on Linux).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Running LincolnCore package tests"
swift test --package-path LincolnCore

if [[ "${1:-}" == "--core" ]]; then
    exit 0
fi

killall Lincoln 2>/dev/null || true

# The test host is launched by testmanagerd, which cannot open bundles inside
# TCC-protected folders (Downloads, Desktop, Documents) and hangs before the
# tests start. Build into a temporary DerivedData when the checkout lives there.
DERIVED_DATA="${LINCOLN_DERIVED_DATA:-build/DerivedData}"
case "$REPO_ROOT" in
    "$HOME/Downloads"*|"$HOME/Desktop"*|"$HOME/Documents"*)
        DERIVED_DATA="${LINCOLN_DERIVED_DATA:-${TMPDIR:-/tmp}/lincoln-DerivedData}"
        echo "==> Checkout is in a TCC-protected folder; using $DERIVED_DATA"
        ;;
esac

ARGS=(-project Lincoln.xcodeproj -scheme Lincoln -derivedDataPath "$DERIVED_DATA" -destination 'platform=macOS,arch=arm64')
if [[ "${1:-}" == "--ui" ]]; then
    echo "==> Running unit and UI tests"
    xcodebuild test "${ARGS[@]}"
else
    echo "==> Running unit tests (LincolnTests)"
    xcodebuild test "${ARGS[@]}" -only-testing:LincolnTests
fi
