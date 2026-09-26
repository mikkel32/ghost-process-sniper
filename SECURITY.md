# Security policy

Ghost Process Sniper can send signals to processes, so safety bugs matter. It runs without administrator rights, has no privileged helper, and makes no network connections.

## Reporting a vulnerability

Please report security issues privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for them.

Especially relevant:

- a way to stop a process without the confirmation step, or a process other than the one previewed (for example through PID reuse),
- a way to affect processes owned by another user or protected system processes,
- anything that makes the app read or write outside its own data folder unexpectedly.

You will get an acknowledgement as soon as possible, and credit in the release notes if you would like it.

## Supported versions

Security fixes are made for the latest release.
