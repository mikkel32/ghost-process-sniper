# Precision and Celsius update

Verified on the host Mac on 9 September 2026.

## What changed

The overview, process details, and menu-bar popover show actual CPU/GPU hardware temperatures. The overview and process browser replace the prominent Heat number with readable action levels and explanations of memory footprint, CPU activity, GPU activity, sustained memory growth, or incomplete measurements. The detail view adds Precision targets: up to three leading contributors, each with an individual process preview.

The dashboard status uses a review count or a monitoring state instead of concatenating raw forecast labels. Search, filter, sort, the guide, and the existing incident and diagnostic views remain available. Internal scoring remains diagnostic data; it is never converted into Celsius.

## Temperature evidence and limits

A screenshot of the running release showed CPU **76.1°C**, GPU **75.2°C**, **12 readable sensors**, and the separate macOS thermal state **Elevated**. These are observations from that moment, not current readings or a calibration certificate. An earlier standalone reader also returned valid temperatures on the same Apple M1 Pro.

The reader uses a small read-only AppleSMC implementation. It only requests key metadata and sensor values. It does not change fan speeds, power limits, permissions, or security settings. It samples at most once every three seconds, caches sensor metadata, and rejects invalid values. Missing or more-than-15-second-old temperature readings display Unavailable.

The CPU/GPU values are the highest temperatures among the readable mapped sensors for each component. They are not temperatures attributable to an individual process. Model-specific mappings exist for M1, M2, and Intel machines; only this M1 Pro was tested live. Unrecognized chip mappings fail to Unavailable. SMC is not a public, stable Apple temperature API, so compatibility with future hardware or macOS changes is not guaranteed.

Primary implementation references consulted:

- [Apple: ProcessInfo thermal state](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum)
- [Stats: model-specific sensor key registry](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)
- [Stats: SMC wire protocol implementation](https://github.com/exelban/stats/blob/master/SMC/smc.swift)

## Measurement and ranking corrections

Process readings carry fresh, cached, or unavailable provenance. Cached readings retain their original measurement date and do not create additional trend samples. Missing measurements do not become zero-valued history. Trend histories distinguish process start identities and changes in family membership.

Freshness, sustained observation, regression quality, and allocation pattern now constrain growth forecasts. Historical incidents alone do not promote a currently quiet process. Unreliable growth does not produce a threshold ETA, and forecasts beyond 24 hours do not display enormous countdowns. Current severity takes precedence over unconfirmed forecast state in sorting.

The scoring cache reuses derived judgments while retaining current measurements and forensics. It invalidates when measurements become stale or unavailable, when sustained-history eligibility changes, and when baseline provenance changes. This prevents stable scores from freezing the timestamp of otherwise fresh readings.

Baselines carry a measurement version. Old baselines are relearned from valid readings without deleting incident history or settings. Cached samples are not learned repeatedly, while independently recorded incident counts can still update. Native AirPlay and pairing services no longer match Go tooling just because their names contain `air`.

## Intervention scope

A single-process preview binds to the chosen PID and start-time identity. A family preview captures its reviewed target identities. Confirmation retains that allow-list, the selected strategy, and the displayed grace delay; it does not silently add new descendants. Existing ownership, protected-process, and recycled-PID checks remain in place. Single-process reclaim estimates cannot fall back to the entire family's memory total.

Previews expire after 60 seconds. Expiry prevents admission of a new intervention; it does not roll back an intervention already started. The sheet prevents duplicate confirmation and dismissal while the operation is active. Operating-system permission failures and processes exiting during an operation remain possible and are reported rather than treated as success.

## Verification

**40 XCTest cases passed**, including new coverage for sensor decoding, freshness, missing-to-measured transitions, duplicate history samples, baseline migration, scoring-cache freshness, topology changes, sorting, exact target scope, expiry, empty approvals, strategy binding, and PID reuse. **All 113 executable core checks passed.** The existing forecast fixtures were updated to carry explicit measurement times; they no longer accidentally test readings thousands of seconds older than their test clock.

An isolated C fixture was compiled locally; its only behavior was printing its PID and sleeping. Using the actual app UI, its individual preview displayed root PID **31952**, one target, and Root only scope. Confirmation reported **one process terminated, zero force signals, and zero survivors**, with two verification passes. The process was absent from a subsequent process listing. The persisted operation record agreed with the UI: **89.516 ms**, displayed as **90 ms**. This is one functional test, not a general latency benchmark. No unrelated user workload was targeted by that test.

The live database integrity check returned **ok**. All **95,495** incident IDs from the pre-upgrade backup were still present after migration. Existing source edits were preserved. The source, prior application bundle, and a consistent SQLite backup are retained under `.build/precision-before/`.

Validation logs are `.build/precision-tests.log`, `.build/precision-core-checks.log`, `.build/precision-release.log`, and `.build/precision-bundle.log`. The previous UI refresh is documented separately in `UI-Refresh-2026-09-09.md`.

The optimized release was rebuilt, bundled, signature-verified, and reopened. Final visual inspection covered compact and wider dashboard layouts, readable Celsius values, process explanations, and the browser's Action column. The application was left open on the live overview with the test search cleared.
