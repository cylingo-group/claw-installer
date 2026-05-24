# Claw Installer

> Developed by **心言集团 (Cylingo Group)** — the team behind
> [**BubboLink**](https://bubbolink.com), our IM-side gateway that lets a
> single chat thread orchestrate OpenClaw, Hermes, Claude Code, Codex and
> other agents at once. Once `bubbolink pair` runs (one click inside this
> installer), every agent you've installed on this machine becomes
> reachable from BubboLink.

A one-click installer for the **OpenClaw** and **Hermes** AI agents on a
fresh host. Supports macOS, Linux, WSL 2 and Windows (via WSL). Ships as a
small Tauri desktop GUI that drives a battle-tested set of shell scripts —
so the same flow runs whether you double-click the app or invoke
`./shell/install.sh` from a terminal.

## What's inside

| Component | What it does |
| --- | --- |
| **OpenClaw** | The open-source agent runtime that powers chat-driven workflows. The installer pins Node, pnpm and the gateway daemon, then provisions its workspace under `~/.openclaw/`. |
| **Hermes** | Cylingo's hosted-model bridge — gives every agent on the host a unified provider config (心元 / DeepSeek / MiniMax / custom OpenAI-compatible). |
| **BubboLink pairing** | After install, paste the 4-digit code from the **BubboLink** mobile app and we'll `bubbolink pair` against every runtime on this machine. |
| **Channel docs** | Quick-links to OpenClaw's WeChat / 飞书 / 钉钉 integration guides — opens in your browser, no GUI config needed. |

## Quick start (end users)

### macOS

1. Download `Claw-Installer-<version>-universal.dmg` from the
   [latest release](https://github.com/cylingo/claw-installer/releases/latest)
   (or your internal distribution channel).
2. Open the DMG and drag **Claw Installer** to `/Applications`.
3. Launch it. The window will guide you through agent selection → install →
   pairing.

### Windows 10 / 11

1. Download `claw-installer-windows.zip` and unzip anywhere.
2. Open the `claw-installer` folder and double-click `claw-installer.exe`.
3. On first run we'll prompt for UAC to provision WSL 2 + Ubuntu — let it
   reboot if asked, then re-launch the installer.

### Linux (Ubuntu / Debian)

```bash
sudo apt install ./Claw-Installer-<version>-amd64.deb
# or
chmod +x Claw-Installer-<version>-x86_64.AppImage
./Claw-Installer-<version>-x86_64.AppImage
```

### Headless / scripted

Skip the GUI and run the shell pipeline directly:

```bash
git clone <repo> && cd claw-installer
./shell/install.sh                            # both agents
./shell/agents/openclaw/install.sh            # just OpenClaw
INSTALLER_AGENTS=hermes ./shell/install.sh    # via env var
```

## Building from source

We ship one-command builds for all three desktop targets. Prerequisites:

- [pnpm](https://pnpm.io) ≥ 9 (the workspace uses pnpm)
- [Rust](https://rustup.rs) stable toolchain
- For **macOS universal**: `rustup target add x86_64-apple-darwin`
- For **Windows cross-compile**: `cargo install cargo-xwin`
- For **Linux build (from macOS)**: Docker Desktop running

Then:

```bash
make build-mac        # universal .app + .dmg → dist/macos/
make build-linux      # .deb + .AppImage → dist/linux/ (via Docker, native arch)
make build-windows    # claw-installer.exe + shell/ → dist/windows/*.zip
make build-all        # all three, sequentially
```

Artifacts land under `dist/<platform>/`.

> **Note on Linux arch:** `make build-linux` produces artifacts matching the
> container's native arch — arm64 on Apple Silicon hosts, amd64 on Intel
> hosts. To cross-build, set `LINUX_PLATFORM`:
> ```
> make build-linux LINUX_PLATFORM=linux/amd64    # x86_64 Linux from arm64 mac (slow: ~2–3 h via qemu)
> make build-linux LINUX_PLATFORM=linux/arm64    # arm64 Linux from x86_64 host
> ```

### Run during development

```bash
make dev              # Tauri dev mode (recommended — live reload + Rust)
make frontend         # browser stub mode (no Rust, no agent IPC)
```

---

## Architecture (for contributors)

The rest of this document describes the installer's internal contracts —
useful if you're modifying the shell scripts or the Rust↔TS IPC layer.

Designed to be driven either from a shell or from a GUI front-end — the GUI
sets `INSTALLER_*` env vars and spawns the same entry points end-users
invoke directly.

## Layout

```
shell/                            CLI implementation: install + lifecycle + uninstall
├─ install.sh                     top-level: env deps + every agent
├─ uninstall.sh                   reverses what we installed, per the manifest
│                                  (honors CLAW_UNINSTALL_AGENT for per-agent mode)
├─ agents/                        per-agent lifecycle scripts
│   ├─ openclaw/{install,start,stop,restart,uninstall}.sh
│   └─ hermes/{install,start,stop,restart,uninstall}.sh
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

gui/                              Tauri-based GUI (drives the shell/ scripts)
```

## Entry points

| Platform        | Command                                                                       |
| --------------- | ----------------------------------------------------------------------------- |
| macOS / Linux   | `./shell/install.sh`                                                          |
| WSL 2           | `./shell/install.sh` (same as Linux)                                          |
| Windows (1-click) | `powershell -ExecutionPolicy Bypass -File shell\windows\bootstrap.ps1`      |
| Single agent    | `./shell/agents/openclaw/install.sh` or `./shell/agents/hermes/install.sh`    |
| Lifecycle       | `./shell/agents/<agent>/{start,stop,restart}.sh`                              |
| Uninstall (all) | `./shell/uninstall.sh` (add `--dry-run` to preview)                           |
| Uninstall (one) | `./shell/agents/<agent>/uninstall.sh`                                         |
| Docker smoke    | `cd shell/docker && docker compose up --build`                                |

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
(`agents/<agent>/install.sh`) inherit `CLAW_SESSION_LOG` from the parent
`install.sh` and append to the same file.

### Debug mode

Pass `--debug` to any entry-point script to tail the session log to stderr in
real time:

```bash
./shell/install.sh --debug
```

This starts `tail -F "$CLAW_SESSION_LOG" >&2 &` in the background and kills it
on EXIT. Useful for CLI triage when you want to see the full forensic output.

### INSTALLER_* env vars

The GUI configures behavior via `INSTALLER_*` environment variables and spawns
one of the entry points above. See each `agents/<agent>/install.sh` header for
the full list of supported variables.

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
| `INSTALLER_REPO_DIR`               | Override path to the `shell/` checkout (used by the Rust backend in dev mode) |

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
