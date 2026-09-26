#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/project.sh"
CONFIGURATION="$(radar_configuration)"
DIST_DIR="$RADAR_ROOT/dist"
STAGING_DIR=""

cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$STAGING_DIR" ]]; then
    if [[ -d "$STAGING_DIR/previous.app" && ! -e "$RADAR_APP_BUNDLE" ]]; then
      if ! mv "$STAGING_DIR/previous.app" "$RADAR_APP_BUNDLE"; then
        printf 'Rollback needs attention; previous bundle preserved at %s\n' "$STAGING_DIR/previous.app" >&2
        exit 1
      fi
    fi
    # Only remove this invocation's generated staging directory.
    case "$STAGING_DIR" in
      "$DIST_DIR"/.radar-stage.*) rm -rf -- "$STAGING_DIR" ;;
    esac
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -L "$RADAR_APP_BUNDLE" ]]; then
  printf 'Refusing to replace a symbolic-link application bundle.\n' >&2
  exit 1
fi

swift build --package-path "$RADAR_ROOT" --configuration "$CONFIGURATION" --product "$RADAR_PRODUCT" >&2
BUILD_DIR="$(swift build --package-path "$RADAR_ROOT" --configuration "$CONFIGURATION" --show-bin-path)"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.radar-stage.XXXXXX")"
STAGED_APP="$STAGING_DIR/$RADAR_APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS"
cp "$BUILD_DIR/$RADAR_PRODUCT" "$STAGED_APP/Contents/MacOS/$RADAR_PRODUCT"
chmod +x "$STAGED_APP/Contents/MacOS/$RADAR_PRODUCT"

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$RADAR_PRODUCT</string>
  <key>CFBundleIdentifier</key><string>$RADAR_BUNDLE_ID</string>
  <key>CFBundleName</key><string>$RADAR_APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$RADAR_APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$RADAR_VERSION</string>
  <key>CFBundleVersion</key><string>$RADAR_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$RADAR_MINIMUM_SYSTEM</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >&2
/usr/bin/codesign --force --sign - "$STAGED_APP" >&2
/usr/bin/codesign --verify --strict "$STAGED_APP" >&2

if [[ -e "$RADAR_APP_BUNDLE" ]]; then
  mv "$RADAR_APP_BUNDLE" "$STAGING_DIR/previous.app"
fi
# An unsuccessful replacement triggers cleanup's rollback.
mv "$STAGED_APP" "$RADAR_APP_BUNDLE"
printf '%s\n' "$RADAR_APP_BUNDLE"
