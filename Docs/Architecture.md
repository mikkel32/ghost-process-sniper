# Architecture and performance boundaries

## Data flow

```text
NativeProcessSampler (actor)
    -> RadarRefreshWorker (actor)
        -> ProcessFamilyBuilder / RadarIntelligence
        -> RadarStore (actor, SQLite)
        -> RadarPublishPayload / RadarConsoleSnapshot
    -> ProcessMonitor (MainActor, observable facade)
        -> small overview sections / current family
        -> ConsoleProjectionWorker (actor)
            -> ProcessSearchIndex (folded text per process identity, built only while searching)
            -> ConsoleQueryStore (MainActor, latest complete query)
                -> process browser / sidebar / incident rows
```

The sampler owns process identity and measurement provenance. Every sampled process — tracked or not — travels with the refresh outcome, so search can reach apps outside the watch scope without a second scan. The refresh worker owns candidate building, scoring, persistence coordination, and presentation preparation. The monitor performs the short main-actor handoff. Process queries are prepared by a separate actor; reading a list from a view does not filter, sort, format, or mutate a cache.

## Source organization

The app now separates platform lifecycle (`Application`), menu-bar integration (`MenuBar`), console navigation (`Shell`), reusable visual primitives (`DesignSystem`), and individual `Features`. The core target has named responsibility folders for domain values, configuration, monitoring, sampling, thermal analysis, intelligence, persistence, search, presentation, diagnostics, and interventions. SwiftPM still builds the existing app and core targets; these folders are responsibility boundaries, not new binary modules.

Process identity, measurements, signatures, forensics, families, and intervention plans now have separate files. The hardware detector is separate from its value models. Process-cause and precision-target views belong to the Processes feature, rather than sharing the temperature-view file. Existing source moves preserve their contents and public type names.

See [Development and source ownership](Development.md) for the complete ownership map and automated checks.

`Sources/GhostProcessSniperCore/Presentation/` is the presentation boundary:

| File | Responsibility |
| --- | --- |
| `RadarConsoleSnapshot.swift` | Lightweight family inventory, ordering, and demanded detail panels |
| `FamilyDetailPanelModel.swift` | Rich detail cards, changes, evidence, and forensics |
| `CompactConsoleSnapshot.swift` | Dashboard guidance, bounded priority queues, compact sidebar rows |
| `ConsoleRowModels.swift` | Incident/rule rows and diagnostic presentation |
| `ConsoleQueryModels.swift` | Pure query transformations and reusable query cache |
| `ConsoleSearchModels.swift` | Filter, search, and ordering of family rows; untracked-process result rows |
| `ConsoleQueryStore.swift` | Actor-based query execution, cancellation, and latest-request publication |
| `RadarPublishPayload.swift` | Worker-to-monitor handoff and content-versus-diagnostics decisions |
| `SnapshotContentRevision.swift` | Rendering invalidation buckets; not raw-measurement ownership |
| `RadarFormat.swift` | Shared display formatting |

The former 1,445-line `RadarConsoleSnapshot.swift` was split along these responsibilities, rather than simply renamed. Publication types also moved out of `SmoothnessModels.swift`; that file now contains refresh timing and responsiveness instrumentation.

The existing core sampling, intelligence, persistence, sensor, and intervention files remain in the core target. The app target contains platform integration and SwiftUI views. This is an incremental refactor of the measured hot paths, not a claim that every implementation file has been rewritten or exhaustively reviewed.

`Sources/GhostProcessSniperCore/Search/` holds the process search engine. It is platform-free apart from `ProcessSearchIndex.swift`, which adapts families and samples:

| File | Responsibility |
| --- | --- |
| `SearchText.swift` | Case-, accent- and width-folded UTF-8 text with word starts; literal, acronym, subsequence, and typo matching |
| `ProcessSearchQuery.swift` | Query language: words, phrases, exclusions, field scopes, identities, measurements, and `is:` states |
| `ProcessSearchEngine.swift` | Scoring across a family's root and helpers, match reasons, highlights, and the exact-then-approximate policy |
| `ProcessSearchIndex.swift` | Search subjects for families and untracked processes, with folded text cached per process identity |

An idle console never touches the index. While a query is active, each new sample re-runs the search (about 2 ms for 1,000 processes); folding happens once per process lifetime.

## Rendering rules

Every tracked family keeps a lightweight browser row. Rich detail panels are prepared only for priority/warning queues and explicitly requested families. A request for a logical signature prepares one representative; a concrete family key selects the exact PID/start-time instance. Public snapshot builders retain their full-materialization default for compatibility. Production refreshes opt into selective preparation.

A newly selected detail is allowed to publish even when its resource numbers share the previous rendering revision. A synchronous single-family fallback keeps first selection usable while the next worker-prepared panel arrives. Query results stay immutable after publication. Cancelling, closing, or superseding a query prevents its late result from overwriting a newer result.

The overview scroll shell does not directly observe live process arrays or history. Header, guidance, queues, analytics, thermal readings, and engine status observe their own inputs. Offscreen overview content is lazy. Browser row labels compare only the immutable values they draw. Outer buttons still receive current action and accessibility data. Stable family keys break sorting ties so equal-ranked processes do not shuffle just because sample order changes.

Keep animation scopes local. Do not animate an entire process array or attach a high-frequency timer to the navigation shell. The existing numeric transitions, selection highlights, hover/press feedback, sensor traces, and motion accessibility/power gates remain in place.

## Measurement and intervention invariants

Rendering buckets do not authorize caching raw measurements. `ProcessMonitor` publishes fresh family data and the raw model even when visible rows do not need rebuilding. Existing measurement-age checks and PID/start-time validation remain authoritative for interventions.

Process-stop code is a separate boundary: previews retain their explicit scope, identities, strategy, delay, and expiry. Presentation work must not widen that scope or decide to stop a process.

### Risk-aware stops

`KillWorkloadProfile` captures names, paths, command lines, ports, and the ancestor chain when a plan is made (the kill snapshot itself stays cheap and skips them). `KillRiskAssessor` turns that into a `KillRiskAssessment`: the workload kind, hazards, freed ports, a supervisor that would restart the target, the app process to quit politely, a clean-shutdown grace period, and whether force needs the user's consent. `InterventionPolicyEngine` folds the assessment into the decision factors and strategy (`quitApp` asks `NSRunningApplication` to terminate before any signal; `carefulShutdown` gives databases and container runtimes long SIGTERM grace). Calibration is looked up per strategy and never shortens a clean-shutdown grace. After a successful stop with a known supervisor, `ProcessKiller` samples once more to report a restart.

## Persistence

Recurrence counts use `incidents(signature_id, started_at)`, matching the query's signature and time-range predicates. The index is created with `IF NOT EXISTS` during migration. The count query and cutoff semantics are unchanged; no history is deleted to obtain the speedup. Keep the existing active-incident index for its distinct query workload.

## Verification and maintenance

`Scripts/verify.sh` is the canonical verification entry point. It runs architecture checks and infrastructure regression tests before the Swift suite, core check executable, and release build. The focused commands below remain useful during development.

```sh
swift test
swift run GhostProcessSniperCoreChecks
RADAR_BENCHMARK_REPORT="$PWD/.build/performance-audit/pipeline.json" \
  swift test -c release --filter PerformanceAuditTests
python3 Scripts/benchmark_incident_query.py \
  --output .build/performance-audit/incident-query.json
```

The opt-in benchmark test is skipped during ordinary tests. It uses synthetic families and does not sample or signal real processes. The Python benchmark creates a temporary synthetic database and verifies identical count results before and after adding the covering index. Neither benchmark is a frame-rate measurement.

`PresentationPipelineTests` exercises selective detail preparation, unchanged-render freshness, deterministic ordering, stale-query rejection, cancellation, closing, query parity, and the SQLite query plan. Existing process-stop and sensor tests remain in the suite.

Main-actor publish timing now includes assignments and observer callbacks, rather than stopping before them. The next refresh reports the preceding completed publish duration to avoid a self-triggering instrumentation loop. This timing still does not include deferred SwiftUI layout or rendering; use Instruments or interactive sampling for those costs.

Primary background references: [Apple's SwiftUI performance guide](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance), [WWDC25: Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/), and [SQLite query planning](https://www.sqlite.org/queryplanner.html).

## Thermal activity projection

`ThermalActivityAnalyzer` owns the process-to-app projection on its own actor. The pure `ThermalActivitySummary` builder deduplicates PID/start-time identities, groups nested application helpers by their outer app bundle, rejects invalid or outdated readings, and produces deterministic activity ordering. It compares the larger of CPU activity normalized by processor count and observed GPU activity. That ordering is not a measurement of power, temperature, or share of total heat.

`ConsoleThermalDashboard` owns the asynchronous request and discards a cancelled request's result. `ThermalContributorsView` receives a small value snapshot and inspection callbacks. Rows expire against their original measurement time even if no further refresh arrives. This feature never imports a signal executor or performs an intervention. Coverage is limited to monitored process families; unavailable readings are reported rather than presented as zero load.

## Settings and build lifecycle

The settings debounce now uses `DebouncedTask`: cancellation exits before a pending write instead of merely interrupting its sleep. A write that has already started is not undone. Regression tests cover cancellation, replacement by a later request, and a single immediate write.

Build identity is centralized in `Scripts/lib/project.sh`. The public bundler acquires an OS-managed advisory lock, then builds and signs a staging bundle. Validation precedes replacement, and a failed replacement restores the old bundle. Build-workflow tests inject failures into temporary fixtures and check the old bundle, rollback, lock release, signing, and invalid-command handling. These tests do not replace the real application or stop running processes.
