# Changelog

All notable changes to Ghost Process Sniper are documented here. The project follows [Semantic Versioning](https://semver.org).

## [Unreleased]

### Search
- Search reaches every running process, not only tracked families. Apps outside the watch scope appear under *Other running processes* with memory, CPU, PID, and copy/reveal actions.
- Matches helper names, command lines, paths, PIDs, and listening ports; words match in any order and ignore case and accents.
- Ranked results with highlighted names and a note explaining matches found through a helper, command, PID, or port.
- Filters: `-exclude`, `"phrases"`, `name:`/`cmd:`/`path:`/`user:`/`kind:`, `pid:`/`port:`, `cpu>`/`mem>`/`gpu>`/`threads>`/`leak>`/`children>`, and `is:` states. Understood filters show as chips; half-typed filters never blank the list.
- Typo- and acronym-tolerant fallback (`crhome`, `vsc`) when nothing matches exactly.
- Return in the search field opens the best match; typing from any section opens the results.
- Incident and duplicate search use the same matching.

### Smarter stopping
- Every stop now knows what it is interrupting: apps, document editors, databases, container runtimes, git, package installs, builds, dev servers, and model runners are recognised from their names, paths, and command lines.
- Apps are asked to quit like ⌘Q before any signal, so they can save their work. Databases and container runtimes get time to shut down cleanly.
- Work that can lose data is never force-stopped unless you allow it; survivors can be force-stopped in one step after you check them.
- Supervisors that would restart a process (nodemon, pm2, forever, supervisord, watchexec, cargo watch, air, tsx watch, entr, overmind, launchd agents) are detected before the stop, and a restart after it is reported.
- The preview leads with what will happen, the risks, and what you get back (memory, CPU, processes, freed ports). Engine internals moved behind **Engine details**.
- Family pages show what stopping the family would do, and the button reads **Quit App…** for apps.
- Grace periods end as soon as the processes exit even when the exit watcher is unavailable.
- Learned timing is kept per strategy, and never shortens an app's or database's clean-shutdown time.

### Layout
- Process list column headers sort by name, memory, or CPU; click again for priority order.

### Documentation
- Dated session notes are replaced by one [Thermals](Docs/Thermals.md) reference and one [Performance](Docs/Performance.md) guide.

### Fixed
- Paste, copy, cut, select all, and undo now work in the console's text fields (the app menu had no Edit menu).
- The **Leaks** filter shows credible leaks only, instead of any family whose memory grew at all.
- The sidebar's *View all* for Stable families opens exactly those families.
- **All Processes** (⌘6) is available from the Radar menu.

### Removed
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

[1.0.0]: https://github.com/mikkel32/ghost-process-sniper/releases/tag/v1.0.0
