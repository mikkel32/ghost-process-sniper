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
| `Search` | Process search: text folding, query language, scoring and the per-identity search index |
| `Presentation` | Immutable display models, snapshots, formatting and asynchronous queries |
| `Diagnostics` | Logging, self-usage accounting and responsiveness instrumentation |
| `Interventions` | Preview, authorization identity, execution, escalation and results |

These remain the existing two production SwiftPM targets. Folder organization does not by itself enforce every dependency inside the core target. In particular, the existing family-to-intervention-plan API remains intact.

## Guardrails

`python3 Scripts/check_architecture.py` verifies declared source ownership, prevents SwiftUI/app imports in core, keeps SQLite access in Persistence, and enforces line budgets. New files have a 600-line ceiling. Existing larger files have explicit ceilings in `Config/architecture.json`; those exceptions are visible debt, not permission to grow. Each ceiling must equal its file's current length: shrink a file and the check asks you to lower its budget (or remove the entry once it is under 600), so any growth shows up as an `architecture.json` edit in review. A deleted or moved exception must be updated rather than left silently stale. `test_roots` applies the same line budgets, without folder rules, to `Tests/GhostProcessSniperCoreTests` and `Checks/GhostProcessSniperCoreChecks`. `--base <git-ref>` additionally fails when any budget is higher than in that ref (for example `--base origin/main`); it is skipped when git or the ref is unavailable.

Put new behavior in an existing responsibility or extract a coherent component. Avoid catch-all `Utils` files, parallel copies of application settings, and direct persistence or signal calls from a view. Prefer a pure value projection plus a narrow actor or service for asynchronous work. Keep measurement freshness separate from display invalidation, and keep process inspection separate from intervention approval.

The large store, sampler, monitor, and intervention implementations remain candidates for subsequent, independently tested decomposition. This pass preserves their established behavior rather than claiming every large implementation was rewritten.

## Build infrastructure

`Scripts/lib/project.sh` owns bundle identity and script-level defaults. `Scripts/bundle-app.sh` is the supported packaging entry point; the files in `Scripts/lib` are its implementation details. The bundle lock is advisory and automatically released by the OS when its holders exit. The lock file may remain on disk without indicating a build is running.

Packaging stages, validates the plist, signs, and verifies the new bundle before replacing the old bundle. An unsuccessful replacement rolls back. A failure during rollback retains the previous bundle and prints its location instead of deleting it. No script silently force-kills the app. `restart` is explicit and uses a normal termination signal after the build succeeds.

The regression tests under `Tests/InfrastructureTests` use temporary fixture bundles. They exercise failure before packaging, failure during replacement, a successful signed replacement, lock contention and release, and invalid command handling. Swift tests under `Monitoring` and `Thermals` cover settings cancellation and the app-activity projection. Existing tests and the core check executable remain part of verification.

## Packaging and releases

`Scripts/lib/project.sh` also reads optional packaging variables. Without them, `bundle-app.sh` produces the same local, ad-hoc-signed bundle as before.

| Variable | Effect |
| --- | --- |
| `RADAR_DIST_DIR` | Where the `.app` is written (default `dist`) |
| `RADAR_ARCHS` | Architectures, e.g. `"arm64 x86_64"` for a universal binary |
| `RADAR_SCRATCH_PATH` | Separate SwiftPM build directory |
| `RADAR_SIGN_IDENTITY` | `-` (ad hoc) or a Developer ID identity; the latter enables the hardened runtime |
| `RADAR_VERSION`, `RADAR_BUILD_NUMBER` | Override the bundle version for a one-off build |

`Scripts/release.sh` combines these into a universal disk image in `dist/release`. `Packaging/render-artwork.swift` renders the app icon, the installer background, and the README icon from code; its outputs are committed so ordinary builds need no extra step. See [Releasing](Releasing.md).

Bundles are staged and signed in `$TMPDIR`, then moved into place. iCloud Drive (including a synced Desktop or Documents folder) re-tags `.app` directories with Finder information that `codesign` rejects, so signing inside such a checkout always fails. For the same reason, `codesign --verify --strict` reports "detritus" for a bundle that already sits in a synced `dist` folder; the bundle is verified before it is moved there, and it runs normally.

If a build fails with `module … is defined in both …` after the repository folder was moved or renamed, SwiftPM's module cache still points at the old path. Remove `.build` (it only contains build products) and build again.

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

## Stop strategy test bench

`Scripts/dev-hog-fixture.sh` starts disposable processes that exercise each stop strategy. Every fixture has `ghost-fixture:<kind>` in its argv and leads its own process group; `stop` signals only groups that still carry the marker, sends SIGTERM, waits up to 3 s, then sends SIGKILL.

```sh
Scripts/dev-hog-fixture.sh start                    # every kind
Scripts/dev-hog-fixture.sh start dev-server slow-db # just these
Scripts/dev-hog-fixture.sh status
Scripts/dev-hog-fixture.sh stop
```

`start` refuses while fixtures from an earlier start are still running. The dev server listens on `127.0.0.1:${GHOST_FIXTURE_PORT:-51730}`, away from Vite's usual 5173.

Manual checklist on macOS. Open the family, preview the stop, run it, then read the report.

| Kind | What it does | Expect in the stop sheet and report |
| --- | --- | --- |
| `leak` | Touches 16 MiB every 0.25 s, plateaus at 1.5 GiB | A growing Python family; SIGINT ends it at the first step and the memory is released |
| `cpu` | Burns one core | Shows as a heat leader on Overview; SIGINT ends it at the first step |
| `ignore-term` | Ignores SIGTERM and SIGINT, burns one core | Every polite step is ignored; the report shows the same-identity survivor forced with SIGKILL |
| `dev-server` | argv0 `vite`, serves the port, exits 0 on SIGINT, ignores SIGTERM | "Interrupts the dev server like Ctrl-C and frees port 51730"; the report ends after SIGINT and the port is free |
| `supervisor` | A "nodemon" parent that restarts its `node` child within 1 s | Stop only the `node` child (per-process preview): "Will restart … nodemon … Stop nodemon instead"; the report says nodemon started it again. Stopping the whole family takes the supervisor down too |
| `slow-db` | argv0 `postgres`, exits 4 s after SIGTERM | Careful shutdown: "Database writes", 12 s to flush and no force without asking; the report ends early at about 4 s instead of waiting the full grace |

Run `stop` afterwards; it also cleans up anything a test left behind.

## Scope of verification

A successful release build and signature check establish that the bundle was produced and validated. They do not prove a running older instance was updated or that the new UI was visually inspected. Keep runtime launch, interactive UI observations, and performance measurements separate when reporting results.
