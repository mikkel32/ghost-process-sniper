# User guide

Ghost Process Sniper lives in the menu bar and keeps watching while its console window is closed. This guide walks through the menu bar, the console section by section, and exactly what happens when you stop something.

## The menu bar

The menu-bar icon is a small scope. Its shape carries the state as well as its colour, so it reads under colour filters too: a plain ring when quiet (it follows the menu bar's appearance), a filled orange centre at Watch, a red scope with heavier crosshairs at Hot, and a solid glowing red disc at Critical.

Click it for the popover. It leads with one verdict, then up to three culprits with their cause and numbers — or up to two early warnings, or a quiet line once the first scan is done — followed by CPU and GPU temperature and memory pressure. Culprit rows carry a [Quick Stop](#quick-stop) button; every row's context menu can show it in the console, snooze it or ignore it. An orange row appears only when history cannot be saved.

Right-click (or Control-click) the icon for a menu: the current status, Quick Stops for up to three culprits, **Open Console**, **Refresh Radar**, **Copy Diagnostics**, **Settings…** and **Quit**.

**Open Dashboard** in the popover opens the console, and so does opening **Ghost Process Sniper** from Applications again — a second launch brings the existing console forward instead of starting a new copy. Closing the window leaves the monitor running, and the console reopens where you left it. Quit from the popover's **More** menu or the status menu.

## Overview

The **Overview** leads with one verdict: what, if anything, needs doing. Its headline is the recommendation itself — or "Your Mac is running smoothly" — with the detail, a confidence note and **Why this recommendation** for the evidence. Its buttons open the family behind it and, when a stop fits, offer its Quick Stop; **Scan now** takes a fresh sample.

Below it:

- **Risk Queue** and **Warming Up**: families that need attention now, and early warnings. Risk rows show their Quick Stop on hover or keyboard focus; warming rows offer it only in the context menu, because an early warning is not yet a reason to stop.
- **Summary cards**: **Families** opens every family, **Needs review** the ones that need attention, **Leaks** the credible leaks, **Duplicates** the overlap review, and **Memory** the processes ordered by footprint.
- **Heat & CPU activity**: temperatures and the work behind them (see [Temperatures](#temperatures)). It moves up to second place, under the verdict, only while macOS reports serious throttling or the hottest sensor has stayed at 90 °C or more for 30 seconds, and moves back after a calm minute.
- **Where your resources go**: the Live Radar of the riskiest families, memory share, the memory pulse and recent incidents.

The levels **Stable**, **Observe**, **Review**, **Urgent** and **Measuring** summarize how much attention a family needs. A Hot or Critical level is held until the family has read lower for 20 seconds and then steps down one level at a time, so a family hovering around a threshold does not flicker.

## All Processes

**All Processes** is a table of every family in the current query, plus every other running process that matches a search. **Name**, **Memory**, **CPU** and **Status** sort both ways, and the toolbar's Sort menu stays in step with the headers. Rows multi-select and move with the arrow keys; **Return** or a double-click opens a family, and **Delete** previews a stop for the selected row. The context menu offers **Stop…** (disabled, with the reason, for another user's or a system process), **Show Details**, **Snooze**, **Ignore**, **Copy PID**, **Copy Command Line** and **Reveal in Finder**.

### Searching

Press **⌘F** anywhere in the console and start typing; results open on this page. Search covers every running process, not only the families the radar tracks:

- **Words** match in any order, ignoring case and accents, across process names, helper names, command lines, and executable paths. A row that matched through a helper or its command says so underneath its name.
- **Numbers** match a PID or a listening port as well as text, so `5173` finds the dev server serving that port.
- **Ports** are found even for a quiet server: a `port:` search has the listening ports of your processes read on the next scan.
- **Tracked families come first**, then processes outside the current watch scope. Those show memory, CPU and PID, and can be stopped through the same preview as any family.
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
| `is:attention` `is:hot` `is:critical` `is:quiet` `is:leaking` `is:killable` `is:dev` `is:duplicate` | Radar states (tracked families only); `is:stoppable` means `is:killable`. |
| `is:mine` `is:system` `is:tracked` `is:untracked` | Ownership and tracking. |

Any unambiguous prefix works for `is:` filters, so `is:leak` means `is:leaking`. A half-typed filter such as `cpu>` is ignored until it is complete.

A *family* groups related processes — an app and its helpers, or a dev server and the workers it spawned. Language servers, databases, test runners, dev servers and notebook kernels that an editor starts are families of their own, so a leaking language server shows up as itself rather than as the editor. Opening a row never stops anything.

## Family pages

A family page leads with the engine's judgement:

- **The verdict** — for example "Likely leak", "Leaking under GC", "Running away", "Probably forgotten" or "Using a lot of memory now" — with its detail and a confidence capsule (low, medium or high, from how fresh the measurements are, how long the family has been watched and how clean its trend is).
- **One recommendation** and the top evidence behind it. When one helper accounts for most of a family's growth, it is named.
- **The most serious consequence of stopping it**, such as unsaved documents or database writes, before any preview opens, and what a stop would give back.
- **The action that fits**: the stop button (**Quit <App>…**, **Stop Process…** or **Stop Tree…**); **Stop <supervisor> Instead…** when pm2, forever or supervisord would restart the family; or **Unsnooze** / **Stop Ignoring** for a muted family. **Snooze** and **Ignore** sit beside it.

The stop button shows a spinner while its preview is prepared. It is disabled, with the reason shown, when the family can never be stopped: Ghost Process Sniper itself, the terminal or app it runs inside, `loginwindow`, `WindowServer`, `launchd`, or a process macOS marks as a system process.

The tabs are **Overview** (the verdict, the memory trend, and chips for memory, CPU, growth and "vs normal"), **Evidence** (why it was flagged, the culprit and the forecast), **Processes** (every member in a tree, with **Stop This Process…**, **Copy PID**, **Copy Command Line** and **Reveal in Finder** per row) and **Details** (the command line and forensics such as the working directory, open files and ports). The inspector (**⌥⌘I**) keeps forensics and the first processes of the tree beside the page.

"Probably forgotten" lists only facts that hold: a job that outlived the terminal it was started from, or whose launcher exited; no CPU use for 30 minutes or more; running for hours; a working directory that was deleted; a port still held while idle. Apps and launchd services stay unlikely unless their working directory is gone — launchd is every app's parent, which says nothing about being forgotten.

After a family is stopped, its page says what was stopped and what was freed instead of a generic "no longer running", and offers to stop the supervisor if one restarted it.

## Quick Stop

Wherever a culprit appears — the popover, the status menu, the Overview's verdict and Risk Queue, and sidebar row menus — a Quick Stop names what the stop will really do: **Quit TextEdit…**, **Shut Down postgres…**, **Stop Server…** (with the ports it frees), **Stop Build…**, **Stop Install…**, or **Stop nodemon…** when a supervisor you own keeps restarting the family. It is red only for confirmed hot families whose stop cannot lose data.

A Quick Stop only opens the stop preview; nothing runs until you confirm there. When the preview targets a supervisor instead of the family you clicked, the sheet says so ("Stopping nodemon, which keeps restarting node"). If preparing the preview takes two seconds or more, a small banner says what is being checked; after ten seconds it gives up and asks you to try again. After a stop that left nothing running, closing the sheet takes you back to where you came from with a "Stopped X — freed Y" note.

## Stopping a process

Stopping always starts from a preview and always needs your confirmation. Previews open from a family page, **Stop…** in the toolbar or the Radar menu (**⇧⌘⌫**), a Quick Stop, a notification's **Stop…** action, a row's context menu, a duplicate copy, or the temperature panel.

### The preview

The stop sheet is one scrolling page:

- **Better stops**, when there is one: **Stop <supervisor> instead** when pm2, forever or supervisord restarts the process on exit (the sheet notes when the family's last stop was undone by a restart), or **Stop only <helper>** when one helper holds 70% or more of the family's memory or CPU (recommended for apps, since the app stays open). Choosing one opens a fresh preview.
- **What will happen**: the workload kind, one plain sentence, and each phase of the plan with its signal and its longest wait.
- **Before you stop it**: the consequences worth knowing, such as unsaved documents, database writes, every container stopping, a git lock file, a half-finished install, or "Will restart".
- **You get back**: memory, CPU, processes and freed ports. Memory is measured when the preview is taken; CPU comes from the radar's last scan.
- The launchd service choice, for a service launchd keeps alive (see [launchd services](#launchd-services-and-homebrew)).
- **Why stop it** and **Why wait**, every target with its state, and **Engine details**, which include what past stops of this family did ("Stopped cleanly 7 of 8 times, usually within 1.3 s").

The preview pins exact PID and start-time identities, so a PID that now belongs to another process is never signalled. It is approved for 60 seconds; when that runs out, or when you come back to the sheet after a while and choose **Update Preview**, it is taken again in place. If something that matters changed — the root exited, the plan changed, processes joined or exited — the sheet says what, and holds Confirm for a moment so a click aimed at the old plan cannot confirm the new one.

Confirm needs **⌘↩**. Return alone never stops anything.

### What a stop does

| Workload | First step | First wait | Force |
| --- | --- | --- | --- |
| Apps and document editors (Xcode, Pages, VS Code…) | Asked to quit like **⌘Q**, so they can save and close their own helpers; leftover helpers then get `SIGTERM` | 8 s (10 s for editors) | Only if you allow it |
| Databases (Postgres, MySQL, Redis, Mongo, Elasticsearch…) | The main process alone is asked to shut down (Postgres gets `SIGINT`, its fast shutdown) so it stops its own workers in order; leftovers get `SIGTERM` | 12 s | Only if you allow it |
| Container runtimes (Docker, OrbStack, Colima…) | `SIGTERM`; every container stops | 15 s | Only if you allow it |
| git mid-operation, package installs | `SIGTERM`; warns about `.git/index.lock` or half-installed dependencies | 5 s / 4 s | Only if you allow it |
| Dev servers | Interrupted like **Ctrl-C** (`SIGINT`), then `SIGTERM` for survivors | 1.2 s | Automatic for survivors |
| Builds, model runners, other processes | `SIGTERM` | 2 s | Automatic for survivors |

The 2-second wait is the **Grace period** in **Settings › Alerts**; the longer waits are floors that learning never shortens. Every wait ends as soon as everything has exited, so a long wait only costs time when something is genuinely slow. A family whose past stops took longer to exit gets a longer first wait, within a limit; one that has repeatedly ignored `SIGTERM`, and loses nothing when forced, gets a short wait before force. A prefork server's master (gunicorn, puma, nginx…) gets the polite signal alone, since a worker signalled first is simply forked again.

Force is thorough: every process still running is frozen first, so none can start another; Ghost looks again for anything born in the meantime; then everything frozen is force-stopped, parent first. Children a process starts during the stop are stopped with it — except when force is held back, for an app that is quitting (its updater or crash reporter is only reported), and for a single-process stop.

### Holding back force

**Never force-stop**, in the sheet's footer, is on by default for apps, editors, databases, container runtimes, git mid-operation and package installs. It holds back force and nothing else: every polite step still runs and every wait runs in full. Anything still running at the end — often an app waiting on a save prompt — is reported.

While the stop runs, each process's row updates in place. A wait of two seconds or more shows a countdown with **Stop Waiting**, and **Skip Force** is there while force is still planned:

- **Stop Waiting** ends the wait now and reports what is still running. Nothing is forced.
- **Skip Force** lets the polite steps finish, then reports anything still running instead of forcing it.

When survivors were held back, the result offers **Force Stop N Processes**, which sends `SIGKILL` to exactly those processes and repeats nothing polite. It is available for a minute after the result; after that, open a new preview.

### launchd services and Homebrew

A `brew services` database or another LaunchAgent with KeepAlive is started again by launchd within a second of a normal stop. For such a service the preview shows **launchd keeps it running**, with **Stop the launchd service (until next login)**, on by default, and **Keep it off after restart**. The confirm button then reads **Stop the Service**: launchd itself asks the process to stop and honours its shutdown timeout, while the rest of the stop runs as usual. If launchd refuses, the process is signalled instead.

The panel also shows the command to keep it off yourself (`brew services stop <formula>`, or `launchctl disable gui/<uid>/<label>`) and the command to undo it (`brew services start <formula>`, or `launchctl enable …` followed by `launchctl bootstrap …`), each with a copy button.

### Supervisors

pm2, forever and supervisord restart a process as soon as it exits, so stopping only the child is undone within a second: the preview recommends **Stop <supervisor> instead**, and the family page offers **Stop <supervisor> Instead…**. Stopping PM2 stops every PM2 app. nodemon, watchexec, cargo watch, air, tsx watch and entr only start the process again on your next save, so stopping the child is usually what you want; the preview says "Restarts on your next save". overmind stops every other process of the Procfile when one exits, and the preview says so.

After a stop where a supervisor restarts on exit, Ghost looks for a restart for about two seconds. Only a new process with a stopped target's name whose parent chain leads to that supervisor counts, so an unrelated `node` from another terminal is never blamed. If one came back, the result names who restarted it and offers to stop that instead.

### The result

The result leads with what happened, by name — "Stopped vite and 3 helpers in 1.2 s. Freed 480 MB.", "Pages is still open; it may be showing a save prompt.", "Stopped postgres, but launchd started it again" — and one next step when something is left. Below it:

- **Ports**: each port the workload listened on is checked. It is **free**, **held by** a named process that escaped the stop (with **Stop It Too** when the radar knows that process), or **likely free** when not every likely holder could be checked.
- **Outcome by process**: every process's fate, problems first.
- Notes on what the stop left: processes kept running or orphaned, a launchd service that stays off until the next login, a process stuck finishing its exit in the kernel, or a fork storm Ghost had to freeze.
- **Copy Report** puts the full account, with engine diagnostics, on the clipboard.

### Special cases

- **Paused jobs.** A job stopped with Ctrl-Z cannot act on a polite signal until it runs again, so Ghost resumes it right after asking it to stop, and resumes a paused app before asking it to quit. The preview notes it.
- **Debugger attached.** A polite stop only pauses a debugged process in the debugger. The preview says so, the wait does not wait for it, and only force or the debugger itself ends it.
- **Zombies.** A process that has exited but not been collected by its parent is never signalled; no signal can do more. The preview names the parent that still has to collect it, and stopping that parent clears it.
- **Protected processes.** Ghost itself, the terminal or app it runs inside, `loginwindow`, `WindowServer`, `launchd` and processes macOS marks as system processes are never targets, even inside a family you stop; if the family's root is one of them, nothing is stopped and the preview says why. Dock, Finder and other processes macOS relaunches, terminal apps, tmux or screen servers and login shells can be stopped, with a warning ("macOS restarts it", "Every session closes").
- **Other users' processes** stay running and are listed as skipped. If macOS refuses a signal to one of yours, the stop tries it once, says so, and moves on.
- **Past stops** inform the evidence and the waits but never lock a family out of stopping. Survivors you chose to keep with **Never force-stop** do not count as failures.

## Duplicates

**Duplicates** lists work running more than once. A *copy* is an independently started instance — from a shell or by launchd; the workers one tool starts are a pool, not duplicates. Interpreted scripts are compared by what they run, so `node vite` and `node tsserver` are not copies of each other.

Selecting a cluster shows its plan: a one-line verdict, every live copy with **Keep** or **Stop** and the reason, and **Stop N Copies…**. The copy the radar recommends keeping — the one in a terminal, else the one that did work most recently — is kept. Only copies that are yours, idle and orphaned are stopped; anything busy, listening, run by launchd, an app you opened, or started by a running parent is kept. A cluster never loses every copy, and one pass stops at most 32.

**Stop N Copies…** opens a checklist. Confirming gives each checked copy its own stop preview and stops the ones that pass, four at a time, with live states. A copy that a supervisor would restart, or whose stop would need a decision about force, is skipped and left running so you can stop it on its own. **Delete** in the table opens the same checklist, and each copy's context menu has **Stop This Copy…**.

## Incidents

**Incidents** is the local history of leaks, spikes and runaway families. Each row is an episode: it stays open through short dips, snoozes and skipped samples, closes after 90 seconds without activity, and a return within ten minutes reopens it and counts a hit. Rows show the episode's peak. Column headers sort by family, score, memory and hits, both ways. A **Running** badge marks families that still run; those rows offer **Open Family** and, while active, **Stop…**, and an exited one offers **Search for It**.

## Rules

**Rules** puts what you muted first: **Snoozed** families with a live "ends in" countdown and **Unsnooze**, and **Ignored** families with **Stop Ignoring**. Your own rules follow, and the built-in rules sit in a collapsed group. A new rule shows its live matches before you save it. Rules notify, highlight, snooze, ignore, or suggest stopping; a rule can never stop a process by itself. Removing a rule offers **Undo**, and a snooze ends on time.

## Temperatures

The **Heat & CPU activity** panel on the Overview answers two separate questions: how hot the chip is, and which work is keeping it busy.

The temperature card shows measured CPU and GPU Celsius — the hottest readable sensor of each — separately from the macOS thermal state. These are hardware readings, never invented per-process temperatures. Sensor maps for M1, M2 and Intel Macs are verified; M3 and M4 Macs use catalog maps, and M5 and later use sensors found on the Mac itself; the card says when a map is unverified. Unsupported, missing, invalid or stale readings show **Unavailable** with the reason, and the panel falls back to macOS thermal pressure. Temperatures are read only while the popover or the console is on screen, and sensor access is read-only.

A single very hot reading is called a brief spike; advice to cut work needs heat that persists. The attribution card names the app or job doing the work — helpers join their app, and a build's compiler processes are one job — and ranks by recent sustained load rather than one reading. Known macOS sources such as Spotlight, Photos analysis, Time Machine and the virtual machine behind Docker are labelled as system work.

- **Scan now** takes fresh readings. **Combined**, **CPU** and **GPU** switch the ranking.
- **Temperature history & measurement details** shows sensor traces.
- **Inspect <app>** shows the current evidence and the sampled processes behind an app.
- **Compare after a change** saves a baseline. Change optional work yourself, then compare fresh CPU/GPU activity and temperatures after at least 15 seconds. The comparison expires after three minutes and never treats a missing app as zero load.
- **Stop …** appears for your own work when it can be stopped: on the card when the same app or job keeps showing up while the Mac is warm, and in its detail sheet. The label names the process family the stop will act on, which can be a helper rather than the app itself. It opens the usual stop preview, and is never offered for macOS services.

Scan, Inspect and Compare never stop or pause apps. Activity is evidence, not a measurement of an application's temperature or heat share. The ⓘ beside the panel title explains how to read the numbers; [Thermals](Thermals.md) documents the rules behind them.

## Notifications

When the radar has a credible reason to interrupt you, it posts one notification per family; a newer one replaces the older instead of stacking. Its actions are **Stop…** (opens the console with the stop preview), **Snooze 1 Hour**, and **Show** (opens the family). Banners appear even while the console is in front. **Settings › Alerts** shows whether notifications are allowed.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Search all processes | ⌘F |
| Open the best match | ↩ in the search field |
| Scan now | ⌘R |
| Overview / All Processes | ⌘1 / ⌘2 |
| Duplicates / Incidents / Rules | ⌘3 / ⌘4 / ⌘5 |
| Back / Forward | ⌘[ / ⌘] |
| Next / previous family | ⌘↓ / ⌘↑ (↓ / ↑ in the sidebar) |
| Stop the selected family | ⇧⌘⌫ |
| Confirm a stop | ⌘↩ |
| Snooze / Ignore the selected family | ⇧⌘S / ⇧⌘E |
| Inspector | ⌥⌘I |
| Copy incident report / diagnostics | ⇧⌘C / ⇧⌘D |
| Open the console | ⌘O |
| Settings | ⌘, |

Back and Forward remember up to 30 visited pages and skip families that have exited. The sidebar keeps Settings and the Quick Guide visible; the guide also opens from the toolbar's **More** menu and lists these shortcuts. Clear filters to recover from an empty search.

## Settings and data

Settings has five tabs:

- **Protection**: protection style, what to watch, family grouping, and the current limits.
- **Alerts**: notifications, the safe-intervention summary and the **Grace period** for an ordinary process.
- **Performance**: adaptive scanning and the active mode. In the background the radar samples every few seconds at utility priority, and slower on battery, in Low Power Mode and when the Mac is hot; with the popover or console on screen it samples about once a second.
- **Diagnostics**: what the radar itself costs (refresh cost, its own CPU and memory), the last stop, the store backlog, host memory pressure, any store error, and **Copy Diagnostics** for bug reports.
- **System**: **Launch at login** (with a note when macOS is waiting for your approval in Login Items), the **Safety boundary** — your own processes only, no privileged helper, the final action always yours — and **Restore Smart Defaults**.

Settings and monitoring history live in a single local database at `~/Library/Application Support/Ghost Process Sniper/Radar.sqlite`. Incident history is kept for 90 days. If the file is ever damaged, it is set aside as `Radar.corrupt-<date>.sqlite` and a fresh one is started; before an upgrade that removes tables, a copy is kept as `Radar.sqlite.bak-v<version>`. To reset everything, quit the app and delete that folder; **Restore Smart Defaults** resets only the settings.
