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

`script/build_and_run.sh` remains a compatibility wrapper and accepts the old `--` forms. `verify` validates the project rather than starting an application just to check its PID. Invalid modes are rejected before building or interacting with a process.

## Where code belongs

| App folder | Ownership |
| --- | --- |
| `Application` | App entry, login item, notifications and their actions |
| `MenuBar` | Status item and icon, status menu, the single main-menu definition, popover |
| `Shell` | Console window and session: navigation and Back/Forward, selection, stops, toasts, toolbar, sidebar, Quick Stop, Settings window |
| `DesignSystem` | Theme, shared surfaces and controls, layouts, tips, motion, shared row actions, the wait label |
| `Features/<feature>` | Feature-specific views and their local UI state: Overview, Processes, Duplicates, Incidents, Rules, Sentinel (the Security page), Interventions (the stop sheet), Thermals, Settings |

| Core folder | Ownership |
| --- | --- |
| `Domain` | Process identities, measurements, sessions, signatures, families and shared values |
| `Configuration` | User settings, performance policy and adaptive configuration |
| `Monitoring` | Refresh loop and scheduling, the refresh worker and pipeline, stop-risk memo, the observable facade |
| `Sampling` | Native process, CPU, GPU and listening-port sampling behind `ProcessProbeSource` |
| `Thermals` | Hardware sensors, the sensor catalog and the separate app-activity projection |
| `Intelligence` | Workload catalog, family building, trends, baselines, CPU behavior, forgotten-process evidence, pressure attribution, scoring and forecasts |
| `Persistence` | SQLite connection, versioned schema, the store and its collaborators |
| `Search` | Process search: text folding, query language, scoring and the per-identity search index |
| `Presentation` | Immutable display models, snapshots, formatting and asynchronous queries |
| `Diagnostics` | Logging, self-usage accounting and responsiveness instrumentation |
| `Interventions` | Stop plans, risk, protection, preview, execution, launchd, outcome verification and learning |
| `Cleanup` | Staged file-cleanup core with no UI yet (see [Cleanup](Cleanup-2026-09-15.md)) |
| `Sentinel` | Security watch: attack-pattern rules, the spawn, startup-item and privacy-sensor watchers, signature checks and the launch feed (see [Sentinel](Sentinel.md)) |

These are the two production SwiftPM targets. Folder organization does not by itself enforce every dependency inside the core target.

## Guardrails

`python3 Scripts/check_architecture.py` enforces:

- **Ownership.** Every source file sits in a folder its target declares in `Config/architecture.json`.
- **The core/UI boundary.** `GhostProcessSniperCore` never imports SwiftUI or the app.
- **SQLite isolation.** SQLite calls live only in `Core/Persistence`.
- **Line budgets.** New files have a 600-line ceiling. A larger legacy file has an explicit budget, and that budget must *equal* the file's current length: shrink the file and the check asks you to lower the budget (or to remove the entry once the file is at 600 lines or fewer), so budgets only ratchet down and any growth shows up as an `architecture.json` edit in review. A budget for a file that no longer exists fails too. Every source file is under 600 lines today; the only legacy budget left is the checks' `main.swift`.
- **Test roots.** `test_roots` gives `Tests/GhostProcessSniperCoreTests` and `Checks/GhostProcessSniperCoreChecks` the same line budgets, without folder rules.
- **No silent increases.** `--base <git-ref>` additionally fails when any budget is higher than in that ref (for example `--base origin/main`); it is skipped when git or the ref is unavailable.

Put new behavior in an existing responsibility or extract a coherent component. Avoid catch-all `Utils` files, parallel copies of application settings, and direct persistence or signal calls from a view. Prefer a pure value projection plus a narrow actor or service for asynchronous work. Keep measurement freshness separate from display invalidation, and keep process inspection separate from stop approval: anything that can stop a process goes through a previewed, identity-bound `KillPlan` and the user's confirmation.

To change the database schema, append a `SQLiteMigration` to `RadarStoreSchema.migrations` with the next version and add a case to `MigrationTests`; never edit a version that has shipped.

## Tests

`Tests/GhostProcessSniperCoreTests` mirrors the core folders (`Configuration`, `Domain`, `Intelligence`, `Interventions`, `Monitoring`, `Performance`, `Persistence`, `Presentation`, `Search`, `Thermals`), with cross-cutting suites at its root. Tests use `@testable import GhostProcessSniperCore`; the app target has no unit tests and is covered by the macOS build.

The fakes model cause and effect rather than returning scripted answers:

- **`FakeProcessTable`** (`Interventions/Support/`) is both the kill engine's snapshot provider and its signaler. Its processes react to what the engine does — exit N ticks after a signal, ignore it, fork a child, respawn under a supervisor, refuse every signal with EPERM, quit on request like an app, hold signals while stopped until `SIGCONT`, linger as zombies until their parent exits, or follow their parent out. Each call to its `sleeper` advances one tick and moves its virtual `now`, which the fixtures pass to the engine as its clock, so grace waits run against the table instead of the wall clock. `KillEngineScenarioTests` shows the pattern; most intervention suites (force hold, tree sweep, launchd, outcome verification, protection, the target advisor) build on it, with `KillFixtures`, `LaunchdFixtures`, `PolicyFixture` and `FakeListeningPortProbe` beside it.
- **`FakeProbeSource`** (`Monitoring/`) scripts the whole kernel side of `NativeProcessSampler` — process table, uptime clock, usage, paths, argv, sessions and ports — so sampler tests drive real ticks without touching the host.
- **Fixtures** in `Support/`: `DevWorkstationFixture` is a deterministic developer Mac (editors with language servers, dev servers, a build, a test-worker pool, duplicate servers, databases, system daemons) whose `tick` advances time and grows families; `IntelligenceFixture` and `RefreshPerformanceFixture` build families and synthetic refreshes.
- **Migration tests** (`Persistence/MigrationTests`) build a store at each older schema version — an unversioned file, then `migrate(migrations.filter { $0.version <= N })` — seed rows, open it with `RadarStore`, and check that rows survive and that an upgraded store ends with exactly the schema of a fresh one.
- **Goldens.** `PipelineGoldenTests` pins digests of signature ids, membership and score-component text over the fixtures, so pipeline optimizations cannot silently change results.

A few native smoke tests (a real shell tree forced by the kill engine, CPU-time conversion against the POSIX clock) run only on macOS. Ordinary tests make no tight timing claims: benchmarks are opt-in, and the few loose or release-only time budgets are listed in [Performance](Performance.md).

`Checks/GhostProcessSniperCoreChecks` is an executable of hand-registered checks run by `swift run GhostProcessSniperCoreChecks` and by `Scripts/verify.sh`. Keep it green; change a check only when a behavior change intentionally alters its expectation.

## Vendored packages

`Packages/ThinkingOrbsKit` is the SwiftUI edition of the [Libraries.dev](https://libraries.dev) thinking orbs (MIT, see its `LICENSE`), vendored as a local SwiftPM package and linked only into the app target. It is pure SwiftUI (`Canvas` and `TimelineView`, no Metal) with no dependencies. The app uses it only for waits of two seconds or more — the stop sheet's clean-exit wait, the "Stop the extras" sheet while each copy waits out its grace (`DuplicateCullSheet`), and `RadarWaitLabel` — never for short waits, where an orb would read as a flicker. Its own tests run with `swift test --package-path Packages/ThinkingOrbsKit`. Keep local changes minimal and note them in its README.

## Build infrastructure

`Scripts/lib/project.sh` owns bundle identity and script-level defaults. `Scripts/bundle-app.sh` is the supported packaging entry point; the files in `Scripts/lib` are its implementation details. The bundle lock is advisory and automatically released by the OS when its holders exit. The lock file may remain on disk without indicating a build is running.

Packaging stages, validates the plist, signs, and verifies the new bundle before replacing the old bundle. An unsuccessful replacement rolls back. A failure during rollback retains the previous bundle and prints its location instead of deleting it. No script silently force-kills the app. `restart` is explicit and uses a normal termination signal after the build succeeds.

The regression tests under `Tests/InfrastructureTests` use temporary fixture bundles. They exercise failure before packaging, failure during replacement, a successful signed replacement, lock contention and release, and invalid command handling; `test_architecture.py` covers the architecture checker itself.

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

## Stop strategy test bench

`Scripts/dev-hog-fixture.sh` starts disposable processes that exercise each stop strategy. Every fixture has `ghost-fixture:<kind>` in its argv and leads its own process group; `stop` signals only groups that still carry the marker, sends SIGTERM, waits up to 3 s, then sends SIGKILL.

```sh
Scripts/dev-hog-fixture.sh start                    # every kind
Scripts/dev-hog-fixture.sh start dev-server slow-db # just these
Scripts/dev-hog-fixture.sh status
Scripts/dev-hog-fixture.sh stop
```

`start` refuses while fixtures from an earlier start are still running. The dev server listens on `127.0.0.1:${GHOST_FIXTURE_PORT:-51730}`, away from Vite's usual 5173.

Manual checklist on macOS. Open the family, preview the stop, run it, then read the result.

| Kind | What it does | Expect in the stop sheet and result |
| --- | --- | --- |
| `leak` | Touches 16 MiB every 0.25 s, plateaus at 1.5 GiB | A growing Python family; SIGTERM ends it in the first phase and the memory is freed |
| `cpu` | Burns one core | Shows as a heat leader on the Overview; SIGTERM ends it in the first phase |
| `ignore-term` | Ignores SIGTERM and SIGINT, burns one core | Every polite step is ignored; the result shows the same-identity survivor frozen and forced with SIGKILL |
| `dev-server` | argv0 `vite`, serves the port, exits 0 on SIGINT, ignores SIGTERM | "Interrupts the dev server like Ctrl-C and frees port 51730"; the result ends after SIGINT with the port chip "51730 free" |
| `supervisor` | A "nodemon" parent that restarts its `node` child within 1 s | Stop only the `node` child (Stop This Process… on the Processes tab): "Restarts on your next save", and the result notes that nodemon starts it again on the next save. The fixture restarts at once, like pm2 rather than nodemon, and Ghost does not probe for a restart after a file-watcher stop. Stopping the whole family takes the supervisor down too |
| `slow-db` | argv0 `postgres`, exits 4 s after SIGTERM | Careful shutdown: "Database writes", 12 s to flush and Never force-stop on. Ghost sends Postgres's fast-shutdown SIGINT to the root alone; this fixture only delays SIGTERM, so it exits at once on SIGINT |

Run `stop` afterwards; it also cleans up anything a test left behind.

## Scope of verification

A successful release build and signature check establish that the bundle was produced and validated. They do not prove a running older instance was updated or that the new UI was visually inspected. Keep runtime launch, interactive UI observations, and performance measurements separate when reporting results.
