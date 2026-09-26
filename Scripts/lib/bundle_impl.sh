#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/project.sh"
CONFIGURATION="$(radar_configuration)"
# Stage and sign outside the checkout: iCloud Drive and other File Provider folders re-tag
# .app directories with Finder info as soon as it is removed, and codesign rejects that.
STAGING_BASE="${TMPDIR:-/tmp}"
STAGING_BASE="${STAGING_BASE%/}"
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
      "$STAGING_BASE"/.radar-stage.*) rm -rf -- "$STAGING_DIR" ;;
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

SWIFT_OPTIONS=()
while IFS= read -r option; do SWIFT_OPTIONS+=("$option"); done < <(radar_swift_build_options)
# The ${name+...} form keeps an empty array valid under `set -u` in macOS's bash 3.2.
swift build --package-path "$RADAR_ROOT" --configuration "$CONFIGURATION" --product "$RADAR_PRODUCT" \
  ${SWIFT_OPTIONS[@]+"${SWIFT_OPTIONS[@]}"} >&2
BUILD_DIR="$(swift build --package-path "$RADAR_ROOT" --configuration "$CONFIGURATION" \
  ${SWIFT_OPTIONS[@]+"${SWIFT_OPTIONS[@]}"} --show-bin-path)"
STAGING_DIR="$(mktemp -d "$STAGING_BASE/.radar-stage.XXXXXX")"
STAGED_APP="$STAGING_DIR/$RADAR_APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS"
cp "$BUILD_DIR/$RADAR_PRODUCT" "$STAGED_APP/Contents/MacOS/$RADAR_PRODUCT"
chmod +x "$STAGED_APP/Contents/MacOS/$RADAR_PRODUCT"

ICON_PLIST=""
if [[ -f "$RADAR_ICON" ]]; then
  mkdir -p "$STAGED_APP/Contents/Resources"
  cp "$RADAR_ICON" "$STAGED_APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$RADAR_PRODUCT</string>
  $ICON_PLIST
  <key>CFBundleIdentifier</key><string>$RADAR_BUNDLE_ID</string>
  <key>CFBundleName</key><string>$RADAR_APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$RADAR_APP_NAME</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$RADAR_VERSION</string>
  <key>CFBundleVersion</key><string>$RADAR_BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>$RADAR_MINIMUM_SYSTEM</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>$RADAR_COPYRIGHT</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >&2
# Build products copied from a synced checkout can carry attributes that codesign rejects.
/usr/bin/xattr -cr "$STAGED_APP"
if [[ "$RADAR_SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign - "$STAGED_APP" >&2
else
  # Developer ID distribution requires the hardened runtime and a secure timestamp for notarization.
  /usr/bin/codesign --force --options runtime --timestamp --sign "$RADAR_SIGN_IDENTITY" "$STAGED_APP" >&2
fi
/usr/bin/codesign --verify --strict "$STAGED_APP" >&2

if [[ -e "$RADAR_APP_BUNDLE" ]]; then
  mv "$RADAR_APP_BUNDLE" "$STAGING_DIR/previous.app"
fi
# An unsuccessful replacement triggers cleanup's rollback.
mv "$STAGED_APP" "$RADAR_APP_BUNDLE"
printf '%s\n' "$RADAR_APP_BUNDLE"
