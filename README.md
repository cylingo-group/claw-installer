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
- `install-<UTC>.log` — full stdout/stderr of each run

`uninstall.sh` reads the manifest and reverses each row in insertion order.
Status `preexisting` rows are skipped (we don't remove what we didn't install).

## GUI ↔ installer contract

The GUI never writes the manifest and never parses installer output. It
configures behavior via `INSTALLER_*` environment variables and spawns one of
the entry points above. See each `install-<agent>.sh` header for the full
list of supported variables.

| Variable                          | Effect                                                    |
| --------------------------------- | --------------------------------------------------------- |
| `INSTALLER_AGENTS=openclaw,hermes` | Subset of agents to install (default: both)              |
| `INSTALLER_NPM_REGISTRY`           | npm/pnpm registry mirror                                  |
| `INSTALLER_GATEWAY_*`              | openclaw gateway port / bind / token                      |
| `INSTALLER_SERVICE_MODE`           | `daemon` / `foreground` / `skip`                          |
| `INSTALLER_WORKSPACE`              | openclaw workspace dir                                    |
| `INSTALLER_HERMES_SKIP_BROWSER=1`  | Skip Playwright/Chromium install                          |
| `INSTALLER_WSL_DISTRO`             | (Windows) override WSL distro (default: Ubuntu)           |
| `INSTALLER_REPO_DIR`               | (Windows) override path to the installer/ checkout        |

Read manifest from Windows:

```
\\wsl.localhost\Ubuntu\home\<user>\.claw-installer\manifest.tsv
```
