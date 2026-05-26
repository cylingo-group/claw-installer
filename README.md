<!-- TODO: hero banner / logo SVG goes here once we have one -->

# Claw Installer

**English** · [简体中文](./README.zh-CN.md)

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Latest release](https://img.shields.io/github/v/release/cylingo-group/claw-installer)](https://github.com/cylingo-group/claw-installer/releases/latest)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey)](#download)

**Set up your AI agents in 5 minutes, on any OS.**

Claw Installer is a one-click desktop installer that gets a fresh laptop from
zero to a working **OpenClaw** + **Hermes** setup — no terminal, no manual
toolchain wrangling. Pick the agents you want, click install, and we'll take
care of Node, pnpm, uv, Python, and everything else they depend on. The same
flow works whether you're on macOS, Linux, or Windows (via WSL 2).

<!-- TODO: hero GIF or screenshot of the installer running (1100×620, ≤ 4 MB) -->

> Made by **Cylingo Group** — also the team behind [**BubboLink**](https://bubbolink.com),
> an IM-side gateway that lets a single chat thread drive every agent on your
> machine. Pair it once from inside this installer and you're done.

## Download

Pick your platform and grab the latest build from the
[releases page](https://github.com/cylingo-group/claw-installer/releases/latest).

| Platform | Recommended | Also available |
| --- | --- | --- |
| **macOS** (11 +, Apple Silicon & Intel) | `Claw-Installer-<version>-universal.dmg` | — |
| **Windows** 10 / 11 | `claw-installer-windows.zip` | — |
| **Linux** (Ubuntu / Debian) | `Claw-Installer-<version>-amd64.deb` | `Claw-Installer-<version>-x86_64.AppImage` |

**macOS** — open the DMG and drag **Claw Installer** to `/Applications`,
then launch it.

**Windows** — unzip and double-click `claw-installer.exe`. On first run
Windows will ask permission to install WSL 2 + Ubuntu; allow it, reboot if
prompted, and re-launch.

**Linux**

```bash
sudo apt install ./Claw-Installer-<version>-amd64.deb
# or, for the portable build:
chmod +x Claw-Installer-<version>-x86_64.AppImage
./Claw-Installer-<version>-x86_64.AppImage
```

Prefer the terminal? Skip the GUI entirely:

```bash
git clone https://github.com/cylingo-group/claw-installer.git
cd claw-installer
./shell/install.sh                          # both agents
INSTALLER_AGENTS=openclaw ./shell/install.sh   # just one
```

## Screenshots

<table>
  <tr>
    <td width="20%" align="center">
      <img src="./docs/images/readme/01.jpeg" width="170" alt="Agent picker"><br>
      <sub><em>Pick which agents you want — one or all at once.</em></sub>
    </td>
    <td width="20%" align="center">
      <img src="./docs/images/readme/02.jpeg" width="170" alt="Install in progress"><br>
      <sub><em>Watch the install in real time, with a live log strip.</em></sub>
    </td>
    <td width="20%" align="center">
      <img src="./docs/images/readme/03.jpeg" width="170" alt="Settings"><br>
      <sub><em>Switch install mirror and UI language any time.</em></sub>
    </td>
    <td width="20%" align="center">
      <img src="./docs/images/readme/04.jpeg" width="170" alt="Model configuration"><br>
      <sub><em>Pick a model provider — BubboHub, DeepSeek, Kimi, MiniMax, or any OpenAI-compatible endpoint.</em></sub>
    </td>
    <td width="20%" align="center">
      <img src="./docs/images/readme/05.jpeg" width="170" alt="Channel configuration"><br>
      <sub><em>Pair with BubboLink, or open the WeChat / Feishu / DingTalk guides.</em></sub>
    </td>
  </tr>
</table>

## What you get

| Component | What it does for you |
| --- | --- |
| **OpenClaw** | An open-source agent runtime that powers chat-driven workflows. Its workspace lives under `~/.openclaw/`. |
| **Hermes** | Cylingo's hosted-model bridge. Gives every agent on the machine a unified provider config (BubboHub / DeepSeek / MiniMax / any OpenAI-compatible endpoint). |
| **BubboLink pairing** | One paste of the 4-digit code from the BubboLink mobile app links every installed agent to your phone. |
| **Channel docs** | One-click shortcuts to OpenClaw's WeChat / Feishu / DingTalk integration guides — opens in your browser, no extra config. |

Under the hood we also pin the runtimes the agents need: **Node** (via
[`fnm`](https://github.com/Schniz/fnm)), **pnpm** (via Corepack), **uv** and
**Python 3.11**, plus a few system utilities (`curl`, `git`, `ripgrep`,
`ffmpeg`, build essentials). If you already have them, we leave yours alone
(see [Privacy](#privacy--what-it-does-to-your-system) below).

## Why claw-installer

Without an installer, getting OpenClaw and Hermes both running on a fresh
machine looks like this:

1. Clone two separate repositories
2. Install Node, pnpm, uv, Python 3.11, Rust, Playwright…
3. Configure PATH in `~/.bashrc` / `~/.zshrc`
4. Read three setup docs to figure out the right env vars
5. Spawn each gateway as a system service
6. Hope nothing collides with what's already on your machine

With Claw Installer it looks like this:

1. Download, click, and wait a few minutes

Other nice things:

- **Idempotent.** Re-running on a half-set-up machine is safe and fast — every
  step probes the current state before doing work.
- **Reversible.** Every side effect is recorded; `./shell/uninstall.sh` undoes
  exactly what we installed and leaves anything you already had alone.
- **GUI + CLI parity.** The desktop app and `./shell/install.sh` run the
  exact same pipeline, so a teammate can repro the same install in CI or over
  SSH.
- **Network-friendly.** Defaults to mainland-China mirrors (npmmirror, Gitee)
  so first-time installs don't stall behind a slow registry.

## System requirements

| OS | Version | Disk | Notes |
| --- | --- | --- | --- |
| **macOS** | 11 Big Sur or newer | ~3 GB free | Apple Silicon & Intel both supported |
| **Windows** | 10 (1903+) / 11 | ~5 GB free | Requires WSL 2 (installer sets it up on first run) |
| **Linux** | Ubuntu 20.04+ / Debian 11+ | ~3 GB free | Other distros likely work; only Ubuntu/Debian are smoke-tested |

A working internet connection is required during install. Subsequent runs of
the installed agents work offline (apart from the model API calls those
agents themselves make).

## Privacy & what it does to your system

We think you should know exactly what an installer does before you double-click
it. Here is everything Claw Installer touches:

**Files it writes**

- `~/.openclaw/` — OpenClaw workspace and config (`openclaw.json`,
  containing your gateway port and a randomly-generated 32-byte auth token)
- `~/.hermes/` — Hermes data directory, including a shallow clone of
  `hermes-agent` under `~/.hermes/hermes-agent/`
- `~/.local/bin/hermes` — Hermes CLI shim
- `~/.npmrc` — a managed block (marked with sentinels) that points npm/pnpm
  at `registry.npmmirror.com`. Your other `.npmrc` settings are left alone.
- `~/.bashrc` / `~/.zshrc` — a managed block adding `fnm` and the relevant
  binaries to `PATH`. Marked with sentinels so it can be removed cleanly.
- `~/.claw-installer/manifest.tsv` — a tab-separated record of every change
  we made (used by the uninstaller)

**Programs it downloads**

- OpenClaw from `registry.npmmirror.com` (npm mirror — overridable via
  `INSTALLER_NPM_REGISTRY`)
- Hermes from `https://gitee.com/cylingo-group/hermes-agent` (shallow HTTPS
  clone)
- `fnm`, Node, Python 3.11, and `uv` from their official upstream channels
  (GitHub Releases / `astral.sh`)
- Optionally Playwright + Chromium (skip with `INSTALLER_HERMES_SKIP_BROWSER=1`)

**Background services it registers**

- A user-level launchd (macOS) / systemd (Linux) service for the OpenClaw
  gateway, listening on `127.0.0.1:18789` by default (loopback only —
  not exposed to your network)
- A launchd / systemd unit definition for Hermes (registered but not started;
  you start it from the GUI after configuring credentials)

**What it does NOT do**

- No telemetry. The installer does not phone home, does not record analytics,
  does not send any data about you, your machine, or your usage anywhere.
  The only outbound traffic is the package downloads listed above.
- No root / admin install paths. Everything lives under your home directory;
  `sudo` is only requested on Linux for the one `apt install` step that
  pulls in system utilities, and only if those utilities are missing.
- No silent updates. Re-running the installer is the only way new versions
  land on your machine.

**Removing it cleanly**

```bash
./shell/uninstall.sh             # reverses what we installed; --dry-run to preview
./shell/agents/openclaw/uninstall.sh    # or remove a single agent
```

The uninstaller reads `~/.claw-installer/manifest.tsv` and skips anything
marked `preexisting` — i.e. it won't remove a directory or package you
already had.

## FAQ

**Will it touch my existing Node or Python installs?**
No. We install Node via `fnm` into its own user-level prefix and Python 3.11
via `uv` — neither modifies your system Node or Python. If `fnm` / `uv` are
already on your `PATH`, we reuse them.

**Do I need to run it as root / `sudo`?**
On macOS and Windows, no. On Linux we'll prompt for `sudo` once if system
utilities (`curl`, `git`, `ripgrep`, `ffmpeg`, `build-essential`) are
missing — that's the only privileged step.

**Why does Windows need WSL?**
OpenClaw and Hermes are built and tested against POSIX environments.
Running them inside WSL 2 keeps Windows users on the same code path as
Linux users, which means fewer Windows-specific surprises. The installer
sets up WSL 2 + Ubuntu on first run if you don't have it.

**Can I uninstall it cleanly?**
Yes. `./shell/uninstall.sh` reverses every change recorded in the manifest
and leaves preexisting files / packages alone. Run with `--dry-run` first
to see what it would do.

**Does it auto-update?**
No. Re-launch the latest installer (or re-run `./shell/install.sh`) when you
want to update. Re-runs are idempotent — already-installed components are
detected and skipped.

**What if I'm behind a corporate firewall or proxy?**
The installer respects the standard `HTTP_PROXY` / `HTTPS_PROXY` /
`NO_PROXY` env vars. If your network blocks npmmirror or Gitee, override
them: `INSTALLER_NPM_REGISTRY=<your-mirror>` and
`INSTALLER_HERMES_INSTALL_URL=<your-mirror>`.

**Can I install just one of the two agents?**
Yes. In the GUI, deselect the one you don't want. From the CLI:
`INSTALLER_AGENTS=openclaw ./shell/install.sh` (or `hermes`).

**Where does my OpenClaw gateway token live, and is it exposed to my LAN?**
The 32-byte token is generated locally and stored in `~/.openclaw/openclaw.json`.
The gateway binds to `127.0.0.1:18789` by default — loopback only, not
reachable from your LAN. Override with `INSTALLER_GATEWAY_BIND`.

## Need help?

- **Found a bug or have a feature request?** [Open a GitHub issue](https://github.com/cylingo-group/claw-installer/issues) —
  include your OS, the version of the installer, and the line on screen
  when things went wrong.
- **Looking for the product?** Visit [bubbolink.com](https://bubbolink.com).
- **Want to chat with us?** <!-- TODO: Discord / Feishu / WeChat invite links -->

## Built with

[Tauri](https://tauri.app) (Rust + TypeScript) on the desktop side, plain
Bash on the installer side. Apache-2.0 licensed and proudly built by
[Cylingo Group](https://bubbolink.com).

<details>
<summary><strong>Build from source</strong> (for contributors)</summary>

Prerequisites:

- [pnpm](https://pnpm.io) ≥ 9
- [Rust](https://rustup.rs) stable toolchain
- For **macOS universal builds**: `rustup target add x86_64-apple-darwin`
- For **Windows cross-compile**: `cargo install cargo-xwin`
- For **Linux builds from macOS**: a running Docker Desktop

Build:

```bash
make build-mac        # universal .app + .dmg → dist/macos/
make build-linux      # .deb + .AppImage → dist/linux/ (via Docker, native arch)
make build-windows    # claw-installer.exe + shell/ → dist/windows/*.zip
make build-all        # all three, sequentially
```

> `make build-linux` produces artifacts matching the Docker container's
> native arch — arm64 on Apple Silicon hosts, amd64 on Intel hosts. To
> cross-build, set `LINUX_PLATFORM=linux/amd64` (slow under qemu) or
> `LINUX_PLATFORM=linux/arm64`.

Run during development:

```bash
make dev              # Tauri dev mode — live reload + Rust
make frontend         # browser stub mode — no Rust, no agent IPC
```

The installer's internals (shell-script layering, manifest format,
GUI ↔ shell protocol, `INSTALLER_*` env vars, two-stream logging) are
documented separately — see `docs/architecture.md` (TODO) or read
`shell/install.sh` and `shell/lib/common.sh` as the source of truth.

</details>

## Contributing

PRs welcome. For anything beyond a small fix, please open an issue first so
we can talk through the approach. Architecture notes will land in
`docs/architecture.md`.

## License

[Apache License 2.0](./LICENSE).
