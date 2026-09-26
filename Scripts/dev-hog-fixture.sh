#!/usr/bin/env bash
# A test bench for Ghost Process Sniper's stop strategies. Every fixture carries
# "ghost-fixture:<kind>" in its argv and leads its own process group, so `stop`
# only ever signals groups that still carry the marker, never a recycled PID.
# Runs with macOS's bash 3.2. See "Stop strategy test bench" in Docs/Development.md.
set -euo pipefail

PID_FILE="${TMPDIR:-/tmp}/ghost-process-sniper-fixture.pids"
PORT="${GHOST_FIXTURE_PORT:-51730}"
MARKER="ghost-fixture:"
ALL_KINDS="leak cpu ignore-term dev-server supervisor slow-db"

usage() {
  echo "usage: $0 start [${ALL_KINDS// /|}]... | status | stop" >&2
  exit 2
}

# True while any process in the group still carries the fixture marker.
group_alive() {
  ps -A -o pgid= -o command= | awk -v group="$1" -v marker="$MARKER" \
    '$1 == group && index($0, marker) { found = 1 } END { exit !found }'
}

recorded_groups() {
  [[ -f "$PID_FILE" ]] || return 0
  awk '{ print $2 }' "$PID_FILE"
}

launch() {
  local kind="$1"
  case "$kind" in
    leak)
      /usr/bin/python3 - "${MARKER}leak" <<'PY' &
import os, time
os.setpgrp()
MiB = 1024 * 1024
chunks = []
# Grows about 64 MiB/s, then plateaus at 1.5 GiB so a laptop never starts swapping.
while len(chunks) * 16 * MiB < 1536 * MiB:
    chunk = bytearray(16 * MiB)
    chunk[::4096] = b"\x01" * len(range(0, len(chunk), 4096))
    chunks.append(chunk)
    time.sleep(0.25)
while True:
    time.sleep(60)
PY
      ;;
    cpu)
      /usr/bin/python3 - "${MARKER}cpu" <<'PY' &
import os
os.setpgrp()
x = 0
while True:
    x = (x + 1) % 1000003
PY
      ;;
    ignore-term)
      /usr/bin/python3 - "${MARKER}ignore-term" <<'PY' &
import os, signal
os.setpgrp()
signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGINT, signal.SIG_IGN)
x = 0
while True:
    x = (x + 1) % 1000003
PY
      ;;
    dev-server)
      # argv0 "vite" makes it read as a dev server; Ctrl-C (SIGINT) is its only clean exit.
      (exec -a vite /usr/bin/python3 - "${MARKER}dev-server" "$PORT" <<'PY'
import os, signal, socket, sys
os.setpgrp()
signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGINT, lambda *_: os._exit(0))
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(sys.argv[2])))
server.listen()
while True:
    connection, _ = server.accept()
    connection.recv(4096)
    connection.sendall(b"HTTP/1.0 200 OK\r\n\r\nghost fixture\n")
    connection.close()
PY
      ) &
      ;;
    supervisor)
      # "nodemon" in argv makes it read as a supervisor watching its "node" child.
      /usr/bin/python3 - "${MARKER}supervisor" nodemon <<'PY' &
import os, subprocess, sys, time
os.setpgrp()
child_code = "import time\nwhile True: time.sleep(60)"
while True:
    child = subprocess.Popen(["node", "-c", child_code, "ghost-fixture:supervisor-child"],
                             executable=sys.executable)
    child.wait()
    time.sleep(0.5)
PY
      ;;
    slow-db)
      # argv0 "postgres" makes it read as a database; it takes 4 s to shut down.
      (exec -a postgres /usr/bin/python3 - "${MARKER}slow-db" <<'PY'
import os, signal, time
os.setpgrp()
stopping = []
signal.signal(signal.SIGTERM, lambda *_: stopping.append(time.monotonic()))
while not stopping or time.monotonic() - stopping[0] < 4:
    time.sleep(0.1)
PY
      ) &
      ;;
    *)
      echo "Unknown fixture kind: $kind" >&2
      usage
      ;;
  esac
  local pid=$!
  # The fixture moves into its own group first thing; record the group it leads.
  local pgid=""
  for _ in $(seq 1 40); do
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [[ "$pgid" == "$pid" ]] && break
    sleep 0.05
  done
  if [[ "$pgid" != "$pid" ]]; then
    echo "Fixture $kind (PID $pid) did not start its own process group; stopping it." >&2
    kill -KILL "$pid" 2>/dev/null || true
    return 1
  fi
  echo "$pid $pgid $kind" >>"$PID_FILE"
}

start() {
  for group in $(recorded_groups); do
    if group_alive "$group"; then
      echo "Fixtures from an earlier start are still running. Run '$0 stop' first." >&2
      exit 1
    fi
  done
  if [[ $# -eq 0 ]]; then
    set -- $ALL_KINDS
  fi
  : >"$PID_FILE"
  for kind in "$@"; do
    # One of each kind keeps the leak under its 1.5 GiB total.
    if awk -v kind="$kind" '$3 == kind { found = 1 } END { exit !found }' "$PID_FILE"; then
      continue
    fi
    launch "$kind"
  done
  echo "Started Ghost Process Sniper fixtures:"
  status
}

status() {
  if [[ ! -s "$PID_FILE" ]]; then
    echo "No fixtures recorded."
    return 0
  fi
  while read -r pid pgid kind; do
    if group_alive "$pgid"; then
      echo "  $kind: running (PID $pid, process group $pgid)"
      ps -A -o pid= -o pgid= -o rss= -o %cpu= -o command= | awk -v group="$pgid" -v marker="$MARKER" \
        '$2 == group && index($0, marker) { printf "      PID %s  %d MiB  %s%% CPU\n", $1, $3 / 1024, $4 }'
    else
      echo "  $kind: stopped (PID $pid)"
    fi
  done <"$PID_FILE"
}

stop() {
  local groups=""
  for group in $(recorded_groups); do
    if group_alive "$group"; then
      kill -TERM -- "-$group" 2>/dev/null || true
      groups="$groups $group"
    fi
  done
  # Some fixtures ignore SIGTERM or take longer than 3 s on purpose.
  for _ in $(seq 1 30); do
    local waiting=0
    for group in $groups; do
      if group_alive "$group"; then waiting=1; fi
    done
    [[ $waiting -eq 1 ]] || break
    sleep 0.1
  done
  for group in $groups; do
    if group_alive "$group"; then
      kill -KILL -- "-$group" 2>/dev/null || true
    fi
  done
  rm -f "$PID_FILE"
  echo "Stopped Ghost Process Sniper fixtures."
}

command="${1:-start}"
[[ $# -gt 0 ]] && shift
case "$command" in
  start) start "$@" ;;
  status) status ;;
  stop) stop ;;
  *) usage ;;
esac
