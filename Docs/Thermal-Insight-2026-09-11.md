# App attribution and thermal usability

## Correcting the underlying CPU measurement

The running dashboard could display almost no CPU activity even while useful process readings were available. The sampler divided `ri_user_time + ri_system_time` and the `PROC_PIDTASKINFO` fallback by one billion without converting Mach absolute-time ticks.

Both counters require the host's `mach_timebase_info` conversion. On the tested Mac the ratio was 125/3. A bounded native probe measured 0.270535 seconds with the POSIX CPU clock, while the previous conversion yielded 0.006495 seconds. Applying the timebase yielded 0.270607 seconds. The previous calculation therefore understated CPU work by approximately 41.7 times on this host, suppressing app attribution and distorting process rankings.

`Sampling/ProcessCPUTime.swift` owns the conversion for both native counter sources. It converts before adding counters to avoid integer overflow. Invalid timebases produce unavailable numeric evidence, and `CPUUsageTracker` rejects invalid inputs without poisoning the next valid sample. Tests cover Apple silicon and unit-ratio timebases, large counters, invalid input, and comparison of both native APIs with POSIX process CPU time. The observed ratio is host-specific; it is not hard-coded into production.

## Overview behavior

`ThermalInsightPanel` is the console's new thermal entry point. Temperature and a named workload appear side by side when space permits, with a stacked layout in narrower windows. A large temperature reading, the separate macOS pressure signal, temperature trend, and a concrete next action form the first level. Application icons and compact resource rows keep the next contributors in view.

`ThermalAppInsight` distinguishes fresh substantial activity, a modest leader, a sample without a clear contributor, and unavailable or expired evidence. Significant observed workload is an app-review heuristic: at least 80% raw single-core CPU, 10% total CPU capacity, or 15% reported GPU activity. It checks the ranked contributors for substantial work before falling back to the first row, so a modest GPU leader cannot conceal a CPU-heavy app. It is not a calibrated measure of heat, energy, fault probability, or operating limits. System services retain advice to review related application activity rather than stop a macOS service.

CPU/GPU ranking remains available. Three rows appear initially; expansion shows up to twelve, with access to the complete process browser. The inspection sheet receives the newest available measurements for its selected app rather than retaining a frozen sample indefinitely. Missing or expired evidence still disables navigation that depends on a current sample.

Temperature history, review-band definitions, and measurement limitations sit in a disclosure. Coverage remains visible and refers to process readings, not a fraction of system power or heat. Existing temperature review bands, sensor validation, process identity checks, intervention boundaries, settings, and stored history remain intact.

## Compare readings

The user can save an app and sensor baseline with **Compare readings**. This does not pause or terminate anything. The panel asks the user to change optional work themselves and compare another scan after at least fifteen seconds.

`ThermalCoolingCheck` requires a newer current sensor sample and newer measurements for the same app. It compares CPU capacity, reported GPU activity, and changes in the same CPU/GPU sensor channels. Stale sensors, invalid temperatures, expired baselines, and absent app readings do not become a successful cooling result. A missing or low-activity app is explicitly described as unmeasurable rather than assigned zero. Comparisons expire after three minutes. An observed drop is not claimed as proof that the app caused the original heat.

## Verification

The first focused run passed all 66 selected tests. The final `Scripts/verify.sh` run completed successfully: 150 Swift tests, with 148 passing and two opt-in benchmarks skipped; 113 executable core checks; 15 infrastructure tests; architecture checks; and release compilation. The log contains no compiler warning or error lines. This pass adds five CPU-clock regressions and eleven insight/comparison scenarios. The complete verification output is in `.build/thermal-insight-verification.log`.

`Scripts/dev.sh restart` successfully rebuilt the staged bundle and normally restarted the application after both implementation passes. A separate final `codesign --verify --deep --strict` check succeeded. Both the packaged and release executables reported UUID `AF4BA919-CCD8-3E26-B041-727C43D4624A`. One running instance was observed at `dist/Ghost Process Sniper.app/Contents/MacOS/GhostProcessSniper`. Matching UUIDs and signature validation are the checks performed; this was not a byte-for-byte comparison of signed and unsigned binaries.

### Live observations

The installed dashboard was inspected through screenshots and accessibility state. The side-by-side temperature and app cards rendered correctly. Visual inspection found a wrapping sort label; it was corrected and the final installed screenshot confirmed the compact segmented control. App names are prominent even in the modest-activity state.

During the first implementation's release build, the running dashboard displayed Xcode at 12.5% of total CPU capacity and named it in the workload recommendation. GPU sorting selected its mode and reordered the displayed rows. These are observations from a changing live workload, not a controlled performance benchmark.

On the final installed build, Scan now refreshed the dashboard. Inspect app opened fresh ChatGPT activity with 168 sampled processes and six retained detail rows; Open process inspector navigated to the corresponding family, and Overview returned to the dashboard. An expired evidence snapshot was also observed with its explicit outdated warning. Compare readings displayed `Baseline saved for ChatGPT`. No app was stopped or paused by the comparison or inspection interactions.

### Verification limits and diagnostic status

One initial source-read request and a final automated sorting/comparison-result check were blocked with: `This tool call was blocked by OpenAI because we couldn't determine the safety status of the request.` Neither denied operation was retried or rerouted. Independent source edits, builds, tests, installation, signature checks, and the completed UI observations above succeeded. The final additional sorting/comparison-result check remains unverified; the final temperature-history and narrow-window interactions were not exercised. Their data logic is covered by automated tests, which do not replace interactive verification.

A separate UI click returned `Computer Use server error -10005: 46 is an invalid element ID`. Refreshing the accessibility state and using its current button identifier allowed a subsequent baseline capture to succeed. This recovery concerned a stale UI identifier, not either safety-status rejection.

The observed incidents were recorded in the local diagnostic queue. The selected report-delivery tool was not advertised in the refreshed native inventory. Email acceptance and inbox delivery were not confirmed; no duplicate or alternate email was sent. The tool-side safety-status cause remains unresolved.
