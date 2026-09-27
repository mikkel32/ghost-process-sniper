# Performance measurements

The core checks make no timing claims, and ordinary tests make no tight ones: wall-clock budgets in debug builds on shared runners were noise, so every benchmark is opt-in, runs a release build on synthetic input, and never samples or signals a live process. Three tests assert a time budget: `testPipelineTickCostOnADeveloperMac` (a 25 ms median tick, release builds only), `MemberTrendStoreTests`' scale test (5 ms per tick, release builds only) and `StopRiskMemoTests.testLongArgvAssessmentStaysCheap` (a loose 25 ms per assessment in every build, which only a full-argv scan would miss). `ProcessMonitorWakeTests` also checks that showing a surface wakes the hidden sleep within 0.5 s. None of them measures frame rate, energy use or real sensors.

## Running the benchmarks

```sh
mkdir -p .build/performance-audit
RADAR_BENCHMARK_REPORT="$PWD/.build/performance-audit/pipeline.json" \
RADAR_INDEX_BENCHMARK_REPORT="$PWD/.build/performance-audit/duplicate-index.json" \
  swift test -c release --filter 'PerformanceAuditTests|DuplicateIndexPerformanceTests'
python3 Scripts/benchmark_incident_query.py --output .build/performance-audit/incident-query.json
```

| Benchmark | Gate | What it measures | Report |
| --- | --- | --- | --- |
| `PerformanceAuditTests.testRefreshPipelineBenchmark` | `RADAR_BENCHMARK_REPORT` | The real `RadarRefreshWorker` ingestion (families, scoring, presentation) for 250 and 1,000 synthetic families, 7 samples after 2 warm-ups; persistence disabled | `pipeline.json` |
| `PerformanceAuditTests.testLargeSampleScaleBenchmark` | `RADAR_BENCHMARK_REPORT` | `RadarPipeline` and a kill preview over a fake process table for 2k, 10k and 30k processes, with functional assertions | `pipeline-scale.json` beside the report |
| `PerformanceAuditTests.testPipelineTickCostOnADeveloperMac` | always runs | `RadarPipeline` over 20 ticks of the 600-process `DevWorkstationFixture`; in release builds the steady-state median must stay at or under 25 ms | printed |
| `DuplicateIndexPerformanceTests` | `RADAR_INDEX_BENCHMARK_REPORT` | Duplicate-to-family resolution, old algorithm against the indexed resolver in alternating order on the same input, results asserted equal | `duplicate-index.json` |
| `Scripts/benchmark_incident_query.py` | always explicit | The recurrence-count query on a temporary 120,000-row SQLite database, before and after the `(signature_id, started_at)` covering index, results asserted equal | the `--output` path |

The 10k and 30k timings used to be millisecond budgets in the core checks (`radarPipelineHandlesLargeSamples`, `fakeKillPreviewStaysOnTheGraph`); the checks now assert only behaviour on a 2k sample.

Treat a single run as one observation. Other workloads, thermal state and power mode all move the numbers; compare before and after on the same Mac, alternating the order when the difference matters.

## Recorded results

Raw reports live in `Docs/Benchmarks/`. They were captured on one development Mac with the release toolchain of the day; they are not guarantees for other Macs or workloads.

**2026-09-09** (`Benchmarks/2026-09-09/`): the refresh pipeline before and after demand-driven detail panels and actor-prepared queries, in three alternating rounds (21 samples per version), plus the unpaired first runs, kept rather than discarded.

| Synthetic families | Before median | After median |
| ---: | ---: | ---: |
| 250 | 48.1 ms | 38.7 ms |
| 1,000 | 192.2 ms | 172.5 ms |

The incident query took 24.6 ms with the old index and 2.1 ms with the covering index (`incident-query.json`), about 12 times faster for that query alone. Rich detail panels in the 1,000-family fixture fell from 1,000 to 9 (a construction count, not a RAM measurement).

**2026-09-11** (`Benchmarks/2026-09-11/refresh-refinement/`): duplicate resolution, old against indexed.

| Families | Clusters | Old median | Indexed median |
| ---: | ---: | ---: | ---: |
| 250 | 125 | 3.0 ms | 0.8 ms |
| 1,000 | 500 | 35.6 ms | 3.2 ms |
| 4,000 | 2,000 | 514.6 ms | 14.5 ms |

The whole refresh pipeline moved from 34.3 to 28.9 ms (250 families) and from 124.8 to 117.9 ms (1,000 families) in one before/after batch (`pipeline-before.json`, `pipeline-after.json`). That fixture uses distinct executables, so it is not the duplicate-heavy workload above.

## Energy: the running app

The benchmarks above time the pipeline; they cannot see SwiftUI layout, rendering, or what the app costs while it sits in the menu bar. On 2026-09-27 the running app was measured directly on an M1 Pro with other apps open: CPU time from `ps` over fixed windows (user plus system, as a percentage of one core), `sample` for where the time went, and Instruments' SwiftUI template for view updates. Each figure is one observation on a busy Mac; compare them as directions, not guarantees.

| State | 2.0.0 | After |
| --- | ---: | ---: |
| Console frontmost, 30–60 s windows | 42% | 23–28% (includes Sentinel) |
| Menu bar only, 60 s after a 150 s warm-up | 0.75–0.93% | 1.05–1.15% (includes Sentinel's watchers) |

What the profiles showed and what changed:

- **Size queries.** SwiftUI hosts each `NavigationSplitView` column in its own hosting view, and AppKit asked the detail column for its minimum size on every update. The Overview answered by measuring its whole scroll content at zero width: about half of the main thread's busy time while the console was visible. The column now sits in `SizeIndependentLayout`, which answers from the proposal alone and lays the page out once at its real size. The measuring samples fell from about 1,800 to 33 in the same window.
- **Unattended consoles.** A console on screen refreshed every second even when nobody had touched the Mac for an hour. After 30 seconds without input it refreshes every 2 seconds, after 2 minutes every 4. Any input returns it to the watched rate on the next tick.
- **Per-tick queries and string work.** Incident recurrence counts were queried on every scan; they are now cached and re-counted only for signatures whose episode closed or reopened. `URL(fileURLWithPath:)` stats the file to learn whether it is a folder, and two per-family paths called it on every refresh; they now use string slicing. Command-line splitting takes an ASCII fast path before the Unicode whitespace lookup.
- **Layouts.** `AdaptivePairLayout` measured each child again for placement; it now caches measurements for one layout pass.
- **Sentinel's cost.** Its watchers are event-driven: kernel process events for spawns, file-system events for launch agents, and Core Audio and CoreMediaIO listeners for the microphone and camera. In a 45-second hidden profile, Sentinel's own work was about 0.08% of a core; signature checks run once per program at utility priority with a pause between files.

To repeat a measurement, compare CPU time from `ps -o utime=,stime= -p <pid>` at the start and end of a window, alternate builds, and keep the same apps open.

## Instrumented timings in the app

**Settings › Diagnostics** reports the app's own refresh cost and CPU; Copy Diagnostics adds the scanner, store and smoothness figures, including the phases of recent slow refreshes. Main-actor publish timing includes the assignments and observer callbacks; the next refresh reports the preceding completed publish, so the measurement cannot trigger itself. It does not include deferred SwiftUI layout or rendering; use Instruments for those.
