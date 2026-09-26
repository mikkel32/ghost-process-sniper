<p align="center">
  <img src="Docs/Assets/icon.png" width="168" alt="Ghost Process Sniper app icon: a ghost in the crosshairs of a radar scope">
</p>

<h1 align="center">Ghost Process Sniper</h1>

<p align="center">
  <strong>A native macOS menu-bar radar for runaway, leaking, duplicated, and forgotten processes.</strong><br>
  See what is heating your Mac, why, and what to do about it — entirely on your Mac.
</p>

<p align="center">
  <a href="https://github.com/mikkel32/ghost-process-sniper/releases/latest"><img alt="Download the latest .dmg" src="https://img.shields.io/badge/Download-.dmg-29B8E0?style=for-the-badge&logo=apple&logoColor=white"></a>
</p>

<p align="center">
  <img alt="macOS 26 or later" src="https://img.shields.io/badge/macOS-26%2B-1f2937?logo=apple&logoColor=white">
  <img alt="Universal: Apple silicon and Intel" src="https://img.shields.io/badge/universal-Apple%20silicon%20%2B%20Intel-1f2937">
  <img alt="Swift 6.3" src="https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white">
  <img alt="No network access" src="https://img.shields.io/badge/network-none-2ea44f">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-3b82f6"></a>
</p>

<p align="center">
  <img src="Docs/Assets/screenshot-overview.png" alt="Ghost Process Sniper console: live CPU and GPU temperature, the app doing the most work, and a list of processes that need attention">
</p>

Dev servers that never shut down. Electron helpers that quietly grow by 50 MB a minute. Three copies of the same watcher from terminals you closed yesterday. A fan that spins up and no idea why.

**Ghost Process Sniper** watches every process you own, groups helpers into *families*, learns what normal looks like, and tells you — in plain language, with the evidence — which ones deserve attention. When something really needs to go, it previews exactly what would be stopped and waits for you to confirm.

## Highlights

- **Menu-bar radar.** A tiny scope that turns orange or red when something needs attention, with a popover summary one click away.
- **Leak and runaway detection.** Sustained memory growth, CPU burn, and GPU load are tracked over time with trend baselines and forecasts, so a single spike doesn't cry wolf.
- **Process families.** Apps, helpers, dev servers, and the workers they spawn are grouped, so you see "Slack" or "vite dev" — not forty anonymous PIDs.
- **Duplicate finder.** Spots overlapping copies of the same work, like identical dev servers or watchers left behind by old sessions.
- **Real temperatures.** Measured CPU and GPU Celsius from hardware sensors (never invented per-app temperatures), plus *What's heating your Mac?*, which ties heat to the apps doing the work.
- **Incident history.** A local timeline of leaks, spikes, and runaways, so recurring offenders stand out.
- **Rules.** Notify, highlight, snooze, ignore, or suggest stopping matching families.
- **Careful interventions.** Every stop knows what it interrupts: apps are asked to quit like ⌘Q so they can save, databases and Docker get time to shut down cleanly, and nothing that can lose data is forced without your say-so. Previews warn when nodemon, pm2, or launchd would just restart the process, pin exact PID + start-time identities, refuse recycled PIDs, and expire after 60 seconds.
- **Light on your Mac.** Adaptive sampling backs off under memory pressure; the Engine view shows exactly how much CPU and memory the radar itself costs.

## Private and unprivileged by design

- **No network access.** There is no networking code: no telemetry, no analytics, no update pings.
- **No admin rights.** No privileged helper, kernel extension, or Full Disk Access. Sensor reads are read-only.
- **Your processes only.** It can only signal processes owned by your user, and only after you confirm.
- **Local data.** Settings and history live in one SQLite file in `~/Library/Application Support/Ghost Process Sniper/`.

## Install

1. Download **`GhostProcessSniper-<version>.dmg`** from the [latest release](https://github.com/mikkel32/ghost-process-sniper/releases/latest).
2. Open it and drag **Ghost Process Sniper** into **Applications**.
3. Open it from Applications. It appears in the menu bar (there is no Dock icon); choose **Open Dashboard** for the full console.

<p align="center">
  <img src="Docs/Assets/installer.png" width="560" alt="The installer window: drag Ghost Process Sniper onto the Applications folder">
</p>

**Requirements:** macOS 26 Tahoe or later, on Apple silicon or Intel.

### "Apple could not verify…" on first launch

Release builds are signed ad hoc but not notarized by Apple (that requires a paid Developer ID), so macOS asks you to confirm the first launch:

1. Open the app once and click **Done** on the warning.
2. Go to **System Settings → Privacy & Security**, scroll to *Security*, and click **Open Anyway** next to Ghost Process Sniper.
3. Confirm with your password or Touch ID. macOS remembers the choice.

Prefer the terminal? After copying the app to Applications:

```sh
xattr -dr com.apple.quarantine "/Applications/Ghost Process Sniper.app"
```

Each release lists the DMG's SHA-256 so you can verify the download with `shasum -a 256 GhostProcessSniper-*.dmg`. Or skip the binary and [build it yourself](#build-from-source) — it takes about two minutes.

## Using it

Click the menu-bar scope for a summary; **Open Dashboard** opens the console:

| Section | What it answers |
| --- | --- |
| **Overview** | What needs attention now, what is trending the wrong way, and why. |
| **All Processes** | Every family plus every other running process, searchable by name, helper, command, path, PID, or port — typo-tolerant, with filters like `cpu>20` or `is:leaking`. |
| **Duplicates** | Which work is running more than once. |
| **Incidents** | What has leaked, spiked, or run away before, and how often. |
| **Rules** | How the radar should treat specific apps or commands. |
| **Engine** | How much the radar itself costs, plus diagnostics for bug reports. |

Handy shortcuts: **⌘F** search (**↩** opens the best match) · **⌘R** scan now · **⌘1–⌘6** switch sections · **⌥⌘I** inspector · **⌘,** settings.

The [user guide](Docs/User-Guide.md) covers every panel, the temperature tools, and exactly how a safe stop works.

## Build from source

You need macOS 26 and Xcode 26 (or a Swift 6.3 toolchain).

```sh
git clone https://github.com/mikkel32/ghost-process-sniper.git
cd ghost-process-sniper
Scripts/dev.sh run
```

That builds an optimized, ad-hoc-signed bundle at `dist/Ghost Process Sniper.app` and opens its console. Other entry points:

| Command | What it does |
| --- | --- |
| `Scripts/verify.sh` | Architecture checks, build-script tests, unit tests, core checks, and a release build |
| `Scripts/dev.sh build` / `restart` / `debug` / `logs` | Build, restart after a build, run under LLDB, stream logs |
| `Scripts/release.sh` | Universal `.dmg` installer and checksum in `dist/release/` |

## How it works

```text
NativeProcessSampler (actor)      libproc / task_info probes, CPU·GPU·memory, SMC sensors
    └─ RadarRefreshWorker (actor) families, duplicates, baselines, forecasts, rules
        └─ RadarStore (actor)     local SQLite timeline and settings
    └─ ProcessMonitor (MainActor) observable facade for the menu bar and console
```

The code is split into two targets: **`GhostProcessSniperCore`** (sampling, intelligence, persistence, interventions — no UI) and **`GhostProcessSniper`** (SwiftUI app, menu bar, console). Architecture rules — folder ownership, the core/UI boundary, SQLite isolation, file-size budgets — are enforced by `Scripts/check_architecture.py`.

Further reading: [Architecture](Docs/Architecture.md) · [Development](Docs/Development.md) · [Releasing](Docs/Releasing.md) · [Performance measurements](Docs/Performance-2026-09-09.md) · [Temperature precision](Docs/Precision-2026-09-09.md) · [Thermal insight](Docs/Thermal-Insight-2026-09-11.md)

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). For bugs, **Engine → Copy Diagnostics** gives a report worth pasting. Security issues: see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Mikkel Mynderup
