# Releasing

A release is a universal `.dmg` attached to a GitHub release, plus its SHA-256 checksum.

## 1. Prepare

1. Update `RADAR_VERSION` (and `RADAR_BUILD_NUMBER`) in `Scripts/lib/project.sh`.
2. Add the release to `CHANGELOG.md`.
3. Run `Scripts/verify.sh`.
4. If the icon or installer artwork changed, run `swift Packaging/render-artwork.swift` and commit the results.

## 2. Build the installer

```sh
Scripts/release.sh
```

This writes `dist/release/GhostProcessSniper-<version>.dmg` and `…dmg.sha256`. The script:

- compiles an arm64 + x86_64 release build in `~/Library/Caches/GhostProcessSniper/release-build`, isolated from day-to-day builds and from folder syncing,
- bundles the app with its icon and metadata, signs it, and checks its architectures, version, and signature,
- builds a drag-to-Applications disk image with a custom background and volume icon,
- compresses and verifies the image and writes the checksum.

Bundling, signing, and disk-image assembly happen in a temporary directory; only the finished `.dmg` and checksum are copied to `dist/release`. It never touches `dist/Ghost Process Sniper.app` or a running copy of the app.

The installer window layout is applied through Finder. The first run asks for permission to control Finder; if that permission is missing, the script prints a warning and still produces a working disk image with a plain window.

Override the architectures with `RADAR_ARCHS="arm64" Scripts/release.sh` for a faster, Apple-silicon-only build.

## 3. Signing and notarization (optional)

By default the app is signed ad hoc, so users confirm the first launch in **Privacy & Security** (the README explains how). With a paid Apple Developer account you can ship a build that opens without any warning:

```sh
# One-time: store notarization credentials in the keychain.
xcrun notarytool store-credentials ghost-notary --apple-id you@example.com --team-id TEAMID

RADAR_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
RADAR_NOTARY_PROFILE="ghost-notary" \
Scripts/release.sh
```

This signs with the hardened runtime and a secure timestamp, notarizes and staples both the app and the disk image. An *Apple Development* certificate is not enough — Gatekeeper only trusts *Developer ID Application* certificates for apps distributed outside the App Store.

## 4. Publish

With the [GitHub CLI](https://cli.github.com):

```sh
VERSION=2.0.0
git tag -a "v$VERSION" -m "Ghost Process Sniper $VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" \
  "dist/release/GhostProcessSniper-$VERSION.dmg" \
  "dist/release/GhostProcessSniper-$VERSION.dmg.sha256" \
  --title "Ghost Process Sniper $VERSION" \
  --notes-file /tmp/release-notes.md
```

Write the notes from the changelog entry, and include the checksum and the first-launch instructions for ad-hoc builds.
