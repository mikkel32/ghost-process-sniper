# Architecture

Two production targets share the work. **`GhostProcessSniperCore`** samples processes, builds and scores families, persists history, prepares every display model, and stops processes; it has no UI, so its behavior is covered by the XCTest suite and the core checks without launching the app. **`GhostProcessSniper`** is the SwiftUI app inside an AppKit shell: the status item and popover, the console window, Settings, and notifications. Folders are responsibility boundaries inside those two targets, not separate modules; [Development](Development.md) has the ownership map and the automated checks.

## Data flow

```text
ProcessMonitor (MainActor, @Observable)          the app's single source of radar state
 ├─ refresh loop (utility QoS) ── one refresh at a time, one shared trailing rerun
 │   ├─ ThermalSampler (actor)                   SMC temperatures; every refresh while visible, ≤ every 4 s hidden
 │   └─ RadarRefreshWorker (actor)
 │       ├─ RadarScheduler                        SamplingPlan from demand, power, heat and pressure
 │       ├─ NativeProcessSampler (actor)          usage for every process, then telemetry,
 │       │                                        forensics and port lanes within a deadline
 │       ├─ RadarPipeline.buildCandidates         families, duplicates, member trends, CPU ledger
 │       ├─ RadarStore.context (actor)            baselines, recurrence counts, composed rules
 │       ├─ RadarPipeline.score                   pressure attribution, scoring cache, enrich,
 │       │                                        hysteresis, continuity
 │       ├─ RadarStore.enqueue                    learn in memory, write behind
 │       ├─ RadarPublishPayload                   console snapshot and detail panels, off-main
 │       └─ ThermalActivityAnalyzer               app and job activity over the raw sample
 └─ publish: assigns only what changed, then notifies the menu bar and console

RadarConsoleSession (app, MainActor)
 └─ ConsoleQueryStore → ConsoleProjectionWorker (actor)   search, filter, sort, selected panel

ProcessKiller (Sendable)                          preview and stop, off the main actor
```

`ProcessMonitor` owns the refresh loop and is the only path into the worker, because `NativeProcessSampler.sample` must never run twice at once. The worker owns sampling, the pipeline, store coordination and presentation preparation; the monitor does the short main-actor handoff. The console's queries run on their own actor, so reading a list in a view body never filters, sorts or formats.

## Scheduling

- **Surfaces.** `setSurface(.popover / .console, visible:)` records which windows show live data; the console reports real visibility, so an occluded or minimized window counts as hidden. Showing a surface wakes the loop at once instead of after the hidden sleep.
- **Cadence** is a pure function of `RadarSchedulingContext` (`RadarScheduler.nextInterval`): about 1 s while visible (0.75 s when something is hot) with realtime budgets; hidden on mains 3.5 s, 2 s at Watch and 1 s when hot (a family with nothing against it but its size does not set the pace), relaxing to 2.5 s once every hot family was alerted on and has been hot for five minutes (a known long build); ×1.5 on battery; 6/4/3 s in Low Power Mode. Thermal pressure multiplies the interval (up to ×2.5), a tick over its budget ×1.35, and the result stays within 0.5–8 s. While hidden, a self-throttle stretches the interval until the radar's own CPU settles near twice the mode's idle target. Power comes from IOPS and Low Power Mode, cached for 30 s.
- **QoS.** The loop task runs at utility priority, so hidden sampling, scoring and store work stay off the performance cores; a visible caller awaiting a refresh escalates it. Hidden sleeps carry 15% timer tolerance so the system can batch the wake-up.
- **Single flight.** A refresh requested while one runs awaits one shared trailing rerun, so any number of callers cost one extra sample and each returns with data sampled after its call. Loop ticks join the running refresh instead.
- **Visible-first work.** The main-actor hitch monitor (a heartbeat on a suspending clock) runs only while a surface is visible; SMC temperatures are read every refresh while visible and at most every 4 s while hidden, so the thermal trend stays warm.

## Sampling

`NativeProcessSampler` reads the process table through an injectable `ProcessProbeSource` in one pass:

- **Usage lane, full coverage.** `proc_pid_rusage` for every readable process on every tick, never gated by budget or thermal state. CPU is a delta of CPU time (converted through `mach_timebase_info` by `ProcessCPUTime`) over the monotonic uptime clock, keyed by identity; a changed process start time between reads discards the reading. Memory is the physical footprint.
- **Task info.** Thread and VM counts come from `PROC_PIDTASKINFO` for a bounded cohort (hot, focused and rotating candidates), which keeps at least four reads even under critical thermal state.
- **Telemetry.** Paths are read for every new identity in its first tick; argv runs most wanted first while the tick deadline allows, with a one-off allowance at cold start or for a big backlog. Name-only placeholders are never cached as fresh, and a new kernel name on the same identity means exec and drops its telemetry and forensics.
- **Forensics.** Working directory, open files and sockets for hot, focused and unattended families; stale forensics are served while demanded ones are re-read.
- **Port census.** `ListeningSocketReader` counts TCP sockets in LISTEN only. In the background the scheduler picks up to 2 quiet developer processes (6 while visible) whose ports are older than 60 s (15 s); a `port:` search calls `ProcessMonitor.requestPortCensus()`, and that tick reads every same-user process with open files, capped at 40 ms.
- **Session.** Process group, session (`getsid`, once per identity), controlling terminal, its foreground group and run state travel in `ProcessSessionInfo`.
- **GPU.** IORegistry accelerator user clients, each counted once by registry ID.
- **Energy.** The usage read is `RUSAGE_INFO_V6`, so the same call returns each process's lifetime energy (`ri_energy_nj`), idle wake-ups and disk writes. `PowerCounterTracker` turns them into rates per identity on the uptime clock and travels them in `ProcessMetrics.power`; a reading without a fresh read keeps its counters but loses its rates.

Every reading carries fresh, cached or unavailable provenance. A cached reading keeps its original measurement date and adds no trend sample, and a missing reading never becomes zero.

## Pipeline and intelligence

`RadarPipeline.buildCandidates` runs `ProcessFamilyBuilder`:

- **Static facts.** `ProcessStaticFactsCache` computes classification, signature, command hint, bundle prefix and duplicate key once per identity, reused while the path and command are unchanged. `WorkloadCatalog` classifies by whole tokens (argv0, executable, bundle, script or module stem, `node_modules` package), so "bun" never matches ".bundle".
- **Families.** `ProcessTree` draws the family boundaries. A service-kind child (language server, database, test runner, build watcher, dev server, notebook kernel) of an editor or app becomes its own family and remembers its `parentFamilyKey`; an app's same-kind helpers stay with it. Launchd-started services that macOS holds an app responsible for (Safari's WebContent, GPU and Networking processes, an IDE's XPC services) join that app's family through `helperOwners`, on `ResponsibleProcessLookup`'s answers, which `RadarRefreshWorker` asks once per tick before the families are built and shares with `ThermalWorkloadResolver`. Every gate must hold: the helper's parent is launchd, same user as the app, a service-like path (`.xpc/`, `/xpcservices/` or launchd-managed), the owner is an app main binary that is not a terminal and started no later than the helper, and the helper is not a workload the app runs for itself (a language server, dev server or notebook kernel stays its own family). They are members (so search and totals include them) and the family key and signature stay the app's; with family grouping off nothing is linked. `LaunchContextResolver` and `LaunchOrigin` tell app bundles and launchd jobs from terminal jobs that outlived their shell and reparented orphans.
- **Coverage.** `FamilyMeasurementCoverage` makes a family scorable when its root is fresh and fresh readings cover 90% of its footprint (75% for trees of eight or more).
- **Member trends.** `MemberTrendStore` keeps per-member memory at two resolutions — a 60-reading, 120 s ring and ninety one-minute buckets, counted in minutes the Mac was awake — for up to 1,200 series. A family's series is the sum of its members, so a child joining or leaving restates history instead of reading as growth. Long-term Theil-Sen slopes over minute means and minimums find slow leaks (twenty minutes of at least 5 MB/min, or 0.5% of RAM an hour on large-memory Macs, with a rising floor, R² 0.6, and growth in at least two thirds of the window, so one large allocation is not a leak); a member with 60% of the growth on a clean fit of its own is named as the culprit, compared on the horizon the growth was proven on (long-term slopes for a slow leak, recent ones otherwise).
- **Memory shape.** `MemoryShapeAnalyzer` estimates noise from the data (MAD of first differences), fits a Theil-Sen slope with a confidence band, and recognizes "leaking under GC" when a sawtooth's troughs keep rising. `TrendMetrics.credibleMemoryVelocity` is the history-gated growth every consumer reads; the raw slope is only for charts.
- **CPU ledger.** `ActivityLedger` counts a new process from its first usage read and keeps each process's cumulative CPU time and twenty one-minute CPU buckets per family, exact at any cadence; sparse reads are spread over the minutes they cover, and idleness is only claimed for time actually measured. `CPUBehaviorAnalyzer` reads it to tell an expected build burst (runaway only after 15 minutes near its level), a one-core spin, an idle service burning CPU against its baseline, and whole-Mac saturation apart. Several cores held at one steady level for ten minutes (1.5 cores or more, no children coming or going) is sustained evidence even below the family limit, which scales with the core count, and a runaway when nobody attends the process (a job whose terminal closed, an orphan).
- **Duplicates.** `DuplicateClusterDetector` keys interpreters by the workload they run and native binaries by path, counts independent copies (the topmost member of a matching chain), and picks the copy to keep: the one in a terminal, else the most recently active, else the newest.

`RadarPipeline.score` then, once per tick, attributes host memory pressure (`PressureAttribution`: each family's share of used memory and of credible growth, and a `HostMemoryOutlook` countdown to critical pressure), and scores each family through `FamilyScoringCache`, whose fingerprint covers the inputs, rule matches and expiries, and the family's own pressure ETA. `RadarIntelligence.enrich` applies:

- **Baselines.** `FamilyBaselineLearner` keeps a time-weighted mean of memory and CPU with their variances — cumulative for the first two hours, then an EWMA (τ = 2 h), so the first reading does not dominate a young baseline — plus learning time and sessions, and skips memory learning during credible growth or a slow leak. A baseline is trusted after 30 readings and 20 minutes; a memory anomaly needs a z-score of 3 as well as 1.3×. `FamilyBaseline.currentMeasurementVersion` is 3: a family's total holds the launchd-started helpers macOS reports for its app, so baselines from before (version 2) are relearned instead of leaving an app permanently "10× its usual size".
- **Evidence and heat.** `FamilyEvidenceScorer` and `GhostHeatModel`; context votes (baseline, host pressure) go to a separate corroboration count, so only trend-proven persistence counts as sustained. Growth is a leak (a sustained signal, a leak component above Watch, the forecaster's Leaking) only with `TrendMetrics.growthIsSustained` (a minute of dated history), past `StartupGrace`, and not in a one-shot build or test run (`DevClassification.isOneShotBuild`: build or test work that is not long-lived). A family already past its memory limit reaches Leaking only at the leak limit or through the twenty-minute long-term trend; the slower near-limit climb counts only while the limit is minutes away. Hardware outliers only lend visibility (capped at Watch). A family that is big and nothing else — no CPU, GPU or growth of its own, no critical pressure on the Mac, no other votes — is held at Watch once its trusted baseline says this size is usual for it (z under 2, under 1.3× normal): "Large, but normal for it". At Warning pressure that holds only at or near the usual size (at most 1.1×), and the evidence adds "the Mac is short of memory, so it stays on watch"; Critical pressure keeps a big family Hot. Growth that only refills toward the usual size (`FamilyBaseline.staysWithinUsualSize`: ten more minutes of it still end inside the usual range, above half the usual size) is not a leak either, and a baseline CPU burst is Hot only at 5× normal *and* half the core-aware family limit, else Watch. A launch is given grace (`StartupGrace`, the root's first 150 seconds, read by the scorer and the forecaster alike): its memory ramp is Watch at most, and its leak component is capped at Watch, so it is not counted as a leak until grace is over. `PressureAttribution` credits a family's growth toward host pressure only from 20 MB/min (`PressureShare.materialGrowthMegabytesPerMinute`, in proportion below it), so a lone slow grower is not the driver of pressure. Such a family (`hasOnlySizeAgainstIt`) is learned by the baseline learner and is not an incident; before, a family Hot only for its size was excluded from learning as an incident and so could never become "normal". Helper count, a long session, past incidents and host-wide outliers below Hot are context, not evidence against it: counted as evidence, incidents recorded for size alone kept such a family Hot, which recorded more.
- **Forgotten evidence.** `ForgottenProcessAssessor` weighs launch context, measured idleness (30 minutes of observed time: a gap of more than five minutes between scans is sleep and does not count), age, a deleted working directory (`WorkingDirectoryProbe` counts only ENOENT and ENOTDIR, and never touches privacy-guarded folders) and a port held while idle; apps and launchd jobs stay capped.
- **Forecast, rules and verdict.** `FamilyRiskForecaster` (memory-only horizon, host-memory ETA), two rule passes, `FamilyVerdict`, `ProcessAssessment` and the suggestions. `AttentionReason` gives every Watch-or-worse family a short specific reason ("Over its memory limit", "Near its memory limit", "1.7x its usual size", "Large, but normal for it", "2 copies running", "Probably forgotten", "Holds 22% of scarce memory", and for a family under the CPU cause what its CPU is doing, from `CPUBehavior` first), first match wins, reading typed facts (a component's `ratio` to its limit, never its text), used by the rows, the sidebar, the radar contacts, the hero and the notification subtitle. `ProcessFamily.needsReview` is the one predicate behind the Overview's hot count, the Risk Queue and the Review filter.

`RadarHysteresis` holds Hot and Critical until a family has read lower for 20 s, then steps down one level at a time; `RadarContinuity` keeps an alert's start time and a suggestion's creation time while they persist, so rows keep their identity. `FamilyPriorityOrder` is the one family comparator.

## Presentation

`RadarPublishPayload.build` runs on the worker. A content publish builds `FamilyTriageViewModel` rows through small sort keys, the `CompactConsoleSnapshot` (verdict brief, queues, sidebar, metric cards) and detail panels for the top eight families plus the focused ones; `SnapshotContentRevision` decides whether anything visible changed. Diagnostics text and timing figures are bucketed so noise does not change them.

`ProcessMonitor.publish` assigns each observed property only when it differs, and the content-gated properties (`consoleSnapshot`, `summary`, `triageFamilies`, `incidents`, `rules`) only when the content revision moved. Views observe the slice they draw: the popover root and the Overview shell read nothing per sample, and thermal views re-render between publishes only at the instants a reading expires.

Detail panels are selection-first. `FamilyDetailPanelModel` carries the decision brief, the process tree and the stop risk. A selected family without a prepared panel gets one from `ConsoleProjectionWorker.panel(familyKey:request:)`, built off the main actor as soon as it is selected and published under its own generation ticket, so a stale selection never lands; a synchronous build is used only for the first frame. Query results are immutable after publication, and a cancelled or superseded query never overwrites a newer one.

| File in `Presentation/` | Responsibility |
| --- | --- |
| `RadarPublishPayload.swift` | Worker-to-monitor handoff and the content-versus-diagnostics decision |
| `RadarConsoleSnapshot.swift` | Family inventory, ordering and prepared detail panels |
| `CompactConsoleSnapshot.swift` | Verdict brief, priority queues, metric cards and sidebar rows |
| `FamilyDetailPanelModel.swift`, `FamilyDecisionBrief.swift`, `FamilyProcessTreeRow.swift` | The family page: panel, verdict-first judgement, process tree |
| `ConsoleQueryStore.swift`, `ConsoleQueryModels.swift`, `ConsoleSearchModels.swift` | Projection actor, latest-result publication, filter, search and ordering |
| `ProcessBrowserRowModel.swift`, `ConsoleRowModels.swift` | Table rows for processes, incidents, rules and diagnostics |
| `QuickStopAction.swift`, `DuplicateCullPlan.swift` | Risk-aware one-click stops; "Stop the extras" plans |
| `KillLiveProgress.swift`, `KillOutcomeRows.swift` | Stop sheet progress reducer and per-process outcome rows |
| `NavigationHistory.swift`, `OverviewLayoutPlan.swift`, `MenuBarStatusPresentation.swift` | Back/Forward, Overview section order, status item text |
| `SnapshotContentRevision.swift`, `RadarFormat.swift` | Rendering invalidation buckets; shared formatting |

## Search

`Sources/GhostProcessSniperCore/Search/` holds the process search engine. It is platform-free apart from `ProcessSearchIndex.swift`, which adapts families and samples:

| File | Responsibility |
| --- | --- |
| `SearchText.swift` | Case-, accent- and width-folded UTF-8 text with word starts; literal, acronym, subsequence, and typo matching |
| `ProcessSearchQuery.swift` | Query language: words, phrases, exclusions, field scopes, identities, measurements, and `is:` states |
| `ProcessSearchEngine.swift` | Scoring across a family's root and helpers, match reasons, highlights, and the exact-then-approximate policy |
| `ProcessSearchIndex.swift` | Search subjects for families and untracked processes, with folded text cached per process identity |

Every sampled process travels with the refresh outcome, so search reaches apps outside the watch scope without a second scan. An idle console never touches the index; while a query is active, each new sample re-runs the search, and folding happens once per process lifetime.

## Stopping processes

The kill engine lives in `Interventions/`. Presentation code never widens a stop's scope or decides to stop anything; every stop starts from a `KillPlan` the user previews and confirms.

- **Plan and workload.** `ProcessMonitor.killPlan(for:)` builds the plan from the family and a `KillWorkloadProfile` of every same-user descendant of the root (at most 256), with names, paths, argv, ports, ancestors and each process's radar CPU and memory. `StopRiskCache` memoizes the `KillRiskAssessment` per stop-set identity key and rebuilds the cheap workload once per sample, so the family page, Quick Stops and the preview agree.
- **Risk.** `KillRiskAssessor` fingerprints the workload into a kind (app, editor, database, container runtime, version control, package install, build, dev server, model runner), its hazards, freed ports, a clean-shutdown grace, whether force needs consent, the app process to quit, and the supervisor that restarts it. It reads only the first 512 bytes of argv.
- **Launchd.** `ProcessKiller.withLaunchdJob` attaches the root's job, for a child of launchd that is not an app: `LaunchdJobResolver` maps the live PID through `launchctl list` (memoized per identity) and `KillLaunchAgentIndex` reads KeepAlive and the program from the LaunchAgents and LaunchDaemons plists.
- **Preflight.** `KillPreflightBuilder` slices a fresh snapshot (`KillGraphArena`) into targets and locked processes — a process owned by someone else locks its whole subtree — then applies `KillProtectionPolicy`: never pid ≤ 1, Ghost, its ancestors, `loginwindow`, `WindowServer`, `launchd`, `kernel_task` or system processes; a caution for relaunched CoreServices agents, terminal apps, tmux or screen servers and login shells. A protected root makes the plan inspect-only. Zombies are set aside, suspended targets are marked. `InterventionPolicyEngine` builds the decision factors and readiness and picks the strategy and its phases; `KillTargetAdvisor` proposes better stops (the restarting supervisor, found on the root's live parent chain, or the helper holding 70% of the family).
- **Learning.** `KillOutcomeModel` keeps a Beta posterior of "every target exits within the grace, unforced" and a censored histogram of exit times per family and strategy, with the workload kind's row as the prior, decayed by 0.9 per stop. It sets the first wait (q90 × 1.5, never below the strategy's and the workload's floor, capped at three times the force delay or the floor, whichever is larger) and chooses stubborn runaway only when the clean-exit rate's upper 80% bound is under 0.3 and the kind loses nothing when forced. History informs but never blocks; held force, refusals, respawns and force follow-ups are not failures.
- **Approval.** `KillPlan.binding` pins the previewed identities, the approved `KillStrategyProfile` and a 60 s expiry. At confirm the preflight runs again on a complete snapshot; the approved phases are the contract (a fresh look may only lengthen the first wait), children born after approval that descend from approved processes are adopted, and anything else new stays locked.
- **Phase walker.** `ProcessKiller.walk` runs each phase: act (a quit request through `NSRunningApplication`, or a signal to the tree or, for databases and prefork masters, the root alone), wait on `KillGraceCoordinator` until the exit watcher or the kernel says every target is gone, verify, and adopt late members. Identity is re-checked before every signal; EPERM is tried once; a suspended target gets `SIGCONT` after its polite signal; traced targets are not waited for. A booted-out launchd job takes the root's place in the first phase. `KillOperationControl` separates holding force (`holdForce`) from ending a wait (`stopWaiting`). The polite phase after a quit request sends nothing while the app that accepted it is still live, so an app answering a save prompt keeps its helpers; `KillReport.settling` and `ProcessKiller.recheck` bring a displayed "still open" result up to date once the app has quit (display-only, never signalled, never learned), and a remembered stop settles only survivors no process with that identity runs any more. For a single-process plan `KillPreflightBuilder` lists the root's live descendants as `KillPreview.leftBehind` (never targets, never signalled), and after the stop `ProcessKiller` looks again for up to 0.75 s before reporting them. `ProcessFamily.linkedIdentities` are helpers linked by `helperOwners`: they are not in `ownedIdentities`, so a family stop asks the app to quit, and `canStopIndividually` lets each be stopped alone through a single-process plan.
- **Freeze, sweep, force.** `forceTree` sends `SIGSTOP` to every live target, sweeps up to three times for newborns (at most 256, else a fork storm is reported), then `SIGKILL` parent first; a failed sweep resumes everything it froze.
- **Outcome.** After a stop with no survivors, `KillRespawnDetector` looks for a restart (only for supervisors that restart on exit, at 150–1,800 ms), and `KillOutcomeVerifier` reads the listening sockets of the likely holders — escaped group members, processes started during the stop, namesakes — within 64 processes and 30 ms, reporting each port as freed, held by a named process, or unverified. `KillOutcomeNarrator` tells the result by name, with one next step.
- **Force follow-up.** `KillPlan.forcingSurvivors` targets exactly the verified survivors with `KillStrategyProfile.forceNow`, approved for 30 s, and stays out of learning.

`confirmKill` returns the report as soon as the run ends; recording and the refresh run in a follow-up task that the next plan and shutdown await, so learning stays ordered. A stop whose root no monitored family owns (such as a supervisor stop) is recorded for the audit trail only.

## Persistence

`RadarStore` is an actor over one `SQLiteDatabase` connection (WAL, per-SQL statement cache). It opens lazily on its own actor at first use, so launch does no SQLite work on the main thread; after a failure it retries at most every 30 s, and a corrupt file is moved aside as `Radar.corrupt-<timestamp>.sqlite` and replaced.

- **Migrations.** `RadarStoreSchema.migrations` applies each version newer than `PRAGMA user_version` in its own transaction: v1 stamps the pre-versioning schema, v2 the incident recurrence index, v3 drops write-only tables (after copying the file to `Radar.sqlite.bak-v<old version>`), v4 rebuilds the kill learning tables, v5 adds the baseline statistics, v6 the daily energy table (`energy_days`). Append a version; never edit one that shipped.
- **Collaborators.** `BaselineBook`, `IncidentLedger`, `RuleBook` and `StoreMaintenance` share the actor's connection; the kill tables live in `RadarStore+KillLearning.swift`.
- **Write-behind.** Every queued model is learned in memory; a flush writes only incident changes and baselines that have learned five more samples or waited ten minutes, and skips the transaction entirely when nothing is due. Staged changes apply only after COMMIT, so a retried flush never learns twice. A failed flush keeps the newest three models and counts the rest.
- **Incident episodes.** `IncidentLedger` keeps open episodes in memory, closes one after 90 s without being observed (at its last activity, so time asleep ends an episode instead of stretching it), reopens it within ten minutes, and writes a row only when an episode starts, peaks, closes or every 30 s. Score, memory, CPU and proven growth are the episode's peaks, written by SQL `MAX` updates. Recurrence counts only resolved incidents. The console reads the log beyond the published 80 rows (`RadarStore.incidentHistory`, the newest 2,000) only while the Incidents page shows a search or a Resolved or Critical filter.
- **Maintenance.** Daily, never in the first minute: old incidents, kill history, stale baselines and expired rules are deleted, then incremental vacuum, `optimize` and a truncating checkpoint. `close()` on quit flushes, persists every learned baseline, checkpoints and closes.

## Energy

`RadarRefreshWorker` owns an `EnergyMonitor` and calls it after the thermal projection, over the full raw sample. It records every process into `EnergyLedger` (an hour of one-minute buckets per app, job or known source, grouped by `ThermalWorkloadResolver`), reads the battery (`IOKitBatterySource`: AppleSmartBattery registry keys, 2 s visible, 15 s hidden) and powerd's assertions (`IOKitSleepAssertionSource`, 5 s and 30 s), and builds an `EnergyReport`: ranked consumers with battery time gained, sleep blockers attributed through `AssertionOnBehalfOfPID`, per-family figures averaged over a minute, and findings from `EnergyFindingRules`. `ResponsibleProcessLookup` asks macOS once per identity which app is responsible for a launchd-started helper outside any bundle, and both the resolver and the heat panel group by it. `EnergyHistoryTracker` keeps today's totals per app and job; the worker loads today's stored rows once and adds what was measured to `energy_days` every five minutes and on quit (`syncEnergyHistory`). `ProcessMonitor` publishes the report as `energy` and a bucketed `energyGlance` for the popover, sidebar and Overview. See [Energy](Energy.md).

## Thermals

`ThermalSampler` reads AppleSMC read-only, before each refresh while a surface is visible and at most every 4 s while hidden; `ProcessMonitor` keeps the latest snapshot and a 180-second `ThermalObservationWindow`, so trends and traces are ready whenever a thermal view opens. `RadarRefreshWorker` calls `ThermalActivityAnalyzer.project` over the full raw sample on every refresh and records it in `ThermalActivityHistory` (a decayed load per app or job). The thermal views never signal a process; their stop shortcut goes through the regular preview. See [Thermals](Thermals.md).

## The app target

| Folder | Responsibility |
| --- | --- |
| `Application` | App entry, login item, notifications and their actions |
| `MenuBar` | `MenuBarCoordinator` (status item, status menu, the single main-menu definition), the popover, the status icon |
| `Shell` | `RadarConsoleController` and `RadarConsoleSession` (selection, Back/Forward, stops, toasts), sidebar, toolbar, Quick Stop, Settings window |
| `DesignSystem` | Theme, shared components, layouts, tips, motion, row actions, `RadarWaitLabel` |
| `Features/<feature>` | Overview, Processes, Duplicates, Incidents, Rules, Interventions (the stop sheet), Thermals, Energy, Sentinel, Settings |

The console session outlives the window, so reopening keeps the selection and projection; presentation stops while the window is hidden. `ThinkingOrbsKit` (vendored in `Packages/`) is used only by the stop sheet's clean-exit wait, the duplicate cull sheet's stopping state (each copy waits out a grace of 2 s or more) and `RadarWaitLabel`, and only for waits of two seconds or more.

Keep animation scopes local. Do not animate an entire process array or attach a high-frequency timer to the navigation shell. `RadarMotion.swift` centralizes finite animation timing; the scope's continuous sweep is a Core Animation transform, not a SwiftUI timer, and pauses when offscreen, inactive, hidden or with Reduce Motion; in Low Power Mode its animations ask for 10 frames a second (`preferredFrameRateRange`), a small share of the compositing, instead of stopping, since some Macs never leave Low Power Mode. Each blip's phosphor glow is a keyframe animation in the same paused-or-running layer clock, offset so it flares as the beam crosses its bearing, so the sweep never asks SwiftUI for a frame. The Live Radar's layout (`LiveRadarScene` in Core) is pure and tested: rings are verdicts, quarters are what a family is, bearings are nudged apart so blips never overlap, names are placed around blips and ring names, and distances and sizes are quantized so a scan's small wobble does not move every blip. Blips move once per scan without an implicit animation: with forty of them one moves almost every scan, and a 0.32 s animation re-rendered the whole window at display rate for a third of every second (measured at about 5 points of a core more than the old radar; without it, the same as the old radar within noise). Blips and contact rows are `Equatable` on what they draw, and the sweep layer skips commits when nothing moved.

## Verification and maintenance

`Scripts/verify.sh` is the canonical verification entry point. It runs architecture checks and infrastructure regression tests before the Swift suite, core check executable, and release build. See [Performance measurements](Performance.md) for the opt-in benchmarks; none of them samples or signals a real process.

Main-actor publish timing includes assignments and observer callbacks. The next refresh reports the preceding completed publish duration to avoid a self-triggering instrumentation loop. This timing does not include deferred SwiftUI layout or rendering; use Instruments for those.

Primary background references: [Apple's SwiftUI performance guide](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance), [WWDC25: Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/), and [SQLite query planning](https://www.sqlite.org/queryplanner.html).

## Settings and build lifecycle

The settings debounce uses `DebouncedTask`: cancellation exits before a pending write instead of merely interrupting its sleep. On quit, `ProcessMonitor.shutdown()` saves a pending settings change, waits for a just-finished stop to be recorded and closes the store; the app replies to `applicationShouldTerminate` once that finishes, or after one second at most.

Build identity is centralized in `Scripts/lib/project.sh`. The public bundler acquires an OS-managed advisory lock, then builds and signs a staging bundle. Validation precedes replacement, and a failed replacement restores the old bundle. Build-workflow tests inject failures into temporary fixtures and check the old bundle, rollback, lock release, signing, and invalid-command handling. These tests do not replace the real application or stop running processes.
