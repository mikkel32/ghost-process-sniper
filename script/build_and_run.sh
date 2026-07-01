#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="GhostProcessSniper"
APP_NAME="Ghost Process Sniper"
BUNDLE_ID="com.local.GhostProcessSniper"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true

bundle_app() {
  "$ROOT_DIR/Scripts/bundle-app.sh" >/dev/null
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    bundle_app
    open_app
    ;;
  --debug|debug)
    bundle_app
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    bundle_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PRODUCT_NAME\""
    ;;
  --telemetry|telemetry)
    bundle_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    bundle_app
    open_app
    sleep 1
    pgrep -x "$PRODUCT_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
