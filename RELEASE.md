# Release Instructions for Lincoln

To publish a new release of Lincoln:

1. **Version Bump**:
   - Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Lincoln.xcodeproj/project.pbxproj` (keep them identical — Sparkle compares `CFBundleVersion`).
   - Update `VERSION` file.

2. **Release Notes**:
   - Write `ReleaseNotes/Lincoln-X.Y.Z.md` (for GitHub releases).
   - Write `ReleaseNotes/Lincoln-X.Y.Z.html` (for Sparkle appcast).

3. **Release Execution**:
   ```bash
   zsh Scripts/release.sh
   ```

`release.sh` handles:
- Preflight verification (working tree clean, version newer than the latest tag, release notes, Developer ID identity, notarytool profile, `gh auth`).
- Running the test suites.
- Building Release configuration with Xcode.
- Inside-out codesigning with entitlements and hardened runtime (`Scripts/codesign_app.sh`).
- Notarization with App Store Connect API (`notarytool`) and stapling (`stapler`).
- Generating Sparkle appcast (`docs/appcast.xml`) with the EdDSA key from the login Keychain.
- Publishing the release to GitHub, pushing the tag, and committing the appcast (served by GitHub Pages from `docs/`).

## Prerequisites (one time)

- `xcrun notarytool store-credentials lincoln-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>` (an existing same-team profile such as `atmo-notary` is picked up automatically).
- Sparkle EdDSA key pair in the login Keychain (`generate_keys`); the public key must match `SUPublicEDKey` in `Lincoln/Info.plist`.
- `gh auth login` with access to `binoio/lincoln`.

## Post-release checks

```bash
codesign --verify --deep --strict dist/Lincoln.app
spctl -a -vv -t exec dist/Lincoln.app
```
