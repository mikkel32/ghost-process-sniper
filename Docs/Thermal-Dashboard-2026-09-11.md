# Thermal dashboard: activity, evidence, and next steps

## User-facing changes

The thermal section is now one `Heat & app activity` panel. It leads with the macOS thermal-pressure assessment and the apps worth reviewing, instead of presenting temperature numbers and an unrelated list. Actual application icons, CPU-capacity meters, GPU activity, and grouped process counts make the rows easier to identify.

Three rankings are available: Combined, CPU, and GPU. The first three rows are shown initially; additional active apps and services can be expanded. A row opens an activity detail sheet with up to six busiest sampled processes, their exact PID/start-time identities in the underlying model, raw CPU/GPU readings, and a suggested next step. Opening the existing process inspector is offered only for an observed family and disabled when the activity snapshot is no longer current. No action in this panel stops an app.

Temperature traces remain available under `Temperatures & recent history`. Measurement explanations and coverage appear within the same panel. `Scan now` requests a refresh through the existing monitor and refresh gate.

## Corrected data path

Previously, the view created an actor task from `monitor.families`. Those families were already selected by the radar's development/heavy/all policy. A sampled app could therefore be omitted from thermal attribution even when it had useful activity readings.

The refresh worker now calls `ThermalActivityAnalyzer.project(processes:families:now:)` with the raw `ProcessSampleBatch`. Families provide navigation references only. An app outside the family filter still has a standalone evidence sheet. The worker publishes the projection through `RefreshOutcome`; the monitor exposes it independently of rendering-revision buckets. The synchronous ingestion path follows the same projection for testability.

Projection deduplicates exact process identities, groups nested helpers under the enclosing application, excludes invalid/missing/stale/future-dated measurements, and retains a deterministic bounded inspection list. CPU and GPU sort orders are prepared on the worker. SwiftUI performs only bounded freshness filtering and rendering. The icon cache is limited to 96 entries and resolves bundle icons once per cached path.

Live inspection exposed another contributing cause: enrichment used fixed process-list positions (`ordinal % stride`) on every scan. Processes outside those slots could remain unmeasured indefinitely, and developer-name hints could consume the rich-read budget before discovery reached ordinary apps.

`ProcessProbeReader` now reads the cheap identity graph first and applies `RichProbeSelector` to bounded, rotating cohorts. Explicit focus/alert demand precedes developer-name hints, while discovery retains a share of the existing budget. Failed or raced task-info reads retain their basic identity records instead of removing those processes. The sampler divides its enrichment budget across parallel workers and respects the existing rich-metrics pressure gate. Sampling is still bounded by the deadline; this is not a promise of universal or instantaneous measurement access.

The native probe implementation is separated from sampler orchestration. The sampler's file budget was reduced from 1,061 to 920 lines after extraction. Partial coverage without an active contributor now says `Still measuring app activity`, rather than implying the unreadable processes are quiet.

## Meaning and limits

macOS thermal state drives the status explanation. There is no universal hard-coded Celsius threshold that declares every Mac healthy or overheating. Normal thermal pressure does not mean that a sensor is cold. A fresh system state can be explained even when model-specific Celsius sensors are unavailable.

CPU capacity is process CPU time divided by the active logical-processor count. The detail view retains the original per-process CPU convention. GPU values are reported process activity, not calibrated heat fractions. Zero may mean no GPU activity was reported; the current process model has no independent per-process GPU availability flag.

The raw batch is still limited by sampling availability and permissions. Coverage explicitly counts usable readings from the latest sample; it does not promise complete attribution of all heat. Workload activity cannot prove the number of watts or degrees attributable to an app. Missing data is not treated as a quiet workload, and a quiet sample is not presented as proof that hardware has cooled down.

## Verification

The installed build passed the complete `Scripts/verify.sh` workflow: 107 Swift tests executed with two opt-in benchmarks skipped and zero failures, all 113 executable core checks passed, and all 15 infrastructure tests passed. Architecture checks and release compilation also passed. This includes 14 dashboard regressions and five sampling-selector regressions. The full output is in `.build/thermal-dashboard-final-verification.log`.

The signed application bundle was rebuilt and Ghost Process Sniper was restarted normally. The running executable was observed at `dist/Ghost Process Sniper.app/Contents/MacOS/GhostProcessSniper`. Strict signature verification succeeded. The release and installed binary share UUID `8475dd94-0567-3f6c-a257-d8fd7289016a`, and every `__TEXT` section was compared and matched. Whole-file hashes were not used as an identity claim because signing modifies the packaged executable.

Actual screenshots and accessibility state were inspected after installation. The dashboard displayed the unified thermal card, current CPU/GPU sensor values, a real application icon, grouped activity, coverage, and the ranking controls. `Scan now` was exercised. An active Maria WebGPT row opened a detail sheet containing six sampled processes with their PIDs and CPU/GPU readings. Coverage was 32 usable readings out of 552 before the sampler refinement and reached 186 out of 570 in an observed post-update snapshot. These are live observations from changing workloads, not a controlled performance benchmark or a promise of complete measurement access.

## Saved polish that is not installed

Visual inspection revealed that the timeline's scheduled tick could precede a newly published sample, causing a `Checking` status despite visible sensor readings. Source edits now use the actual render-time clock for the new dashboard and detail-sheet freshness checks. A separate formatting edit preserves fractional activity rather than displaying small nonzero values as zero. One additional regression test was added for that formatting.

Those final timing and formatting edits have not been compiled, tested, or installed. Their requested verification was blocked with: `This tool call was blocked by OpenAI because we couldn't determine the safety status of the request.` The installed application remains the fully tested build described above and can still show the observed status flicker and rounded percentages. The new formatting test was not part of the verified 107-test run.

A subsequent read-only UI-state check was blocked by the same safety-status message before the process-inspector navigation could be exercised. Sorting/history controls were visible but their remaining interactions were not fully verified. Earlier UI timeouts recovered after the app update; neither those timeouts nor the safety-status blocks establish an authentication, filesystem, or tunnel fault. Blocked operations were not retried or rerouted. Diagnostic reporting is queued locally with delivery pending, not confirmed sent.

## Background references

- [Apple: View CPU activity in Activity Monitor](https://support.apple.com/en-gb/guide/activity-monitor/actmntr43452/mac)
- [Apple: View information about processes](https://support.apple.com/en-gb/guide/activity-monitor/actmntr1001/mac)
- [Apple: Designing for adverse network and temperature conditions](https://developer.apple.com/videos/play/wwdc2019/422/)
