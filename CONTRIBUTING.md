# Contributing

Thanks for helping make Ghost Process Sniper better.

## Reporting bugs

Open an issue with:

- your macOS version and Mac model (Apple silicon or Intel),
- what you expected and what happened,
- the report from **Engine → Copy Diagnostics**, if the console opens.

Process names and command lines can reveal what you are working on — skim the diagnostics before pasting and redact anything private.

## Development setup

Requirements: macOS 26, Xcode 26 or a Swift 6.3 toolchain, and Python 3 for the infrastructure checks.

```sh
Scripts/dev.sh run      # build and open the app
Scripts/verify.sh       # everything CI runs; please run it before opening a pull request
```

[Docs/Development.md](Docs/Development.md) explains where code belongs, the architecture guardrails, and the build scripts.

## Pull requests

- Keep changes focused; one behavior change per pull request is easiest to review.
- Put new code in the folder that owns its responsibility. `Scripts/check_architecture.py` enforces folder ownership, the core/UI boundary (no SwiftUI in `GhostProcessSniperCore`), SQLite isolation, and a 600-line budget for new files.
- Add or update tests in `Tests/` or checks in `Checks/` for behavior you change.
- Anything that can stop a process must keep the existing safeguards: an explicit preview, exact PID + start-time identities, protected-process checks, and user confirmation.
- The app does not use the network. Changes that add network access need a strong reason and an explicit discussion first.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
