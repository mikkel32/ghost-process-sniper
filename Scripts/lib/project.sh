#!/usr/bin/env bash
# Shared application identity for build, verification, and launch scripts.
RADAR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RADAR_PRODUCT="GhostProcessSniper"
RADAR_APP_NAME="Ghost Process Sniper"
RADAR_BUNDLE_ID="com.local.GhostProcessSniper"
RADAR_MINIMUM_SYSTEM="26.0"
RADAR_VERSION="${RADAR_VERSION:-2.0.0}"
RADAR_BUILD_NUMBER="${RADAR_BUILD_NUMBER:-2}"
RADAR_COPYRIGHT="Copyright © 2026 Mikkel Mynderup. MIT License."
RADAR_ICON="$RADAR_ROOT/Packaging/AppIcon.icns"

# Packaging knobs. Defaults produce the local, ad-hoc-signed development bundle in dist/.
#   RADAR_DIST_DIR       Directory that receives the .app bundle.
#   RADAR_ARCHS          Space-separated architectures, e.g. "arm64 x86_64" for a universal binary.
#   RADAR_SCRATCH_PATH   Separate SwiftPM build directory (keeps release builds isolated from .build).
#   RADAR_SIGN_IDENTITY  "-" for ad-hoc, or a "Developer ID Application: …" identity.
RADAR_DIST_DIR="${RADAR_DIST_DIR:-$RADAR_ROOT/dist}"
RADAR_ARCHS="${RADAR_ARCHS:-}"
RADAR_SCRATCH_PATH="${RADAR_SCRATCH_PATH:-}"
RADAR_SIGN_IDENTITY="${RADAR_SIGN_IDENTITY:--}"
RADAR_APP_BUNDLE="$RADAR_DIST_DIR/$RADAR_APP_NAME.app"

radar_configuration() {
  case "${CONFIGURATION:-release}" in
    debug|release) printf '%s\n' "${CONFIGURATION:-release}" ;;
    *) printf 'CONFIGURATION must be debug or release.\n' >&2; return 2 ;;
  esac
}

# Prints one SwiftPM option per line for the configured architectures and scratch path.
radar_swift_build_options() {
  local arch
  for arch in $RADAR_ARCHS; do
    printf -- '--arch\n%s\n' "$arch"
  done
  if [[ -n "$RADAR_SCRATCH_PATH" ]]; then
    printf -- '--scratch-path\n%s\n' "$RADAR_SCRATCH_PATH"
  fi
}
