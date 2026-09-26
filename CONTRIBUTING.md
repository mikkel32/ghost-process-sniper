# Contributing

Thanks for helping make Ghost Process Sniper better.

## Reporting bugs

Open an issue with:

- your macOS version and Mac model (Apple silicon or Intel),
- what you expected and what happened,
- the report from **Copy Diagnostics** (in **Settings › Diagnostics**, the status menu, or ⇧⌘D in the console),
- for a stop that went wrong, the stop sheet's **Copy Report**.

Process names and command lines can reveal what you are working on — skim the diagnostics before pasting and redact anything private.

## Development setup

Requirements: macOS 26, Xcode 26 or a Swift 6.3 toolchain, and Python 3 for the infrastructure checks.

```sh
Scripts/dev.sh run      # build and open the app
Scripts/verify.sh       # everything CI runs; please run it before opening a pull request
```

[Docs/Development.md](Docs/Development.md) explains where code belongs, the architecture guardrails, the test layout and fakes, and the build scripts; [Docs/Architecture.md](Docs/Architecture.md) explains how the engine fits together.

## Pull requests

- Keep changes focused; one behavior change per pull request is easiest to review.
- Put new code in the folder that owns its responsibility. `Scripts/check_architecture.py` enforces folder ownership, the core/UI boundary (no SwiftUI in `GhostProcessSniperCore`), SQLite isolation, and a 600-line budget for every file, tests and checks included. The few legacy budgets above 600 may only go down: when you shrink such a file, lower its budget to the new length (or remove it once the file is at 600 lines or fewer).
- Add or update tests in `Tests/` or checks in `Checks/` for behavior you change. Kill-engine behavior is best tested against `FakeProcessTable`, whose processes react to signals; schema changes need a new migration and a `MigrationTests` case.
- Anything that can stop a process must keep the existing safeguards: an explicit preview, exact PID + start-time identities, the protection floor (`KillProtectionPolicy`), approved phases that run as previewed, and user confirmation.
- Keep `Packages/ThinkingOrbsKit` as vendored; it is only for waits of two seconds or more.
- The app does not use the network. Changes that add network access need a strong reason and an explicit discussion first.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
