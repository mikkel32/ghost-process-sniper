# Sentinel: security watch

Sentinel looks at every process the radar samples for the shapes attacks take on macOS, and explains each finding with the chain of processes that launched it and the exact text that matched. It runs without administrator rights, sends nothing anywhere, and never acts on its own.

Code lives in `Sources/GhostProcessSniperCore/Sentinel` (detection) and `Sources/GhostProcessSniper/Features/Sentinel` (the Security page).

## How a process is judged

Each process identity (PID plus start time) is judged once, when it first appears, together with its ancestors at that moment. Ghost never judges its own process or anything it starts, so running it straight from its mounted disk image is not a finding. A parent that exits takes that evidence with it, so the chain is captured at first sight. A process is judged again only when its arguments arrive a tick late or it starts listening on a port; the chain captured first is kept then, so a payload whose wrapper shell has since exited keeps its "Chrome started this" explanation and its level.

`SentinelRules` combines four kinds of evidence:

| Evidence | Examples | Severity |
| --- | --- | --- |
| **Who launched it** | A browser, mail app or document app starting a shell, AppleScript, an interpreter or a download tool (`Google Chrome › zsh › curl`). Chat apps count as notable, and so does a browser extension's native-messaging host (its arguments name the extension: `chrome-extension://…`, or a Firefox host manifest). A command runner in between (Chrome › sh › curl) still counts. | Suspicious; Dangerous with a payload |
| **What it runs** (`CommandPatterns`) | `curl … \| sh` and `bash -c "$(curl …)"`; base64/`xxd`/`openssl` decoding piped to a shell or `exec(base64…)`; `osascript` dialogs asking for a password; `dscl -authonly`; `security find-generic-password … Chrome Safe Storage`; copying a browser profile's `Cookies`, `Login Data` or `Local State`, `~/Library/Keychains`, or a wallet's data (`~/.electrum/wallets`, `Exodus/exodus.wallet`), matched as whole paths with URLs ignored; `xattr -d com.apple.quarantine`, `spctl --master-disable`; writing to `LaunchAgents`; `/dev/tcp` wired to a shell (`>& /dev/tcp/…`, `exec 5<>/dev/tcp/…`), `nc -e /bin/sh`, `socat exec:`; mining pools (`stratum+tcp://`, `-o pool.example.com:3333`); silent `screencapture`, `ffmpeg -f avfoundation` | Info to Dangerous |
| **Where it lives** | `/tmp`, per-user temporary folders, `/Users/Shared` (Suspicious only once the signature shows no known developer signed it), hidden home files and folders that are not known tool caches (`~/.helper`, `~/.xq/agent`; `~/.cargo`, `~/.nvm` and about 60 others are allowed; a hidden home program is Notable on its own), `~/Downloads`, mounted disk images, the Trash, a deleted executable | Notable to Suspicious |
| **What it pretends to be** | A system name from the wrong folder (`launchd` outside `/sbin`), look-alike letters (`Fіnder` with a Cyrillic і), an app named `Invoice.pdf.app`. Simulator runtimes and Xcode's platform folders ship their own `cfprefsd`, `trustd` and `tccd`, and count as Apple's. | Suspicious to Dangerous |

A listening port adds evidence: a shell waiting for connections is Dangerous and `nc`/`socat` listening is Suspicious. A program in a temporary or hidden folder that listens is Suspicious; it is Dangerous only when nobody vouches for its signature, nobody started it from a terminal, and it shows another sign of an attack. A program signed by Apple, the App Store or a Developer ID that listens adds nothing. Dev servers listening are normal. A program in a hidden home folder that no known tool uses counts as oddly placed like one in `/tmp` once its signature has been read and shows nobody vouches for it (until then the quieter Notable verdict stands, as for `/Users/Shared`), and it holds for the escalation rules below.

**Coding assistants.** A program in `/tmp` that Claude's or Codex's own shell started (a shell sits between it and the assistant) and whose temporary folder is the only Suspicious thing about it is Notable: it is probably a program the assistant just built, so it neither notifies nor lights the menu-bar icon. Only an assistant running from where such tools install counts (`/Applications`, `~/Applications`, Claude's Application Support folder, Homebrew, `/usr/local`, and the home folders their installers use: `~/.local/bin`, `~/.claude`, `~/.codex`, npm's and the version managers'); a file that merely carries the name in `~/Documents`, `~/Library/Caches`, `/tmp` or Downloads does not. Programs typed or pasted into a terminal stay Suspicious, and a listener, payload, miner, deleted file or unknown launcher keeps its severity. The trade-off: a dropper started by a prompt-injected assistant reads Notable unless another signal applies.

**Interpreters.** Python's framework launcher (`Python.app` inside a `Python.framework`, as used by Xcode, the Command Line Tools, python.org and Homebrew) counts as the interpreter, unlike an app's bundled node or embedded Python: its arguments are read, a browser starting it is reported, and Trust covers one command at a time.

A command pasted into a terminal reaches Sentinel as separate processes: `curl -fsSL https://x | sh` is a `curl` and a bare `sh` whose arguments never contain the `|`. `PipelineCorrelator` puts them back together: a downloader writing to standard output (curl without `-o`, `wget -O-`), any decoders or decompressors, and a shell or interpreter reading standard input (no script, no `-c`; `sudo` and `env` are looked through), all children of one shell in one process group, started within two seconds. The runner is judged on the whole command, whichever member arrived first, so the installer allowlist, the "pasted" advice and the stealer's-chain escalation (`curl … | base64 -d | bash` is Dangerous) apply as if it had been typed as one argument.

Signals that describe an attack chain together outrank each alone (`SentinelRules.escalate`):

- a content app launching a runner whose command carries a payload,
- download-and-run plus decoding, a password prompt or quarantine removal (how password stealers install),
- a binary in a temporary or hidden folder that also carries a payload, a miner, a tunnel command or a listener judged a backdoor.

Well-known installer one-liners (Homebrew, rustup, bun, uv, nvm, Ollama and others) are recorded as context, not flagged, when every address the command downloads and runs is an installer's: https, the installer's exact host (so `sh.rustup.rs.evil.example` and `sh.rustup.rs@evil.example` are not it) and its path. An installer address elsewhere in the command does not vouch for another download. The tests pin both sides: attack shapes are caught, and everyday developer commands (`git pull`, `cargo build`, `vite`, `python3 -m http.server`, `security find-identity`, `curl` to an API, `curl -c cookies.txt`, `wget -nc -e robots=off`, a `</dev/tcp/localhost/5432` port check, compiling `threadpool.c`, `brew install --cask exodus`, a booted simulator) raise nothing.

## Signatures and download marks

`CodeSignatureInspector` checks every third-party executable once per (path, device, inode, size, change time), one file at a time at utility priority, off the refresh path, and hands a result out only while the file on disk is still the one it read: a binary swapped in place, even back-dated with `touch -r`, waits for its own check instead of inheriting the old signature. It records the code directory hash (cdhash) too. It uses basic validation (the signature and certificate chain, without hashing every page of a large binary) and classifies the signer as Apple, Mac App Store, Developer ID, another certificate, ad hoc, unsigned or invalid. It also reads the quarantine mark and `kMDItemWhereFroms`, so a finding can say which page a program was downloaded from.

Ad hoc signatures are normal for Homebrew and anything you compile, so they only count for a program that was downloaded, hidden or temporary. Unsigned is notable; an invalid signature is suspicious. Validation never uses the network (`kSecCSNoNetworkAccess`: no revocation or online notarization lookups).

Rules that depend on the signer (`/Users/Shared`, a listener in an odd folder) run again once the signature is read. Until then the quieter verdict stands, so a signed program never flashes an alarm while it waits.

## Trust

**Trust** never means "this path". What it covers depends on the program:

| Program | Trust covers | A change that is flagged |
| --- | --- | --- |
| Signed by a Developer ID or the App Store | Any version with the same team and identifier (`Trust Slack (Team BQR82RBBHL)`) | Another team, another identifier, ad hoc or unsigned |
| Signed by Apple, outside the system folders | Any version with the same identifier | Anything else |
| Ad hoc or another certificate | This exact build, by its cdhash | Any rebuild |
| Unsigned | This exact file (device, inode, size, change time) | Any write or metadata change |
| A shell, interpreter, download tool or anything in the system folders | One script it runs, while the script is unchanged, or one exact command (kept as a SHA-256, never as text) | An edited script; any other command |

A pasted command is trusted as the whole pipeline it was pasted as, address included: a different URL asks again, and a pasted pipeline never matches trust given to a script. Trust also works on a finding whose process has already exited, for as long as it is listed (30 minutes); it clears exited siblings the new entry really covers (signer, build or file), but not a sibling reverse shell when the trust is command-scoped.

Shells and tools are never trusted whole: trusting `bash` for a browser extension's native host would otherwise hide every later reverse shell or pasted download that runs through bash. An invalid signature is never trusted, and a program whose signature has not been read yet cannot be trusted until it has.

A trusted program whose file no longer matches becomes a Suspicious finding that says what was trusted and what is there now ("You trusted Slack as signed by team BQR82RBBHL; the file there now is unsigned"). While a trusted program's signature is being read its finding waits, so it never flashes an alarm. The **Trusted** list on the Security page shows each entry's scope, with **Revoke**. Entries are saved as JSON under `Sentinel.trust.v2`; paths trusted by 2.1 and earlier are carried over once, shells and tools dropped, and each bound to the first signature read; the old list is left for an earlier version.

## Watching without polling

- **Spawns.** `SpawnWatcher` subscribes to kernel process events (`fork`, `exec`, `exit`) for running browsers, mail, chat and document apps, and terminals. Shells already open when watching starts (tabs opened before Ghost, or before it relaunched) are adopted and followed without being reported, and each new watch looks once for a child that appeared while it was being armed. A fork wakes its queue, the child is followed to its `exec`, and its path and arguments are read while it runs, several levels down (Terminal › login › zsh › curl). A command that lives for 200 ms is caught with its full arguments. An app's own helpers are not followed. A runner started by a content app wakes the radar at once.
- **Startup items.** `PersistenceMonitor` reads `~/Library/LaunchAgents`, `/Library/LaunchAgents` and `/Library/LaunchDaemons`, and watches those folders with file-system events. A new item is judged by what it runs and from where, marked NEW, and announced with a notification. Inline shell scripts, Apple-style labels in your Library folder and targets in odd folders are flagged.
- **Microphone and camera.** `PrivacySensorMonitor` registers Core Audio and CoreMediaIO property listeners and re-reads only when a device starts or stops or the audio client list changes. `ListenerSet` keeps exactly one listener per device: the input that stops being the default and cameras that go away lose theirs, and a camera that returns under a reused ID gets a fresh one. macOS names the processes recording audio (macOS 14 and later), but only says whether a camera is on. A shell or script recording audio becomes a finding; a meeting app is only listed. Siri waiting for "Hey Siri" (`corespeechd`, in `/System/Library/PrivateFrameworks/CoreSpeech.framework`) keeps the tile calm; any other client, or that name from another path, turns it orange.

None of these open a device, ask for a permission, or poll while nothing happens.

## Limits

- Sentinel sees processes owned by any user, but reads arguments only where macOS allows (your own processes, and system tools it can inspect). It is not Endpoint Security: a process that starts and exits between two scans is seen only if a watched app started it.
- Patterns describe known techniques. A novel attack that looks like normal software will not match, and some legitimate tools will. Every finding shows its evidence so you can judge.
- Screen recording by a particular app cannot be observed with public APIs; Sentinel flags known capture commands instead.
- The launch feed and captured command lines stay in memory (the last 300 launches) and are never written to disk. Alert cooldowns are saved as SHA-256 hashes only, never paths or app names.

## Using it

The **Security** page (⌘3) leads with a shield that shows the worst live finding. Below it are the microphone and camera, findings, what starts automatically, and the launch feed. The feed filters to flagged launches, commands, or everything. **Stop…** opens the usual stop preview. **Trust** names exactly what it trusts (see [Trust](#trust)), and **Dismiss** hides one finding for as long as it lasts. A live suspicious or dangerous finding also appears above the Overview, raises the menu-bar icon, and sends one notification (`SentinelAlertGate`), as far as Settings › Alerts allows (Dangerous always notifies). The same program flagged for the same reason at the same severity stays silent for 24 hours however often it restarts, so a worker pool or a relaunching helper alerts once, and the cooldown survives a relaunch; a finding that turns dangerous alerts again, and so does a startup item that turns worse. A dangerous finding's cooldown does not outlive the run, so it can still notify after a relaunch. An alert the notifier could not post (notifications not yet allowed, or a failed post) is taken back and offered again shortly, so it is not lost.

A **dangerous command that has already exited** (a pasted `curl … | sh` is over in a second, which is what the spawn watcher exists to catch) still sends one notification, and stays visible: the Security header, the sidebar row, the Overview banner and the menu-bar popover say "A dangerous command ran and has already exited" until it expires after 30 minutes or is dismissed. An exited Suspicious finding stays a card only. The menu-bar icon follows running findings only; the page header (shield and tint), the sidebar row, the Overview banner and the popover also show the exited Dangerous one.
