# Tasks: windows-wsl-auto-provision

Ordered implementation sequence. Tasks within a phase may be committed independently; cross-phase dependencies are noted.

---

## Phase 0: Types — Rust and TypeScript (no behaviour change)

**T0.1 — `InstallerEvent::RebootRequired` in Rust**
- Add `RebootRequired` variant to the `InstallerEvent` enum in `gui/src-tauri/src/types.rs`.
- No other changes; the enum is `#[serde(tag = "type", rename_all = "camelCase")]` so the serialised form is `{ "type": "rebootRequired" }`.
- Compile-check only: `cargo check --manifest-path gui/src-tauri/Cargo.toml`.

**T0.2 — `InstallerEvent` union in TypeScript**
- Add `{ type: "RebootRequired" }` to the `InstallerEvent` discriminated union in `gui/src/store/installer-store.ts`.
- Add `rebootModalOpen: boolean` (default `false`) to the `State` interface and `create()` call.
- Add `dismissRebootModal: () => void` action (sets `rebootModalOpen: false`).
- TypeScript compile-check: `pnpm --filter gui tsc --noEmit`.

---

## Phase 1: PowerShell — Layout Fix (prerequisite for all other Windows work)

**T1.1 — Fix `Copy-RepoIntoWsl` to copy `agents/` directory**
- In `shell/windows/bootstrap.ps1`, replace the inline bash heredoc in `Copy-RepoIntoWsl` to:
  - Remove references to `install-openclaw.sh` and `install-hermes.sh`.
  - Add `cp -R "$wslSrc/agents" "$dest/"` after the `steps/` line.
  - Change `chmod` glob to `find "$dest" -name '*.sh' -exec chmod +x {} \;`.
- Add validation: after the `install.sh` existence check, assert `(Test-Path (Join-Path $LocalPath 'agents'))` and exit 1 with a clear message if absent.
- Manual test (or integration test): run `bootstrap.ps1` on a Windows WSL host with a clean distro → verify `~/claw-installer-src/agents/openclaw/install.sh` is executable inside WSL.

---

## Phase 2: PowerShell — New Parameters

**T2.1 — Add `-Agent` and `-Service` to `param()` block**
- Add `[string]$Agent = ''` and `[string]$Service = ''` to the `param()` block in `bootstrap.ps1`.
- No behaviour change yet; parameters are parsed but unused.

**T2.2 — Extend `Invoke-BashInstaller` to support `-Agent`**
- When `$Agent` is non-empty, set `$entryPoint = "./agents/$Agent/install.sh"` instead of `"./install.sh"`.
- Validate that `$Agent` is `"openclaw"` or `"hermes"` (or empty); exit 1 for any other value.
- Unit test: call the function with `$Agent = "openclaw"` and `$DryRun`; assert the dry-run output contains `agents/openclaw/install.sh`.

**T2.3 — Add `Invoke-BashService` function**
- Implement the function as specified in CAP-4 of the proposal.
- Env-var forwarding uses `INSTALLER_*` and `CLAW_*` allow-list (see T3.2).
- Validate `$ServiceAction` is `"start"`, `"stop"`, or `"restart"`; exit 1 otherwise.
- Add service dispatch in `main`: before the `$Uninstall` branch, check `if ($Service -and $Agent)` and call `Invoke-BashService`; exit with its return code.

**T2.4 — `CLAW_*` env-var forward allow-list**
- Extend the `Where-Object` filter in `Invoke-BashInstaller` and `Invoke-BashUninstaller` to include `$_.Name -like 'CLAW_*'`.
- Exclude `CLAW_SESSION_LOG` explicitly (always appended separately).
- Also apply the same extended filter in the new `Invoke-BashService`.

---

## Phase 3: PowerShell — Elevation and Automated WSL Install

**T3.1 — Add `Assert-Elevated` function**
- Implement the function as specified in CAP-1 of the proposal.
- Parameter reconstruction from `$PSBoundParameters`: iterate `GetEnumerator()`, serialise switches as bare flags when `.IsPresent`, string/int params as `-Key Value` pairs.
- Catch the `Start-Process -Verb RunAs` exception; exit 4 with message "用户取消了 UAC 授权" on catch.
- Forward exit code of elevated child: `exit $proc.ExitCode`.
- Place call in `main` AFTER the `-Preflight` early-return and AFTER `Test-WslAvailable_Quick` check, so preflight never triggers UAC.

**T3.2 — Rename `Test-WslAvailable` → `Test-WslAvailable_Quick`**
- The existing function only checks `Get-Command wsl.exe` and exits 3 if absent.
- Rename to `Test-WslAvailable_Quick`; change it to only emit a warning log (`Write-Log`) when `wsl.exe` is absent — do NOT exit. The actual install/exit logic moves to `Ensure-WslInstalled` (T3.3).
- Update all callsites in `main`.

**T3.3 — Add `Install-WslFeatures` and `Ensure-WslInstalled` functions**
- `Install-WslFeatures`: check `Get-WindowsOptionalFeature` for `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`; enable disabled features with `-NoRestart`; set `$script:NeedsReboot = $true` if `RestartNeeded`.
- `Ensure-WslInstalled`: call `Install-WslFeatures`; then run `wsl.exe --install --no-launch -d $Distro` (detect `--no-launch` support via `wsl.exe --help`); check output for `"restart"` or `"reboot"` to set `$script:NeedsReboot`; if `$NeedsReboot`, exit 2.
- Fallback on any exception in `Install-WslFeatures` or `wsl --install`: print the original manual-install instructions and exit 3.
- Place `Ensure-WslInstalled` call in `main` after `Assert-Elevated`.

**T3.4 — Update `Ensure-Distro` to auto-install**
- Replace the "print and exit 2" branch with: `wsl --install -d $Name --no-launch` + exit 2 with "完成 Ubuntu 初始化后重新运行" message.
- Fallback: on exception, fall through to the original instructions + exit 2 path.

---

## Phase 4: Rust — `commands.rs` Windows Branches

**T4.1 — `build_command`: forward `-Agent` on Windows when single-agent**
- In the `#[cfg(target_os = "windows")]` branch of `build_command`, append `-Agent <agents[0]>` when `agents.len() == 1`.
- No change to the non-Windows branch.
- Unit test (cfg-gated): assert `build_command` args contain `-Agent openclaw` when `agents = ["openclaw"]`.

**T4.2 — `build_service_command`: add Windows branch**
- Add `#[cfg(target_os = "windows")]` branch that spawns `powershell.exe` with `-Service <action> -Agent <agent>` args.
- The existing `#[cfg(not(target_os = "windows"))]` bash branch remains unchanged.
- Compile-check on both targets.

**T4.3 — `run_uninstaller`: set `CLAW_UNINSTALL_AGENT` on Windows**
- After `cmd = build_uninstall_command(&app, &_agent)`, add a `#[cfg(target_os = "windows")]` block that calls `cmd.env("CLAW_UNINSTALL_AGENT", &_agent)` when `_agent` is `"openclaw"` or `"hermes"`.
- Unit test (cfg-gated): assert the env var is set in the command for a Windows target.

**T4.4 — `run_event_loop`: emit `RebootRequired` on exit code 2**
- In the `Terminated` arm, replace the flat `success = payload.code == Some(0)` pattern with a match:
  - `Some(0)` → emit `StepChanged { key: "done" }` then `Finished { success: true }`.
  - `Some(2)` → emit `RebootRequired`.
  - `code` → emit `Finished { success: false, message: "脚本退出码 <code>" }`.
- Existing tests must pass (exit code 0 and non-zero paths).

**T4.5 — Add `system_reboot` Tauri command**
- Implement `system_reboot` with `#[cfg(target_os = "windows")]` (runs `shutdown /r /t 0`) and `#[cfg(not(target_os = "windows"))]` (returns `Err`).
- Register in `generate_handler!` in `lib.rs`.
- Declare in Tauri capability files (see T4.6).

**T4.6 — Capability file: add `shell:allow-execute` for `shutdown.exe`**
- In `gui/src-tauri/capabilities/installer-windows.json`, add an entry allowing `shutdown.exe` with args `["/r", "/t", "0"]`.

---

## Phase 5: Frontend — RebootModal and Store Wiring

**T5.1 — `handleInstallerEvent`: handle `RebootRequired`**
- In the `handleInstallerEvent` function in `installer-store.ts`: when `event.type === "RebootRequired"`, call `set({ rebootModalOpen: true })` and transition all queued installing agents to `"not-installed"` (install did not complete, safe to retry).
- Also handle `RebootRequired` in the `confirmUninstall` event handler (uninstall also exits 2 on first WSL provision; same modal).

**T5.2 — `api/installer.ts`: add `systemReboot`**
- Add `export async function systemReboot(): Promise<void> { return invoke("system_reboot"); }`.

**T5.3 — `RebootModal.tsx` component**
- Create `gui/src/components/installer/RebootModal.tsx`.
- Uses the existing `Dialog`, `DialogContent`, `DialogHeader`, `DialogTitle`, `DialogDescription`, `DialogFooter` primitives from `@/components/ui/dialog`.
- "现在重启" button: `variant="destructive"`, calls `systemReboot()` on click, then calls `dismissRebootModal()`.
- "稍后" button: `variant="outline"`, calls `dismissRebootModal()`.
- `systemReboot()` is wrapped in a try/catch; on error, show a toast or inline error (do not crash).

**T5.4 — Mount `RebootModal` in `App.tsx`**
- Import `RebootModal` and render it unconditionally in `App.tsx`; the Dialog's `open` prop is bound to `useInstaller(s => s.rebootModalOpen)`.
- The modal is invisible in stub/browser mode because `rebootModalOpen` defaults to `false` and is never set to `true` without a real `RebootRequired` event.

---

## Phase 6: Integration Verification

**T6.1 — DryRun matrix on Windows**
- Run `bootstrap.ps1 -DryRun -Agent openclaw` → assert dry-run output shows `agents/openclaw/install.sh`.
- Run `bootstrap.ps1 -DryRun -Uninstall` → assert dry-run output shows `uninstall.sh --yes`.
- Run `bootstrap.ps1 -DryRun -Service restart -Agent hermes` → assert dry-run output shows `agents/hermes/restart.sh`.
- Run `bootstrap.ps1 -Preflight` (non-elevated session) → assert no UAC dialog, exits 0 (if WSL + distro present) or 2/3 (if not).

**T6.2 — `Copy-RepoIntoWsl` layout test**
- On a Windows host with WSL + Ubuntu: run `bootstrap.ps1` pointing `$RepoDir` at the repo root.
- Inside WSL after run: verify `~/claw-installer-src/agents/openclaw/install.sh` exists and is executable; verify `~/claw-installer-src/agents/hermes/install.sh` exists and is executable.

**T6.3 — Rust compile check on all targets**
- `cargo build --manifest-path gui/src-tauri/Cargo.toml` on macOS/Linux (non-Windows target).
- Verify `build_service_command` compiles and the Windows branch is not included via `cfg`.
- Cross-compile check: `cargo check --target x86_64-pc-windows-msvc` (requires Windows target installed) to verify the Windows branches compile.

**T6.4 — GUI RebootModal display test (stub mode)**
- Temporarily set `rebootModalOpen: true` in the store initial state.
- Run `pnpm dev` → open browser → verify the modal renders with correct Chinese copy, destructive "现在重启" button, and outline "稍后" button.
- Revert the temporary change.

**T6.5 — End-to-end: service action on Windows**
- On a Windows host with a fully installed agent: click "重启" in the GUI for the agent.
- Verify Tauri spawns `bootstrap.ps1 -Service restart -Agent <name>`.
- Verify the agent transitions to `ready` on exit 0.
