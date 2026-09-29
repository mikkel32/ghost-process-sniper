# Energy: battery, sleep and power use

The Energy page answers "what is draining my battery, and what is keeping my Mac awake?" with measured numbers, not estimates from CPU percentages. It needs no administrator rights, reads nothing from the network, and never stops anything on its own.

Code lives in `Sources/GhostProcessSniperCore/Power` (measurement and judgement) and `Sources/GhostProcessSniper/Features/Energy` (the page, the family strip and the popover row).

## What is measured

| Measure | Source | Notes |
| --- | --- | --- |
| **Energy per process** | `proc_pid_rusage(RUSAGE_INFO_V6)`: `ri_energy_nj` | The energy macOS attributes to the process's CPU work since it started. Read in the same call as CPU time, for every process, every scan. Macs whose kernel does not account it report zero; the page then ranks by wake-ups and writes. |
| **Wake-ups** | `ri_interrupt_wkups` | Times a timer or interrupt woke the processor for the process: the count macOS's own wake-ups monitor limits. (The package-idle counter barely moves on Apple silicon.) |
| **Disk writes** | `ri_diskio_byteswritten` | Bytes written to storage. |
| **The Mac's draw** | AppleSmartBattery `PowerTelemetryData` `AccumulatedSystemLoad` and `SystemLoadAccumulatorCount`, else the snapshot (`SystemLoad`, `BatteryPower`, amperage × voltage) | The whole Mac, display and graphics included. The accumulators are the power controller's own running sum of load samples (about one a second) and how many it took, so two readings give the exact mean between them. The registry republishes only every 10 to 60 seconds, so the snapshot is one held sample and is only the fallback until ten samples exist and on Macs without the counters. Outside 0 to 400 W is discarded. |
| **Battery** | AppleSmartBattery capacity, voltage, design capacity, cycle count; `NominalChargeCapacity`; `AdapterDetails` | Remaining watt-hours come from the raw capacity and voltage. Health is `NominalChargeCapacity` (what macOS's Maximum Capacity comes from) over design capacity, falling back to the raw maximum on Macs without the key. |
| **Charger** | `AdapterDetails` `Watts`, read only while external power is connected | The negotiated rating (65 W), not the live wall input: that equals the Mac's load plus what goes into the battery, so it moves with the work and is not the charger's size. |
| **Charging state** | Signed net battery flow (`InstantAmperage` × `Voltage`, positive into the battery) | Not the charging flag, which stays on while a charger too small for the work lets the battery drain. **Charging** above +0.5 W (holds down to +0.2), **Draining while plugged in** at or below -1.5 W (holds to -0.5) and only while the wall input is at least 80% of the rating (otherwise the reading is stale and the flag decides), **Plugged in, not charging** in between. Without a current the flag decides. |
| **Sleep blockers** | `IOPMCopyAssertionsByProcess` | The same list `pmset -g assertions` prints, including `AssertionOnBehalfOfPID`, which names the app a daemon holds an assertion for. |

Rates are computed per process identity (PID plus start time) from two reads on the monotonic uptime clock, so a reused PID never borrows another process's counters and sleep never counts as time. A process's first read only sets its baseline.

The battery is read every 2 s while a window shows energy and every 15 s otherwise; powerd is asked every 5 s and 30 s. Each read asks for the few registry keys it needs, never the battery's whole property table.

## Who gets the blame

Processes are grouped into the app, command-line job or known macOS source that owns them, the same way the heat panel groups them (`ThermalWorkloadResolver`): an app's helpers join the app, compiler children join their build, and a job is named after the command below the shell.

Helpers launchd starts for an app outside its bundle, such as Safari's `com.apple.WebKit.WebContent` tabs, would otherwise stand alone. For those, Ghost asks macOS which process is responsible for them (the attribution Activity Monitor uses) once per process, so a busy tab counts against Safari. The heat panel uses the same attribution.

Sleep assertions a daemon holds for an app are blamed on the app: when coreaudiod keeps the Mac awake because a Safari tab still holds the speakers open, the row reads **Safari · An audio stream is open (held by coreaudiod)**.

## The energy ledger

`EnergyLedger` keeps an hour of one-minute buckets per group: joules, wake-ups, bytes written, CPU seconds and the time actually observed. Each bucket adds the growth of every member's lifetime counters since its last read, so totals are exact at any scan rate, and a gap longer than 30 s (sleep, a stalled scan) is charged but not counted as observed time. Averages are over the time observed.

## Today and this week

Each scan's charges also go into today's totals, keyed so the same work adds up across runs: an app by its path, a known source by name, and a command-line job by its command (two runs of `vite` are one row). Every five minutes, and when Ghost quits, what has not been written yet is added to that day's row in the `energy_days` table (schema v6). At launch today's rows are read back, so a restart continues the day. The **Today** card shows the heaviest apps, today's measured total against a full charge, and a bar per day for the last week. Days older than five weeks are deleted by the daily maintenance.

## Findings

A finding says what, shows the numbers, and gives one next step. It stays until its measure falls below 80% of the threshold, so it does not flicker at the edge.

| Finding | When | Level |
| --- | --- | --- |
| **Keeps your Mac awake** | An app or job (not macOS, not a keep-awake utility) has held a sleep or display assertion for 30 minutes while averaging under 1% of one core for the last ten | Attention after two hours, or on battery |
| **Wakes the processor** | One of its processes averages 150 wake-ups a second or more over about five minutes (after about four minutes of observation) while the app or job uses under a quarter of a core. 150 a second per process over five minutes is the limit macOS's own wake-ups monitor enforces | Attention at 500 a second, or 300 on battery |
| **Writing to disk** | About 1.7 MB/s for ten minutes (1 GB), after eight minutes of observation. Builds, tests, databases, container VMs and model runners write for a living, so for them it takes 20 MB/s | Attention at 20 MB/s |
| **Costing battery** | On battery, at least a fifth of the Mac's draw (and 1.5 W) over five minutes, and stopping it would add 20 minutes or more | Attention at an hour or more |

Keep-awake utilities (Amphetamine, KeepingYouAwake, Lungo, Theine and others) and `caffeinate` with a timeout, a PID to wait for or a command to run are listed but never flagged; a bare `caffeinate` left running is.

An app that holds both a system-sleep and a display-sleep assertion is one finding, one card and one notification: the assertion held longest leads the headline (a tie goes to the whole Mac) and the other is added once it has held 30 minutes too. macOS's own services and known sources (iCloud sync, security checks, software update, Spotlight) are never coloured or flagged.

The Energy rows and the family chips follow the same tests as the findings: a row's wake-ups figure is orange only when its busiest process is over the limit while the app is nearly idle, and its writes figure only when a *Writing to disk* finding would show. A finding can be showing while its row is plain (it holds on below its limit), never the reverse.

## Battery time

While on battery, the draw is the mean of the power controller's own samples over the last 90 seconds (the snapshot average is the fallback), and the time left is the remaining watt-hours over that draw. The header's draw and the apps' share use five minutes, the same window as the per-app figures, and so does the *Costing battery* finding. The time an app would give back is the difference between the battery lasting at today's draw and at today's draw minus the app's five-minute average, capped so the display and the rest of the Mac always remain. It is a ceiling: stopping an app can move some work elsewhere.

## Where it shows

- **Energy** (⌘4): the battery and draw with an hour's sparkline (headed *Charging*, *Plugged in, not charging* or *Draining while plugged in*, with the charger's rating and, when it can be true, how much of the draw apps and jobs account for), findings, **Using energy now** (average watts, wake-ups, writes and battery time gained), **Keeping your Mac awake** (unexpected holders first; keep-awake apps marked; macOS's own services folded away) and apps that used energy in the last hour and exited.
- **Overview**: a banner while a finding needs attention.
- **Notifications**: one per finding that needs attention (`EnergyAlertGate`); the same finding stays quiet for 12 hours, so an app that keeps the Mac awake every night alerts once a night.
- **Popover**: the top finding, or the battery line while on battery.
- **Family pages**: energy, wake-ups, disk writes and whether the family keeps the Mac awake, averaged over about a minute.
- **Search**: `watts>2`, `wakeups>150`, `writes>5mb` (per second).

## Limits

- Per-process energy covers CPU work. Graphics, the display, radios and storage come on top; the page shows the Mac's whole draw next to the measured share, which is a floor. The share is left out when it cannot be true (apps above the whole Mac's draw, or no draw at all).
- Processes owned by other users (root daemons) cannot be read without privileges, so their energy is not measured; their sleep assertions still are.
- Battery time is a projection from the last minute's draw, which changes with brightness and workload.
