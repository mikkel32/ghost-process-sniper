# Changelog

All notable changes to Ghost Process Sniper are documented here. The project follows [Semantic Versioning](https://semver.org).

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
