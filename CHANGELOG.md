# Changelog

All notable changes to Ghost Process Sniper are documented here. The project follows [Semantic Versioning](https://semver.org).

## [2.2.0] — 2026-09-30

2.2 is about telling you what is going on, and why. A new **Energy** page shows real watts per app, what keeps your Mac awake, and how much longer the battery would last without each app. The **Live Radar** was rebuilt so it can be read: rings are verdicts, quarters say what a family is, and everything worth a look is named. Rows say *why* ("1.7x its usual size", "Holds 22% of scarce memory", "Busy-looping on one core") instead of "Memory footprint", helpers macOS starts for an app (Safari's tabs) belong to that app, and big apps you use every day are learned instead of being flagged forever, with far fewer false alarms from launches, builds, refills, short climbs and memory pressure. The **security watch** is harder to fool and misses less: trust is bound to what a program is and never its path, pasted `curl … | sh` commands and one-shot dangerous commands are caught, and a file that only carries a coding assistant's name no longer softens an alert. Stopping is more honest about what it left running.

**After updating, Ghost relearns what is normal for each app, which takes about twenty minutes; until then big apps can read Review.**

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
- The header no longer contradicts itself. It said "Charging 76%", "your Mac is drawing 94 W" and "Charger 65 W" together. It now says **Charging**, **Plugged in, not charging** or **Draining while plugged in** from which way current really flows through the battery (with a dead band so it does not flicker), instead of the charging flag, which stays on while a charger too small for the work lets the battery drain. The Charger chip shows the charger's rating, not the live wall input, which includes what goes into the battery.
- The Mac's draw is the power controller's own interval mean instead of one snapshot held for up to a minute; the time left uses the last 90 seconds, and the header's draw and the apps' share use five minutes, the same window as the per-app figures. The header says how much of the draw apps and jobs account for ("3,3 W of it (17%)"), and says nothing when that cannot be true. Battery health follows the capacity macOS derives Maximum Capacity from, so it reads what System Settings reads.
- A row's wake-ups and writes figures turn orange only when a finding would show, judged per process like the findings; before, they turned orange from the group's sum, so big multi-process apps looked guilty with nothing behind it. An app that keeps both the Mac and its display awake is one card and one notification, and the header counts apps, not assertions.

### Live Radar
- Rebuilt so it can be read, not just watched. Rings are verdicts (Critical at the center, then Hot, Watch and Quiet); before, distance was raw heat, so a big app held at Watch sat at the center, closer than the one family actually flagged.
- Quarters say what a family is: apps, servers, developer tools, background work. Before, a blip's bearing was a hash with no meaning and every quiet process piled up on the rim.
- Names are on the scope: everything at Watch or above, anything getting worse, and the biggest while there is room, placed so they never cover each other, a blip or a ring's name. Before, every blip was an anonymous dot until you hovered it.
- A blip's size is its memory, and a dotted streak shows where it was five minutes ago, with an arrowhead when it is getting worse or easing off.
- A contacts list beside the scope names the same families worst first; pointing at a row lights its blip and the other way round, with an instant callout instead of a tooltip.
- The sweep lights each blip as it passes, on the render server. In Low Power Mode it steps at 10 frames a second instead of stopping; before, a Mac always in Low Power Mode only ever showed a frozen beam.
- Contacts say why a family is there ("Over its memory limit · 2.7 GB", "1.7x its usual size · 4.4 GB"). The radar costs about the same CPU as the scope it replaced.
- The Live Radar follows the Risk Queue on the Overview, so it starts on screen instead of below the summary cards and temperatures.

### Families and reasons
- Helpers macOS starts for an app now belong to that app's family: Safari's tabs, GPU and network processes, and an IDE's XPC services are one row with the app's true total instead of several anonymous `com.apple.WebKit.WebContent` rows at 600 to 750 MB each. Only real service helpers join (launchd's child, same user, a service-like path, an app that started first and is not a terminal); an orphaned dev server from a terminal or editor, and a language server an editor runs, stay their own families. Quitting the app takes its helpers with it, each helper can still be stopped on its own, and searching for the app's or a helper's name finds the family.
- Rows say why a family is on the radar ("Over its memory limit", "Near its memory limit", "1.7x its usual size", "Large, but normal for it", "Large; learning its usual", "2 copies running", "Probably forgotten") instead of "Memory footprint" and "Activity to review" for everything. Busy families say what their CPU is doing ("Over its CPU limit", "Busy-looping on one core", "Using most of this Mac's CPU", "Busy; it usually idles", "Busy for 12 min", "Build or test work") instead of "CPU activity", and a family over its memory limit that also keeps a core busy is filed under memory, not CPU. While the Mac is short of memory, each big family says how much of it it holds ("Holds 22% of scarce memory") rather than every row reading "Memory is tight on this Mac". All Processes rows read "9 processes · 1.7x its usual size". The family page's evidence lists only what was raised to Watch or beyond, and says "Bigger than usual for it" or "Memory is tight on this Mac" where it said "Using a lot of memory now" beside a baseline of "0.7x usual".
- The family page's process tree has a **Growth** column, and the process that holds most of a credible leak carries an orange *leaking* tag, so the helper named in "Stop only <helper>" can be found among same-named helpers. The inspector lists the root and the ten biggest processes by memory instead of the ten lowest PIDs.
- A simulator is named by its runtime ("iOS 26.5 Simulator") instead of `launchd_sim` in lists, stop previews and notifications; searching for `launchd_sim` still finds it. Xcode-beta, Xcode_26.1 and other versioned Xcode installs are recognised as Xcode.
- Duplicates lists a cluster only when it adds up (32 MB or 5% CPU in all, four or more copies, or a copy to stop that serves a port), labels unclassified tools "Repeated tool", shows the real shortcut (⌘5) and, when a search hides every cluster, says so with a Clear Search button.

### Smarter detection
- One large allocation, such as a language server loading a project, is no longer called a slow leak 20–60 minutes later. A slow leak now has to keep growing through most of its window.
- Waking the Mac no longer makes every quiet process "idle for 8 h": idleness counts only time the Mac was awake, so a dev server you used just before closing the lid is not "probably forgotten" in the morning. A slow leak keeps its rate across a sleep too, instead of being diluted by the night and missed.
- A newly learned normal describes how an app really behaves, not the moment it was first seen: a language server first seen idle no longer reads "60% CPU vs about 2.9% normally" at every routine burst. A slow leak is never learned as normal, and your own leak threshold decides what counts as growth.
- A big app at the size it always has is no longer Hot just for being big: once Ghost has learned an app's usual size, a chat app at 2.5 GB on a 16 GB Mac is watched ("Large, but normal for it"), not put in the risk queue. Growth, CPU, GPU, a size above its usual or critical memory pressure still raise it. Being big is also no longer logged as an incident, and no longer keeps an app's normal from being learned: before, an app that was Hot for its size never learned its size, so it stayed Hot for good. It no longer speeds up background scanning either: a big app open all day kept Ghost scanning every second instead of every 3.5 seconds. Incidents recorded for its size in earlier versions no longer count against it, nor does being the busiest app on the Mac while you use it (Claude at half a core flipped between Watch and Hot), and a big app above its usual size says by how much ("Bigger than usual for it: 1.7x the 1.2 GB it usually uses").
- A loop holding several cores steadily is caught on big Macs too: the CPU limit grows with the core count, so three cores held for hours used to go unnoticed. After ten steady minutes it is evidence, and a runaway when the process has nobody attending it, such as a job whose terminal closed.
- "Stop only <helper>" names the helper that is actually leaking: while an app leaks slowly, a helper that just started and is warming up no longer takes the blame.
- A climb is called a leak only after Ghost has watched it for a minute. Twenty seconds of clean growth on an app that had run for half an hour (the Simulator booting a device) was Urgent "Sustained memory growth" before the app had been observed for 25 seconds; it now reads Watch ("the trend still needs confirmation") and escalates only if the climb keeps going. "Memory and CPU accelerating" waits for the same minute and for the startup grace.
- A build or test run is no longer called a leak: a compile job climbing 535 MB/min is the work itself, and gives its memory back when it exits. Its size still counts (Hot when over its limit), a Mac it squeezes is still flagged through memory pressure, and build watchers, which stay up, keep full leak detection. Before, another tool's `xcodebuild` was Urgent with a Stop Build button.
- An app already past its memory limit is no longer "Leaking" for slow growth a minute in: Claude at 4 GB climbing 44 MB/min while in use was, and so was every big app while its baseline relearned. Past its limit, slow growth is watched until it reaches the leak limit or twenty minutes prove it; a family about to cross its limit is still called a leak for a slower sustained climb.
- Right after launch on a busy Mac, an app's helpers no longer show as separate families: the first scans read every program's path even past their time budget, so Claude's renderer is part of Claude from the first scan instead of a Hot family of its own (All Processes read "175 of 26" and Attention held 57 rows for half a minute).
- A launch is no longer scored Critical. For a process's first 150 seconds a memory ramp reads at most Watch ("Memory is rising, but the process only just started") with no Urgent badge, no notification and no stop suggestion, and it is not counted as a leak (Leaks, "Sustained memory growth", "Stop only <helper>") until grace is over. A launch already far over its memory limit still reads Hot.
- A burst of CPU in a big app is judged against the Mac's cores: 61% of one core is 20× a chat app's usual 3%, but on a ten-core Mac it is a seventh of the CPU limit. It counts as Hot only at five times normal and half the core-aware limit, and otherwise stays at Watch, so the app is no longer taken off "Large, but normal for it", recorded as an incident and never learned.
- Growing back to a usual size is a refill, not a leak: an app restarted or purged of its caches (Claude at 1.7 GB against a learned usual of 2.5 GB) stays "Large, but normal for it" while ten more minutes of its growth still end inside its usual size. Growth past the leak limit is unaffected.
- Memory pressure at Warning no longer turns every big app into Review: an app at or near its usual size (at most 1.1×) stays on Watch, is not recorded as an incident and is still learned, with "the Mac is short of memory, so it stays on watch" in its evidence; anything bigger stays Hot, and Critical pressure still keeps big apps Hot. A lone slow grower is no longer called the driver of host memory pressure: growth counts from 20 MB/min.
- Copies that give almost nothing back no longer raise a family: two idle 2 MB copies of a tool made both families Watch ("Activity to review, 2 MB"). Independent copies raise their families only when stopping the extras would free at least 32 MB, or a copy listens on a port. Booted simulators are never copies of each other.
- The CPU history counts a new process from its first usage read, one scan sooner.
- Heavy radar mode tracks an app whose helpers add up to half the memory limit even when no single process does. Developer tools and All modes are unchanged.

### Overview and console
- The Overview no longer calls a big app at its usual size an "Early warning": with no Hot family and only size against the watched ones, the verdict stays calm and says how many families are watched for size only. Growth, CPU, duplicates, a forgotten process tree, a size above the learned normal and pressure or baseline votes still raise one. Warming Up lists families with an early sign first.
- The verdict's first button says where it goes (Review app, Review database, Review containers, Review family) instead of "Quit app" beside the real Quit button. The Overview's numbers match the lists they open: Needs review opens a new **Review** filter, the Risk Queue shows its full count with "Show all N", and Leaks counts every credible leak. When the Risk Queue and Warming Up are both empty, one slim all-clear strip replaces the two empty cards.
- Incidents no longer stretch across sleep: an episode not observed for 90 seconds ends at its last sighting. An incident's CPU and growth are the episode's peaks (a 400% build could read 0%, and a leak could show a negative growth beside "memory climbing 247 MB/min"). Search and the Resolved and Critical filters reach the newest 2,000 incidents instead of 80, an app with repeated episodes gets a descriptive Recurrence section, durations read in whole units, and the family name comes before the Running marker.
- Snoozing or ignoring a family that just exited or restarted now really saves the rule, for its signature; before, the toast said "Snoozed X for 1 h" while nothing was saved. The Toggle Inspector shortcut (⌥⌘I) works only on a family page, and the Snooze, Ignore, Stop and Next/Previous menu commands follow the toolbar's rules.
- Command-W, Command-M and Zoom work in the console and Settings, through a new Window menu. Menu-bar hover text no longer repeats itself ("4 to review - 28 families" instead of "4 hot - 28 families - 4 hot - 0 leaks"), the sidebar's Duplicates, Incidents and Rules are one row of tiles so "Duplicates" is no longer clipped, and the popover shows *Throttling* or *Critical heat* while macOS reports serious or critical thermal pressure.
- A first-ever launch opens the console with a short welcome (where Ghost lives, an Allow button for notifications, Open at login, a tour). Before, a new user double-clicking the app saw nothing at all. It is shown once, never to anyone who already has a Ghost store, and never with `--console` or `--section`.
- All Processes counts its total from the same scan as its rows (it could read "26 of 25"), the popover shows the same draw as the Energy page (it used the last ninety seconds, the page five minutes), and the menu bar's spoken state says "4 to review" as the console does, not "4 hot".
- With adaptive scanning off, the Refresh slider (1 to 5 seconds) sets the on-screen pace in every mode; the half-second setting never took effect and is gone.

### Stopping
- Asking an app to quit (⌘Q) now confirms it is still the same process right before the request goes out, on the main thread, instead of before waiting for it; a process ID reused in between can never receive the request.
- An app that is still answering its quit request (a save prompt, "Leave site?") no longer has its helpers, renderers and extension hosts terminated behind its back; helpers an app left behind after it exited still get `SIGTERM`. A "still open" result is no longer stale: when Ghost becomes active again, and from a new **Check Again** button, the sheet takes one targets-only look (never a signal), and an app that has quit turns the result into "Stopped Pages…".
- A stop of a single process says which children it leaves behind, checks them again for a moment afterwards, and lists the ones still running with **Stop It Too**. "You get back" and "Stop only <helper>" no longer ignore the memory of processes past the stop snapshot's 64 heavy reads (Chrome, Electron apps, Xcode builds, the simulator). Stopping an app helper says what it is; a macOS XPC service is no longer called launchd-kept or an orphan; stopping a simulated device gives the exact `xcrun simctl shutdown` command.
- A family's page after a stop no longer says "Stopped" and "Freed" for workers that are still running: a family leaves the scan the moment its root exits, and only survivors that are really gone are counted.

### Sentinel
- Trust is bound to what makes a program trustworthy, never to its path: a signed app is trusted by its team and identifier, so updates stay trusted; an ad hoc build by its exact build; an unsigned program by its exact file. The Trust item says which ("Trust Slack (Team BQR82RBBHL)").
- Shells, interpreters and system tools are never trusted whole. Trusting bash for a browser extension used to hide every later bash finding, reverse shells included; now it trusts that one script or command.
- A trusted program that changes — another signer, a rebuild, an edited script — is flagged again as Suspicious, saying what was trusted and what is there now.
- A binary swapped in place can no longer inherit the signature of the file it replaced, even when back-dated with `touch -r`.
- The Security page lists what you trusted, with Revoke. Paths trusted in earlier versions are carried over once; shells and tools among them are dropped.
- A download-and-run command is excused as a known installer only when the address it downloads is that installer's own https host: look-alikes such as `sh.rustup.rs.evil.example` or `sh.rustup.rs@evil.example`, and a harmless installer URL placed elsewhere in the same command, no longer hide it.
- Trusting one finding no longer changes whether other findings for the same program show as running.
- A command pasted into a terminal that downloads and runs code (`curl … | sh`) is caught, including `curl -so - …`, `sudo -u root bash` and `bash -o pipefail`: the shell starts it as separate processes, and Sentinel now puts the pipeline back together from its process group. The "pasted command" warning appears, and decoding on the way (`curl … | base64 -d | bash`) is Dangerous. Official installers such as rustup and Homebrew stay quiet.
- Terminal tabs that were already open when Ghost started are watched too; before, only tabs opened afterwards were.
- Switching microphones or plugging cameras in and out no longer piles up listeners, and a camera that comes back is watched again at once instead of after a minute.
- Dismissed findings stop counting once they expire, and a program that runs a second command inside the same process gets its own launch-feed entry.
- Trusting a pasted `curl … | sh` now trusts that exact pipeline, address included, not every later `sh`: one click on Trust This Exact Command used to store the digest of a bare `sh` and hide every later pasted download through the same shell. Trust also works on a finding whose process has already exited, for as long as it is listed.
- Python run through its framework app (Xcode, the Command Line Tools, python.org, Homebrew) is read: `exec(base64…)` one-liners, socket reverse shells and cookie-store copies through it raised nothing before, and a browser starting Python was not reported. A hidden file directly in the home folder (`~/.helper`) is flagged, and a hidden home program that nobody vouches for counts as oddly placed like one in `/tmp`.
- A program Claude or Codex just built and ran from a temporary folder is a Notable, not an alarm, when a shell the assistant started ran it and the temporary folder is the only Suspicious thing about it. Only an assistant running from where such tools install counts (`/Applications`, Homebrew, `~/.local/bin`, `~/.claude`, `~/.codex`, npm's and the version managers' folders): a file that merely carries the name in `~/Documents`, `~/Library/Caches` or a project does not.
- A dangerous command that had already exited when it was caught (a pasted `curl … | sh` is over in a second) sends one notification, and the Security page, the sidebar row, the Overview banner and the popover say so for 30 minutes; before, it alerted nothing under a green "Nothing suspicious running". Exited Suspicious findings stay quiet.
- An alert the notifier could not post (notifications not yet allowed, or a failed post) is offered again shortly instead of being counted as delivered and held back for a day. A startup item that turns worse after its first alert (its signature is read, or its plist is rewritten with a reverse shell) alerts again.
- Judging a process again when its arguments or ports arrive late keeps who launched it, so a payload whose wrapper shell had exited keeps its "Chrome started this" explanation and its Dangerous level. The Microphone tile stays calm while only Siri waits for "Hey Siri" (decided by the daemon's exact name and system path) and turns orange as soon as any other app records.

### Alerts
- A process family that stays Hot or Critical alerts once per episode, again when it gets worse (at least five minutes later) and as a reminder after twelve hours; before, it re-alerted with sound every 15 minutes. At most three process alerts are posted in any ten minutes, most urgent first, so a fourth family is no longer starved by three that already alerted.
- The Security (24 h) and Energy (12 h) cooldowns survive a relaunch, so an update, crash or login does not re-announce a standing finding; only SHA-256 hashes are saved, never paths or app names. **Settings › Alerts › What can notify you** turns process alerts and energy alerts off and can limit Security to Dangerous only; a dangerous finding always notifies.

### Heat
- macOS daemons that run as you (`cloudd`, `sharingd`, `suggestd` and similar) are named "macOS service" like on the Energy page and are never offered a Stop shortcut. iCloud sync, security checks (Gatekeeper, XProtect) and software update are explained sources instead of anonymous rows and "Start with syspolicyd".
- `swift`, `clang`, `git`, `make` and `python3` run from inside Xcode.app and started from a shell are that shell's job ("swift-build", "xcodebuild" in Terminal), not one row named "Xcode". A shell script run from a prompt is one job named after the script, a job orphaned to launchd that macOS holds a terminal responsible for is "Job in Terminal", and a recycled pid can no longer move a process's energy to an unrelated app.
- The thermal card shows fan speed under the temperatures ("Fans idle", or the fastest fan's rpm and share of its maximum), read-only and hidden on Macs without fans. The SMC key names come from a public registry and are unverified on this project's hardware.

### Search and diagnostics
- Search filters accept a decimal comma (`mem>1,5gb`, `watts>0,5`), which was silently dropped before, and a space before the unit (`mem>1.5 GB`, `writes>5 MB/s`). `--inspect` and `--type=renderer` find command-line flags instead of excluding them.
- Copy Diagnostics names the build, macOS, Mac model, chip, memory, cores, Low Power Mode, thermal state and locale, plus the detection settings and store sizes, and writes the home folder as `~`.

### Upgrading
- **Ghost relearns what is normal for each app after this update, about twenty minutes.** A family now includes the helpers macOS starts for its app, so the sizes learned by 2.1 no longer describe it. Until the new normal is trusted, big apps can read Review.
- Sections are ⌘1 Overview, ⌘2 All Processes, ⌘3 Security, ⌘4 Energy, ⌘5 Duplicates, ⌘6 Incidents, ⌘7 Rules. The store gains one table for Energy history (schema 6); nothing is dropped.

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
