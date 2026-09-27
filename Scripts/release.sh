#!/usr/bin/env bash
# Builds the distributable installer: dist/release/GhostProcessSniper-<version>.dmg and its .sha256.
#
# The app is a universal binary (Apple silicon + Intel) compiled in an isolated SwiftPM build
# directory under ~/Library/Caches, so a stale or moved .build never leaks into a release. It is ad-hoc signed unless a
# Developer ID identity is provided; with a notarytool keychain profile it is also notarized:
#
#   RADAR_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   RADAR_NOTARY_PROFILE="ghost-notary" Scripts/release.sh
#
# RADAR_REQUIRE_DMG_LAYOUT=1 makes a missing installer-window layout an error instead of a
# warning; the release workflow sets it so a published image always has its artwork.
#
# Everything is assembled and signed in a temporary directory (iCloud Drive folders re-tag app
# bundles with Finder info that codesign rejects); only the finished files are copied to
# dist/release. The running app and dist/Ghost Process Sniper.app are never touched.
# See Docs/Releasing.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT/dist/release"
WORK_BASE="${TMPDIR:-/tmp}"
WORK_BASE="${WORK_BASE%/}"
WORK_DIR="$(mktemp -d "$WORK_BASE/gps-release.XXXXXX")"
DEVICE=""
export CONFIGURATION=release
export RADAR_DIST_DIR="$WORK_DIR/app"
export RADAR_ARCHS="${RADAR_ARCHS-arm64 x86_64}"
# Outside the checkout: a synced folder can evict or re-tag intermediate build files mid-build.
export RADAR_SCRATCH_PATH="${RADAR_SCRATCH_PATH:-$HOME/Library/Caches/GhostProcessSniper/release-build}"
source "$ROOT/Scripts/lib/project.sh"

NOTARY_PROFILE="${RADAR_NOTARY_PROFILE:-}"
VOLUME_NAME="$RADAR_APP_NAME"
DMG_NAME="$RADAR_PRODUCT-$RADAR_VERSION.dmg"
DMG_PATH="$WORK_DIR/$DMG_NAME"
BACKGROUND="$ROOT/Packaging/dmg-background.tiff"

step() { printf '\n==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet 2>/dev/null || hdiutil detach "$DEVICE" -force -quiet 2>/dev/null || true
  fi
  case "$WORK_DIR" in
    "$WORK_BASE"/gps-release.*) rm -rf -- "$WORK_DIR" ;;
  esac
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Runs a command, stopping it after the given number of seconds.
with_timeout() {
  local seconds="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$seconds"; kill -TERM "$pid" 2>/dev/null ) &
  local watchdog=$!
  local status=0
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$status"
}

notarize() {
  local target="$1" upload="$1"
  if [[ -d "$target" ]]; then
    upload="$WORK_DIR/notarize-$(basename "$target" .app).zip"
    /usr/bin/ditto -c -k --keepParent "$target" "$upload"
  fi
  step "Notarizing $(basename "$target")"
  xcrun notarytool submit "$upload" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$target"
}

[[ -f "$RADAR_ICON" && -f "$BACKGROUND" ]] || fail "Release artwork is missing; run: swift Packaging/render-artwork.swift"
if [[ -n "$NOTARY_PROFILE" && "$RADAR_SIGN_IDENTITY" == "-" ]]; then
  fail "Notarization needs RADAR_SIGN_IDENTITY set to a Developer ID Application identity."
fi
if [[ -e "/Volumes/$VOLUME_NAME" ]]; then
  fail "A volume named \"$VOLUME_NAME\" is already mounted. Eject it and try again."
fi
mkdir -p "$RELEASE_DIR"

step "Building $RADAR_APP_NAME $RADAR_VERSION (${RADAR_ARCHS:-host architecture}, release)"
bash "$ROOT/Scripts/bundle-app.sh" >/dev/null
APP="$RADAR_APP_BUNDLE"
EXECUTABLE="$APP/Contents/MacOS/$RADAR_PRODUCT"

step "Validating the application bundle"
BUILT_ARCHS="$(lipo -archs "$EXECUTABLE")"
for arch in $RADAR_ARCHS; do
  [[ " $BUILT_ARCHS " == *" $arch "* ]] || fail "Executable is missing $arch (found: $BUILT_ARCHS)."
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$RADAR_VERSION" ]] \
  || fail "Bundle version does not match $RADAR_VERSION."
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || fail "Bundle has no icon."
/usr/bin/codesign --verify --deep --strict "$APP"
printf 'Architectures: %s\nSignature: %s\n' "$BUILT_ARCHS" "$RADAR_SIGN_IDENTITY" >&2

if [[ -n "$NOTARY_PROFILE" ]]; then notarize "$APP"; fi

step "Assembling the disk image"
SOURCE="$WORK_DIR/source"
mkdir -p "$SOURCE/.background"
/usr/bin/ditto --norsrc --noextattr "$APP" "$SOURCE/$RADAR_APP_NAME.app"
ln -s /Applications "$SOURCE/Applications"
cp -X "$BACKGROUND" "$SOURCE/.background/background.tiff"

WRITABLE="$WORK_DIR/writable.dmg"
SIZE_MB=$(( $(du -sm "$SOURCE" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$SOURCE" -fs HFS+ -format UDRW \
  -size "${SIZE_MB}m" -ov "$WRITABLE"
ATTACHED="$(hdiutil attach -readwrite -noverify -noautoopen "$WRITABLE")"
DEVICE="$(printf '%s\n' "$ATTACHED" | awk '/Apple_HFS/ { print $1; exit }')"
MOUNT="$(printf '%s\n' "$ATTACHED" | awk -F'\t' '/Apple_HFS/ { print $NF; exit }' | sed 's/[[:space:]]*$//')"
[[ -n "$DEVICE" && -d "$MOUNT" ]] || fail "Could not mount the writable image."

step "Arranging the installer window (Finder)"
if with_timeout 90 osascript "$ROOT/Scripts/lib/dmg_layout.applescript" "$VOLUME_NAME" "$RADAR_APP_NAME"; then
  sleep 1
fi
if [[ -f "$MOUNT/.DS_Store" ]]; then
  printf 'Installer window layout applied.\n' >&2
else
  [[ "${RADAR_REQUIRE_DMG_LAYOUT:-0}" != 1 ]] || fail "Finder did not save the installer window layout."
  printf 'warning: Finder did not save a window layout (Automation permission for Finder may be\n' >&2
  printf '         missing). The disk image still installs normally, with a default window.\n' >&2
fi

# Finder deletes .VolumeIcon.icns while it arranges the window, so the volume icon goes in afterwards.
cp -X "$RADAR_ICON" "$MOUNT/.VolumeIcon.icns"
/usr/bin/SetFile -a C "$MOUNT"
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$DEVICE" -quiet || { sleep 3; hdiutil detach "$DEVICE" -force -quiet; }
DEVICE=""

step "Compressing $DMG_NAME"
hdiutil convert "$WRITABLE" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
if [[ "$RADAR_SIGN_IDENTITY" != "-" ]]; then
  /usr/bin/codesign --force --timestamp --sign "$RADAR_SIGN_IDENTITY" "$DMG_PATH"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then notarize "$DMG_PATH"; fi
hdiutil verify -quiet "$DMG_PATH"
( cd "$WORK_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256" )

rm -f "$RELEASE_DIR/$DMG_NAME" "$RELEASE_DIR/$DMG_NAME.sha256"
cp -X "$DMG_PATH" "$DMG_PATH.sha256" "$RELEASE_DIR/"
( cd "$RELEASE_DIR" && shasum -a 256 -c "$DMG_NAME.sha256" >/dev/null ) || fail "Copied disk image failed its checksum."

step "Done"
printf '%s\n' "$RELEASE_DIR/$DMG_NAME"
printf 'Size:   %s\n' "$(du -h "$RELEASE_DIR/$DMG_NAME" | cut -f1)" >&2
printf 'SHA256: %s\n' "$(cut -d' ' -f1 "$RELEASE_DIR/$DMG_NAME.sha256")" >&2
if [[ "$RADAR_SIGN_IDENTITY" == "-" ]]; then
  printf 'Signed ad hoc (not notarized): first launch needs Privacy & Security > Open Anyway.\n' >&2
fi
