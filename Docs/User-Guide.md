# User guide

Ghost Process Sniper lives in the menu bar and keeps watching while its console window is closed. This guide walks through the console section by section.

## Opening the console

Choose **Open Dashboard** from the menu-bar popover, or open **Ghost Process Sniper** from Applications again — a second launch brings the existing console forward instead of starting a new copy. Closing the window leaves the monitor running. Quit from the popover.

The menu-bar icon is a small scope that changes color with the overall state: grey when quiet, orange when something is worth watching, red when a process needs attention.

## Overview

The **Overview** separates current issues from early warnings. Its summary cards are shortcuts: **Memory** opens processes ordered by footprint, **Leaks** opens the growth filter, and **Duplicates** opens the overlap review. Expand **Why this recommendation** to inspect the supporting evidence.

Process rows explain the cause using memory, CPU, GPU, and sustained growth. The levels **Stable**, **Observe**, **Review**, **Urgent**, and **Measuring** summarize how much attention a family needs. Cached or missing measurements never become new growth samples.

## All Processes

**All Processes** includes every family in the current query, not just the sidebar's short priority list. Use the filters and sort menu to narrow the list, then select a row to inspect it.

### Searching

Press **⌘F** anywhere in the console and start typing; results open on this page. Search covers every running process, not only the families the radar tracks:

- **Words** match in any order, ignoring case and accents, across process names, helper names, command lines, and executable paths. A row that matched through a helper or its command says so underneath its name.
- **Numbers** match a PID or a listening port as well as text, so `5173` finds the dev server serving that port.
- **Tracked families come first**, then *Other running processes* — apps outside the current watch scope. They show memory, CPU, and PID, and their context menu copies the PID or command line or reveals the app in Finder.
- **Close matches** appear only when nothing matches exactly: `crhome` finds Chrome and `vsc` finds Visual Studio Code.
- **Return** opens the best-matching family.

Narrow a search with filters; the chips under the filter bar show how the search was understood:

| Filter | Meaning |
| --- | --- |
| `"exact phrase"` | Words that must appear together. |
| `-word` | Exclude matches, for example `chrome -helper`. |
| `name:` `cmd:` `path:` `user:` `kind:` | Search one field only. |
| `pid:123,456` `port:3000` | Exact identities. |
| `cpu>20` `mem>1.5gb` `gpu>5` `threads>100` | Measurements; memory without a unit means MB. |
| `leak>2` `children>3` | Growth in MB/min and helper count (tracked families only). |
| `is:attention` `is:hot` `is:critical` `is:quiet` `is:leaking` `is:killable` `is:dev` `is:duplicate` | Radar states (tracked families only). |
| `is:mine` `is:system` `is:tracked` `is:untracked` | Ownership and tracking. |

Any unambiguous prefix works for `is:` filters, so `is:leak` means `is:leaking`. A half-typed filter such as `cpu>` is ignored until it is complete.

A *family* groups related processes — an app and its helpers, or a dev server and the workers it spawned. Opening a row never stops anything.

## Temperatures and "What's heating your Mac?"

**Hardware temperatures** shows measured CPU and GPU Celsius separately from the macOS thermal state. These are the hottest readable sensors for each component, not invented per-process temperatures. Sensor maps for M1, M2, and Intel Macs are verified; M3 and M4 Macs use catalog maps, and newer Apple chips use sensors found on the Mac itself; the panel notes when a map is unverified. Unsupported, missing, invalid, or stale readings show **Unavailable** with the reason. Sensor access is read-only and needs no administrator helper.

**What's heating your Mac?** puts the current temperature beside a named workload and a concrete next step. The panel distinguishes likely workload contributors, modest activity, incomplete evidence, and expired readings. Rows show real application icons, grouped helpers, CPU capacity, and reported GPU activity. CPU capacity uses all active logical processors; raw per-process CPU remains available in the detail sheet.

- **Scan now** takes fresh readings. **Combined**, **CPU**, and **GPU** switch the ranking.
- **Temperature history & measurement details** shows sensor traces.
- **Inspect app** shows the current evidence and the sampled processes behind an app.
- **Compare readings** saves a baseline. Change optional work yourself, then compare fresh CPU/GPU activity and temperatures after at least 15 seconds. The comparison expires after three minutes and never treats a missing app as zero load.

- **Stop …** appears for your own work when it can be stopped: on the card when the same app or job keeps showing up while the Mac is warm, and in its detail sheet. The label names the process family the stop will act on, which can be a helper rather than the app itself. It opens the usual stop preview; nothing stops until you confirm there. It is never offered for macOS services.

Scan, Inspect, and Compare never stop or pause apps. Activity is evidence, not a measurement of an application's temperature or heat share. The ⓘ beside the panel title explains how to read the numbers; [Thermals](Thermals.md) documents the rules behind them.

## Duplicates, Incidents, Rules, Engine

- **Duplicates** finds overlapping copies of the same work — for example several identical dev servers or watchers left running from old terminal sessions.
- **Incidents** is the local history of leaks, spikes, and runaway families, stored in a SQLite database on your Mac.
- **Rules** let you tell the radar to notify, highlight, snooze, ignore, or suggest stopping matching families. Rules only produce suggestions; a rule can never stop a process by itself.
- **Engine** shows the monitor's own health: refresh cost, sampling cadence, UI smoothness, storage timings, and the CPU and memory Ghost Process Sniper itself is using. **Copy Diagnostics** puts a text report on the clipboard for bug reports.

## Stopping a process safely

Stopping always starts from a preview and always needs your confirmation.

In a family's details, **Precision targets** previews one contributor at a time; a family preview covers the wider process tree. The preview pins exact PID and start-time identities, the strategy, and its delay, and expires after 60 seconds. New descendants that appear after the preview are excluded rather than silently added. Ownership, protected-process, recycled-PID, and escalation checks run again at confirmation. The standard strategy asks politely first (`SIGTERM`) and escalates only if the process does not exit.

Expiry prevents starting an intervention; it does not undo one already admitted. High usage alone is not a reason to stop work you need.

### Knowing what a stop will do

Before anything is stopped, Ghost Process Sniper works out what the process actually is from its name, path, and command line. The preview's first page explains the result in plain words (**What will happen**, **Before you stop it**, **You get back**), and the family page shows the same summary before you open a preview.

| Workload | How it is stopped | Force |
| --- | --- | --- |
| Apps and document editors (Xcode, Pages, VS Code…) | Asked to quit like **⌘Q**, so they can save and close their own helpers; anything left gets `SIGTERM` | Only if you allow it |
| Databases (Postgres, MySQL, Redis, Mongo, Elasticsearch…) | `SIGTERM` with 12 seconds to flush data | Only if you allow it |
| Container runtimes (Docker, OrbStack, Colima…) | `SIGTERM` with 15 seconds; every container stops | Only if you allow it |
| git mid-operation, package installs | `SIGTERM`; warns about `.git/index.lock` or half-installed dependencies | Only if you allow it |
| Dev servers | Interrupted like **Ctrl-C** (`SIGINT`) first; freed ports are listed | Automatic for survivors |
| Builds, model runners, other processes | `SIGTERM`, then force for survivors | Automatic for survivors |

"Only if you allow it" means the **Report anything that refuses to stop** switch starts on. If something is still running afterwards — often an app waiting on a save prompt — check it, then use **Force Stop** in the result.

If a supervisor such as **nodemon**, **pm2**, **forever**, **watchexec**, **cargo watch**, or a launchd agent would restart the process, the preview says so and suggests stopping the supervisor instead. After a stop, Ghost watches briefly and tells you if the process came back and who restarted it.

Waiting always ends as soon as the processes exit, so long grace periods only cost time when something is genuinely slow to shut down.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Search all processes | ⌘F |
| Scan now | ⌘R |
| Overview / All Processes | ⌘1 / ⌘2 |
| Duplicates / Incidents / Rules | ⌘3 / ⌘4 / ⌘5 |
| Back / Forward | ⌘[ / ⌘] |
| Next / previous matching family | ⌘↓ / ⌘↑ |
| Inspector for a selected family | ⌥⌘I |
| Settings | ⌘, |

The sidebar keeps Settings and the Quick Guide visible; the guide also opens from the toolbar's **More** menu. Clear filters to recover from an empty search. When a selected process exits, the console offers a route back to running processes or incident history.

## Settings and data

Settings cover alerts, protection style and what to watch, family grouping, performance (adaptive sampling that tightens automatically under memory pressure), and startup options such as **Launch at login**. The **Safety boundary** section states the app's limits: it acts on your own processes only, installs no privileged helper, and always leaves the final action to you.

Settings and monitoring history live in a single local database at `~/Library/Application Support/Ghost Process Sniper/Radar.sqlite`. To reset everything, quit the app and delete that folder; **Restore Smart Defaults** in Settings resets only the settings.
