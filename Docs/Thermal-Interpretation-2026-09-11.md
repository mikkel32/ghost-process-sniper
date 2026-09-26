# Temperature-aware review

## What the dashboard now explains

The combined headline evaluates the hottest valid CPU or GPU sensor. A normal macOS pressure report no longer hides a warm or hot reading. The platform pressure report remains a separate observation.

| Measured temperature | App review band |
| --- | --- |
| Below 70 degrees C | Below warm band |
| 70 to below 80 degrees C | Warm |
| 80 to below 90 degrees C | Hot |
| 90 degrees C or higher | Very hot |

These are product review bands, not Apple operating limits. They do not diagnose a defective device or guarantee that temperatures below a band are safe. Critical and serious platform pressure always retain their higher-priority guidance, even if a sensor is missing or reads lower.

The next step distinguishes a substantial observed workload, modest activity, missing evidence and cooling. An app is not blamed just because it is first in the ranking. Process-count coverage is shown as the last scan's coverage, not as a percentage of the machine's power or heat. A zero GPU counter is not proof of no GPU work. Users can inspect activity and pause optional work in the app; these recommendations never issue process signals or change fans or power settings.

## Evidence and architecture

`ThermalTemperatureAssessment` owns sensor validation and review bands. `ThermalObservationWindow` owns a bounded value history. `ThermalWorkloadAssessment` owns the activity interpretation. `ThermalPressureReading` reads the typed `ProcessInfo.thermalState` value independently of sensor availability or display strings. `ThermalDiagnosis` combines their evidence into display strings. The existing public `state` and `status` remain platform-pressure values for compatibility; `reviewStatus` is the combined, temperature-aware label drawn by `ThermalStatusCard`.

History records distinct sensor timestamps while the dashboard is open. It retains at most 90 observations and 180 seconds. Duplicate timestamps do not add evidence, out-of-order readings are ignored, and gaps over 15 seconds break continuity. Missing values break only their own sensor's history. Future-dated, invalid, or more-than-15-second-old readings cannot become current temperature assessments.

Trends require at least four distinct observations across 30 seconds. They compare the early and recent medians in a 60-second window from the same sensor; a two-degree change separates rising or falling from steady. Switching between the hottest CPU and GPU cannot splice their values into a fictional trend. A single high reading remains visibly high even when it is not enough to establish a sustained rise.

Persistence describes the span of actual samples above 70 or 80 degrees C. Timer ticks never lengthen that span. Cooling does not erase a currently warm or hot review band. This is recent sample context, not a learned hardware baseline or a prediction of failure.

The feature consumes existing process and sensor snapshots and reads the platform's pressure enum during its existing display updates. It starts no additional process sampler and adds no extra high-frequency animation loop. The existing three-second expiry timer is retained, and the separate temperature-clock and fractional-percentage corrections from the preceding pass are included in source.

## Validation

`ThermalInterpretationTests` covers review-band boundaries, independent platform pressure, missing/stale/future/invalid sensors, partial activity coverage, modest leaders, plausible workload contributors, duplicate timestamps, rising/steady/cooling trends, persistence, gaps, per-sensor continuity, transient spikes, ordering and bounded history.

```sh
swift test --filter ThermalInterpretationTests
Scripts/verify.sh
Scripts/dev.sh restart
```

Final `Scripts/verify.sh` completed successfully: 134 Swift tests executed, with 132 passing and the two opt-in benchmarks skipped; all 113 core checks and 15 infrastructure tests passed. Architecture checks and release compilation passed. The final verification log contains zero compiler warning or error lines. The interpretation suite adds 26 scenarios. Synthetic scenario tests do not measure frame rate or diagnose the host machine.

`Scripts/dev.sh restart` completed successfully after the final compatibility fix. The running overview was inspected again after that restart.

### Live observations

- The first temperature-aware build displayed "Cooling, but still 74.1°C" and later "82.7°C and rising" with a Hot review label.
- The inspector exposed the existing snapshot's "Elevated" platform-state label. The former parser recognized "Fair" but not "Elevated", incorrectly producing an unknown state. The live dashboard now uses the typed platform enum, and the compatibility parser recognizes both labels. A regression test covers the observed label and surrounding whitespace.
- After the final restart, the dashboard displayed CPU 75.1°C, GPU 74.8°C, elevated macOS pressure, falling temperature and samples above 70°C spanning 34 seconds. These are observations from the test session, not a claim about the machine's later state.
- CPU and GPU ranking controls selected their respective modes and changed the visible app order. Fractional activity values were visible in both an app row and its detail sheet.
- An app activity card opened a detail sheet showing six of seven sampled processes. "Open process inspector" navigated to the corresponding family, and Overview returned to the dashboard. No process-stop action was invoked.
- Temperature history expanded and showed both CPU and GPU traces. Scan now and the explanation disclosure were exercised. The explanation displayed the review-band policy and evidence limitations. The final overview was left open with its disclosures collapsed.

### Verification limitation

A supplemental source read and a separate post-install audit of binary UUID, executable sections, signature and PID were blocked with: "This tool call was blocked by OpenAI because we couldn't determine the safety status of the request." The exact installed-binary identity comparison and independent signature/PID audit remain unverified. This does not undo the successful tests, release builds, restart commands or inspected running UI. The diagnostic incident was queued; mail acceptance and inbox delivery were not confirmed.

## Primary references

- [Apple: Keep your Mac laptop within acceptable operating temperatures](https://support.apple.com/en-us/102336). Internal readings differ from external case temperature; Apple cautions against diagnosing hardware issues with third-party sensor apps and recommends checking CPU activity and ventilation for unexpected warmth.
- [Apple: Designing for Adverse Network and Temperature Conditions](https://developer.apple.com/videos/play/wwdc2019/422/). Platform thermal states guide responses to thermal pressure and demanding workloads. These states are not a published universal CPU/GPU Celsius table.

The numeric review bands and trend rules above are explicitly this application's policy, not thresholds attributed to either reference.
