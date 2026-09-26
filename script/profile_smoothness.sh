#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="GhostProcessSniper"
APP_NAME="Ghost Process Sniper"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
LOG_DIR="$ROOT_DIR/logs"
DURATION_SECONDS="${1:-20}"
CAPTURE_SAMPLE=1

if [[ "${2:-}" == "--no-sample" || "${1:-}" == "--no-sample" ]]; then
  CAPTURE_SAMPLE=0
  if [[ "${1:-}" == "--no-sample" ]]; then
    DURATION_SECONDS="20"
  fi
fi

mkdir -p "$LOG_DIR"
"$ROOT_DIR/Scripts/bundle-app.sh" >/dev/null

PID="$(pgrep -x "$PRODUCT_NAME" | head -n 1 || true)"
if [[ -z "$PID" ]]; then
  # Smoothness regressions live in the console layer tree, not the tiny
  # menu-bar surface, so launch the real dashboard for representative data.
  /usr/bin/open -n "$APP_BUNDLE" --args --console
  sleep 1
  PID="$(pgrep -x "$PRODUCT_NAME" | head -n 1 || true)"
fi

if [[ -z "$PID" ]]; then
  echo "Ghost Process Sniper is not running after launch." >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/smoothness-$STAMP.log"
SAMPLE_FILE="$LOG_DIR/smoothness-$STAMP.sample.txt"

echo "Profiling PID $PID for ${DURATION_SECONDS}s"
echo "Logs: $LOG_FILE"
echo "Sample: $SAMPLE_FILE"

(
  /usr/bin/log stream \
    --style compact \
    --predicate 'subsystem == "com.local.GhostProcessSniper" && category == "performance"'
) >"$LOG_FILE" 2>&1 &
LOG_PID="$!"

sleep "$DURATION_SECONDS"
if [[ "$CAPTURE_SAMPLE" -eq 1 ]]; then
  /usr/bin/sample "$PID" 3 -file "$SAMPLE_FILE" >/dev/null 2>&1 || true
else
  echo "Sample capture skipped (--no-sample)." >"$SAMPLE_FILE"
fi
kill "$LOG_PID" >/dev/null 2>&1 || true

echo "Recent smoothness lines:"
tail -n 40 "$LOG_FILE" || true
