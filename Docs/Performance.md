# Performance measurements

Debug test runs and the core checks make no timing claims: wall-clock budgets in debug builds on shared runners were noise, so every benchmark is opt-in, runs a release build on synthetic input, and never samples or signals a live process. The one exception is `testPipelineTickCostOnADeveloperMac`, which asserts a budget only in release builds. None of them measures frame rate, energy use or real sensors.

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

## Instrumented timings in the app

**Settings › Diagnostics** reports the app's own refresh cost and CPU; Copy Diagnostics adds the scanner, store and smoothness figures, including the phases of recent slow refreshes. Main-actor publish timing includes the assignments and observer callbacks; the next refresh reports the preceding completed publish, so the measurement cannot trigger itself. It does not include deferred SwiftUI layout or rendering; use Instruments for those.
