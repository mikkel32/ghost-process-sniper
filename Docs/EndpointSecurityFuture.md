# Optional Endpoint Security Watcher

Ghost Process Sniper v3 intentionally stays local, advisory, and unprivileged.
The radar uses `libproc` polling plus a local SQLite timeline because that works
in a normal menu-bar app without admin setup, Full Disk Access prompts, or
system-extension packaging.

Endpoint Security is still the right future layer if the app needs precise
process lifecycle events. A future privileged watcher should subscribe to
notify-only `exec`, `fork`, `exit`, and signal events, then feed process
identities into the same `ProcessMonitor` model. It should be optional: if the
entitlement, root/system-extension install, or TCC approval is missing, the app
should keep the current `libproc` + SQLite radar active.

The future watcher must remain an event source, not the scoring brain. Baselines,
rules, incidents, alert state, and kill-plan revalidation should stay in the
current core so the app has one advisory model regardless of whether privileged
event capture is installed.

Do not parse `eslogger` output in the app. Apple describes `eslogger` as a
diagnostic tool rather than a stable application API, so a real implementation
should bind Endpoint Security directly.

## v8 Scanner Boundary

v8 keeps the shipping implementation unprivileged and uses a hyper-efficient
polling radar instead of privileged process events. The app now treats native
sampling as a set of budgeted lanes:

- cheap PID/identity/metric probes run every refresh;
- command/path/argv telemetry is cached and refreshed only for new, changed,
  hot, focused, or expired-cache processes;
- cwd/file-descriptor/socket/port forensics is queued behind a scanner deadline;
- inaccessible forensics is negative-cached so protected processes do not burn
  repeated work every tick.

A future Endpoint Security watcher should only replace the "which PIDs changed"
hint source. It should publish exec/fork/exit/signal events into the same
`ProcessMonitor` refresh planner, letting the existing sampler skip more quiet
PIDs without moving scoring, rules, persistence, notifications, or kill safety
into a privileged component.

The optional watcher should be notify-only, user-controlled, and removable. If
its entitlement, system-extension install, root privilege, or Full Disk Access
setup is missing, the menu-bar app must keep running with the v8 unprivileged
scanner and show the watcher as unavailable rather than degraded or broken.
