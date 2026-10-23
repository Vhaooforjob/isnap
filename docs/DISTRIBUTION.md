# Signed releases and in-app updates

Xcode builds pin Sparkle 2.10.0. The Swift package CLI build intentionally excludes the app-only updater dependency. `AppUpdater` uses Sparkle when the app bundle has an HTTPS `SUFeedURL` and a valid 32-byte base64 `SUPublicEDKey`. Unconfigured development builds keep the existing GitHub release notification. Startup checks respect iSnap's setting; the explicit Check Now command uses Sparkle's standard check/download/install UI. Sparkle manages automatic checks and their user consent once initialized.

Official setup: https://sparkle-project.org/documentation/ and https://sparkle-project.org/documentation/programmatic-setup/.

## One-time publisher setup

1. Install a **Developer ID Application** certificate and its private key in the signing Mac's keychain.
2. Store notarization credentials using `xcrun notarytool store-credentials`; use that keychain profile name below. Credentials must not be checked into this repository.
3. Run Sparkle's `bin/generate_keys` from the resolved package artifacts once. Keep its private key in the login keychain and securely back it up. Use the printed public key as `ISNAP_UPDATE_PUBLIC_KEY`. The same keychain must be available to `generate_appcast` during release preparation.
4. Commit release sources, update both app/widget version and build numbers, and prepare release notes. Keep build numbers increasing.

```sh
ISNAP_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
ISNAP_NOTARY_PROFILE='isnap-notary' \
ISNAP_UPDATE_PUBLIC_KEY='BASE64_PUBLIC_KEY_FROM_GENERATE_KEYS' \
ISNAP_RELEASE_OUTPUT='/tmp/isnap-signed-release' \
bash scripts/release.sh
```

The script builds universal app/widget binaries, signs nested Sparkle helpers before the host, notarizes and staples the app and DMG, generates a signed update feed, validates archives and writes checksums. Ad-hoc builds remain available by omitting signing variables. Only ad-hoc builds disable library validation to load the bundled framework; Developer ID releases retain it. A configured update feed requires the signed/notarized path. Existing artifacts are rejected instead of overwritten. Temporary staging is unique per run and removed on exit; provenance identifies dirty source builds.

The default feed is the `appcast.xml` asset on the latest GitHub Release. Publish it together with the exact signed ZIP, DMG and checksum manifest when a release is approved. Feed download URLs point to the versioned release, not `latest`. To use another feed host, set `ISNAP_UPDATE_FEED_URL` and adapt the artifact download prefix in the script. Do not publish a feed before its referenced archive is accessible. Test an update from a previous signed installed build before general distribution.

No certificate, notarization submission, signing key creation, release publishing or application installation is implied by a source build. The release preflight on 2026-10-23 found an Apple Development identity but no Developer ID Application identity. Version 1.0.5 therefore uses ad-hoc signing; notarization and signed update installation have not been validated.

The ad-hoc path was exercised successfully: universal app/widget, nested signing verification, ZIP extraction, DMG checksum and SHA-256 manifest validation all passed. The script reads the existing public key before configured signing and rejects a mismatch; it does not silently generate or replace keys.
