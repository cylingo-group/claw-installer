# Change Proposal: Claw Installer GUI v1

**Slug**: `claw-installer-gui-v1`
**Status**: Draft
**Author**: Planner agent
**Date**: 2026-05-19

---

## Problem Statement

Non-technical users (designers, PMs, early adopters) have no accessible way to install OpenClaw and Hermes agents. The only path today is a raw terminal command — `./installer/install.sh` — which produces hundreds of lines of shell output, requires the user to own WSL configuration on Windows, and gives no guidance when something fails. The goal is a one-click desktop installer GUI that hides all shell complexity behind a translated progress bar, surfaces only actionable state transitions (installed / error / ready), and ships as a native `.dmg` / `.deb` / `.AppImage` / `.msi` depending on platform.

---

## Proposed Solution

Scaffold a `gui/` Tauri 2.0 application beside the existing `installer/` tree. The frontend is a direct port of the locked v2 prototype (`docs/ued/claw-installer-gui/v2/src/`) with targeted surgery to replace the `setInterval`-tick stub with real Tauri IPC. The Rust backend wraps the existing shell entry points via `tauri-plugin-shell`, streams structured events through a typed `Channel<InstallerEvent>`, and reads install state from the manifest TSV on startup. No changes are made to any existing installer shell scripts except `installer/windows/bootstrap.ps1`, which receives a `-Uninstall` switch for Windows uninstall support.

The surface the user sees is identical to the v2 prototype: a 280 px sidebar with two `AgentCard` components, a "一键安装全部" CTA at the bottom, a slide-in `SettingsPanel` (placeholder in v1), and an `UninstallDialog`. The only visual additions beyond the prototype are:

1. A `currentStep` / `currentStepDetail` text line beneath the indeterminate progress bar — replacing the `logTail` stream UI which is dropped entirely.
2. A Windows-only `HostStatusBanner` rendered above the agent list when `hostStatus` is `needs-wsl-install` or `needs-ubuntu-firstrun`.

---

## Scope & Boundaries

### In Scope (v1)

- `gui/` Tauri 2.0 app scaffolded fresh, frontend ported from v2 prototype.
- Install one or both agents via existing `install.sh`, `install-openclaw.sh`, `install-hermes.sh`.
- Uninstall via `uninstall.sh --yes` (Unix) and a new `bootstrap.ps1 -Uninstall` switch (Windows).
- Manifest-driven startup status read (no spinner on relaunch after successful install).
- `SettingsPanel` exists as a placeholder slide-in with "配置项即将开放" copy (already in v2).
- Windows preflight states `needs-wsl-install` (exit 3) and `needs-ubuntu-firstrun` (exit 2) surfaced as banners with copy-the-command CTA and Retry button.
- Stop / Start / Restart buttons rendered but wired to no-op handlers in v1 (visual contract exists; backend hooks land in v1.1).
- Cancel during install (kills the child process, sets agent to `error`).
- Error display with Retry CTA (idempotent re-run is the recovery path).
- pnpm workspace: root `pnpm-workspace.yaml` lists `gui/`.
- Platform packaging: `.dmg + .app` (macOS), `.deb + .AppImage` (Linux), `.msi` (Windows).

### Explicitly Out of Scope (v1)

- Per-agent runtime configuration (Channel, model provider, gateway token editing). The SettingsPanel is a placeholder.
- Service control logic (start/stop/restart actually invoking the daemon). No-op in v1.
- Custom uninstall flags (`--purge-workspace`, `--purge-hermes-home`). GUI always runs `uninstall.sh --yes` with no purge flags.
- Localization beyond zh-Hans + English (copy already in v2). No i18n framework added.
- Auto-update. Tauri updater plugin not included.
- Error state persistence across launches. Non-goal: documented explicitly; idempotent re-run is sufficient.
- `AgentDetail` right-pane view from the v2 component tree. The v2 `App.tsx` already renders only the sidebar (280 px window), not the split-pane detail view. This proposal preserves that layout.
- `LogDrawer.tsx` — dropped entirely from the ported tree, along with its store fields.
- Per-step percentage progress. The indeterminate bar ships.

---

## A. Frontend Deliverables (`gui/src/`)

### A1. Scaffold and Port

Scaffold with:

```
pnpm create tauri-app gui --template react-ts
```

Then replace the scaffolded `src/`, `index.html`, `vite.config.ts`, `tsconfig.json`, `tsconfig.app.json`, `tsconfig.node.json`, `components.json` with the equivalents from `docs/ued/claw-installer-gui/v2/`. Remove the `ued-framework` devDependency from `package.json` (it is a local prototype tooling dependency not needed in production). Keep all other deps from v2's `package.json`.

Add to `gui/package.json`:

```json
"packageManager": "pnpm@9.x",
"engines": { "node": ">=20" }
```

The `vite.config.ts` in `gui/` drops the `uedFramework` plugin and retains the `@/` alias and Tailwind v4 plugin:

```ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { "@": path.resolve(__dirname, "./src") },
  },
  // Tauri dev server: use port 5173, do not open browser
  server: { port: 5173, strictPort: true },
  // Required for Tauri: prevent Vite from obscuring Rust errors
  clearScreen: false,
  envPrefix: ["VITE_", "TAURI_"],
  build: {
    target: ["es2021", "chrome105", "safari13"],
    minify: !process.env.TAURI_DEBUG ? "esbuild" : false,
    sourcemap: !!process.env.TAURI_DEBUG,
  },
});
```

### A2. Files Dropped vs. Added

**Dropped from v2 tree (do not port):**

- `src/components/installer/LogDrawer.tsx` — not rendered, not ported.
- `src/stub/log-lines.ts` — replaced by `src/stub/sample.ts` (see A5 stub mode).
- `src/store/app-store.ts` — unused scaffolding placeholder, drop.

**Added:**

- `src/api/installer.ts` — thin wrapper around `invoke` + `Channel` (see A3).
- `src/components/installer/HostStatusBanner.tsx` — Windows preflight banner (see A6).
- `src/stub/sample.ts` — updated stub with step-event simulation (see A5).

### A3. `src/api/installer.ts`

This module is the only place in the frontend that touches Tauri IPC. All `invoke` calls and `Channel` construction are isolated here.

```ts
import { invoke } from "@tauri-apps/api/core";
import { Channel } from "@tauri-apps/api/core";
import type { InstallerEvent } from "@/store/installer-store";

export async function readInstallerState(): Promise<InstallerStatePayload> {
  return invoke<InstallerStatePayload>("read_installer_state");
}

export async function readHostStatus(): Promise<HostStatusPayload> {
  return invoke<HostStatusPayload>("read_host_status");
}

export async function runInstaller(
  agents: string[],
  env: Record<string, string>,
  onEvent: (e: InstallerEvent) => void
): Promise<void> {
  const ch = new Channel<InstallerEvent>();
  ch.onmessage = onEvent;
  return invoke("run_installer", { agents, env, onEvent: ch });
}

export async function cancelInstaller(): Promise<void> {
  return invoke("cancel_installer");
}

export async function runUninstaller(
  agent: string,
  onEvent: (e: InstallerEvent) => void
): Promise<void> {
  const ch = new Channel<InstallerEvent>();
  ch.onmessage = onEvent;
  return invoke("run_uninstaller", { agent, onEvent: ch });
}

export interface InstallerStatePayload {
  openclaw: "installed" | "not-installed";
  hermes: "installed" | "not-installed";
}

export interface HostStatusPayload {
  status: "ok" | "needs-wsl-install" | "needs-ubuntu-firstrun";
  command?: string; // the copy-able command shown in the banner
}
```

When `__TAURI_INTERNALS__` is absent from `window` (i.e. browser / prototype mode), this module is shadowed by a stub implementation in `src/stub/sample.ts` — see A5.

### A4. Store Changes — `src/store/installer-store.ts`

The store is the largest change relative to the v2 prototype. The diff is specified field-by-field:

**Fields REMOVED:**

| Field | Reason |
|---|---|
| `logTail: LogLine[]` | Log lines are not surfaced in the UI |
| `logDrawerOpen: boolean` | LogDrawer dropped |
| `progress: number` (on `AgentState`) | Step tracking is now server-driven |

**Fields ADDED to `AgentState`:**

| Field | Type | Purpose |
|---|---|---|
| `currentStep` | `string \| null` | Chinese-translated name of the active install step |
| `currentStepDetail` | `string \| null` | Short phrase describing what is happening |

**Fields ADDED to top-level `State`:**

| Field | Type | Purpose |
|---|---|---|
| `hostStatus` | `HostStatus` | Windows preflight result; `"ok"` on non-Windows |
| `isBootstrapping` | `boolean` | True while `readInstallerState` + `readHostStatus` are in flight on startup |

**Type changes:**

`AgentStatus` gains two new variants for Windows preflight (these only apply to `hostStatus`, not per-agent status, but are declared near the agent status type for grouping):

```ts
export type HostStatus =
  | "ok"
  | "needs-wsl-install"
  | "needs-ubuntu-firstrun";
```

`AgentStatus` itself loses no variants; `installing` and `uninstalling` remain as-is.

**Actions REMOVED:**

| Action | Reason |
|---|---|
| `toggleLogDrawer` | LogDrawer dropped |

**Actions ADDED:**

| Action | Signature | Purpose |
|---|---|---|
| `setCurrentStep` | `(id: AgentId, step: string \| null, detail: string \| null) => void` | Called by Channel handler when `StepChanged` event arrives |
| `setAgentStatus` | `(id: AgentId, status: AgentStatus, meta?: { version?: string; installedAt?: string; errorMessage?: string }) => void` | Called by Channel handler for `StatusChanged` events |
| `refreshHostStatus` | `() => Promise<void>` | Calls `readHostStatus()` and updates `hostStatus`; used by Retry button in `HostStatusBanner` |
| `bootstrap` | `() => Promise<void>` | Called from `useEffect` in `App.tsx` on mount; reads manifest + host status; sets `isBootstrapping = false` when done |

**`startInstall` action — new behavior:**

The `setInterval` tick loop is removed. The action now:
1. Sets the queue agents to `status: "installing"`, `currentStep: null`, `currentStepDetail: null`.
2. Builds the `env` record from `settings` (see mapping in C2).
3. Calls `api/installer.ts#runInstaller(agents, env, handleEvent)`.
4. `handleEvent` dispatches to store actions based on `InstallerEvent` variant.

**`cancelInstall` action — new behavior:**

Calls `api/installer.ts#cancelInstaller()` then sets queued agents to `status: "error"`, `errorMessage: "已被用户中止"`.

**`confirmUninstall` action — new behavior:**

1. Sets `agents[id].status = "uninstalling"`, `uninstallTarget = null`.
2. Calls `api/installer.ts#runUninstaller(id, handleEvent)`.
3. On `Finished` event with `success: true`: resets agent to `initialAgents[id]` (not-installed state).
4. On `Finished` event with `success: false`: sets `status: "error"`, `errorMessage: <message>`.
5. The abort/back affordance in `UninstallDialog` is hidden while `status === "uninstalling"` — enforced in the dialog component, not the store.

**Stub mode wiring:**

The store's `startInstall`, `cancelInstall`, `confirmUninstall`, `bootstrap` actions check `IS_TAURI_ENV` (a module-level boolean: `typeof window !== "undefined" && "__TAURI_INTERNALS__" in window`). When false, they call the stub implementations from `src/stub/sample.ts` instead of `src/api/installer.ts`.

### A5. Stub Mode (`src/stub/sample.ts`)

Stub implements the same event sequence as the real backend, using `setTimeout`-based simulation. This allows the team to run `pnpm dev` in a browser and iterate on the UI without a Rust build.

```ts
// Stub InstallerEvent emitter for browser-mode development.
// Toggle: when __TAURI_INTERNALS__ is NOT on window, the store uses these.

const STEP_SEQUENCE_OPENCLAW = [
  { key: "base-deps",  label: "正在安装系统依赖…",     detail: "curl / git / openssl" },
  { key: "fnm",        label: "正在安装 fnm…",          detail: "Node 版本管理器" },
  { key: "node",       label: "正在配置 Node 运行时…",  detail: "Node v24" },
  { key: "pnpm",       label: "正在准备 pnpm…",         detail: "via corepack" },
  { key: "npmrc",      label: "正在写入镜像源…",         detail: "~/.npmrc" },
  { key: "openclaw",   label: "正在安装 OpenClaw…",     detail: "pnpm add -g openclaw" },
  { key: "done",       label: "✓ 完成",                  detail: "" },
];

const STEP_SEQUENCE_HERMES = [
  { key: "base-deps",     label: "正在安装系统依赖…",        detail: "" },
  { key: "system-tools",  label: "正在安装系统工具…",        detail: "ripgrep / ffmpeg" },
  { key: "hermes",        label: "正在安装 Hermes…",         detail: "克隆代码仓库" },
  { key: "done",          label: "✓ 完成",                    detail: "" },
];

export function runStubInstaller(
  agents: string[],
  onEvent: (e: InstallerEvent) => void
): () => void { /* ... returns cancel fn */ }
```

The stub is a peer module, not imported by production code paths (tree-shaken in prod builds via the `IS_TAURI_ENV` gate in the store).

### A6. `HostStatusBanner.tsx`

Rendered in `Sidebar.tsx` above the agent list when `hostStatus !== "ok"`. Hidden on non-Windows at runtime because `read_host_status` always returns `{ status: "ok" }` on non-Windows platforms.

```tsx
// Two banner variants:
// needs-wsl-install  → "需要安装 WSL" + copy button for `wsl --install`
// needs-ubuntu-firstrun → "需要完成 Ubuntu 初始化" + copy button for distro command
```

The Retry button calls `useInstaller(s => s.refreshHostStatus)` and re-probes.

### A7. `UninstallDialog.tsx` Change

During `uninstalling` status, the "取消" and "确认卸载" buttons are replaced with a non-interactive progress indicator (the same `ProgressBar` used in `AgentCard.tsx` with `tone="danger"`). No abort/back affordance is exposed. Copy: "卸载中，请稍候…".

---

## B. Rust Backend Deliverables (`gui/src-tauri/`)

### B1. Dependencies (`Cargo.toml`)

```toml
[dependencies]
tauri = { version = "2", features = ["macos-private-api"] }
tauri-plugin-shell = "2"
tauri-plugin-fs = "2"
tauri-plugin-os = "2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }

[build-dependencies]
tauri-build = { version = "2", features = [] }
```

### B2. State Types

```rust
// src-tauri/src/types.rs
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum InstallerEvent {
    /// A new install step has become active.
    StepChanged {
        key: String,   // e.g. "base-deps"
        label: String, // zh-Hans: e.g. "正在安装系统依赖…"
        detail: String,
    },
    /// An agent's status changed (installed, error, etc.).
    StatusChanged {
        agent: String,  // "openclaw" | "hermes"
        status: String, // "installing" | "ready" | "error" | "uninstalling" | "not-installed"
        message: Option<String>,
    },
    /// Install/uninstall process completed.
    Finished {
        success: bool,
        message: Option<String>,
    },
    /// Raw log line (written to disk; not surfaced in UI).
    LogLine {
        line: String,
    },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct InstallerStatePayload {
    pub openclaw: String, // "installed" | "not-installed"
    pub hermes: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct HostStatusPayload {
    pub status: String, // "ok" | "needs-wsl-install" | "needs-ubuntu-firstrun"
    pub command: Option<String>,
}
```

### B3. Step → Label Mapping (Rust-side)

The mapping lives exclusively in Rust. The frontend never parses log lines.

```rust
// src-tauri/src/steps.rs
pub fn step_label(key: &str) -> (&'static str, &'static str) {
    // Returns (label_zh, detail_zh)
    match key {
        "base-deps"    => ("正在安装系统依赖…",    "curl / git / openssl / unzip"),
        "system-tools" => ("正在安装系统工具…",    "ripgrep / ffmpeg / build 工具链"),
        "fnm"          => ("正在安装 fnm…",         "Node 版本管理器"),
        "node"         => ("正在配置 Node 运行时…", "Node v24 via fnm"),
        "hermes-node"  => ("正在配置 Hermes Node…", "Node v22 for Hermes"),
        "uv"           => ("正在安装 uv…",           "Python 包管理器"),
        "python"       => ("正在安装 Python…",       "Python 3.11 via uv"),
        "pnpm"         => ("正在准备 pnpm…",         "via corepack"),
        "npmrc"        => ("正在写入镜像源…",        "~/.npmrc"),
        "shell-rc"     => ("正在配置 Shell 环境…",   "~/.bashrc / ~/.zshrc"),
        "openclaw"     => ("正在安装 OpenClaw…",     "pnpm add -g openclaw"),
        "hermes"       => ("正在安装 Hermes…",       "克隆代码仓库 + 上游安装脚本"),
        "done"         => ("✓ 完成",                 ""),
        other          => (other, ""),
    }
}

/// Parse a stdout line from the installer. Returns Some(step_key) if the line
/// matches the step-header pattern `==> <key>:`.
pub fn parse_step_line(line: &str) -> Option<&str> {
    let trimmed = line.trim();
    if let Some(rest) = trimmed.strip_prefix("==> ") {
        if let Some(colon_pos) = rest.find(':') {
            return Some(&rest[..colon_pos]);
        }
    }
    None
}
```

The regex `^==> (\S+?):` is the documented pattern in the installer scripts (confirmed in `stub/log-lines.ts` which uses exactly `"==> base-deps: ..."`, `"==> fnm: ..."`, etc.).

### B4. Global State

```rust
// src-tauri/src/lib.rs
use std::sync::Arc;
use tokio::sync::Mutex;
use tauri_plugin_shell::process::CommandChild;

pub struct AppState {
    pub child: Arc<Mutex<Option<CommandChild>>>,
}
```

Registered with `tauri::Builder::manage(AppState { child: Arc::new(Mutex::new(None)) })`.

### B5. Commands

#### `read_installer_state`

Reads `~/.claw-installer/manifest.tsv` (path from `CLAW_MANIFEST` env or the default). Parses TSV to determine install status per agent.

**Manifest parsing logic:**
- Split each non-comment line on `\t`. Column order: `timestamp \t action \t target \t status \t note`.
- For OpenClaw: look for a row where `action == "pnpm_global_pkg"` AND `target == "openclaw"`. Status `"installed"` or `"preexisting"` both map to `"installed"`.
- For Hermes: look for a row where `action == "hermes_bin"`. Status `"installed"` or `"preexisting"` both map to `"installed"`.
- If the manifest file does not exist: return `not-installed` for both.

```rust
#[tauri::command]
async fn read_installer_state(app: tauri::AppHandle) -> Result<InstallerStatePayload, String> {
    let manifest_path = manifest_path(&app);
    // ... TSV parsing as above
}
```

**Dev override**: if `INSTALLER_REPO_DIR` is set, the manifest path resolves relative to it.

#### `read_host_status`

On non-Windows: always returns `{ status: "ok", command: None }`.

On Windows:

```rust
#[cfg(target_os = "windows")]
#[tauri::command]
async fn read_host_status(app: tauri::AppHandle) -> Result<HostStatusPayload, String> {
    // Run the bootstrap.ps1 preflight probe.
    // We add a -Preflight switch to bootstrap.ps1 that runs only steps 1–3
    // (Windows build check, WSL check, distro check) and exits with the
    // same exit codes as the full run (0 = ok, 2 = needs ubuntu firstrun,
    // 3 = needs wsl install).
    let ps_path = resolve_installer_path(&app, "windows/bootstrap.ps1");
    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass",
               "-File", &ps_path.to_string_lossy(),
               "-Preflight"])
        .output()
        .await
        .map_err(|e| e.to_string())?;
    match output.status.code() {
        Some(0) => Ok(HostStatusPayload { status: "ok".into(), command: None }),
        Some(2) => Ok(HostStatusPayload {
            status: "needs-ubuntu-firstrun".into(),
            command: Some("wsl --install -d Ubuntu".into()),
        }),
        Some(3) | _ => Ok(HostStatusPayload {
            status: "needs-wsl-install".into(),
            command: Some("wsl --install".into()),
        }),
    }
}

#[cfg(not(target_os = "windows"))]
#[tauri::command]
async fn read_host_status() -> Result<HostStatusPayload, String> {
    Ok(HostStatusPayload { status: "ok".into(), command: None })
}
```

#### `run_installer`

```rust
#[tauri::command]
async fn run_installer(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    agents: Vec<String>,         // e.g. ["openclaw", "hermes"]
    env: std::collections::HashMap<String, String>, // INSTALLER_* vars from settings
    on_event: tauri::ipc::Channel<InstallerEvent>,
) -> Result<(), String> {
    use tauri_plugin_shell::ShellExt;

    let script_path = resolve_installer_script(&app, &agents);
    // On Windows: powershell.exe -NoProfile -ExecutionPolicy Bypass -File <bootstrap.ps1>
    // On Unix: bash <install.sh> or <install-openclaw.sh> or <install-hermes.sh>
    let mut cmd = build_command(&app, &agents);

    // Forward INSTALLER_* env vars
    for (k, v) in &env {
        cmd = cmd.env(k, v);
    }
    // Always pass --yes equivalent; the GUI never prompts
    // (uninstall.sh uses --yes; install.sh has no interactive prompts)

    let (mut rx, child) = cmd.spawn().map_err(|e| e.to_string())?;
    *state.child.lock().await = Some(child);

    let mut last_step: Option<String> = None;

    while let Some(event) = rx.recv().await {
        use tauri_plugin_shell::process::CommandEvent;
        match event {
            CommandEvent::Stdout(line) | CommandEvent::Stderr(line) => {
                let line_str = String::from_utf8_lossy(&line).to_string();

                // Always emit raw log line (for disk log; not rendered in UI)
                on_event.send(InstallerEvent::LogLine { line: line_str.clone() }).ok();

                // Check for step header
                if let Some(step_key) = parse_step_line(&line_str) {
                    if last_step.as_deref() != Some(step_key) {
                        last_step = Some(step_key.to_string());
                        let (label, detail) = step_label(step_key);
                        on_event.send(InstallerEvent::StepChanged {
                            key: step_key.to_string(),
                            label: label.to_string(),
                            detail: detail.to_string(),
                        }).ok();
                    }
                }
            }
            CommandEvent::Terminated(status) => {
                *state.child.lock().await = None;
                let success = status.code == Some(0);
                if success {
                    on_event.send(InstallerEvent::StepChanged {
                        key: "done".into(),
                        label: "✓ 完成".into(),
                        detail: "".into(),
                    }).ok();
                }
                on_event.send(InstallerEvent::Finished {
                    success,
                    message: if !success {
                        Some(format!("脚本退出码 {}", status.code.unwrap_or(-1)))
                    } else { None },
                }).ok();
                break;
            }
            CommandEvent::Error(e) => {
                *state.child.lock().await = None;
                on_event.send(InstallerEvent::Finished {
                    success: false,
                    message: Some(e),
                }).ok();
                break;
            }
            _ => {}
        }
    }
    Ok(())
}
```

**Script selection logic** (`build_command`):

```
agents = ["openclaw"]       → bash installer/install-openclaw.sh
agents = ["hermes"]         → bash installer/install-hermes.sh
agents = ["openclaw","hermes"] or ["hermes","openclaw"]
                            → bash installer/install.sh
                              (top-level script runs both; INSTALLER_AGENTS not needed)
Windows (any agents)        → powershell.exe -NoProfile -ExecutionPolicy Bypass
                              -File installer\windows\bootstrap.ps1
                              (bootstrap.ps1 always runs install.sh internally)
```

Resource path resolution:

```rust
fn resolve_installer_path(app: &tauri::AppHandle, rel: &str) -> PathBuf {
    if let Ok(repo_dir) = std::env::var("INSTALLER_REPO_DIR") {
        return PathBuf::from(repo_dir).join(rel);
    }
    app.path().resource_dir()
        .expect("resource_dir unavailable")
        .join("installer")
        .join(rel)
}
```

#### `cancel_installer`

```rust
#[tauri::command]
async fn cancel_installer(state: tauri::State<'_, AppState>) -> Result<(), String> {
    if let Some(child) = state.child.lock().await.take() {
        child.kill().map_err(|e| e.to_string())?;
    }
    Ok(())
}
```

#### `run_uninstaller`

```rust
#[tauri::command]
async fn run_uninstaller(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    agent: String,  // "openclaw" | "hermes" — for display only; uninstall.sh reads manifest
    on_event: tauri::ipc::Channel<InstallerEvent>,
) -> Result<(), String> {
    // Unix: bash installer/uninstall.sh --yes
    // Windows: powershell.exe -NoProfile -ExecutionPolicy Bypass -File
    //          installer\windows\bootstrap.ps1 -Uninstall
    // Agent-specific uninstall is not supported in v1; the GUI only calls this
    // after the user confirms a single agent uninstall, but uninstall.sh
    // reverses all manifest entries. This is acceptable for v1 because
    // agents are typically uninstalled one at a time when only one is installed.
    //
    // NOTE: cancel_installer is intentionally NOT wired to the UI during uninstall.
    //       The Rust command exists but the frontend does not call it during uninstall.
    let mut cmd = build_uninstall_command(&app);
    let (mut rx, child) = cmd.spawn().map_err(|e| e.to_string())?;
    *state.child.lock().await = Some(child);
    // Event loop identical to run_installer, step parsing applies
    // ...
    Ok(())
}
```

### B6. Tauri Configuration (`tauri.conf.json`)

```json
{
  "productName": "Claw Installer",
  "version": "0.1.0",
  "identifier": "com.claw-installer.gui",
  "build": {
    "beforeDevCommand": "pnpm dev",
    "beforeBuildCommand": "pnpm build",
    "devUrl": "http://localhost:5173",
    "frontendDist": "../dist"
  },
  "app": {
    "windows": [{
      "title": "Claw Installer",
      "width": 280,
      "height": 600,
      "minWidth": 280,
      "minHeight": 480,
      "resizable": true,
      "center": true
    }]
  },
  "bundle": {
    "active": true,
    "targets": "all",
    "resources": ["../installer/**/*"]
  }
}
```

### B7. Capabilities

**`gui/src-tauri/capabilities/installer-unix.json`:**

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "installer-unix",
  "description": "Unix installer permissions",
  "platforms": ["macOS", "linux"],
  "windows": ["main"],
  "permissions": [
    {
      "identifier": "shell:allow-execute",
      "allow": [
        {
          "name": "bash",
          "cmd": "bash",
          "args": { "validator": ".*" }
        }
      ]
    },
    {
      "identifier": "fs:allow-read-text-file",
      "allow": [
        { "path": "$HOME/.claw-installer/manifest.tsv" },
        { "path": "$HOME/.claw-installer/install-*.log" }
      ]
    },
    "os:allow-platform"
  ]
}
```

**`gui/src-tauri/capabilities/installer-windows.json`:**

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "installer-windows",
  "description": "Windows installer permissions",
  "platforms": ["windows"],
  "windows": ["main"],
  "permissions": [
    {
      "identifier": "shell:allow-execute",
      "allow": [
        {
          "name": "powershell",
          "cmd": "powershell.exe",
          "args": { "validator": ".*" }
        },
        {
          "name": "wsl",
          "cmd": "wsl.exe",
          "args": { "validator": ".*" }
        }
      ]
    },
    {
      "identifier": "fs:allow-read-text-file",
      "allow": [
        {
          "path": "\\\\wsl.localhost\\Ubuntu\\home\\*\\.claw-installer\\manifest.tsv"
        }
      ]
    },
    "os:allow-platform"
  ]
}
```

---

## C. Installer Script Changes (`installer/`)

### C1. `installer/windows/bootstrap.ps1` — Add `-Uninstall` Switch and `-Preflight` Switch

Two new switches are added to the existing `param()` block. No existing behavior is changed.

**`-Preflight` switch**: Runs only the Windows/WSL preflight checks (steps 1–3: `Test-WindowsBuild`, `Test-WslAvailable`, `Ensure-Distro`) and exits with the appropriate exit code (0 / 2 / 3). Does not run `Ensure-Systemd`, `Copy-RepoIntoWsl`, or `Invoke-BashInstaller`. This is the probe used by `read_host_status`.

**`-Uninstall` switch**: After the standard preflight (steps 1–3) succeeds, ships the installer files into WSL and runs `uninstall.sh --yes` inside WSL instead of `install.sh`. All `INSTALLER_*` env var forwarding (lines ~200–210 of the existing script) is reused. The agent-specific uninstall is not supported via PS in v1 (WSL uninstall.sh always reverses all manifest entries).

Pseudocode for the `main` block change:

```powershell
param(
  [string]$Distro   = ...,
  [string]$RepoDir  = ...,
  [switch]$DryRun,
  [switch]$Preflight,   # NEW
  [switch]$Uninstall    # NEW
)

# ... existing functions unchanged ...

# ---- main -----------------------------------------------------------------
Write-Host ""
Write-Step "claw-installer Windows bootstrap (distro=$Distro, repo=$RepoDir)"
Write-Host ""

Test-WindowsBuild
Test-WslAvailable
Ensure-Wsl2Default
Ensure-Distro -Name $Distro

$ver = Get-DistroVersion -Name $Distro
if ($ver -ne 2) { ... exit 3 }

# NEW: -Preflight exits here with 0 — all checks passed.
if ($Preflight) {
  Write-Step "Preflight checks passed."
  exit 0
}

$null = Ensure-Systemd -Name $Distro
$destInWsl = Copy-RepoIntoWsl -Name $Distro -LocalPath $RepoDir

# NEW: -Uninstall runs uninstall.sh instead of install.sh.
if ($Uninstall) {
  $rc = Invoke-BashUninstaller -Name $Distro -DestDir $destInWsl
} else {
  $rc = Invoke-BashInstaller -Name $Distro -DestDir $destInWsl
}

# ... existing exit logic unchanged ...
```

New `Invoke-BashUninstaller` function:

```powershell
function Invoke-BashUninstaller {
  param([string]$Name, [string]$DestDir)
  # Forward INSTALLER_* vars the same way Invoke-BashInstaller does.
  $forward = @()
  Get-ChildItem env: | Where-Object { $_.Name -like 'INSTALLER_*' -and $_.Name -ne 'INSTALLER_REPO_DIR' -and $_.Name -ne 'INSTALLER_WSL_DISTRO' } | ForEach-Object {
    $v = $_.Value -replace "'", "'\''"
    $forward += ("export {0}='{1}'" -f $_.Name, $v)
  }
  $envBlock = $forward -join "`n"
  $script = @"
set -e
$envBlock
cd "$DestDir"
./uninstall.sh --yes
"@
  Write-Step "Running ./uninstall.sh --yes inside WSL distro '$Name'"
  if ($DryRun) { Write-Host "  [dry-run] wsl -d $Name -- bash -lc <run uninstaller>"; return 0 }
  & wsl.exe -d $Name -- bash -lc $script
  return $LASTEXITCODE
}
```

### C2. Settings → Env Var Mapping

The `InstallerSettings` from the store maps to `INSTALLER_*` vars as follows:

| Store field | Env var | Notes |
|---|---|---|
| `registryMirror` | `INSTALLER_NPM_REGISTRY` | Only set if non-empty and not default |
| `gatewayPort` | `INSTALLER_GATEWAY_PORT` | Only set if != 18789 |
| `gatewayBind` | `INSTALLER_GATEWAY_BIND` | Only set if != "loopback" |
| `serviceMode` | `INSTALLER_SERVICE_MODE` | Always forwarded |
| `workspace` | `INSTALLER_WORKSPACE` | Only set if non-empty |
| `skipBrowser` | `INSTALLER_HERMES_SKIP_BROWSER=1` | Set when true |
| `forceReinstall` | `INSTALLER_FORCE_REINSTALL=1` | Set when true |

The `agents` array determines which entry-point script is invoked (see B5 script selection).

---

## D. Build & Dev Affordances

### D1. Workspace

Root `pnpm-workspace.yaml` (create if absent):

```yaml
packages:
  - "gui"
```

Root `package.json` (create if absent):

```json
{
  "name": "claw-installer-workspace",
  "private": true,
  "scripts": {
    "dev:gui":   "pnpm --filter gui tauri dev",
    "build:gui": "pnpm --filter gui tauri build"
  }
}
```

### D2. Dev Server Configuration

Tauri's `devUrl` is `http://localhost:5173`. During `tauri dev`, the Rust backend hot-reloads on Rust file changes; Vite hot-reloads on TS/CSS changes. The Vite server must be running before `tauri dev` starts — the `beforeDevCommand` in `tauri.conf.json` is `pnpm dev` (Vite only), and Tauri starts the Vite server automatically.

### D3. Resource Path Seam

In production builds, the installer scripts live at `{resource_dir}/installer/**`. In development, set `INSTALLER_REPO_DIR=<absolute path to repo root>/installer` to point the Rust backend directly at the working copy:

```sh
INSTALLER_REPO_DIR=/Users/yourname/workspace/claw-installer/installer pnpm dev:gui
```

This env var is documented in `gui/README.md` (to be written by the developer agent). It is NOT checked into source; the developer sets it in their shell.

### D4. Stub Mode Toggle (Frontend)

The stub is active whenever `window.__TAURI_INTERNALS__` is absent — which is any browser-based dev session (`pnpm dev` without `tauri dev`). No feature flag is needed. To run the stub:

```sh
cd gui && pnpm dev
# Open http://localhost:5173 in a browser.
# All install/uninstall interactions use setTimeout-based simulation.
```

To run with the real Rust backend:

```sh
INSTALLER_REPO_DIR=.../installer pnpm dev:gui
```

---

## E. Project Layout

```
claw-installer/
├── installer/                          (unchanged except bootstrap.ps1)
│   └── windows/bootstrap.ps1          add -Uninstall and -Preflight switches
├── gui/                                NEW — Tauri 2.0 app
│   ├── package.json                    engines.packageManager = pnpm
│   ├── pnpm-lock.yaml
│   ├── index.html
│   ├── vite.config.ts                  no ued-framework plugin; Tauri config
│   ├── tsconfig.json
│   ├── tsconfig.app.json
│   ├── tsconfig.node.json
│   ├── components.json                 shadcn/ui registry config
│   ├── src/
│   │   ├── main.tsx
│   │   ├── App.tsx                     adds bootstrap() useEffect; HostStatusBanner
│   │   ├── api/
│   │   │   └── installer.ts            NEW — Tauri IPC wrapper
│   │   ├── components/
│   │   │   ├── installer/
│   │   │   │   ├── AgentCard.tsx       unchanged from v2
│   │   │   │   ├── AgentDetail.tsx     optional — not rendered in current App.tsx
│   │   │   │   ├── ConfigForm.tsx      unchanged from v2
│   │   │   │   ├── HostStatusBanner.tsx NEW — Windows preflight banner
│   │   │   │   ├── InstallProgress.tsx unchanged from v2 (indeterminate bar only)
│   │   │   │   ├── SettingsDialog.tsx  unchanged (if present in v2 tree)
│   │   │   │   ├── SettingsPanel.tsx   unchanged from v2 (placeholder)
│   │   │   │   ├── Sidebar.tsx         adds HostStatusBanner render
│   │   │   │   ├── StatusPill.tsx      unchanged from v2
│   │   │   │   └── UninstallDialog.tsx adds non-cancellable uninstalling state
│   │   │   └── ui/                     shadcn/ui primitives (unchanged from v2)
│   │   ├── lib/
│   │   │   └── utils.ts                unchanged from v2
│   │   ├── store/
│   │   │   └── installer-store.ts      modified per Section A4
│   │   ├── stub/
│   │   │   └── sample.ts               updated stub (step-event simulation)
│   │   └── styles/
│   │       ├── index.css               unchanged from v2
│   │       └── tokens.css              unchanged from v2 (graphite palette)
│   └── src-tauri/
│       ├── Cargo.toml
│       ├── Cargo.lock
│       ├── build.rs
│       ├── tauri.conf.json
│       ├── icons/                      (generated by tauri icon CLI)
│       ├── capabilities/
│       │   ├── installer-unix.json     NEW
│       │   └── installer-windows.json  NEW
│       └── src/
│           ├── lib.rs                  AppState, command registration
│           ├── commands.rs             run_installer, cancel_installer, etc.
│           ├── types.rs                InstallerEvent, payload types
│           └── steps.rs                step_label(), parse_step_line()
├── pnpm-workspace.yaml                 NEW — lists "gui"
├── package.json                        NEW — root workspace scripts
└── openspec/changes/claw-installer-gui-v1/
    └── proposal.md                     this file
```

---

## F. Acceptance Criteria

**AC1 — Full install from fresh host (macOS/Linux):**
From a host with neither agent in the manifest, clicking "一键安装全部" sets both agent cards to `installing` state, runs `install.sh`, and on exit code 0 transitions both cards to show the gear + trash icons and the 启动/停止/重启 row. The app title area shows no spinner.

**AC2 — Progress UX during install:**
While any install is running, the only motion visible to the user is: (a) the indeterminate animated bar on the active agent's card, and (b) a single line of Chinese step text (e.g., "正在配置 Node 运行时…") updated each time a new `==> <step>:` line is emitted. No log lines, no raw stdout pane, no percentage counter.

**AC3 — Uninstall is non-cancellable:**
After the user clicks "确认卸载" in `UninstallDialog`, the dialog closes, the agent card enters `uninstalling` state showing the danger progress bar, and no back/abort affordance is visible. On the `Finished` event with `success: true`, the card resets to "立即安装". The `cancel_installer` Rust command is NOT called during uninstall.

**AC4 — Windows: WSL absent banner:**
On a Windows host where `wsl.exe` is absent or returns exit code 3, the sidebar shows a red/warning banner above the agent list with copy "需要安装 WSL" and a button that copies `wsl --install` to the clipboard. A "Retry" button calls `refreshHostStatus`. While `hostStatus !== "ok"`, the agent cards are disabled (install buttons are grayed out and non-clickable).

**AC5 — Windows: Ubuntu first-run banner:**
On a Windows host where WSL is installed but the Ubuntu distro has not completed first-run setup (exit code 2), the banner shows copy "需要完成 Ubuntu 初始化" with a button to copy `wsl --install -d Ubuntu`. Retry re-probes.

**AC6 — Manifest-driven startup:**
On relaunch after a successful install, `read_installer_state` finds the manifest, both agents read as `"installed"`, and the UI opens with both cards already in the ready state (gear + trash + service buttons). No install spinner or progress bar is shown.

**AC7 — Cancel during install:**
Clicking "中止" during an install calls `cancel_installer`, kills the child process, sets the installing agent's status to `error` with message "已被用户中止", and shows the error state with a "重试" button. The other agent (if queued but not yet started) also shows an error.

**AC8 — Script failure / error path:**
If the installer script exits with a non-zero code, the agent card transitions to `error` state with a brief error message (e.g., "脚本退出码 1") and a "重新安装" button. Clicking the button starts a fresh install. No raw log is shown.

**AC9 — Settings panel (placeholder):**
Clicking the gear icon on an installed agent card slides in the `SettingsPanel` with "配置项即将开放" copy. The slide-in/out animation is 200 ms ease-out. No configuration is actually applied.

**AC10 — Stop/Start/Restart are no-ops:**
The three service-control buttons on installed cards are visible and clickable without error. They do not change the agent status in v1 (no backend hook is called). This is a known intentional gap, not a bug.

**AC11 — pnpm-only lockfile:**
After `pnpm install` in `gui/`, only `pnpm-lock.yaml` is created. No `package-lock.json` or `yarn.lock` exists. `npm install` in `gui/` fails with an engines/packageManager error.

**AC12 — Stub mode:**
`cd gui && pnpm dev` starts the Vite dev server. Opening `http://localhost:5173` in a browser shows the full UI. Clicking "一键安装全部" runs the stub installer simulation with step-text updates and terminates successfully after ~8 s. No Tauri runtime is required.

---

## G. Risks & Migration

### G1. Tauri 2 Windows Spawn Intermittent Hang (Issue #11513)

Tauri's shell plugin has a known intermittent issue on Windows where child process spawning can hang when the process writes large amounts to stdout before the receiver reads. The mitigation in this proposal is:

- The frontend does not render log lines, so the Channel send rate is low (only `StepChanged` events, not every `LogLine`).
- The Rust side still drains all `CommandEvent::Stdout` lines (into `LogLine` events) to prevent pipe buffer saturation — it just does not send them over the Channel in a UI-blocking way.
- If hangs are encountered in testing: fallback is to spawn via `std::process::Command` in a `tokio::task::spawn_blocking` and route events through a `tokio::sync::mpsc` channel, bypassing `tauri-plugin-shell`'s event loop.

This risk is noted; the probability is low because the stdout volume is bounded (installer scripts emit a few hundred lines total).

### G2. Manifest Format Drift

`installer/lib/manifest.sh` defines the TSV schema as `timestamp \t action \t target \t status \t note` (5 columns, tab-separated). The Rust parser uses `splitn(5, '\t')` and accesses columns by index. If the manifest schema changes (e.g., a column is inserted before `action`), the Rust parser silently misreads install state.

**Mitigation**: The Rust parser should assert column indices explicitly and return a parsing error (not silently return `not-installed`) when the column count doesn't match. A follow-up task should add a schema version header to `manifest.tsv` (e.g., `# version: 1`) that the Rust parser reads and validates.

### G3. Resource Path Mismatch (Dev vs. Prod)

In production, scripts are at `{resource_dir}/installer/**`. In dev, they are at the working checkout. The `INSTALLER_REPO_DIR` env var is the seam. If a developer runs `pnpm dev:gui` without setting `INSTALLER_REPO_DIR`, `resolve_installer_path` falls back to `resource_dir`, which in dev mode may not have the scripts bundled (Tauri dev builds do not always populate resource_dir).

**Mitigation**: `lib.rs` should panic with a descriptive message at startup if neither `INSTALLER_REPO_DIR` is set nor the resource dir contains `installer/install.sh`. This surfaces the misconfiguration immediately rather than as a cryptic "script not found" error at install time.

### G4. `AgentDetail` / `LogDrawer` Entanglement

The v2 `AgentDetail.tsx` component references `toggleLogDrawer` and `recentRuns`. When porting, `AgentDetail.tsx` must be either dropped (it is not rendered in the current `App.tsx`) or cleaned of its log-related calls. The proposal recommends dropping it from the ported tree in v1. If the developer agent decides to include it for future use, it must be stripped of `toggleLogDrawer` and `recentRuns` references.

### G5. Windows-Only `read_host_status` and `-Preflight` Flag

The `-Preflight` switch on `bootstrap.ps1` is a new addition. If the Rust command is called on a version of `bootstrap.ps1` that does not have this switch, the script will emit an error about unknown parameter. **Mitigation**: the `-Preflight` switch is added in the same PR as the Rust command that calls it. The developer agent must not ship the Rust backend without the PS script update.

---

## Open Questions

**OQ-1: Single-agent uninstall scope.**
`uninstall.sh` reverses all manifest entries in one pass; it does not have a `--agent <name>` flag. If the user installs both agents and later uninstalls only one, the current flow will attempt to remove both. For v1, the proposal accepts this limitation (the user must reinstall the other agent). A follow-up should add agent-scoped uninstall to `uninstall.sh`. This should be documented to users in the `UninstallDialog` copy: "此操作将按安装清单回滚所有改动。如需单独卸载，请先参考文档。" (or silently accept the limitation for now). **Decision needed**: should the dialog copy acknowledge the limitation, or is single-agent uninstall actually the only flow users will encounter?

**OQ-2: `AgentDetail` right pane inclusion.**
The current v2 `App.tsx` renders only the 280 px sidebar with no right pane. `AgentDetail.tsx` exists in the component tree but is not mounted. The proposal does not port `AgentDetail.tsx`. If the product roadmap calls for a wider window with a right detail pane, this changes the layout significantly. No action needed for v1, but should be confirmed.

**OQ-3: Windows manifest path.**
On Windows, the manifest lives at `\\wsl.localhost\Ubuntu\home\<user>\.claw-installer\manifest.tsv`. The `read_installer_state` command needs to resolve the current WSL user's home directory to construct this path. The `bootstrap.ps1` already knows the distro name; the Rust command needs either (a) a probe via `wsl.exe -d Ubuntu -- echo $HOME` or (b) a hardcoded convention (`\\wsl.localhost\Ubuntu\home\<username>\...`). The username is not known without a WSL probe. **Proposed approach**: on Windows, `read_installer_state` runs `wsl.exe -d Ubuntu -- cat ~/.claw-installer/manifest.tsv` and parses stdout directly, bypassing the Windows filesystem path entirely. This is simpler and avoids UNC path encoding issues. Confirm this approach before implementation.
