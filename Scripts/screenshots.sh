#!/bin/zsh
#
# screenshots.sh: capture Lincoln window screenshots into docs/images/.
#
# The app runs against a throwaway HOME so captures are reproducible and never
# contain personal data (hosts, proxies, recent files). Screenshots are taken
# from the shipping build by default, so the page shows what users install.
#
# Usage:
#   Scripts/screenshots.sh              # capture from the latest release
#   Scripts/screenshots.sh --local      # capture from build/DerivedData (Scripts/build.sh first)
#   Scripts/screenshots.sh --keep-open  # leave the app running afterwards
#
# Requires: Screen Recording permission for the terminal running this
#   (System Settings > Privacy & Security > Screen & System Audio Recording).
#   Without it screencapture fails with "could not create image from window".

set -euo pipefail

APP_NAME="Lincoln"
REPO="binoio/lincoln"
OUT_DIR="docs/images"
MAIN_SHOT="main-window.png"
# Retina captures are 2x; halve them so the page ships sensible bytes.
TARGET_WIDTH=1400

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

USE_LOCAL=0
KEEP_OPEN=0
for arg in "$@"; do
    case "$arg" in
        --local)     USE_LOCAL=1 ;;
        --keep-open) KEEP_OPEN=1 ;;
        -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

WORK="$(mktemp -d)"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"
APP_PID=""

cleanup() {
    if [[ -n "$APP_PID" && "$KEEP_OPEN" -eq 0 ]]; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- resolve app
if [[ "$USE_LOCAL" -eq 1 ]]; then
    APP_PATH="$(find build/DerivedData -maxdepth 6 -name "$APP_NAME.app" -type d 2>/dev/null | head -1)"
    if [[ -z "$APP_PATH" ]]; then
        echo "==> No local build found. Run Scripts/build.sh first." >&2
        exit 1
    fi
    echo "==> Using local build: $APP_PATH"
else
    echo "==> Downloading the latest $APP_NAME release"
    gh release download -R "$REPO" --pattern '*.zip' -D "$WORK" --clobber
    ditto -x -k "$WORK"/*.zip "$WORK"
    APP_PATH="$WORK/$APP_NAME.app"
    if [[ ! -d "$APP_PATH" ]]; then
        echo "==> Release zip did not contain $APP_NAME.app" >&2
        exit 1
    fi
    # The shipping build must be the notarized one users actually get.
    spctl -a -t exec "$APP_PATH" || { echo "==> Gatekeeper rejected the app" >&2; exit 1; }
fi

# ------------------------------------------------------------- window helper
HELPER_SRC="$WORK/windowlist.swift"
cat > "$HELPER_SRC" <<'SWIFT'
import CoreGraphics
import Foundation

// Prints "<windowID>\t<width>x<height>\t<title>" for each on-screen window
// belonging to the owner named in argv[1], largest first.
let owner = CommandLine.arguments.dropFirst().first ?? ""
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    exit(2)
}
var rows: [(Int, Double, Double, String)] = []
for info in infos {
    guard let id = info[kCGWindowNumber as String] as? Int,
          let name = info[kCGWindowOwnerName as String] as? String, name == owner,
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let w = bounds["Width"] as? Double,
          let h = bounds["Height"] as? Double
    else { continue }
    if w < 300 || h < 200 { continue }   // skip panels, popovers, status surfaces
    rows.append((id, w, h, (info[kCGWindowName as String] as? String) ?? ""))
}
for (id, w, h, title) in rows.sorted(by: { $0.1 * $0.2 > $1.1 * $1.2 }) {
    print("\(id)\t\(Int(w))x\(Int(h))\t\(title)")
}
SWIFT
swiftc -O -o "$WORK/windowlist" "$HELPER_SRC"

# ------------------------------------------------------------------- run app
echo "==> Launching $APP_NAME against a throwaway HOME"
# `open` (rather than exec'ing the binary) brings the app frontmost, so the
# capture shows an active window rather than a greyed-out inactive one.
open -n --env "HOME=$FAKE_HOME" -a "$APP_PATH"
for _ in {1..20}; do
    APP_PID="$(pgrep -f "$APP_PATH/Contents/MacOS/$APP_NAME" | head -1)"
    [[ -n "$APP_PID" ]] && break
    sleep 0.5
done
if [[ -z "$APP_PID" ]]; then
    echo "==> $APP_NAME did not start" >&2
    exit 1
fi

WINDOW_ID=""
for _ in {1..40}; do
    sleep 0.5
    WINDOW_ID="$("$WORK/windowlist" "$APP_NAME" | head -1 | cut -f1)"
    [[ -n "$WINDOW_ID" ]] && break
done

if [[ -z "$WINDOW_ID" ]]; then
    echo "==> $APP_NAME never opened a window" >&2
    exit 1
fi

# Let the window finish its open animation before capturing.
sleep 1.5

# ------------------------------------------------------------------- capture
mkdir -p "$OUT_DIR"
RAW="$WORK/raw.png"
if ! screencapture -x -l"$WINDOW_ID" "$RAW"; then
    echo "==> screencapture failed. Grant this terminal Screen Recording permission in" >&2
    echo "    System Settings > Privacy & Security > Screen & System Audio Recording." >&2
    exit 1
fi

sips -Z "$TARGET_WIDTH" "$RAW" --out "$OUT_DIR/$MAIN_SHOT" >/dev/null
echo "==> Wrote $OUT_DIR/$MAIN_SHOT ($(sips -g pixelWidth -g pixelHeight "$OUT_DIR/$MAIN_SHOT" | tail -2 | tr -d ' \n' | sed 's/pixelWidth:/, /;s/pixelHeight:/x/'))"
