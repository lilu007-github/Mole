# Burrow

A SwiftUI app for the Mole CLI in this repository. Burrow never deletes files
itself: every cleanup, uninstall and optimization runs through the bundled `mo`,
so Mole's protection rules, dry-run previews and operation log all apply.

## Features

| Area | What Burrow does | How |
|---|---|---|
| Status | Health score, CPU/memory/network/power history, disks, battery, GPU, Bluetooth, camera and microphone in use, top processes with details and quit, idle dev daemons | `mo status --json`, CoreAudio/CoreMediaIO, `ps`, `lsof` |
| Analyze | Folder list or treemap, drill-down, reveal in Finder | `mo analyze --json` |
| Clean | Preview, clean, whitelist, external drives | `mo clean`, Mole's whitelist functions |
| AI data | Tool folder sizes, Mole's AI cache rows, old Claude Code / Codex conversations to Trash, agent worktrees (read-only) | Burrow (the one place it moves files, to Trash, logged in Mole's format) |
| Build artifacts | Scan paths, per-artifact selection | `mo purge` menu, verified against Mole's list |
| Optimize | Preview, run with admin prompt relay, performance diagnosis | `mo optimize` |
| Installers | Select and delete | `mo installer` menu, verified against Mole's plan |
| Uninstall | Plan, personal data choice, quit running apps first | `mo uninstall` in a PTY |
| App updates | Homebrew casks and Sparkle feeds, ignore, update all | `brew outdated/upgrade`, appcasts |
| Startup items | LaunchAgents/Daemons with state and broken programs | plists, `launchctl` (read-only) |
| History | Sessions, per-run rows, deletions | `mo history --json`, operations.log |
| Tools | Menu bar panel and metric, keep awake (pauses on low battery), Clean Screen, Doctor, eject drives, notifications, global shortcuts, launch at login | AppKit, IOKit, Carbon hot keys |

Not included: fan control and battery charge limits (need a privileged helper
that writes hardware settings), Wi-Fi low latency (needs a privileged process
to keep AWDL down), and instant cleanup of an app dragged to the Trash (Mole
cleans orphaned data after 30 days; uninstall through Burrow cleans at once).

## Build

```bash
app/scripts/setup-signing.sh   # once: create a local signing identity
app/build-app.sh --open        # build app/build/Burrow.app and open it
```

Requirements: macOS 14+, Command Line Tools (Swift 5.10+) and Go. Full Xcode is
not needed.

`build-app.sh` produces a universal (Apple silicon + Intel) app with the CLI from
this checkout bundled in `Contents/Resources/mole`: the `mole` script, `bin/`,
`lib/` and the Go helpers `status-go` / `analyze-go`. The bundled Mole version is
shown in Settings (⌘,). To use a different Mole, set its path there.

## Checks

```bash
app/scripts/run-checks.sh            # all checks, about a minute
app/scripts/run-checks.sh parser     # only checks whose name contains "parser"
BURROW_SKIP_LIVE=1 app/scripts/run-checks.sh   # skip checks that run the CLI
```

Command Line Tools ship no test framework, so `run-checks.sh` compiles the app
sources (minus the `@main` entry) together with `Tests/Checks` into one
executable. Parsing and AI-cleanup checks use hand-written samples and a fixture
home folder. Live checks run this checkout's `mole`, only read-only commands and
`--dry-run`s; Mole records those dry runs in its operation log as usual.

GitHub Actions (`.github/workflows/burrow.yml`) runs the offline checks and
builds an ad-hoc signed `Burrow.zip` artifact on every push that touches `app/`.

## Keeping up with Mole

```bash
app/scripts/sync-upstream.sh          # merge tw93/Mole's main, run checks, rebuild
app/scripts/sync-upstream.sh --push   # same, then push main and this branch
```

The fork's `main` mirrors upstream; Burrow lives on its own branch in `app/`, so
merges should not conflict. Run it before building a copy to use, so the bundled
CLI carries Mole's latest safety fixes.

## Signing

macOS keeps privacy permissions (App Management, Full Disk Access) per code
signature. An ad-hoc signature changes with every build, so permissions would
have to be granted again after each rebuild.

`scripts/setup-signing.sh` creates a self-signed certificate, "Burrow Local
Signing", in its own keychain (`~/Library/Keychains/burrow-signing.keychain-db`,
password in `~/.config/burrow`, mode 600), not in the login keychain. Builds signed
with it keep the same designated requirement, so permissions survive rebuilds.
The certificate is only trusted by this Mac; distributing Burrow to others needs
an Apple Developer ID and notarization.

Remove the identity with `app/scripts/setup-signing.sh --remove`.

## License

Burrow bundles Mole, which is GPL-3.0, so Burrow is distributed under the same
license. Per Mole's `TRADEMARK.md`, Burrow uses its own name and does not use the
Mole name or logo.
