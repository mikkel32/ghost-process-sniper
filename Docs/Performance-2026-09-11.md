# Refresh performance and architecture refinement

Measurements captured on September 11, 2026, using the local release toolchain.

## Changes

`DuplicateFamilyResolver` owns duplicate-to-family membership resolution. It builds an index from exact process identities to family positions once per projection, instead of checking every family for every duplicate cluster. Repeated members within a family are deduplicated; overlapping families remain supported. The index does not outlive its input snapshot.

Updating a duplicate cluster's ownership now retains its immutable members, totals, hints, and sample timestamps. The old implementation recomputed those values and sorted the members again. The family builder also no longer repeats its final family sort after ownership-only enrichment.

`FamilySamplingDemand` owns the pure projection of sampling priorities. One pass derives the highest priority, candidate identities, forensics identities, and demand counts. Runtime keys select one concrete family; logical signatures preserve the existing ability to request matching instances. The scheduler continues to own cadence, pressure gates, and budgets.

The final console source edit sends runtime keys for its eight visible priority rows and its selected family, instead of also sending their logical signatures. It is intended to prevent UI focus from requesting richer sampling for every matching sibling. Independent hot/warning demand can still request other families. A newly added regression fixture with 256 quiet instances sharing one signature asserts a bound of nine instances for eight priorities plus one additional selection. This last UI edit and additional test remain unverified, as detailed below.

These are focused components inside the existing core target, not new SwiftPM modules. The larger engine file remains in place.

## Paired duplicate-resolution benchmark

The old algorithm and the new production resolver ran in the same process, on the same synthetic input, in alternating order. Each population has two processes per duplicate cluster and one process per family. Two warm-up rounds were discarded; each median below uses seven retained measurements. Full result equality was asserted on every iteration, outside the timed sections.

| Families | Clusters | Previous median | Indexed median | Speedup |
| ---: | ---: | ---: | ---: | ---: |
| 250 | 125 | 3.020 ms | 0.755 ms | 4.0x |
| 1,000 | 500 | 35.629 ms | 3.206 ms | 11.1x |
| 4,000 | 2,000 | 514.563 ms | 14.458 ms | 35.6x |

Raw measurements: [duplicate-index.json](Benchmarks/2026-09-11/refresh-refinement/duplicate-index.json).

The 4,000-family case is a scaling stress test. These speedups apply to duplicate resolution, not to the whole application. The previous implementation remains only in test support as the comparison oracle.

## Broader refresh pipeline

The existing `PerformanceAuditTests` benchmark was captured before the production changes and again afterward. It builds, scores, and prepares presentation models for synthetic process samples, with persistence disabled. It checks that the full family inventory and requested details remain present.

| Families | Before median | After median | Lower measured time |
| ---: | ---: | ---: | ---: |
| 250 | 34.290 ms | 28.867 ms | 15.8% |
| 1,000 | 124.762 ms | 117.869 ms | 5.5% |

Raw measurements: [before](Benchmarks/2026-09-11/refresh-refinement/pipeline-before.json) and [after](Benchmarks/2026-09-11/refresh-refinement/pipeline-after.json).

This is one before/after batch with seven retained samples per population, rather than an alternating whole-pipeline comparison. Background load and thermal conditions can affect the result. This fixture uses distinct executables, so it is not the duplicate-heavy workload above. Its ingestion entry point also bypasses the scheduler's sampling-plan calculation. The whole-pipeline differences should not be attributed solely to the identity index or interpreted as a guaranteed application-wide improvement.

## Regression coverage

`DuplicateFamilyResolverTests` compares exact results against the old implementation over multiple sizes and forty deterministic mixed-ownership fixtures. Additional cases cover overlapping families, repeated members, unknown identities, recycled PIDs, empty inputs, exited families, immutable projection reuse, and the real family-builder integration.

`FamilySamplingDemandTests` covers bounded priority-plus-selection demand, exact runtime selection, logical signature selection, recycled PIDs, hot versus watch demand, empty input, and the scheduler's actual sampling plan. Existing measurement freshness, presentation, intervention, and persistence checks remain part of verification.

## Verified state and remaining work

Before the final console handoff edit, `Scripts/verify.sh` passed architecture checks, all 15 infrastructure tests, 85 Swift tests with two opt-in benchmarks skipped, all 113 executable core checks, and release compilation. Both opt-in benchmarks then passed in release mode, and a validated, signed application bundle was produced.

Afterward, the console handoff was narrowed to runtime keys and the 256-instance demand test was added. The command to verify and rebuild that final source state was blocked with: "This tool call was blocked by OpenAI because we couldn't determine the safety status of the request." Those final changes are saved but not verified. The produced bundle predates the final console edit. The application was not restarted and its live UI was not inspected.

The broader proposed engine-file decomposition was also blocked in a separate operation and remains pending. The two focused components and the measured core optimizations described above were successfully implemented and tested. These distinctions preserve the earlier completed work without treating a later tool failure as a successful final build.

## Reproduce

```sh
Scripts/verify.sh
mkdir -p .build/performance-audit
RADAR_INDEX_BENCHMARK_REPORT="$PWD/.build/performance-audit/duplicate-index.json" \
RADAR_BENCHMARK_REPORT="$PWD/.build/performance-audit/pipeline.json" \
  swift test -c release --filter 'PerformanceAuditTests|DuplicateIndexPerformanceTests'
```

The two benchmarks are opt-in and skip during ordinary test runs. Their fixtures do not sample or signal live processes. Release compilation and bundle verification are separate from launching or visually inspecting the running application. No frame-rate, energy-use, real sensor, SQLite-throughput, or process-termination performance claim is made by these measurements.
