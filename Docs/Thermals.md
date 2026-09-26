# Thermals: sensors, interpretation and attribution

The thermal feature answers two separate questions: how hot the chip is (measured by hardware sensors), and which work is keeping it busy (measured by process activity). It never invents a per-app temperature or a share of heat, and nothing in it changes fans, power limits or processes by itself.

## Data flow

```text
ThermalSampler (actor, ThermalTelemetry.swift)       read-only AppleSMC, snapshot cached for 3 s
    └─ ProcessMonitor.refresh                         awaits it before each worker refresh
        └─ ThermalSnapshotStore                       assigns only a changed snapshot; records a new
            ├─ monitor.thermals                       reading into monitor.thermalObservations
            └─ monitor.thermalObservations            (ThermalObservationWindow: 90 readings, 180 s)

RadarRefreshWorker.ingest (every refresh, raw sample batch)
    └─ ThermalActivityAnalyzer.project                every sampled process, grouped into apps and jobs
        └─ ThermalActivityHistory.record              worker-owned, 180 s, decayed load per contributor
            └─ RefreshOutcome → monitor.thermalActivity (ThermalActivitySummary)

ThermalInsightPanel (Overview)
    ├─ ThermalDiagnosis.evaluate                      band + trend + macOS thermal pressure → headline
    └─ ThermalAppInsight.evaluate                     the named workload and its next step
```

The projection runs over the raw batch, so radar family filters never hide an app; families only supply the navigation target. The observation window lives in the monitor, so the trend and the traces are ready the moment a thermal view opens. Opening a thermal view never starts a scan or a second projection.

The console also hands the window to `OverviewThermalBandTracker`, which moves the thermal panel up to second on the Overview only while macOS reports serious throttling or very hot readings (two or more in a row at 90 °C or above) have lasted 30 s, and moves it back after a minute of calm.

Views re-render when the monitor publishes and, between publishes, only at the instants a reading expires (`ThermalActivitySummary.expiryDates(after:)`, `ThermalSnapshot.expiresAt`) through explicit `TimelineView` schedules. There is no periodic timer.

## Sensors

`ThermalSampler` talks to AppleSMC through `SMCTransport`, whose IOKit implementation lets only the read commands 5, 8 and 9 through. A snapshot reports the hottest valid sensor per component, the key or key set that produced it, and why readings are unavailable. Readings outside (0, 125] °C are rejected, and a snapshot older than 15 s shows Unavailable. `ProcessInfo.thermalState` (macOS thermal pressure) is read separately and is never derived from Celsius.

| Chip | Sensor map | Status |
| --- | --- | --- |
| Apple M1 family | Fixed key table | Verified on an M1 Pro |
| Apple M2 family | Fixed key table | Verified |
| Intel | `TC0D`/`TC0P`, `TG0D`/`TG0P` | Verified |
| Apple M3, M4 families | Key tables from the chip catalog | Unverified; the hero card says so |
| Other Apple chips (M5 and later) | One SMC enumeration (at most 4,096 keys): float `Tp`/`Te` keys as CPU and `Tg` as GPU when they read 20–110 °C, at most 24 each | Best effort; the card says so |
| Anything else | None | Unavailable, with the reason shown |

The chip generation is parsed as a whole number from the brand string ("Apple M1 Pro" → 1), so a future "Apple M10" never matches the M1 table. SMC is not a public API; future hardware or macOS changes can break any map.

## Review bands, trend and persistence

| Hottest valid sensor | Review band |
| --- | --- |
| Below 70 °C | Below warm band |
| 70 to below 80 °C | Warm |
| 80 to below 90 °C | Hot |
| 90 °C or more | Very hot |

These are this app's review bands, not Apple operating limits or a hardware fault detector. Serious and critical macOS thermal pressure always keep their higher-priority guidance, even when a sensor is missing or reads lower.

- **Recording.** Only a new sensor timestamp adds a reading; duplicate and out-of-order readings are ignored, and a re-published cached snapshot is not reassigned. The window keeps 90 readings and 180 s.
- **Trend.** Needs at least 4 readings from the same sensor series spanning at least 30 s within the latest 60 s. It compares the median of the earliest and latest (up to 3) readings; a change of 2 °C or more is rising or falling, anything less is steady. A missing value, a switch to a different sensor series, or a gap over 15 s ends the series, so the trend restarts at the gap.
- **Persistence.** The span of consecutive readings at or above 70, 80 and 90 °C. One reading is not a span, so a single spike never reads as sustained heat.
- **Traces.** `ThermalObservationWindow.segments(for:at:)` draws only real readings and starts a new segment at a missing value or a gap over 15 s.

## Attribution

`ThermalActivitySummary.build` deduplicates PID + start-time identities, drops invalid readings and readings older than 12 s, and groups processes by what owns them (`ThermalWorkloadResolver` walks the process tree):

1. Known macOS and virtualization sources (Spotlight, Photos analysis, Time Machine, WindowServer, Linux VMs) become one row each and count as system work.
2. Processes inside an `.app` bundle, or launched by an app that is not a terminal, join that app.
3. Work started from a shell or a terminal becomes one command-line job, named after the process the shell started and noting the terminal it runs in, so `make -j10` reads as one build rather than ten compiler rows.
4. Other process trees become one job under their topmost ancestor; a lone process stands alone.

Native CPU counters (`proc_pid_rusage` and `PROC_PIDTASKINFO`) count Mach absolute-time ticks. `Sampling/ProcessCPUTime.swift` converts them with `mach_timebase_info` (125/3 on the tested Apple silicon Mac) before adding them; without it CPU work was understated about 42 times and attribution collapsed.

Rows rank by the larger of CPU capacity (process CPU divided by the logical processor count) and reported GPU activity, and appear from 5%. A row is substantial at 80% single-core CPU, 10% of total CPU capacity or 15% reported GPU. Each row keeps at most six process records; totals include every usable process.

`ThermalActivityHistory` keeps, per contributor, a decayed accumulated load, because chip temperature integrates power over roughly a minute:

- Every measured contributor at 5% or more updates it: `ewma = ewma·exp(−gap/60) + activity·(1 − exp(−min(gap, 15)/60))`, where gap is the time since that contributor's last measurement. The old average decays over the whole gap; only the new reading's weight is capped at 15 s. With gaps of 15 s or less this is the usual `ewma·(1−α) + activity·α`, so 1 s and 5 s refresh cadences agree.
- A new contributor starts at `activity·(1 − exp(−Δt/60))` for the time since the previous sample, so one reading can never reach full weight.
- A reading without a measurement only lets the load decay: `load(t) = ewma·exp(−(t − lastMeasured)/60)`. Entries below 1% or older than 180 s are dropped. Re-publishing the same sample replaces its contribution instead of counting twice.

`ThermalAppInsight` names the leader as the substantial current row or, while heat needs review, the heaviest sustained load, whichever is larger. A compile at 80% for 150 s that ended 10 s ago therefore outranks a 12% one-reading blip. Evidence is *repeated* after at least 3 readings spanning 20 s. Recent work is described as "averaged N% of CPU capacity over the last M min (recent readings weigh more)".

### Path to stopping

The thermal panel never signals anything. `ThermalStopTarget` resolves the process family a stop would actually open (a contributor groups a whole app, but its family key points at the busiest member family, so the button can read "Stop SourceKitService (Xcode)…"). It is offered only for user work with owned processes: never for system work, known macOS sources, families with none of the user's processes or Ghost Process Sniper itself; processes the user does not own are left for the stop preview to lock. The attribution card shows it only for repeated evidence while heat needs review; the contributor sheet shows it whenever a target resolves. It follows the family's Quick Stop: "Quit" for an app, red only when the stop is recommended, and it goes through `RadarConsoleSession.quickStop`, which opens the family's page and then the usual stop preview, risk assessment and confirmation.

### Compare readings

`ThermalCoolingCheck` saves an app and sensor baseline. After the user changes optional work themselves, it compares newer CPU capacity, reported GPU activity and the same sensor series. Missing apps are not treated as zero load, stale or invalid sensors never produce a cooling result, and comparisons expire after 3 minutes. A drop is not proof that the app caused the heat.

## Limits

- Coverage counts usable readings in the latest scan. Some processes cannot be measured; the panel says so rather than treating them as quiet.
- A GPU value of zero is not proof that no GPU work happened.
- Activity is evidence about workload, not watts, degrees or a share of heat.

## Tests

`ThermalActivityTests`, `ThermalActivityHistoryTests`, `ThermalAppInsightTests`, `ThermalDashboardTests`, `ThermalInterpretationTests`, `ThermalObservationTraceTests`, `ThermalStopTargetTests`, `ThermalWorkloadResolverTests` and `SMCSensorCatalogTests` run on Linux as well as macOS; the SwiftUI views are covered by the macOS build.

Background: [Apple: Keep your Mac laptop within acceptable operating temperatures](https://support.apple.com/en-us/102336) · [ProcessInfo.ThermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum) · [WWDC19: Designing for adverse network and temperature conditions](https://developer.apple.com/videos/play/wwdc2019/422/) · [Stats sensor key registry](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)
