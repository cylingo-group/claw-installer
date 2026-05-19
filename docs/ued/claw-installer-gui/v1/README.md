# UED Visual Spec: claw-installer-gui

- **Created**: 2026-05-18T17:21:03.648Z
- **Snapshot of**: docs/ued/claw-installer-gui/draft

## Style decision

| Dimension     | Choice              |
|---------------|---------------------|
| Locales       | `en, zh-Hans` (primary: `zh-Hans`) |
| Layout        | `dashboard-sidebar`        |
| Palette       | `graphite`       |
| Typography    | `neutral-modern`    |
| Visual style  | `minimal`   |

Committed: 2026-05-18T13:21:54.942Z

## Inspect history

0 inspect events captured during iteration (see `decisions/inspect-events.jsonl`).

## Brief

# claw-installer GUI — Brief

## What this surface is
Tauri-based desktop GUI that drives the claw-installer CLI (`installer/install.sh`
on macOS/Linux, `windows/bootstrap.ps1` on Windows). Sits between an end user
and two agents — **openclaw** and **hermes** — managing their full lifecycle.

The GUI never writes the manifest. It sets `INSTALLER_*` env vars and spawns
the shell entry points; `uninstall.sh` owns rollback.

## Primary jobs
1. **First-run install** — pick agents (default: both), kick off install, show
   live progress + result. Should feel "click button, see it work, done".
2. **Ongoing service control** — start/stop/restart the openclaw gateway
   daemon, see whether it's running, swap config (gateway port, registry
   mirror, workspace dir).
3. **Repair / reinstall / uninstall** — force-reinstall, rerun on a fresh
   host, cleanly uninstall via the manifest.
4. **Logs** — view recent `install-<UTC>.log` files when something goes wrong.

## Audience
**Non-technical end users** (designers, PMs trying out the agents) are the
primary persona. Developers should also be comfortable here — they just won't
need this GUI for most things. Defaults must be sensible; "advanced settings"
should be tucked behind a single fold, not splashed across the surface.

Terminology: avoid `daemon`, `corepack`, `fnm`, `pnpm`. Prefer "background
service", "agent", "ready".

## Platform
Tauri desktop app. Three OS targets — macOS, Linux, Windows. Window size
roughly 1024×720 default, resizable down to ~800×560. **Desktop-first**;
no responsive mobile needed.

## Brand / Vibe
- **Friendly, guided** — Raycast / Arc / Linear-onboarding feel. Warm accent,
  generous spacing, soft shadows, smooth motion. Not corporate, not brutalist,
  not data-dense.
- Existing claw / openclaw brand assets: none surfaced yet — invent a coherent
  theme that suits a "developer tooling, but approachable" product.
- Dark mode: must work; users will run this alongside a terminal. Light is
  default.

## Information architecture
Persistent **Dashboard** model (not a wizard). Probable shape:
- Left: agent list — openclaw, hermes — each with a status pill
  (Not installed / Installing… / Ready / Stopped / Error).
- Right: detail pane per selected agent — install button, configure, restart,
  uninstall, view logs.
- Top-level: a global "install everything" CTA when nothing is installed yet
  (first-run shortcut so the dashboard isn't intimidating empty).

## Constraints
- Status pills + CTAs must be glanceable without scrolling.
- A long-running install must not block other interactions; logs should be
  inspectable while installing.
- Errors must offer a clear next action ("View log", "Retry", "Reinstall").
- A11y: WCAG AA contrast minimum.

## Locales
Default: `en + zh-Hans`, primary `zh-Hans` (most early users are in CN
context, but English copy must coexist for the OSS audience).

## Out of scope (for this design pass)
- Agent functionality itself (chatting with openclaw, hermes tasks). The GUI
  only manages their installation and runtime.
- Account / login / sync.
- In-GUI editing of arbitrary `openclaw config` keys — only the headline ones
  (gateway port, registry mirror, workspace).

## Run this snapshot

```bash
cd docs/ued/claw-installer-gui/v1
pnpm install
pnpm dev
```

## Files

- `src/` — implementation source
- `decisions/` — brief, style decision, inspect event log
- `index.html`, `vite.config.ts`, `tsconfig*.json`, `package.json`, `components.json` — workspace config
