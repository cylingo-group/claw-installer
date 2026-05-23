# Tasks: claw-installer-gui-v1

Ordered implementation sequence. Each task is independently testable; later tasks depend on earlier ones only where noted.

---

## Phase 0: Workspace & Scaffold

**T0.1 — Root workspace** [x]
- Create `pnpm-workspace.yaml` at repo root listing `"gui"`.
- Create root `package.json` with `dev:gui` and `build:gui` scripts.

**T0.2 — Scaffold gui/** [x]
- Run `pnpm create tauri-app gui --template react-ts` from repo root.
- Delete scaffolded `src/` and `index.html`; copy from `docs/ued/claw-installer-gui/v2/src/` and `docs/ued/claw-installer-gui/v2/index.html`.
- Copy `tsconfig*.json`, `components.json` from v2.
- Replace `vite.config.ts` with the Tauri-compatible version (drop `ued-framework` plugin, add Tauri `clearScreen`/`envPrefix`/`build` config).
- Add `engines.packageManager` to `gui/package.json`; remove `ued-framework` devDep.
- Run `pnpm install` inside `gui/`; verify `pnpm-lock.yaml` created; verify no `node_modules/.package-lock.json`.

---

## Phase 1: Script Changes

**T1.1 — `bootstrap.ps1`: add `-Preflight` switch** [x]
- Add `[switch]$Preflight` to param block.
- After `Test-WindowsBuild` / `Test-WslAvailable` / `Ensure-Wsl2Default` / `Ensure-Distro` / version check: if `$Preflight`, write-step and `exit 0`.
- Manual test: `powershell -File installer\windows\bootstrap.ps1 -Preflight` on a Windows host with WSL installed → exit 0.

**T1.2 — `bootstrap.ps1`: add `-Uninstall` switch** [x]
- Add `[switch]$Uninstall` to param block.
- Add `Invoke-BashUninstaller` function (mirrors `Invoke-BashInstaller`, runs `./uninstall.sh --yes`).
- In `main`: after `Copy-RepoIntoWsl`, branch on `$Uninstall`.
- Manual test: `bootstrap.ps1 -Uninstall` on a host with a manifest → confirm uninstall.sh runs.

---

## Phase 2: Frontend Store Refactor

**T2.1 — Drop log fields from store** [x]
- Remove `logTail`, `logDrawerOpen` from `State` interface and `create()` call.
- Remove `toggleLogDrawer` action.
- Remove `progress` from `AgentState`.
- Remove `LogLine` type.
- Remove import of `openclawLogScript`, `hermesLogScript` from `installer-store.ts`.
- Remove `SCRIPTS`, `TICK_MS`, `tickHandle`, `nowIso` from the store module.
- Verify: no TypeScript errors after removal.

**T2.2 — Add new fields and types** [x]
- Add `currentStep: string | null` and `currentStepDetail: string | null` to `AgentState`.
- Add `hostStatus: HostStatus` to `State` (default `"ok"`).
- Add `isBootstrapping: boolean` to `State` (default `true`).
- Add `HostStatus` type export.
- Add `setCurrentStep`, `setAgentStatus`, `refreshHostStatus`, `bootstrap` actions (stubs that no-op for now — wired to real API in T3).

**T2.3 — Refactor `startInstall`** [x]
- Remove `setInterval` tick loop.
- Implement `IS_TAURI_ENV` check.
- In Tauri mode: call stub `api/installer.ts#runInstaller` placeholder (returns immediately).
- In stub mode: call `runStubInstaller` from `src/stub/sample.ts`.

**T2.4 — Refactor `confirmUninstall`** [x]
- Remove `setTimeout` simulation.
- In Tauri mode: call stub `api/installer.ts#runUninstaller` placeholder.
- In stub mode: call `runStubUninstaller` from `src/stub/sample.ts`.

---

## Phase 3: Frontend New Components

**T3.1 — `src/api/installer.ts`** [x]
- Implement all five exported functions with Tauri `invoke` + `Channel`.
- Include the `IS_TAURI_ENV` guard: when false, throw an error (stub mode should never reach this file).

**T3.2 — `src/stub/sample.ts`** [x]
- Implement `runStubInstaller` with step-event sequence for openclaw and hermes.
- Implement `runStubUninstaller` with a 4.5 s delay then `Finished { success: true }`.
- Wire into store actions from T2.3 / T2.4.

**T3.3 — `HostStatusBanner.tsx`** [x]
- Render banner with copy-to-clipboard button and Retry button.
- Show only when `hostStatus !== "ok"`.

**T3.4 — Modify `Sidebar.tsx`** [x]
- Import `HostStatusBanner`; render above agent list.
- Disable "一键安装全部" and per-card install buttons when `hostStatus !== "ok"` or `isBootstrapping === true`.

**T3.5 — Modify `UninstallDialog.tsx`** [x]
- When `agents[target].status === "uninstalling"`: replace button row with `ProgressBar tone="danger"` and copy "卸载中，请稍候…".
- No cancel/back affordance during uninstall.

**T3.6 — Modify `AgentCard.tsx`** [x]
- When `status === "installing"`: add a second line beneath the indeterminate bar showing `currentStep` text (from store).
- When `status === "uninstalling"`: show "卸载中…" and `currentStep` if available.

**T3.7 — Modify `App.tsx`** [x]
- Add `useEffect(() => { useInstaller.getState().bootstrap(); }, [])` on mount.
- Render `HostStatusBanner` (via Sidebar, already done in T3.4).

---

## Phase 4: Rust Backend

**T4.1 — Project setup** [x]
- Update `Cargo.toml` with required plugins.
- Add `tauri-plugin-shell`, `tauri-plugin-fs`, `tauri-plugin-os` to `lib.rs` plugin registration.
- Create `capabilities/installer-unix.json` and `capabilities/installer-windows.json`.

**T4.2 — Types and step mapping** [x]
- Create `src/types.rs` with `InstallerEvent`, `InstallerStatePayload`, `HostStatusPayload`.
- Create `src/steps.rs` with `step_label()` and `parse_step_line()`.

**T4.3 — `read_installer_state` command** [x]
- Implement manifest TSV parsing.
- Handle missing manifest (return `not-installed` for both).
- Handle Windows path via `wsl.exe -d Ubuntu -- cat ~/.claw-installer/manifest.tsv`.
- Unit-testable: extract parsing logic into a pure function.

**T4.4 — `read_host_status` command** [x]
- Implement platform-branched command (cfg macros).
- Non-Windows: constant `ok`.
- Windows: spawn `bootstrap.ps1 -Preflight`, map exit codes.

**T4.5 — `run_installer` command** [x]
- Implement `build_command` for Unix vs Windows vs single-agent vs both-agents.
- Implement event loop with `parse_step_line` → `StepChanged` emission.
- Implement `LogLine` emission (drained but not UI-bound).
- Implement `Finished` emission on termination.
- Store child in `AppState`.

**T4.6 — `cancel_installer` command** [x]
- Kill child if present.

**T4.7 — `run_uninstaller` command** [x]
- Unix: `bash uninstall.sh --yes`.
- Windows: `powershell.exe bootstrap.ps1 -Uninstall`.
- Same event loop as `run_installer`.
- Does NOT expose cancel affordance to the frontend (no UI call).

**T4.8 — Wire all commands in `lib.rs`** [x]
- Register all commands in `tauri::Builder::invoke_handler`.
- Register `AppState`.
- Startup dev guard: if not in Tauri env AND no `INSTALLER_REPO_DIR`, emit a startup warning log (do not panic in dev mode, panic only in release builds).

---

## Phase 5: Wire Store to Real API

**T5.1 — Connect `startInstall` to `run_installer`** [x]
- Replace stub call with `api/installer.ts#runInstaller`.
- Handle `StepChanged`: call `setCurrentStep`.
- Handle `StatusChanged`: call `setAgentStatus`.
- Handle `Finished`: set agent to `ready` or `error`.

**T5.2 — Connect `confirmUninstall` to `run_uninstaller`** [x]
- Replace stub call with `api/installer.ts#runUninstaller`.
- Handle events the same way.

**T5.3 — Connect `cancelInstall` to `cancel_installer`** [x]
- Replace stub call with `api/installer.ts#cancelInstaller`.

**T5.4 — Connect `bootstrap` to `readInstallerState` + `readHostStatus`** [x]
- Call both on mount; update store; set `isBootstrapping = false`.

---

## Phase 6: Packaging & Verification

**T6.1 — Tauri icons** [x]
- Run `tauri icon` with a source icon asset (to be supplied).

**T6.2 — Build verification** [x]
- `pnpm build:gui` on macOS → `.dmg` + `.app` produced.
- AC1 through AC12 manual test pass.

**T6.3 — Windows smoke test** (if CI available) [x]
- Build `.msi` on Windows runner.
- AC4 / AC5 banner states verified with a WSL-absent Windows VM.
