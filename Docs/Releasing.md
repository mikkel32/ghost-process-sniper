# Releasing

A release is a universal `.dmg` attached to a GitHub release, plus its SHA-256 checksum and a build-provenance attestation. GitHub Actions builds it from the tag; a person tests the draft and publishes it. Publishing updates the website.

## 1. Prepare

1. Update `RADAR_VERSION` (and `RADAR_BUILD_NUMBER`) in `Scripts/lib/project.sh`.
2. Turn `## [Unreleased]` in `CHANGELOG.md` into `## [x.y.z] — YYYY-MM-DD`. Its text becomes the release notes, so start with a one-paragraph summary.
3. Run `Scripts/verify.sh` and preview the notes with `Scripts/release_notes.sh`.
4. If the icon, installer or website artwork changed, run `swift Packaging/render-artwork.swift` and commit the results. New screenshots go in `Docs/Assets/`; the README and the website share them.
5. Merge to `main`.

## 2. Tag

```sh
VERSION=2.1.0
git tag -a "v$VERSION" -m "Ghost Process Sniper $VERSION"
git push origin "v$VERSION"
```

The [Release workflow](../.github/workflows/release.yml) then:

- checks that the tag matches `RADAR_VERSION` and that the changelog has an entry for it,
- runs `Scripts/verify.sh`,
- builds the universal disk image with `Scripts/release.sh` (a missing installer-window layout fails the build),
- attests its build provenance, so anyone can check the file with `gh attestation verify`,
- keeps the image with the workflow run for 30 days,
- opens a **draft** release with the image, its checksum, and notes from `Scripts/release_notes.sh`.

Running the workflow by hand (**Actions › Release › Run workflow**) builds and attests an image from any branch without creating a release.

## 3. Test the draft and publish

Download the image from the draft, then:

```sh
shasum -a 256 -c GhostProcessSniper-$VERSION.dmg.sha256
gh attestation verify GhostProcessSniper-$VERSION.dmg --repo mikkel32/ghost-process-sniper
```

Open it, check the installer window, drag the app to Applications, and launch it. When it works, publish:

```sh
gh release edit "v$VERSION" --draft=false --latest
```

Publishing runs the [Website workflow](../.github/workflows/pages.yml), which rebuilds <https://mikkel32.github.io/ghost-process-sniper/> with the new download link, version, size and checksum.

## Building locally

`Scripts/release.sh` builds the same image on your Mac, in `dist/release/`. It:

- compiles an arm64 + x86_64 release build in `~/Library/Caches/GhostProcessSniper/release-build`, isolated from day-to-day builds and from folder syncing,
- bundles the app with its icon and metadata, signs it, and checks its architectures, version, and signature,
- builds a drag-to-Applications disk image with a custom background and volume icon,
- compresses and verifies the image and writes the checksum.

Bundling, signing, and disk-image assembly happen in a temporary directory; only the finished `.dmg` and checksum are copied to `dist/release`. It never touches `dist/Ghost Process Sniper.app` or a running copy of the app.

The installer window layout is applied through Finder. The first run asks for permission to control Finder; if that permission is missing, the script prints a warning and still produces a working disk image with a plain window (set `RADAR_REQUIRE_DMG_LAYOUT=1` to make that an error).

Override the architectures with `RADAR_ARCHS="arm64" Scripts/release.sh` for a faster, Apple-silicon-only build.

## Signing and notarization (optional)

By default the app is signed ad hoc, so users confirm the first launch in **Privacy & Security** (the README explains how). With a paid Apple Developer account you can ship a build that opens without any warning:

```sh
# One-time: store notarization credentials in the keychain.
xcrun notarytool store-credentials ghost-notary --apple-id you@example.com --team-id TEAMID

RADAR_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
RADAR_NOTARY_PROFILE="ghost-notary" \
Scripts/release.sh
```

This signs with the hardened runtime and a secure timestamp, notarizes and staples both the app and the disk image. An *Apple Development* certificate is not enough — Gatekeeper only trusts *Developer ID Application* certificates for apps distributed outside the App Store. To do this in the Release workflow instead, import the certificate into a temporary keychain from repository secrets before `Scripts/release.sh` runs.
