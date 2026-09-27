# Changelog

All notable changes to Ghost Process Sniper are documented here. The project follows [Semantic Versioning](https://semver.org).

## [Unreleased]

### Sentinel
- Trust is bound to what makes a program trustworthy, never to its path: a signed app is trusted by its team and identifier, so updates stay trusted; an ad hoc build by its exact build; an unsigned program by its exact file. The Trust item says which ("Trust Slack (Team BQR82RBBHL)").
- Shells, interpreters and system tools are never trusted whole. Trusting bash for a browser extension used to hide every later bash finding, reverse shells included; now it trusts that one script or command.
- A trusted program that changes — another signer, a rebuild, an edited script — is flagged again as Suspicious, saying what was trusted and what is there now.
- A binary swapped in place can no longer inherit the signature of the file it replaced, even when back-dated with `touch -r`.
- The Security page lists what you trusted, with Revoke. Paths trusted in earlier versions are carried over once; shells and tools among them are dropped.
- A download-and-run command is excused as a known installer only when the address it downloads is that installer's own https host: look-alikes such as `sh.rustup.rs.evil.example` or `sh.rustup.rs@evil.example`, and a harmless installer URL placed elsewhere in the same command, no longer hide it.
- A command pasted into a terminal that downloads and runs code (`curl … | sh`) is caught: the shell starts it as separate processes, and Sentinel now puts the pipeline back together from its process group. The "pasted command" warning appears, and decoding on the way (`curl … | base64 -d | bash`) is Dangerous. Official installers such as rustup and Homebrew stay quiet.
- Terminal tabs that were already open when Ghost started are watched too; before, only tabs opened afterwards were.
- Dismissed findings stop counting once they expire, and a program that runs a second command inside the same process gets its own launch-feed entry.

### Smarter detection
- One large allocation, such as a language server loading a project, is no longer called a slow leak 20–60 minutes later. A slow leak now has to keep growing through most of its window.
- Waking the Mac no longer makes every quiet process "idle for 8 h": idleness counts only time the Mac was awake, so a dev server you used just before closing the lid is not "probably forgotten" in the morning. A slow leak keeps its rate across a sleep too, instead of being diluted by the night and missed.
- A newly learned normal describes how an app really behaves, not the moment it was first seen: a language server first seen idle no longer reads "60% CPU vs about 2.9% normally" at every routine burst. A slow leak is never learned as normal, and your own leak threshold decides what counts as growth.
- A big app at the size it always has is no longer Hot just for being big: once Ghost has learned an app's usual size, a chat app at 2.5 GB on a 16 GB Mac is watched ("Large, but normal for it"), not put in the risk queue. Growth, CPU, GPU or memory pressure still raise it.
- A loop holding several cores steadily is caught on big Macs too: the CPU limit grows with the core count, so three cores held for hours used to go unnoticed. After ten steady minutes it is evidence, and a runaway when the process has nobody attending it, such as a job whose terminal closed.
- "Stop only <helper>" names the helper that is actually leaking: while an app leaks slowly, a helper that just started and is warming up no longer takes the blame.

### Energy
- A new **Energy** section (⌘4) shows what uses energy in real watts, measured by macOS for every process, next to the whole Mac's draw, the battery time left, battery health and cycle count, and the last hour as a sparkline.
- On battery, every app and job says how much longer the battery would last without it ("+40 min").
- **Today** shows what used energy today — across restarts — against a full charge, with a bar for each day of the last week. Daily totals are kept for five weeks in the local database.
- **Keeping your Mac awake** names everything holding back sleep and for how long, and blames the app even when macOS holds it on the app's behalf: a Safari tab that left the speakers open reads "Safari · An audio stream is open (held by coreaudiod)". Keep-awake apps such as Amphetamine are marked, and macOS's own services are folded away.
- Findings with one next step: an idle app keeping the Mac awake for half an hour or more, an app waking the processor 150 times a second or more while doing almost nothing (the limit macOS itself enforces), a job writing to disk without a break, and on battery an app costing 20 minutes of battery or more. Builds, databases and VMs are allowed to write a lot.
- Family pages show the family's energy, wake-ups, disk writes and whether it keeps the Mac awake. The popover shows the top energy finding, or the battery line while on battery, and the Overview shows a banner while a finding needs attention.
- A finding that needs attention, such as an idle app keeping the Mac awake for two hours, sends one notification; the same finding stays quiet for 12 hours.
- Search understands `watts>2`, `wakeups>150` and `writes>5mb`.
- Safari tabs and other helpers macOS starts for an app outside its bundle now count toward that app, on the Energy page and in the heat panel, instead of standing alone as `com.apple.WebKit.WebContent`.
- Sections are now ⌘1 Overview, ⌘2 All Processes, ⌘3 Security, ⌘4 Energy, ⌘5 Duplicates, ⌘6 Incidents, ⌘7 Rules, following the sidebar order.

## [2.1.0] — 2026-09-27

Sentinel, a security watch that explains what it sees; a console that does about half the layout work; numbers that read the same in every language; and releases built in the open, with provenance you can verify.

### Sentinel security watch
- A new **Security** section (⌘3) looks at every process for the shapes attacks take on macOS and explains each finding with the chain that launched it (`Google Chrome › zsh › curl`), the exact text that matched, and one next step.
- Catches browsers, mail, chat and document apps starting shells or scripts; pasted commands that download and run code (with advice about fake CAPTCHA and "fix" instructions); base64 and other encoded payloads; homemade password dialogs and `dscl -authonly`; keychain, browser-cookie and wallet theft; quarantine stripping and Gatekeeper disabling; launch-agent persistence; reverse shells and shells or relays waiting for connections; tunnels; crypto miners; silent screen and camera capture.
- Flags programs running from temporary, shared or hidden folders, the Trash, mounted disk images or Downloads, deleted executables, system names from the wrong folder or spelled with look-alike letters, and apps disguised as documents (`Invoice.pdf.app`).
- Checks each third-party program's code signature once, offline (Apple, App Store, Developer ID, ad hoc, unsigned, invalid), and shows the page it was downloaded from.
- Watches browsers and terminals with kernel process events, so commands that run for under a second are caught with their arguments, at no cost while nothing starts.
- Lists launch agents and daemons and catches new ones the moment they are written, with a notification.
- Shows which apps are recording from the microphone and whether a camera is on, from system listeners that open no device and need no permission.
- A live launch feed of every new process, a banner above the Overview, a raised menu-bar icon and one notification per new suspicious or dangerous program and reason; a program that restarts for the same reason stays silent for a day. Findings never act on their own: **Stop…** uses the usual preview, and programs can be trusted or findings dismissed.
- Stays quiet on everyday work that resembles an attack: simulator daemons, browser-extension helpers, compiler output, port checks, cookie-jar files, downloads named after wallets, signed programs in `/Users/Shared` and dev servers built into `/tmp`. The attack shapes they resemble are still caught.

### Power
- The console's detail column no longer measures the whole page for its minimum size on every update; that was about half of the console's main-thread time while it was on screen.
- An open console refreshes at half, then a quarter, of its usual rate when nobody has touched the Mac for 30 seconds or 2 minutes, and returns to the full rate on the next tick after any input.
- Incident recurrence counts are cached between flushes instead of being queried on every scan.
- The two-column layout measures each child once per layout pass.
- Measured with the console frontmost: about 42% of a core before, 23–28% after, including Sentinel ([Performance](Docs/Performance.md)).

### Interface
- Sections are ⌘1 Overview, ⌘2 All Processes, ⌘3 Security, ⌘4 Duplicates, ⌘5 Incidents, ⌘6 Rules, following the sidebar order.
- `--section security` (or any section name) opens the console on that page at launch.

### Fixed
- Temperatures and PIDs are formatted the same way in every locale: a Danish Mac no longer shows `91,0°C` next to `91.0°C`, or `PID 12.273` in the stop preview.
- The Overview's recommendation says what a stop does once; it read "Asks ChatGPT to quit like ⌘Q, then stops anything it leaves behind. ChatGPT is asked to quit like ⌘Q…".
- Ghost no longer lists itself under Warming Up or in the Risk Queue while its console is open. It still appears in All Processes, and Settings › Diagnostics shows what it costs.

### Distribution
- Releases are built from the tagged source by GitHub Actions. Each disk image carries a signed build-provenance attestation, so `gh attestation verify GhostProcessSniper-2.1.0.dmg --repo mikkel32/ghost-process-sniper` proves the file came from that build.
- A website, [mikkel32.github.io/ghost-process-sniper](https://mikkel32.github.io/ghost-process-sniper/), with the download, install steps and checksum. It loads nothing from other sites.
- Release notes are generated from this changelog and include the checksum and first-launch steps.

## [2.0.0] — 2026-09-26

A verdict-first redesign with risk-aware stopping, search across every running process, and a faster, lighter radar. Existing history and settings are migrated on first launch; a copy of the database is kept before any upgrade that drops tables.

### Search
- Search reaches every running process, not only tracked families. Apps outside the watch scope appear under *Other running processes* with memory, CPU, PID, and copy/reveal actions.
- Matches helper names, command lines, paths, PIDs, and listening ports; words match in any order and ignore case and accents.
- Ranked results with highlighted names and a note explaining matches found through a helper, command, PID, or port.
- Filters: `-exclude`, `"phrases"`, `name:`/`cmd:`/`path:`/`user:`/`kind:`, `pid:`/`port:`, `cpu>`/`mem>`/`gpu>`/`threads>`/`leak>`/`children>`, and `is:` states. Understood filters show as chips; half-typed filters never blank the list.
- Typo- and acronym-tolerant fallback (`crhome`, `vsc`) when nothing matches exactly.
- Return in the search field opens the best match; typing from any section opens the results.
- Incident and duplicate search use the same matching.
- A `port:` search reads the listening ports of all your processes on the next scan, so a quiet dev server holding :3000 is found.
- Any process search finds can be stopped through the usual preview, tracked or not.

### Stopping (engine and safety)
- Every stop knows what it is interrupting: apps, document editors, databases, container runtimes, git, package installs, builds, dev servers, and model runners are recognized from their names, paths, and command lines. The risk is judged on everything the stop would really hit, so a database started under a task runner still gets a careful shutdown.
- Apps are asked to quit like ⌘Q before any signal, so they can save their work; an app that accepted the request is never sent `SIGTERM`, which would close it past a save prompt.
- Databases and prefork servers (gunicorn, puma, nginx…) are asked to stop through their main process, which shuts its workers down in order; Postgres gets `SIGINT`, its fast shutdown. Leftovers then get `SIGTERM`, and force still reaches every process.
- Holding back force no longer cuts the wait short. With **Never force-stop** on (the default for work that can lose data) every polite step runs and every wait runs in full; before, a held stop reported "Still running" milliseconds after the quit request and learned that as a failure.
- The phases you approve in the preview are the phases that run. A fresh look at confirm can only make the first wait longer.
- A protection floor under every stop: Ghost itself, the terminal or app it runs inside, `loginwindow`, `WindowServer`, `launchd`, `kernel_task` and system processes can never be targets, and a family rooted at one of them cannot be stopped. Dock, Finder, terminal apps, tmux or screen servers and login shells can be stopped with a warning.
- Force is thorough: every process still running is frozen, Ghost looks again for anything born in the meantime, then everything frozen is force-stopped, parent first. Children a target starts during the stop are stopped with it (they are only reported while force is held, when an app is quitting, or in a single-process stop), and children started after the preview stop with their approved parent instead of refusing the whole stop.
- launchd-aware stops: the launchd job behind a process is found through `launchctl` and the LaunchAgents and LaunchDaemons plists. A KeepAlive job, such as a `brew services` database, is named as what restarts it, and the stop can boot the service out until the next login or keep it off for good.
- Supervisors are told apart by what they do: pm2, forever and supervisord restart on exit, so stopping the supervisor is offered as the better stop; nodemon, watchexec, cargo watch, air, tsx watch and entr restart on the next save; overmind stops its siblings. A restart is reported only for a new process whose parent chain leads to the supervisor, never for an unrelated `node` from another terminal.
- After a stop, the ports the workload listened on are checked: free, still held by a named process, or not fully verifiable.
- Jobs paused with Ctrl-Z are resumed so they can exit; a debugger-attached process is explained and not waited on; zombies are never signalled and the parent that has to collect them is named; a process stuck exiting in the kernel is named; a signal macOS refuses is tried once and reported as refused.
- Identity (PID plus start time) is re-checked right before every signal, so a PID reused mid-stop is never hit.
- A learned outcome model replaces invented odds: per family and per workload kind it learns how often a strategy ends cleanly and how long exits take, sets the first wait from that, and says so ("Stopped cleanly 7 of 8 times, usually within 1.3 s"). A workload's own shutdown time (git 5 s, installs 4 s, databases 12 s) is a floor that learning never shortens, and a big footprint no longer means a quick force.
- Kill history informs a stop but never locks a family out of stopping; survivors you chose to keep and other users' processes it skipped no longer count as failures.
- **Force Stop N Processes** after a held stop sends `SIGKILL` to exactly the verified survivors instead of repeating the whole graceful stop.
- The stop sheet's reclaim reports real memory footprint and the radar's CPU instead of resident size and "CPU 0%".
- Grace periods end as soon as the processes exit even when the exit watcher is unavailable.

### Stop sheet and actions
- The stop sheet is one page: better stops, what will happen, the risks, what you get back, the evidence and the targets. Confirm needs ⌘↩, so pressing Return can never stop anything.
- Better stops are offered in the preview: stop the supervisor that restarts the process, or only the helper holding most of the family's memory or CPU.
- The preview no longer expires into a dead end: at 60 seconds, or with **Update Preview** after you were away, it is taken again in place, says what changed, and holds Confirm for a moment.
- While a stop runs, each process updates in place under a plain headline. A clean-exit wait of two seconds or more shows a countdown with a thinking orb and **Stop Waiting**; **Skip Force** holds back force mid-stop.
- The result says what happened by name, with one next step: who exited, who needed force, who is still running and why, what was freed. Port chips offer **Stop It Too** for a process still holding a port, and the copied report leads with the same story.
- **Quick Stop** wherever a culprit appears — the popover, the status item's right-click menu, the Overview's verdict and Risk Queue, and row menus — named for what it will do (**Quit TextEdit…**, **Shut Down postgres…**, **Stop Server…**, or **Stop nodemon…** when a supervisor keeps restarting the family). It only opens the preview.
- One verb for the same stop everywhere: **Stop…** (⇧⌘⌫) replaces "Kill Preview", and family pages read **Quit <App>…**, **Stop Process…** or **Stop Tree…**.
- Family pages disable the stop button with the reason when the family is protected, show a spinner while the preview is prepared, and offer **Stop <supervisor> Instead…**.
- A preview that takes two seconds or more shows what is being checked; after ten seconds it gives up with a retry note. After a clean stop, closing the sheet returns to where you were with a "Stopped X — freed Y" note, and an exited family's page says what was stopped.
- Duplicates can stop the extras: each cluster says which copy to keep and why, and **Stop N Copies…** stops the orphaned extras, each through its own preview.
- Single processes can be stopped from a family's Processes tab, the process table and a duplicate cluster; incidents whose family still runs, and the temperature panel, open a stop preview too.
- Notifications carry **Stop…**, **Snooze 1 Hour** and **Show** actions, and a newer alert for a family replaces the older one.

### Detection intelligence
- Developer tools are classified by whole words from a real workload catalog: "bun" no longer matches every `.bundle`, and Xcode, rust-analyzer, gopls, clangd, Postgres and OrbStack are recognized.
- Language servers, databases, dev servers, test runners and notebook kernels an editor starts are their own families, so a leaking language server surfaces as itself, not as the editor.
- Slow leaks are caught: per-member memory history at two resolutions (two minutes and ninety minutes) finds steady growth of 5 MB/min or more over twenty minutes, and names the helper responsible with a "Stop only <helper>" suggestion. A child joining or leaving no longer resets the trend or reads as a leak.
- Memory-shape analysis is noise-aware: a clean leak with jittery samples is still a climb, and a sawtooth whose troughs keep rising reads as "Leaking under GC". Two close samples can no longer claim thousands of MB/min.
- CPU behavior is read from twenty minutes of exact CPU time: builds and tests are expected bursts ("Let it finish", runaway only after 15 minutes), a process pinned at one core is a busy loop, an idle service burning CPU against its learned normal is flagged, and 60% of every core for three minutes is saturation.
- Forgotten processes are judged by how they were launched (a job that outlived its terminal, an orphan), measured idleness, age, a deleted working directory and a port held while idle. Apps and LaunchAgents are no longer "Probably forgotten" just because launchd is their parent.
- Learned baselines are time-weighted over two hours with variance, and trusted only after 30 readings and 20 minutes; memory anomalies need a real outlier, and a normally idle service at 80% CPU is flagged.
- Host memory pressure comes from the kernel and swap growth, is attributed to the families holding and growing memory, and counts down to critical pressure ("Memory critical in ~9 min · vite").
- Duplicates count independently started copies only, compare interpreted scripts by what they run, and recommend which copy to keep (the one in a terminal, else the most recently active).
- One slow helper no longer blanks a whole family: families are scored once their measured readings cover 90% of the footprint.
- Hot and Critical hold for 20 seconds after a family cools, then step down one level at a time, so levels, alerts and the menu-bar icon no longer flap.
- The verdict agrees with the measured level, the Overview brief aims at confirmed trouble and says what stopping it would do, and the largest app on the Mac is no longer Hot just for being the largest.
- A momentary CPU breach no longer reads as "Leaking, threshold ETA breached now".
- Cards, alerts and suggestions keep stable identities, so rows no longer flicker or lose hover and VoiceOver focus on every scan.

### Sampling and performance
- Every one of your processes has its CPU and memory measured on every scan; before, most were re-read only every few minutes.
- Paths are read for every new process in its first scan, a process that execs something new is re-read, and name-only placeholders are never passed off as fresh.
- Listening ports count only TCP sockets in LISTEN, and a background port census keeps quiet dev servers' ports current.
- GPU time is no longer counted twice on Apple silicon.
- Scans are scheduled by what is on screen, power and heat: about once a second while the popover or console is visible, every few seconds in the background, slower on battery, in Low Power Mode and under thermal pressure. Background work runs at utility priority with timer tolerance, and opening the popover or console starts a scan at once.
- Scan now, the console's refresh and the refresh after a stop always return data sampled after the request, sharing one extra scan instead of being dropped.
- The per-scan pipeline costs less than half as much as before, with identical families, scores and signatures.
- Only what changed is published: diagnostics, health and timing figures no longer redraw their views every second, and the popover, Overview and Settings redraw only the parts whose data changed.
- A family page's detail and stop risk are built off the main thread as soon as it is selected; assessing a 41-process Electron family's stop risk dropped from about 38 ms to under 2 ms.
- The stop result appears as soon as the processes are gone; recording and the refresh follow.
- Temperatures are read on every scan while the popover or console is on screen and at most every 4 seconds otherwise, which keeps the trend warm without constant sensor reads.

### Thermals
- Temperatures on M3 and M4 Macs through catalog sensor maps, and on newer Apple chips through sensors found on the Mac once per launch; the panel says when a map is unverified, and unsupported Macs show macOS thermal pressure with the reason.
- The chip generation is parsed as a whole number, so a future "Apple M10" never uses the M1 table, and only SMC read commands can be sent.
- Temperature trends survive the hottest core changing from sample to sample.
- A single very hot reading is a brief spike, not a reason to cut work.
- Heat is attributed to whole jobs through the process tree: a `make -j10` build is one job, helpers join their app, and Spotlight, Photos analysis, Time Machine, WindowServer and the Docker VM are labelled as system work.
- Heat suspects are ranked by recent sustained load, so a finished two-minute compile outranks a one-reading blip.
- Trends and traces are ready the moment the panel opens, the panel re-renders only when a reading expires, and it offers a stop preview for your own work behind the heat.
- The Overview's thermal panel moves up only while the Mac is really hot (throttling, or 90 °C or more for 30 seconds).

### Interface
- The popover leads with one verdict, up to three culprits with Quick Stop, and a temperature and pressure strip, sized to its content.
- The Overview leads with one verdict and its action, keeps the Risk and Warming queues above the fold, and shows pages at once instead of replaying entrance fades.
- Family pages are verdict-first: the verdict, a confidence capsule, one recommendation, the top evidence, the most serious stop consequence, and the action that fits, with Overview, Evidence, Processes (a process tree) and Details tabs.
- All Processes is a native table: every column but PID sorts both ways, rows multi-select and move with the arrow keys, Return opens a family and Delete previews a stop.
- Incidents sort by their column headers and offer Open Family, Stop… or Search for It; Rules show snoozes and ignores first with a live countdown, and removing a rule offers Undo.
- Back and Forward (⌘[ and ⌘]); ⌘1–⌘5 follow the sidebar order; the sidebar answers ↑ and ↓.
- The Engine screen moved into **Settings › Diagnostics**.
- ⌘, and every Settings button open Settings reliably; a login item waiting for approval is explained instead of snapping off.
- The menu-bar icon is drawn for the current appearance and display, and its shape carries the level; Critical has its own color and icon.
- The console keeps its place across closes and stops its presentation work while hidden or covered.
- Row menus offer Copy PID, Copy Command Line and Reveal in Finder; toasts can carry Undo and are announced to VoiceOver.
- The thinking orb from the vendored ThinkingOrbsKit (Libraries.dev, MIT) marks waits of two seconds or more.

### Persistence
- The database schema is versioned, with each migration in its own transaction and a copy of the file kept before an upgrade that drops tables.
- The store opens lazily off the main thread; a corrupt file is set aside and a fresh one started instead of disabling history for every launch.
- Learning happens in memory and is written behind, and a flush writes only what is due: in a 300-family test, 30 scans went from 9,684 row writes to 318.
- Incidents are episodes: one row that survives short dips, snoozes and skipped samples, reopens within ten minutes, and records its peak.
- Quitting saves a pending settings change, records a stop that just finished, and closes the database cleanly.
- Daily maintenance deletes old history and expired rules and returns the space; a failing disk can no longer grow the write backlog without bound.
- Kill learning tables are rebuilt once, discarding records that held fake survivors.

### Fixed
- Paste, copy, cut, select all, and undo now work in the console's text fields (the app menu had no Edit menu).
- The **Leaks** filter shows credible leaks only, instead of any family whose memory grew at all.
- The sidebar's *View all* for Stable families opens exactly those families.
- **All Processes** (⌘2) is available from the Radar menu.
- A first incident no longer counts as its own recurrence.
- Return-Return-Return in the old stop wizard could confirm a stop.
- One stop that met a save prompt could lock every later stop of that family (and similar ones) into inspect-only.
- Three workers forked after the preview made the whole stop refuse with a misleading message.
- A stopped family could stay listed until the next scan.
- The Mac waking from sleep no longer records the whole sleep as a UI hitch.
- Snoozes end on time instead of at the next rule edit or restart.
- Family pages remember whether you showed or hid the inspector, and a sort direction chosen in a column header no longer leaks into the next sort.
- The Critical menu-bar icon no longer erases the menu bar behind its ring.

### Removed
- The Engine sidebar screen (its useful parts are in **Settings › Diagnostics**).
- The MetricKit subscriber, which only logged payload counts.
- The invented stop odds and their calibrator, dead family-detail pipelines, an invisible thermal advice engine, and other unused sampling, configuration and kill-engine code.
- Write-only database tables (samples, forecasts, recommendation history, predictive alerts, actions).
- Dated performance, thermal, motion, precision and UI-refresh session notes in `Docs/`; what still holds now lives in the [Thermals](Docs/Thermals.md) reference and the [Performance](Docs/Performance.md) guide. The Cleanup status note stays, trimmed to what still holds.
- Unused views, models, and APIs left over from earlier designs, and a second, divergent copy of the family filter logic.

## [1.0.0] — 2026-09-26

First public release.

### Monitoring
- Menu-bar radar with a color-coded scope icon and a summary popover.
- Console with Overview, All Processes, Duplicates, Incidents, Rules, and Engine sections.
- Process families that group apps, helpers, dev servers, and spawned workers.
- Leak, CPU-runaway, and GPU-load detection with trend baselines, forecasts, and readable action levels (Stable, Observe, Review, Urgent, Measuring).
- Duplicate-process detection for overlapping copies of the same work.
- Local SQLite incident history.

### Temperatures
- Measured CPU and GPU Celsius from hardware sensors, separate from the macOS thermal state. Model mappings for M1, M2, and Intel Macs; unsupported readings show Unavailable.
- *What's heating your Mac?* app-activity panel with Combined, CPU, and GPU rankings, app inspection, and before/after reading comparison.

### Interventions
- Stop previews with exact PID and start-time identities, protected-process and recycled-PID checks, 60-second expiry, and `SIGTERM`-first escalation. Every stop requires confirmation.

### Distribution
- Universal (Apple silicon + Intel) build, new app icon, and a drag-to-install disk image.
- `Scripts/release.sh` builds the installer in an isolated build directory, with optional Developer ID signing and notarization.

### Fixed
- App bundles are staged and signed outside the checkout, so packaging works when the repository lives in an iCloud-synced Desktop or Documents folder.
- Cleanup tests no longer crash when the repository is checked out in an iCloud-synced folder; fixtures now live in `~/Library/Caches`.

[2.0.0]: https://github.com/mikkel32/ghost-process-sniper/releases/tag/v2.0.0
[1.0.0]: https://github.com/mikkel32/ghost-process-sniper/releases/tag/v1.0.0
