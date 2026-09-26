# Performance refactor — 9 September 2026

## What the audit found

The source inventory covered roughly 29,600 Swift lines before this pass. Targeted review followed sampling, refresh, persistence, publication, query preparation, and the views that consume those results. This was not an exhaustive line-by-line review of every subsystem.

A six-second native `sample` capture of the existing release identified repeated SQLite table-page reads in `RadarStore.recentIncidentCounts`. The main thread was idle in the event loop in that particular capture, so it did **not** establish the cause or frequency of interactive scrolling hitches.

Source review found additional avoidable work: rich detail panels were constructed for every family; list queries were prepared synchronously by view-facing getters; the navigation shell observed every refresh; and the overview eagerly composed its sections. Equal-ranked rows had no final identity tie-break. The publish-cost metric also stopped before the actual assignments and observer callbacks.

## Implemented changes

The recurrence query now has a covering index on `(signature_id, started_at)`. Its SQL, inclusive cutoff, and count semantics are unchanged. The migration adds an index; it does not clear history.

Rich details are demand-driven in production. All process rows remain available, while priority/warning queues and explicitly selected identities receive prepared panels. In the 1,000-family fixture, rich panel dictionary entries fell from 2,000 to 18: **1,000 panels to 9**, with a runtime key and signature alias per panel. This is a construction-count reduction, not a measured RAM reduction.

`ConsoleProjectionWorker` prepares filters, sorting, and sidebar rows on an actor. `ConsoleQueryStore` publishes only the latest complete result. Cancelled or superseded requests cannot replace newer results. Browser getters no longer perform query work or mutate caches while SwiftUI reads them.

The overview has independent header, guidance, queue, analytics, thermal, and engine dependencies inside a lazy scroll stack. Browser labels skip redraws when their visible values are unchanged. Existing animations remain local and intact. Sorting ties use stable identities to avoid unnecessary reshuffling.

Raw process data now refreshes even when rendering buckets are unchanged. Newly requested panels can publish without a resource-number change. Publish timing includes assignments and observer callbacks and reports the preceding completed handoff rather than a misleading partial duration.

The presentation layer is organized into nine focused files under `Sources/GhostProcessSniperCore/Presentation`. See [Architecture](Architecture.md) for ownership and maintenance rules.

## Measurements

### Paired pipeline comparison

The preserved pre-refactor core was built in a separate temporary benchmark package. Old and new optimized builds were alternated in three rounds: before/after, after/before, before/after. Each invocation excluded two warmup iterations and retained seven measurements, producing **21 samples per version per input size**.

The fixture supplies the same synthetic process records to the real refresh-worker ingestion path, with no live process sampling, no database, and no signals. It measures ingestion, scoring, and presentation preparation, not UI frame rendering. The machine remained shared with other workloads; timing noise and host-pressure differences are not eliminated by alternation.

| Synthetic families | Before median | After median | Median time reduction |
| ---: | ---: | ---: | ---: |
| 250 | 48.117 ms | 38.694 ms | 19.6% |
| 1,000 | 192.164 ms | 172.546 ms | 10.2% |

The first unpaired baseline was 35.884/145.881 ms. The first unpaired new run was slower at 48.277/182.502 ms, and a repeat was 33.993/159.424 ms. Those results are retained rather than discarded. They motivated the alternating comparison; the initial results alone did not demonstrate a pipeline speedup. These medians are not a guarantee for other Macs, workloads, or future samples.

### Incident query comparison

`Scripts/benchmark_incident_query.py` uses 120,000 synthetic incident rows, queries 400 signatures, and verifies identical results before and after adding the index. The same database, predicate, and parameters are used in both phases; seven post-warmup timings are retained per phase.

| Query implementation | Median | Approximate SQLite VM steps |
| --- | ---: | ---: |
| Existing signature/active index | 24.586 ms | 441,000 |
| New signature/start-time covering index | 2.073 ms | 202,000 |

That query was approximately **11.9× faster** in this synthetic Python/SQLite 3.50.4 test. This is not an 11.9× app-wide speedup. A separate native XCTest verifies the covering query plan and exact cutoff counts using the app's schema.

Raw reports, including the initial slower run and all alternating rounds, are preserved in [Benchmarks/2026-09-09](Benchmarks/2026-09-09). Reproduction commands are in [Architecture](Architecture.md).

## Verification recorded so far

The debug suite ran 61 cases with one intentionally skipped opt-in benchmark and no failures. The release suite, with the benchmark enabled, ran **all 61 cases with no failures**. All **113 executable core checks** passed. New regression coverage includes out-of-order query completion, cancellation, closing, selective details, exact-instance selection, retained process rows, raw-data freshness, stable sorting, and SQL index/count behavior.

Byte-for-byte comparisons against the pre-refactor source confirm that `ProcessKiller`, `ProcessModels`, `KillModels`, `KillInterventionBrain`, `InterventionPolicyEngine`, and `ThermalTelemetry` were not changed by this pass. Source/tests/checks/package and the previous application bundle are backed up under `.build/performance-before`.

The native profile and build/test logs are under `.build/performance-audit`. The profile is an engineering diagnostic, not a frame-rate benchmark. Live UI validation and final bundle status are recorded below after deployment.
