# claw-installer

Single installer that brings up the OpenClaw and Hermes agents on a fresh
host (macOS, Linux, WSL 2, Windows-via-WSL). Designed to be driven either
from a shell or from a GUI front-end — the GUI sets `INSTALLER_*` env vars
and spawns the same entry points end-users invoke directly.

## Layout

```
installer/                        CLI installers (shell + PS bootstrap)
├─ install.sh                     top-level: env deps + every agent
├─ install-openclaw.sh            openclaw agent (pnpm-based)
├─ install-hermes.sh              hermes agent (delegates to upstream install.sh)
├─ uninstall.sh                   reverses what we installed, per the manifest
├─ lib/                           shared helpers + manifest plumbing
│   ├─ common.sh
│   └─ manifest.sh
├─ steps/                         fine-grained env primitives
│   ├─ base-deps.sh               curl / git / openssl / unzip / ca-certificates
│   ├─ fnm.sh                     fnm (Node version manager)
│   ├─ node.sh                    Node via fnm
│   ├─ pnpm.sh                    pnpm via corepack
│   ├─ npmrc.sh                   ~/.npmrc mirror block
│   └─ shell-rc.sh                ~/.bashrc / ~/.zshrc PATH persistence
├─ vendor/fnm/                    vendored fnm installer (offline-friendly)
├─ windows/bootstrap.ps1          Windows entry: WSL preflight → install.sh
└─ docker/                        smoke-test infra (Ubuntu 24.04 in a box)
    ├─ Dockerfile
    ├─ docker-compose.yml
    └─ docker-entrypoint.sh

gui/                              Tauri-based installer GUI (in progress)
```

## Entry points

| Platform        | Command                                                                |
| --------------- | ---------------------------------------------------------------------- |
| macOS / Linux   | `./installer/install.sh`                                               |
| WSL 2           | `./installer/install.sh` (same as Linux)                               |
| Windows (1-click) | `powershell -ExecutionPolicy Bypass -File installer\windows\bootstrap.ps1` |
| Single agent    | `./installer/install-openclaw.sh` or `./installer/install-hermes.sh`   |
| Uninstall       | `./installer/uninstall.sh` (add `--dry-run` to preview)                |
| Docker smoke    | `cd installer/docker && docker compose up --build`                     |

## Install state

Everything we change lands in **`~/.claw-installer/`** (overridable via
`CLAW_STATE_DIR`):

- `manifest.tsv` — structured record of every side effect; first-write wins

Session logs land in **`$TMPDIR/claw-installer/`**:

- `install-<UTC-unix-ts>.log` — full forensic record of an install run
- `uninstall-<UTC-unix-ts>.log` — full forensic record of an uninstall run

When spawned by Rust, the log path is passed as `CLAW_SESSION_LOG` via the
child process environment. When invoked directly from the terminal without
Rust, scripts auto-generate a fallback path under `$TMPDIR/claw-installer/cli-<ts>.log`.

`uninstall.sh` reads the manifest and reverses each row in insertion order.
Status `preexisting` rows are skipped (we don't remove what we didn't install).

## GUI ↔ installer contract

### Two-stream logging

Scripts author every user-visible string explicitly using three primitives:

- **`display "中文描述…"`** — writes to stdout (user sees it) AND to the session
  log file. Every line the 5-line log strip shows comes from `display`.
- **`log "technical detail"`** — writes to the session log file ONLY. Never
  appears on the user's terminal.
- **`run <cmd> [args…]`** — logs `+ <cmd>`, executes the command with both stdout
  and stderr going to the session log file, and returns the command's exit code.

### Step sentinel protocol

When a step starts, the script emits:

```
@@step:<key>:<label>
```

via `display "@@step:node:正在配置 Node 22 运行时"`. Rust parses this with the
regex `^@@step:([a-z][a-z0-9-]*):(.+)$` and emits `InstallerEvent::StepChanged {
key, label, detail: "" }`. The line is **not** forwarded as `LogLine`.

All other stdout lines are forwarded verbatim as `LogLine` events. Rust does
**no filtering, no ANSI stripping, no translation** — scripts are the sole
authors of what the user sees.

### Failure output

On a step failure the scripts emit this 3-line block on stdout (so Rust
forwards it as `LogLine` events for the GUI to surface):

```
✗ 失败步骤：<current step Chinese label>
✗ 失败原因：<command + exit code>
✗ 详见完整日志：<absolute CLAW_SESSION_LOG path>
```

### CLAW_SESSION_LOG env var

Rust pre-creates `$TMPDIR/claw-installer/<install|uninstall>-<ts>.log`, then
passes `CLAW_SESSION_LOG=<path>` to the child process. Scripts open `fd 3`
appending to this file when `common.sh` is sourced. Child agent scripts
(`install-openclaw.sh`, `install-hermes.sh`) inherit `CLAW_SESSION_LOG` from
the parent `install.sh` and append to the same file.

### Debug mode

Pass `--debug` to any entry-point script to tail the session log to stderr in
real time:

```bash
./installer/install.sh --debug
```

This starts `tail -F "$CLAW_SESSION_LOG" >&2 &` in the background and kills it
on EXIT. Useful for CLI triage when you want to see the full forensic output.

### INSTALLER_* env vars

The GUI configures behavior via `INSTALLER_*` environment variables and spawns
one of the entry points above. See each `install-<agent>.sh` header for the
full list of supported variables.

| Variable                          | Effect                                                    |
| --------------------------------- | --------------------------------------------------------- |
| `INSTALLER_AGENTS=openclaw,hermes` | Subset of agents to install (default: both)              |
| `INSTALLER_NPM_REGISTRY`           | npm/pnpm registry mirror                                  |
| `INSTALLER_GATEWAY_*`              | openclaw gateway port / bind / token                      |
| `INSTALLER_SERVICE_MODE`           | `daemon` / `foreground` / `skip`                          |
| `INSTALLER_WORKSPACE`              | openclaw workspace dir                                    |
| `INSTALLER_HERMES_SKIP_BROWSER=1`  | Skip Playwright/Chromium install                          |
| `INSTALLER_FORCE_REINSTALL=1`      | Bypass all "already installed" fast-paths and redo everything |
| `INSTALLER_WSL_DISTRO`             | (Windows) override WSL distro (default: Ubuntu)           |
| `INSTALLER_REPO_DIR`               | (Windows) override path to the installer/ checkout        |

## Re-runs are idempotent

Re-running `install.sh` on a host that's already set up is fast and safe:
each step probes for existing state before doing work.

- **System packages** (curl, git, ripgrep, ffmpeg, build chain): only missing
  packages get installed; already-present ones are recorded as `preexisting`.
- **fnm / Node / pnpm / uv / Python 3.11**: skipped when the requested
  version is already installed and active.
- **`~/.npmrc` and `~/.bashrc`/`~/.zshrc` managed blocks**: rewritten only if
  the existing block content differs from the desired content.
- **openclaw package**: skipped when `openclaw` is already on PATH.
- **openclaw config**: existing gateway token is reused (never silently
  rotated); individual `openclaw config set` calls are skipped when the
  current value already matches.
- **openclaw gateway service**: if `openclaw gateway status` reports the
  daemon is running, the installer skips `gateway install`, `doctor --repair`,
  and `gateway start` — no daemon restart on re-run.
- **hermes**: skipped when `$HERMES_HOME/../hermes-agent` is already checked
  out and `~/.local/bin/hermes` is executable.

Set `INSTALLER_FORCE_REINSTALL=1` to bypass these fast-paths.

Read manifest from Windows:

```
\\wsl.localhost\Ubuntu\home\<user>\.claw-installer\manifest.tsv
```
