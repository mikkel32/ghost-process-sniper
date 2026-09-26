#!/usr/bin/env bash
# Shared application identity for build, verification, and launch scripts.
RADAR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RADAR_PRODUCT="GhostProcessSniper"
RADAR_APP_NAME="Ghost Process Sniper"
RADAR_BUNDLE_ID="com.local.GhostProcessSniper"
RADAR_MINIMUM_SYSTEM="26.0"
RADAR_VERSION="0.1.0"
RADAR_BUILD_NUMBER="1"
RADAR_APP_BUNDLE="$RADAR_ROOT/dist/$RADAR_APP_NAME.app"

radar_configuration() {
  case "${CONFIGURATION:-release}" in
    debug|release) printf '%s\n' "${CONFIGURATION:-release}" ;;
    *) printf 'CONFIGURATION must be debug or release.\n' >&2; return 2 ;;
  esac
}
