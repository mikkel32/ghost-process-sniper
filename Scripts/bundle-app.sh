#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"
radar_configuration >/dev/null
mkdir -p "$RADAR_ROOT/dist"
exec python3 "$RADAR_ROOT/Scripts/lib/with_lock.py" \
  "$RADAR_ROOT/dist/.bundle.lock" bash "$RADAR_ROOT/Scripts/lib/bundle_impl.sh"
