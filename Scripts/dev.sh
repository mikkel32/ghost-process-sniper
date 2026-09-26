#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"
MODE="${1:-run}"
MODE="${MODE#--}"

case "$MODE" in
  build|run|restart|debug|verify|logs|telemetry) ;;
  *) printf 'usage: %s [build|run|restart|debug|verify|logs|telemetry]\n' "$0" >&2; exit 2 ;;
esac

case "$MODE" in
  verify) exec bash "$RADAR_ROOT/Scripts/verify.sh" ;;
  logs) exec /usr/bin/log stream --info --style compact --predicate "process == \"$RADAR_PRODUCT\"" ;;
  telemetry) exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$RADAR_BUNDLE_ID\"" ;;
esac

bash "$RADAR_ROOT/Scripts/bundle-app.sh" >/dev/null
case "$MODE" in
  build) printf '%s\n' "$RADAR_APP_BUNDLE" ;;
  debug) exec lldb -- "$RADAR_APP_BUNDLE/Contents/MacOS/$RADAR_PRODUCT" ;;
  run)
    if pgrep -x "$RADAR_PRODUCT" >/dev/null; then
      printf 'Updated bundle is ready. The existing instance is still running; use Scripts/dev.sh restart to replace it.\n'
    else
      /usr/bin/open -n "$RADAR_APP_BUNDLE" --args --console
    fi
    ;;
  restart)
    # An explicit restart happens only after a successful, verified build.
    pkill -TERM -x "$RADAR_PRODUCT" 2>/dev/null || true
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      if ! pgrep -x "$RADAR_PRODUCT" >/dev/null; then
        /usr/bin/open -n "$RADAR_APP_BUNDLE" --args --console
        exit 0
      fi
      sleep 0.2
    done
    printf 'The running app has not exited. The new bundle is ready; no force-stop was used.\n' >&2
    exit 1
    ;;
esac
