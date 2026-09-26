# User guide

Ghost Process Sniper lives in the menu bar and keeps watching while its console window is closed. This guide walks through the console section by section.

## Opening the console

Choose **Open Dashboard** from the menu-bar popover, or open **Ghost Process Sniper** from Applications again — a second launch brings the existing console forward instead of starting a new copy. Closing the window leaves the monitor running. Quit from the popover.

The menu-bar icon is a small scope that changes color with the overall state: grey when quiet, orange when something is worth watching, red when a process needs attention.

## Overview

The **Overview** separates current issues from early warnings. Its summary cards are shortcuts: **Memory** opens processes ordered by footprint, **Leaks** opens the growth filter, and **Duplicates** opens the overlap review. Expand **Why this recommendation** to inspect the supporting evidence.

Process rows explain the cause using memory, CPU, GPU, and sustained growth. The levels **Stable**, **Observe**, **Review**, **Urgent**, and **Measuring** summarize how much attention a family needs. Cached or missing measurements never become new growth samples.

## All Processes

**All Processes** includes every family in the current query, not just the sidebar's short priority list. Search by name, command, or executable path. Use the filters and sort menu to narrow the list, then select a row to inspect it.

A *family* groups related processes — an app and its helpers, or a dev server and the workers it spawned. Opening a row never stops anything.

## Temperatures and "What's heating your Mac?"

**Hardware temperatures** shows measured CPU and GPU Celsius separately from the macOS thermal state. These are the hottest readable sensors for each component, not invented per-process temperatures. The reader has model-specific mappings for M1, M2, and Intel Macs; the M1 Pro is live-tested. Unsupported, missing, invalid, or stale readings show **Unavailable**. Sensor access is read-only and needs no administrator helper.

**What's heating your Mac?** puts the current temperature beside a named workload and a concrete next step. The panel distinguishes likely workload contributors, modest activity, incomplete evidence, and expired readings. Rows show real application icons, grouped helpers, CPU capacity, and reported GPU activity. CPU capacity uses all active logical processors; raw per-process CPU remains available in the detail sheet.

- **Scan now** takes fresh readings. **Combined**, **CPU**, and **GPU** switch the ranking.
- **Temperature history & measurement details** shows sensor traces.
- **Inspect app** shows the current evidence and the sampled processes behind an app.
- **Compare readings** saves a baseline. Change optional work yourself, then compare fresh CPU/GPU activity and temperatures after at least 15 seconds. The comparison expires after three minutes and never treats a missing app as zero load.

None of these actions stop or pause apps. Activity is evidence, not a measurement of an application's temperature or heat share. See [Thermal insight and CPU clock correction](Thermal-Insight-2026-09-11.md).

## Duplicates, Incidents, Rules, Engine

- **Duplicates** finds overlapping copies of the same work — for example several identical dev servers or watchers left running from old terminal sessions.
- **Incidents** is the local history of leaks, spikes, and runaway families, stored in a SQLite database on your Mac.
- **Rules** let you tell the radar to notify, highlight, snooze, ignore, or suggest stopping matching families. Rules only produce suggestions; a rule can never stop a process by itself.
- **Engine** shows the monitor's own health: refresh cost, sampling cadence, UI smoothness, storage timings, and the CPU and memory Ghost Process Sniper itself is using. **Copy Diagnostics** puts a text report on the clipboard for bug reports.

## Stopping a process safely

Stopping always starts from a preview and always needs your confirmation.

In a family's details, **Precision targets** previews one contributor at a time; a family preview covers the wider process tree. The preview pins exact PID and start-time identities, the strategy, and its delay, and expires after 60 seconds. New descendants that appear after the preview are excluded rather than silently added. Ownership, protected-process, recycled-PID, and escalation checks run again at confirmation. The standard strategy asks politely first (`SIGTERM`) and escalates only if the process does not exit.

Expiry prevents starting an intervention; it does not undo one already admitted. High usage alone is not a reason to stop work you need.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Search all processes | ⌘F |
| Scan now | ⌘R |
| Overview | ⌘1 |
| Duplicates / Incidents / Rules / Engine | ⌘2 / ⌘3 / ⌘4 / ⌘5 |
| All Processes | ⌘6 |
| Next / previous matching family | ⌘↓ / ⌘↑ |
| Inspector for a selected family | ⌥⌘I |
| Settings | ⌘, |

The sidebar keeps Settings and the Quick Guide visible; the guide also opens from the toolbar's **More** menu. Clear filters to recover from an empty search. When a selected process exits, the console offers a route back to running processes or incident history.

## Settings and data

Settings cover alerts, protection style and what to watch, family grouping, performance (adaptive sampling that tightens automatically under memory pressure), and startup options such as **Launch at login**. The **Safety boundary** section states the app's limits: it acts on your own processes only, installs no privileged helper, and always leaves the final action to you.

Settings and monitoring history live in a single local database at `~/Library/Application Support/Ghost Process Sniper/Radar.sqlite`. To reset everything, quit the app and delete that folder; **Restore Smart Defaults** in Settings resets only the settings.
