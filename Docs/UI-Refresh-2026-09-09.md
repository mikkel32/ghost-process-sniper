# UI refresh verification — 9 September 2026

## Delivered

The console now has an adaptive overview with large, actionable metric cards, a dedicated all-process browser, readable sidebar navigation, hover feedback, clear query recovery, and an in-app guide. Evidence in the recommendation card expands on demand. The native Radar menu exposes section shortcuts, and Find Processes works from non-search sections such as Engine.

The browser uses a bounded layout so its lazy list cannot enlarge the console or push its header and footer offscreen. The console constrains its initial frame to the visible screen. Next/previous family navigation follows the current filtered order. Explicit navigation requests are not overwritten by initial scene restoration. Invalid saved route values recover to Overview.

## Verification performed

- `swift test`: **19 tests passed**, including eight new route serialization and filtered-navigation tests.
- `GhostProcessSniperCoreChecks`: **passed**. The PID-copy assertion now checks the chosen sequential/parallel strategy rather than treating successful BSD reads as the total enumerated PID count.
- `swift build --configuration release`: **passed**.
- `Scripts/bundle-app.sh`: **passed**, using the release configuration.
- `codesign --verify --deep --strict --verbose=2`: **passed** for the generated app bundle. This is the existing local ad-hoc signing workflow, not notarization or a public release.

The actual app was opened and its screenshots inspected before and after the changes. Interactive checks covered the overview at wide and compact sizes; browser resizing and scrolling; a real QuickTime search; unmatched-query recovery; clearing a query and filter together; the Memory card and descending sort; the Quiet filter; filtered next-family navigation; the guide and Escape dismissal; Engine-to-search navigation; and opening and closing Settings without changing preferences. Closing the console left the app process alive, and opening the existing app again restored a console window.

## Scope and preservation

Existing working-tree changes were retained. The prior app bundle and copies of the existing files edited in this pass are preserved under `.build/ui-improvement-before/`. The earlier adaptive detection/settings work was present before this UI pass; it is not represented here as newly implemented functionality.

Manual UI checks did not confirm a process-stop action or change detection settings. This pass is not an exhaustive VoiceOver audit, a frame-rate benchmark, a long-running stability test, or a certification of the pre-existing detection heuristics. The current build and tests passed; those broader claims were not measured.
