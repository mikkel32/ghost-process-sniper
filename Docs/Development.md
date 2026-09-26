# Development and source ownership

## Everyday commands

Run commands from the repository root. Requires the same macOS 26 and Swift 6.3 toolchain as the application; infrastructure checks also use Python 3.

```sh
Scripts/verify.sh                 # Complete checks and release compilation
Scripts/dev.sh build              # Validated application bundle
Scripts/dev.sh run                # Open if no instance is already running
Scripts/dev.sh restart            # Explicit restart after a successful build
Scripts/dev.sh debug              # Build, then launch under LLDB
Scripts/dev.sh logs               # Read process logs without rebuilding
Scripts/dev.sh telemetry          # Read subsystem logs without rebuilding
```

`script/build_and_run.sh` remains a compatibility wrapper and accepts the old `--` forms. `verify` now validates the project rather than starting an application just to check its PID. Invalid modes are rejected before building or interacting with a process.

## Where code belongs

| App folder | Ownership |
| --- | --- |
| `Application` | App entry, login integration, notifications, MetricKit |
| `MenuBar` | Status item, icon rendering, popover |
| `Shell` | Window coordination, navigation, selection, toolbar and sidebar |
| `DesignSystem` | Shared surfaces, controls, motion and radar primitives |
| `Features/<feature>` | Feature-specific views and their local UI state |

| Core folder | Ownership |
| --- | --- |
| `Domain` | Process identities, measurements, signatures, families and shared values |
| `Configuration` | User settings, performance policy and adaptive configuration |
| `Monitoring` | Refresh lifecycle, worker orchestration and the observable facade |
| `Sampling` | Native process/CPU/GPU sampling and sampling support |
| `Thermals` | Hardware sensors and the separate app-activity projection |
| `Intelligence` | Classification, family building, scoring, forecasts and patterns |
| `Persistence` | SQLite connection, schema, persistence and query ownership |
| `Presentation` | Immutable display models, snapshots, formatting and asynchronous queries |
| `Diagnostics` | Logging, self-usage accounting and responsiveness instrumentation |
| `Interventions` | Preview, authorization identity, execution, escalation and results |

These remain the existing two production SwiftPM targets. Folder organization does not by itself enforce every dependency inside the core target. In particular, the existing family-to-intervention-plan API remains intact.

## Guardrails

`python3 Scripts/check_architecture.py` verifies declared source ownership, prevents SwiftUI/app imports in core, keeps SQLite access in Persistence, and enforces line budgets. New files have a 600-line ceiling. Existing larger files have explicit current-size ceilings in `Config/architecture.json`; those exceptions are visible debt, not permission to grow indefinitely. A deleted or moved exception must be updated rather than left silently stale.

Put new behavior in an existing responsibility or extract a coherent component. Avoid catch-all `Utils` files, parallel copies of application settings, and direct persistence or signal calls from a view. Prefer a pure value projection plus a narrow actor or service for asynchronous work. Keep measurement freshness separate from display invalidation, and keep process inspection separate from intervention approval.

The large store, sampler, monitor, and intervention implementations remain candidates for subsequent, independently tested decomposition. This pass preserves their established behavior rather than claiming every large implementation was rewritten.

## Build infrastructure

`Scripts/lib/project.sh` owns bundle identity and script-level defaults. `Scripts/bundle-app.sh` is the supported packaging entry point; the files in `Scripts/lib` are its implementation details. The bundle lock is advisory and automatically released by the OS when its holders exit. The lock file may remain on disk without indicating a build is running.

Packaging stages, validates the plist, signs, and verifies the new bundle before replacing the old bundle. An unsuccessful replacement rolls back. A failure during rollback retains the previous bundle and prints its location instead of deleting it. No script silently force-kills the app. `restart` is explicit and uses a normal termination signal after the build succeeds.

The regression tests under `Tests/InfrastructureTests` use temporary fixture bundles. They exercise failure before packaging, failure during replacement, a successful signed replacement, lock contention and release, and invalid command handling. Swift tests under `Monitoring` and `Thermals` cover settings cancellation and the app-activity projection. Existing tests and the core check executable remain part of verification.

## Refresh projections

The refresh path has independently testable, sample-local projections:

- `Intelligence/DuplicateFamilyResolver.swift` indexes exact process identities once, then resolves duplicate ownership through that index. It supports overlapping families without counting repeated members twice. The index is discarded after each projection, so recycled PIDs and exited families cannot leave stale ownership behind.
- `Monitoring/FamilySamplingDemand.swift` derives sampling priorities in one pass. A runtime family key requests the selected instance; a logical signature requests matching instances. The scheduler still owns cadence, pressure gates, and sampling budgets.
- `Thermals/ThermalActivityAnalyzer.swift` projects the raw process batch into app activity. Filtered families supply optional inspector navigation but never decide which sampled apps can appear. `RefreshOutcome` carries the bounded evidence and precomputed sort orders to the observable monitor, including refreshes whose display revision is otherwise unchanged. Opening the thermal dashboard does not schedule a second projection task.

`ThermalDiagnosis` is a pure explanation layer over thermal state, measurement freshness, and activity coverage. SwiftUI components render status, bounded app rows, cached app icons, and an inspection sheet. Hardware readings, activity estimates, and process-stop authorization remain separate. Icon caching is limited to 96 entries; per-app inspection retains at most six process records while aggregate totals include every usable sampled process.

`Sampling/ProcessProbeReader.swift` owns native BSD and task-info probes. `RichProbeSelector.swift` rotates bounded discovery cohorts so stable process-list positions and developer hints cannot permanently starve ordinary apps of activity measurements. Explicit focus/alert demand has priority, deadlines and pressure gates remain in force, and the sampler divides the total rich-read budget across workers. Failed enrichment retains a basic process record.

Duplicate ownership updates retain the cluster's existing immutable measurement projection. They do not sort its members or rebuild its command/path hints. Family enrichment also retains its existing ordering because ownership resolution changes none of the sort keys.

`DuplicateFamilyResolverTests` compares the indexed result against the previous algorithm, including overlap, missing membership, repeated identities, and PID reuse. `FamilySamplingDemandTests` covers exact selection, logical signatures, empty snapshots, and the actual scheduler plan. These checks are included in `Scripts/verify.sh`.

For paired release timings, create an output directory and run:

```sh
mkdir -p .build/performance-audit
RADAR_INDEX_BENCHMARK_REPORT="$PWD/.build/performance-audit/duplicate-index.json" \
  swift test -c release --filter DuplicateIndexPerformanceTests
```

This benchmark alternates the old and indexed implementations on the same synthetic input, verifies identical results, and discards two warm-up rounds. It measures duplicate resolution, not full application frame rate. The legacy implementation exists only in test support.

## Scope of verification

A successful release build and signature check establish that the bundle was produced and validated. They do not prove a running older instance was updated or that the new UI was visually inspected. Keep runtime launch, interactive UI observations, and performance measurements separate when reporting results.
