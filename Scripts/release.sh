#!/bin/zsh
#
# release.sh: Build, sign, notarize (App Store Connect API), EdDSA-sign,
# and publish a Lincoln release with an updated Sparkle appcast.
#
# One-time setup:
#   1. App Store Connect API key: xcrun notarytool store-credentials lincoln-notary \
#        --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#      (an existing profile for the same team, e.g. atmo-notary, also works)
#   2. Sparkle EdDSA key pair in the login Keychain (bin/generate_keys).
#   3. gh auth login with access to binoio/lincoln.
#
# Per release: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION together in
# Lincoln.xcodeproj (and VERSION), write ReleaseNotes/Lincoln-X.Y.Z.md and
# .html, commit, run.

set -euo pipefail

IDENTITY="${LINCOLN_SIGN_IDENTITY:-Developer ID Application: Michael Bino (43L352U8Y8)}"
REPO="binoio/lincoln"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Resolve the notarytool keychain profile: explicit env var, then lincoln-notary,
# then any same-team profile such as atmo-notary.
NOTARY_PROFILE=""
for candidate in "${LINCOLN_NOTARY_PROFILE:-}" lincoln-notary kona-notary atmo-notary edith-notary outsight-notary; do
    [[ -n "$candidate" ]] || continue
    if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
        NOTARY_PROFILE="$candidate"
        break
    fi
done
[[ -n "$NOTARY_PROFILE" ]] || { echo "error: no notarytool keychain profile found (run: xcrun notarytool store-credentials lincoln-notary ...)" >&2; exit 1; }

VERSION=$(grep -m1 'MARKETING_VERSION' Lincoln.xcodeproj/project.pbxproj | sed 's/[^0-9.]*//g')
BUILD_NUMBER=$(grep -m1 'CURRENT_PROJECT_VERSION' Lincoln.xcodeproj/project.pbxproj | sed 's/[^0-9.]*//g')
TAG="v${VERSION}"
DERIVED_DATA="build/DerivedData"
APP="dist/Lincoln.app"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ZIP="dist/Lincoln-${VERSION}.zip"
NOTES_MD="ReleaseNotes/Lincoln-${VERSION}.md"
NOTES_HTML="ReleaseNotes/Lincoln-${VERSION}.html"

echo "==> Preflight for Lincoln ${VERSION} (build ${BUILD_NUMBER}, notary profile: ${NOTARY_PROFILE})"
[[ "$BUILD_NUMBER" == "$VERSION" ]] || { echo "error: CURRENT_PROJECT_VERSION ($BUILD_NUMBER) must match MARKETING_VERSION ($VERSION) — Sparkle compares CFBundleVersion" >&2; exit 1; }
[[ "$(cat VERSION | tr -d '[:space:]')" == "$VERSION" ]] || { echo "error: VERSION file ($(cat VERSION)) must match MARKETING_VERSION ($VERSION)" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree not clean" >&2; exit 1; }
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists" >&2; exit 1
fi
LATEST_TAG=$(git tag -l 'v*' | sort -V | tail -1)
if [[ -n "$LATEST_TAG" && "$(print -l "$LATEST_TAG" "$TAG" | sort -V | tail -1)" != "$TAG" ]]; then
    echo "error: version ($VERSION) is not newer than latest tag ($LATEST_TAG)" >&2; exit 1
fi
[[ -f "$NOTES_MD" ]] || { echo "error: $NOTES_MD missing" >&2; exit 1; }
[[ -f "$NOTES_HTML" ]] || { echo "error: $NOTES_HTML missing" >&2; exit 1; }
# Capture before testing: with pipefail, `grep -q` exiting early would kill
# the producer with SIGPIPE and fail the pipeline even on a match
IDENTITIES=$(security find-identity -v -p codesigning)
[[ "$IDENTITIES" == *"Developer ID Application"* ]] || {
    echo "error: no Developer ID Application signing identity in keychain" >&2; exit 1
}
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated" >&2; exit 1; }

echo "==> Running test suites"
zsh Scripts/test.sh

echo "==> Building (Release, unsigned; signed inside-out below)"
xcodebuild \
    -project Lincoln.xcodeproj \
    -scheme Lincoln \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=macOS' \
    build \
    CODE_SIGNING_ALLOWED=NO

mkdir -p dist
rm -rf "$APP"
ditto "$DERIVED_DATA/Build/Products/Release/Lincoln.app" "$APP"

SPARKLE_BIN=$(find "$DERIVED_DATA/SourcePackages/artifacts" -type d -name bin -path "*parkle*" 2>/dev/null | head -1)
[[ -n "$SPARKLE_BIN" ]] || { echo "error: Sparkle tools not found under $DERIVED_DATA/SourcePackages/artifacts" >&2; exit 1; }

echo "==> Verifying bundle"
PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" == "io.binoio.Lincoln" ]] || { echo "error: wrong bundle id" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]] || { echo "error: bundle version mismatch" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$PLIST")" == https://* ]] || { echo "error: SUFeedURL missing or not https" >&2; exit 1; }
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST")"
[[ -n "$PUBLIC_KEY" ]] || { echo "error: SUPublicEDKey missing" >&2; exit 1; }
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
[[ "$PUBLIC_KEY" == "$KEYCHAIN_KEY" ]] || { echo "error: SUPublicEDKey ($PUBLIC_KEY) does not match the EdDSA key in the login Keychain ($KEYCHAIN_KEY)" >&2; exit 1; }
[[ -d "$FRAMEWORK" ]] || { echo "error: Sparkle.framework not embedded" >&2; exit 1; }
[[ -x "$APP/Contents/MacOS/lincoln-askpass" ]] || { echo "error: lincoln-askpass helper not embedded" >&2; exit 1; }
LOAD_COMMANDS=$(otool -l "$APP/Contents/MacOS/Lincoln")
[[ "$LOAD_COMMANDS" == *"@executable_path/../Frameworks"* ]] || { echo "error: Frameworks rpath missing" >&2; exit 1; }

echo "==> Codesigning (inside-out; never --deep)"
zsh Scripts/codesign_app.sh "$APP" "$IDENTITY"
codesign --verify --deep --strict "$APP"

echo "==> Notarizing via App Store Connect API"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Generating appcast (EdDSA signature from login Keychain)"
WORK="dist/appcast-work"
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ZIP" "$WORK/"
cp "$NOTES_HTML" "$WORK/Lincoln-${VERSION}.html"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
    --embed-release-notes \
    -o docs/appcast.xml "$WORK"

echo "==> Publishing (release first so the asset exists before the appcast goes live)"
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Lincoln ${VERSION}" --notes-file "$NOTES_MD"

git add docs/appcast.xml
git commit -m "Publish appcast for ${VERSION}"
git push origin HEAD

echo "==> Done: Lincoln ${VERSION} released. Pages will deploy the appcast shortly."
