#!/usr/bin/env bash
set -euo pipefail

PID_FILE="${TMPDIR:-/tmp}/ghost-process-sniper-fixture.pids"

case "${1:-start}" in
  start)
    : >"$PID_FILE"
    /usr/bin/python3 - <<'PY' &
import time
data = []
while True:
    data.append(bytearray(16 * 1024 * 1024))
    time.sleep(0.25)
PY
    echo "$!" >>"$PID_FILE"

    /usr/bin/python3 - <<'PY' &
import time
x = 0
while True:
    x = (x + 1) % 1000003
PY
    echo "$!" >>"$PID_FILE"

    /usr/bin/python3 - <<'PY' &
import os
import signal
import subprocess
import time

child = subprocess.Popen([
    "/usr/bin/python3",
    "-c",
    "import time\nchunks=[]\nwhile True:\n chunks.append(bytearray(4*1024*1024)); time.sleep(1)"
])

def stop(signum, frame):
    try:
        child.terminate()
    finally:
        raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while True:
    time.sleep(60)
PY
    echo "$!" >>"$PID_FILE"

    if command -v node >/dev/null 2>&1; then
      node -e 'const chunks=[]; setInterval(()=>chunks.push(Buffer.alloc(8*1024*1024)), 500); setInterval(()=>{}, 1000)' &
      echo "$!" >>"$PID_FILE"
    fi

    echo "Spawned Ghost Process Sniper fixture PIDs: $(tr '\n' ' ' < "$PID_FILE")"
    ;;
  stop)
    if [[ -f "$PID_FILE" ]]; then
      xargs kill <"$PID_FILE" >/dev/null 2>&1 || true
      rm -f "$PID_FILE"
    fi
    echo "Stopped Ghost Process Sniper fixture."
    ;;
  *)
    echo "usage: $0 [start|stop]" >&2
    exit 2
    ;;
esac
