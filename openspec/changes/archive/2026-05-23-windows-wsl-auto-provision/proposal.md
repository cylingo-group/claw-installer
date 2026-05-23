# Change Proposal: Windows WSL Auto-Provisioning

**Slug**: `windows-wsl-auto-provision`
**Status**: Draft
**Author**: LuoChuan
**Date**: 2026-05-19

---

## Problem Statement

The Windows path of claw-installer today requires users to manually prepare WSL 2 before clicking "Install" in the GUI. `bootstrap.ps1` detects a missing `wsl.exe` or distro and immediately exits with instructions — it never auto-installs anything. This creates a multi-step manual process that breaks the "one-click install" promise for Windows users.

Additionally, three independent bugs exist in the current Windows implementation:

1. `Copy-RepoIntoWsl` still references `install-openclaw.sh` and `install-hermes.sh` — files that no longer exist after the layout was refactored to `shell/agents/<agent>/*.sh`. On Windows, any install attempt fails with a file-not-found error at the copy step.
2. `Copy-RepoIntoWsl` never copies the `agents/` directory at all, so the per-agent scripts are unavailable inside WSL.
3. `build_service_command` in `commands.rs` unconditionally runs `bash` — it has no `#[cfg(target_os = "windows")]` branch, so service lifecycle actions (start/stop/restart) crash on Windows.

The fix bundles: (a) automated WSL 2 + Ubuntu provisioning with a one-reboot handoff, (b) a GUI reboot prompt, (c) layout fixes for the copy step, (d) new `-Agent`/`-Service` parameters on `bootstrap.ps1`, (e) env-var forwarding for `CLAW_*` vars, and (f) the missing Rust Windows branches.

---

## Proposed Solution

One change proposal covering six capability areas. They are tightly coupled — the Rust and PS1 changes share a parameter contract, the GUI reboot prompt requires a new wire signal, and the layout fix is a prerequisite for any Windows install to work at all. Splitting into separate proposals would create ordering dependencies with no implementation benefit.

**High-level flow after this change:**

```
User clicks Install
  → Tauri spawns bootstrap.ps1 (elevated, via UAC re-spawn)
    [WSL absent]  → Enable-WindowsOptionalFeature + wsl --install → exit 2
                  → GUI shows reboot modal → user reboots or dismisses
    [WSL present, distro absent] → wsl --install -d Ubuntu → exit 2
                  → GUI shows reboot/firstrun modal
    [WSL + distro present] → Copy agents/ into WSL → run install.sh → exit 0
                  → GUI shows installed state
```

---

## Scope & Boundaries

### In Scope

- PowerShell self-elevation via UAC (`Start-Process -Verb RunAs`).
- Automated `Enable-WindowsOptionalFeature` for WSL + VirtualMachinePlatform, then `wsl --install`.
- GUI `RebootRequired` event + modal with "现在重启" / "稍后" buttons.
- New Tauri command `system_reboot` (Windows-only, runs `shutdown /r /t 0`).
- `Copy-RepoIntoWsl` layout fix: copy `agents/` instead of the removed per-agent root scripts.
- New `-Agent <openclaw|hermes>` and `-Service <start|stop|restart>` parameters on `bootstrap.ps1`.
- `CLAW_*` prefix added to the env-var forward allow-list in `bootstrap.ps1`.
- `build_service_command` Windows branch in `commands.rs`.
- `run_uninstaller` on Windows: set `CLAW_UNINSTALL_AGENT` env when agent is `openclaw` or `hermes`.

### Explicitly Out of Scope

- Non-Windows changes to shell scripts beyond the files listed above.
- Code signing or packaging configuration.
- `bundle.resources` tauri.conf.json changes (tracked separately).
- WSL1-to-WSL2 version upgrade (already handled by existing `Get-DistroVersion` check + exit 3).
- Distro first-run interactive setup (still requires user interaction in the Ubuntu terminal window; the script exits 2 after `wsl --install -d` returns, GUI surfaces the prompt).

---

## Key Design Decisions

### ADR-1: Dedicated `RebootRequired` event variant, not a sentinel in `Finished.message`

**Decision**: Add `InstallerEvent::RebootRequired` as a new enum variant in Rust and a new discriminated union member in TypeScript.

**Alternatives considered**:
- Reuse `Finished { success: false, message: "<<REBOOT>>" }` — rejected because the GUI would need to string-match `message` to distinguish a reboot signal from an actual error. Fragile; breaks if message text changes.
- Reuse exit code 2 mapping in `run_event_loop` — rejected because the event loop currently fires `Finished` on `Terminated`. Adding special-case logic for exit code 2 inside `run_event_loop` mixes the WSL provisioning concern into generic event routing.

**Rationale**: A typed variant is zero-cost (the enum already uses `#[serde(tag = "type")]`) and keeps the frontend switch exhaustive.

### ADR-2: UAC re-spawn rather than always-elevated

**Decision**: `bootstrap.ps1` detects whether it is already elevated (`[Security.Principal.WindowsIdentity]::GetCurrent()` + `IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`). If not elevated, it re-spawns itself via `Start-Process powershell -Verb RunAs` with all original parameters forwarded. If elevation is declined (UAC cancel, `OperationCanceledException` or `$LASTEXITCODE -ne 0` from `Start-Process`), it exits with code 4 + a clear message.

**Why not always require elevation**: The `-Preflight` path used by `read_host_status` does not need elevation. Forcing elevation there would show a UAC prompt just for a status probe, which is poor UX.

**Consequence**: The `build_command` Windows branch in Rust does not need to change — it continues to spawn `powershell.exe` without `runas`; the script self-elevates when necessary.

### ADR-3: `wsl --install` is the primary path; `Enable-WindowsOptionalFeature` is the guard

**Decision**: `Install-WslFeatures` first checks `Get-WindowsOptionalFeature -Online` for `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`. If either is `Disabled`, it runs `Enable-WindowsOptionalFeature -Online -FeatureName ... -NoRestart` before calling `wsl.exe --install`. This is required because on some Windows 10 builds, `wsl --install` silently fails if the optional features are not enabled first.

**Reboot detection**: `RestartNeeded` on either feature result → exit 2. `wsl --install`'s own output is checked for the string `"restart"` as a belt-and-suspenders guard. The GUI always exits 2 on first WSL provisioning; the second run proceeds to the distro/install steps.

### ADR-4: `-Agent` parameter for single-agent install; top-level `install.sh` is the default

**Decision**: When `-Agent openclaw` or `-Agent hermes` is passed, `Invoke-BashInstaller` runs `./agents/$Agent/install.sh` instead of `./install.sh`. When `-Agent` is absent (or empty), `./install.sh` is run (multi-agent orchestrator). This mirrors the Unix behavior in `build_command` (Rust side), which already branches on `agents.len() == 1`.

**Consequence**: `build_command` on Windows must forward the selected agent as `-Agent <name>` when `agents.len() == 1`.

### ADR-5: `-Service` parameter replaces missing Windows branch in `build_service_command`

**Decision**: `build_service_command` gains a `#[cfg(target_os = "windows")]` branch that spawns `powershell.exe -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -Service <action> -Agent <agent>`. Inside the script, `Invoke-BashService` runs `./agents/$Agent/$Service.sh` inside WSL.

**Why not a new script**: Keeping all Windows bootstrapping in one file reduces the surface of Windows-specific code. The `-Service` parameter is a natural extension of the existing `-Uninstall` pattern.

### ADR-6: Exit code contract

| Code | Meaning | GUI action |
|------|---------|------------|
| 0 | Success | Transition to installed/ready |
| 1 | Generic failure | Error state + retry CTA |
| 2 | Reboot required (WSL feature install or distro first-run) | `RebootRequired` event → modal |
| 3 | Manual action required (WSL absent, no elevation available) | Error state with instructions |
| 4 | UAC cancelled by user | Error state + message "用户取消了 UAC 授权" |

The `run_event_loop` function inspects the exit code on `Terminated` to emit `RebootRequired` for code 2 instead of `Finished { success: false }`.

---

## Capability Areas

### CAP-1: PowerShell Self-Elevation

**Location**: `shell/windows/bootstrap.ps1`

New function `Assert-Elevated`:

```powershell
function Assert-Elevated {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]$identity
  if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    return  # already elevated, nothing to do
  }
  Write-Display "需要管理员权限，正在请求 UAC 授权…"
  # Re-build the arg list from $PSBoundParameters so every param is forwarded.
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  foreach ($kv in $PSBoundParameters.GetEnumerator()) {
    if ($kv.Value -is [switch]) {
      if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
    } else {
      $argList += "-$($kv.Key)", $kv.Value
    }
  }
  try {
    $proc = Start-Process powershell -ArgumentList $argList -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
  } catch {
    Write-Err2 "UAC 授权被拒绝或取消：$_"
    exit 4
  }
}
```

`Assert-Elevated` is called at the top of `main`, before `Test-WindowsBuild`.

**Param block additions** (alongside existing params):

```powershell
[string]$Agent   = '',          # 'openclaw' | 'hermes' | '' (all)
[string]$Service = ''           # 'start' | 'stop' | 'restart' | ''
```

Both must be forwarded by `Assert-Elevated`'s parameter reconstruction.

### CAP-2: Automated WSL Install

**Location**: `shell/windows/bootstrap.ps1`

Replace `Test-WslAvailable` (which currently exits 3 immediately) with `Ensure-WslInstalled`:

```powershell
function Ensure-WslInstalled {
  if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    Write-Step "wsl.exe found on PATH."
    return
  }
  # Must be elevated to install WSL features.
  Write-Display "未检测到 WSL，正在自动安装…"
  Install-WslFeatures   # enables optional features; sets $script:NeedsReboot if required
  Write-Log "Running: wsl.exe --install --no-launch -d $Distro"
  if (-not $DryRun) {
    $out = & wsl.exe --install --no-launch -d $Distro 2>&1
    Write-Log $out
    if ($out -match 'restart|reboot') { $script:NeedsReboot = $true }
  }
  if ($script:NeedsReboot) {
    Write-Display "WSL 安装完成，需要重启 Windows 才能继续。"
    exit 2
  }
}

function Install-WslFeatures {
  $script:NeedsReboot = $false
  foreach ($feat in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
    $f = Get-WindowsOptionalFeature -Online -FeatureName $feat
    if ($f.State -eq 'Disabled') {
      Write-Display "正在启用 Windows 功能：$feat …"
      if (-not $DryRun) {
        $r = Enable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart
        if ($r.RestartNeeded) { $script:NeedsReboot = $true }
      }
    }
  }
}
```

Replace `Ensure-Distro` "print and exit" branch with auto-install:

```powershell
function Ensure-Distro {
  param([string]$Name)
  if (Test-DistroInstalled -Name $Name) {
    Write-Step "WSL distro '$Name' present."
    return
  }
  Write-Display "WSL 发行版 '$Name' 未安装，正在自动安装…"
  if (-not $DryRun) {
    $out = & wsl.exe --install -d $Name --no-launch 2>&1
    Write-Log $out
  }
  # First-run interactive setup still requires user; signal GUI to prompt.
  Write-Display "发行版安装完成。请在弹出的 Ubuntu 窗口中完成用户名/密码设置，然后重新运行安装程序。"
  exit 2
}
```

**Fallback**: when `Enable-WindowsOptionalFeature` or `wsl --install` itself fails (non-zero exit), fall through to the original "print instructions + exit 3" path so the user always gets actionable guidance.

### CAP-3: `agents/` Layout Fix in `Copy-RepoIntoWsl`

**Location**: `shell/windows/bootstrap.ps1`

Current broken copy script references `install-openclaw.sh` and `install-hermes.sh` (removed) and omits `agents/`. Replace:

```powershell
$cp = @"
set -e
dest="`$HOME/claw-installer-src"
rm -rf "`$dest"
mkdir -p "`$dest"
cp "$wslSrc/install.sh"   "`$dest/"
cp "$wslSrc/uninstall.sh" "`$dest/"
cp -R "$wslSrc/lib"       "`$dest/"
cp -R "$wslSrc/steps"     "`$dest/"
cp -R "$wslSrc/agents"    "`$dest/"
if [ -d "$wslSrc/vendor" ]; then cp -R "$wslSrc/vendor" "`$dest/"; fi
find "`$dest" -name '*.sh' -exec chmod +x {} \;
echo "Copied to `$dest"
"@
```

Validation: verify `install.sh` exists in `$LocalPath` (keep existing check) and add a check that `agents/` exists:

```powershell
if (-not (Test-Path (Join-Path $LocalPath 'agents'))) {
  Write-Err2 "Expected agents/ directory not found in $LocalPath"
  exit 1
}
```

### CAP-4: `-Agent` and `-Service` Parameters for Single-Agent and Service Dispatch

**Location**: `shell/windows/bootstrap.ps1`

**`Invoke-BashInstaller` change**: when `$Agent` is non-empty, run `./agents/$Agent/install.sh` instead of `./install.sh`:

```powershell
$entryPoint = if ($Agent) { "./agents/$Agent/install.sh" } else { "./install.sh" }
$script = @"
set -e
$envBlock
mkdir -p "`$(dirname '$wslSessionLog')"
cd "$DestDir"
$entryPoint $debugFlag
"@
```

**New `Invoke-BashService` function**: handles `-Service` + `-Agent` dispatch:

```powershell
function Invoke-BashService {
  param([string]$Name, [string]$DestDir, [string]$AgentName, [string]$ServiceAction)
  $_lts = (Get-Date -Format 'yyyyMMddTHHmmssZ')
  $wslSessionLog = "/tmp/claw-installer/$ServiceAction-$AgentName-$_lts.log"
  $forward = @()
  Get-ChildItem env: | Where-Object {
    ($_.Name -like 'INSTALLER_*' -or $_.Name -like 'CLAW_*') -and
    $_.Name -ne 'INSTALLER_REPO_DIR' -and
    $_.Name -ne 'INSTALLER_WSL_DISTRO'
  } | ForEach-Object {
    $v = $_.Value -replace "'", "'\''"
    $forward += ("export {0}='{1}'" -f $_.Name, $v)
  }
  $forward += "export CLAW_SESSION_LOG='$wslSessionLog'"
  $envBlock = $forward -join "`n"
  $script = @"
set -e
$envBlock
mkdir -p "`$(dirname '$wslSessionLog')"
cd "$DestDir"
./agents/$AgentName/$ServiceAction.sh
"@
  Write-Display "正在 WSL（$Name）中执行 $AgentName $ServiceAction…"
  if ($DryRun) { Write-Host "  [dry-run] wsl -d $Name -- bash -lc <$AgentName/$ServiceAction.sh>"; return 0 }
  & wsl.exe -d $Name -- bash -lc $script
  return $LASTEXITCODE
}
```

**`main` block service dispatch** (added before the existing `$Uninstall` branch):

```powershell
if ($Service -and $Agent) {
  $rc = Invoke-BashService -Name $Distro -DestDir $destInWsl -AgentName $Agent -ServiceAction $Service
  exit $rc
}
```

### CAP-5: `CLAW_*` Env-Var Forwarding

**Location**: `shell/windows/bootstrap.ps1` — `Invoke-BashInstaller`, `Invoke-BashUninstaller`

Extend the `Where-Object` filter in both functions to also forward env vars matching `CLAW_*` (excluding `CLAW_SESSION_LOG` which is always appended explicitly):

```powershell
Get-ChildItem env: | Where-Object {
  ($_.Name -like 'INSTALLER_*' -or $_.Name -like 'CLAW_*') -and
  $_.Name -ne 'INSTALLER_REPO_DIR' -and
  $_.Name -ne 'INSTALLER_WSL_DISTRO' -and
  $_.Name -ne 'CLAW_SESSION_LOG'
} | ForEach-Object { ... }
```

### CAP-6: Rust `commands.rs` — Windows Branches

**`build_command` (already correct on Windows — no change needed)**. The existing Windows branch calls `bootstrap.ps1` without `-Agent`; this must be extended to forward `-Agent` when `agents.len() == 1`:

```rust
#[cfg(target_os = "windows")]
{
    let ps_path = resolve_installer_path(app, r"windows\bootstrap.ps1");
    let mut args = vec![
        "-NoProfile".to_string(),
        "-ExecutionPolicy".to_string(),
        "Bypass".to_string(),
        "-File".to_string(),
        ps_path.to_string_lossy().to_string(),
    ];
    if agents.len() == 1 {
        args.push("-Agent".to_string());
        args.push(agents[0].clone());
    }
    shell.command("powershell.exe").args(args)
}
```

**`build_uninstall_command` on Windows — add `CLAW_UNINSTALL_AGENT`**: The Rust function already spawns `bootstrap.ps1 -Uninstall`. The caller (`run_uninstaller`) must set the env var so `bootstrap.ps1` can forward it into WSL:

```rust
// In run_uninstaller, after cmd = build_uninstall_command(&app, &_agent):
#[cfg(target_os = "windows")]
if _agent == "openclaw" || _agent == "hermes" {
    cmd = cmd.env("CLAW_UNINSTALL_AGENT", &_agent);
}
```

**`build_service_command` — add Windows branch**:

```rust
fn build_service_command(
    app: &tauri::AppHandle,
    agent: &str,
    action: &str,
) -> tauri_plugin_shell::process::Command {
    let shell = app.shell();

    #[cfg(target_os = "windows")]
    {
        let ps_path = resolve_installer_path(app, r"windows\bootstrap.ps1");
        shell.command("powershell.exe").args([
            "-NoProfile".to_string(),
            "-ExecutionPolicy".to_string(),
            "Bypass".to_string(),
            "-File".to_string(),
            ps_path.to_string_lossy().to_string(),
            "-Service".to_string(),
            action.to_string(),
            "-Agent".to_string(),
            agent.to_string(),
        ])
    }

    #[cfg(not(target_os = "windows"))]
    {
        let script = resolve_installer_path(app, &format!("agents/{}/{}.sh", agent, action));
        shell.command("bash").args([script.to_string_lossy().to_string()])
    }
}
```

**`run_event_loop` — emit `RebootRequired` on exit code 2**:

```rust
Some(CommandEvent::Terminated(payload)) => {
    *child_state.lock().await = None;
    match payload.code {
        Some(0) => {
            let _ = on_event.send(InstallerEvent::StepChanged {
                key: "done".to_string(),
                label: "✓ 完成".to_string(),
                detail: String::new(),
            });
            let _ = on_event.send(InstallerEvent::Finished { success: true, message: None });
        }
        Some(2) => {
            let _ = on_event.send(InstallerEvent::RebootRequired);
        }
        code => {
            let _ = on_event.send(InstallerEvent::Finished {
                success: false,
                message: Some(format!("脚本退出码 {}", code.unwrap_or(-1))),
            });
        }
    }
    break;
}
```

**New variant in `types.rs`**:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum InstallerEvent {
    StepChanged { key: String, label: String, detail: String },
    StatusChanged { agent: String, status: String, message: Option<String> },
    Finished { success: bool, message: Option<String> },
    LogLine { line: String },
    LogPath { path: String },
    RebootRequired,   // NEW — Windows only, exit code 2
}
```

**New `system_reboot` command** (Windows-only):

```rust
#[cfg(target_os = "windows")]
#[tauri::command]
pub async fn system_reboot() -> Result<(), String> {
    std::process::Command::new("shutdown")
        .args(["/r", "/t", "0"])
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(not(target_os = "windows"))]
#[tauri::command]
pub async fn system_reboot() -> Result<(), String> {
    Err("system_reboot is only supported on Windows".into())
}
```

Must be registered in `lib.rs` / `generate_handler!`.

### CAP-7: GUI Reboot Modal

**Location**: `gui/src/store/installer-store.ts`, new `gui/src/components/installer/RebootModal.tsx`

**Store changes**:

- Add `InstallerEvent` union member: `{ type: "RebootRequired" }`
- Add top-level store field: `rebootModalOpen: boolean` (default `false`)
- Add store action: `dismissRebootModal: () => void` — sets `rebootModalOpen: false`
- In `handleInstallerEvent`: when `event.type === "RebootRequired"`, set `rebootModalOpen: true` and transition all queued installing agents to `not-installed` (install did not complete)

**`api/installer.ts` addition**:

```ts
export async function systemReboot(): Promise<void> {
  return invoke("system_reboot");
}
```

**`RebootModal.tsx`** — rendered from `App.tsx` when `rebootModalOpen`:

```
Dialog title: "需要重启 Windows"
Body: "WSL 2 安装完成，需要重启 Windows 才能继续。重启后重新打开安装程序以完成安装。"
Primary button: "现在重启" → calls systemReboot() then closes modal
Secondary button: "稍后" → calls dismissRebootModal()
```

The modal uses the existing `Dialog` shadcn/ui primitive (already in `gui/src/components/ui/dialog.tsx`). No new dependencies needed.

**TypeScript `InstallerEvent` type** — add the new variant:

```ts
export type InstallerEvent =
  | { type: "StepChanged"; key: string; label: string; detail: string }
  | { type: "StatusChanged"; agent: string; status: string; message: string | null }
  | { type: "Finished"; success: boolean; message: string | null }
  | { type: "LogLine"; line: string }
  | { type: "LogPath"; path: string }
  | { type: "RebootRequired" };   // NEW
```

---

## Acceptance Criteria

**AC1 — WSL absent, elevated, auto-install succeeds but needs reboot:**
On a clean Windows host with no WSL: clicking "Install" triggers UAC → bootstrap runs `Enable-WindowsOptionalFeature` → `wsl --install` → exits 2 → GUI shows the reboot modal. "现在重启" issues `shutdown /r /t 0`. "稍后" closes the modal with agents in `not-installed` state.

**AC2 — WSL absent, UAC cancelled:**
User cancels the UAC dialog → bootstrap exits 4 → GUI shows error state with message "用户取消了 UAC 授权" → retry CTA is available.

**AC3 — WSL present, distro absent, auto-installs:**
`wsl.exe` on PATH but Ubuntu not installed → `Ensure-Distro` runs `wsl --install -d Ubuntu --no-launch` → exits 2 → GUI shows reboot/firstrun modal. On second run after user completes Ubuntu first-run, full install proceeds.

**AC4 — Full install succeeds (WSL + Ubuntu already provisioned):**
Standard case: bootstrap is elevated (or was already), distro present, systemd configured, `agents/` directory correctly copied into WSL, `./install.sh` runs → exit 0 → GUI transitions both agents to `ready`.

**AC5 — Single-agent install on Windows:**
When GUI calls `runInstaller(["openclaw"], env, ...)`: Rust passes `-Agent openclaw` to `bootstrap.ps1` → `Invoke-BashInstaller` runs `./agents/openclaw/install.sh` inside WSL.

**AC6 — Service lifecycle on Windows:**
When GUI calls `runServiceAction("hermes", "restart", ...)`: Rust calls `build_service_command` which spawns `bootstrap.ps1 -Service restart -Agent hermes` → `Invoke-BashService` runs `./agents/hermes/restart.sh` inside WSL → exit 0 → GUI agent transitions to `ready`.

**AC7 — `CLAW_UNINSTALL_AGENT` forwarded on Windows uninstall:**
When GUI calls `runUninstaller("openclaw", ...)`: Rust sets `CLAW_UNINSTALL_AGENT=openclaw` in the child environment → `bootstrap.ps1` forwards it into WSL → `uninstall.sh` inside WSL honors the env var and performs a partial uninstall.

**AC8 — Layout fix: `agents/` directory present inside WSL after copy:**
After `Copy-RepoIntoWsl` runs, the WSL path `~/claw-installer-src/agents/openclaw/install.sh` and `~/claw-installer-src/agents/hermes/install.sh` exist and are executable.

**AC9 — No UAC prompt for preflight probe:**
`read_host_status` spawns `bootstrap.ps1 -Preflight`. The `-Preflight` path does not reach `Assert-Elevated` (elevation check is after the preflight early-return — see Implementation Note below) OR `Ensure-WslInstalled` is not called during preflight. No UAC dialog appears when the status probe runs at startup.

**AC10 — `system_reboot` is a no-op on non-Windows:**
Calling the Tauri command `system_reboot` from a macOS or Linux build returns an Err, which the frontend catches and does not crash on.

**AC11 — Stub mode unchanged:**
Browser-mode development (`pnpm dev` without Tauri) continues to work. The `RebootRequired` event is never emitted in stub mode. The `RebootModal` is never shown (store default `rebootModalOpen: false`).

---

## Implementation Notes

### Elevation gate placement

`Assert-Elevated` must be called only when WSL install is actually needed, or unconditionally for all install/uninstall paths. For `-Preflight`, elevation is not needed and must not be requested. Recommended placement:

```powershell
# Preflight exits before reaching Assert-Elevated.
Test-WindowsBuild
Test-WslAvailable_Quick   # only checks if wsl.exe is on PATH; does NOT auto-install
Ensure-Wsl2Default
if ($Preflight) { ... exit 0 }

# Non-preflight paths: elevation needed for install/uninstall.
Assert-Elevated

Ensure-WslInstalled   # may run Enable-WindowsOptionalFeature + wsl --install
Ensure-Distro ...
```

`Test-WslAvailable_Quick` is a renamed version of the current `Test-WslAvailable` that only prints a warning (does not exit 3) when `wsl.exe` is missing — the actual auto-install happens in `Ensure-WslInstalled` post-elevation.

### Parameter forwarding in `Assert-Elevated`

All current and future parameters (`-Distro`, `-RepoDir`, `-DryRun`, `-Preflight`, `-Uninstall`, `-DebugMode`, `-Agent`, `-Service`) must be reconstructed from `$PSBoundParameters`. Switch params (`[switch]`) must be serialised as bare flags when present.

### `build_command` agent forwarding (Rust)

The existing `build_command` Windows branch does not pass `-Agent`. This must be added:

```rust
if agents.len() == 1 {
    args.push("-Agent".to_string());
    args.push(agents[0].clone());
}
```

Without this, single-agent installs on Windows would still run the full `install.sh` (functional but installs both agents, which is wrong for a targeted install).

### `read_host_status` exit code contract

`read_host_status` currently interprets exit code 2 as `needs-ubuntu-firstrun` and code 3 as `needs-wsl-install`. After this change:
- Code 2 still means "needs-ubuntu-firstrun" in the context of `-Preflight` (the distro check fires before elevation, so it exits 2 if the distro is not fully set up).
- Code 3 means "wsl.exe absent and auto-install not possible" (elevation not available, or running in a context where `Enable-WindowsOptionalFeature` is unavailable). The GUI renders `HostStatusBanner` for code 3, not the reboot modal.
- `RebootRequired` is only emitted during `run_installer` / `run_uninstaller` (not during the preflight probe).

---

## Dependencies & Risks

### Risk R1: `wsl --install` behavior varies across Windows 10 builds

On some older Windows 10 builds (pre-22H2), `wsl --install` requires the optional features to already be enabled and may not accept `--no-launch`. The `Install-WslFeatures` guard (ADR-3) addresses the feature enablement. `--no-launch` must be conditionally omitted if the installed `wsl.exe` version does not support it (test via `wsl --help | Select-String no-launch`).

**Mitigation**: detect `wsl.exe` version via `wsl.exe --version` (available on modern WSL) and fall back to `wsl --install` without `--no-launch` on older builds. Log the detection result.

### Risk R2: UAC re-spawn loses GUI channel connection

When `bootstrap.ps1` re-spawns itself as an elevated process via `Start-Process -Wait`, the Tauri `Channel<InstallerEvent>` is connected to the original (non-elevated) process. The elevated child's stdout is not piped back to Rust because `Start-Process -Verb RunAs` does not support `-RedirectStandardOutput` in the same way.

**Mitigation**: The original process exits after the elevated child exits, forwarding the child's exit code (`exit $proc.ExitCode`). Rust sees a single `Terminated` event with the final exit code. Log output from the elevated child is written to `$SessionLog` (a temp file) rather than stdout. On exit code 2, Rust emits `RebootRequired`; on 0, `Finished { success: true }`. The GUI does not receive live log lines during the WSL install phase on first run — this is acceptable because WSL install is an OS-level operation with no meaningful per-step progress to show.

**If live streaming is later required**: the elevated child can write to a named pipe or a shared temp file that the unelevated parent tails. This is out of scope for this proposal.

### Risk R3: `shutdown /r /t 0` is instantaneous

`system_reboot` issues an immediate reboot. If the user has unsaved work in other applications, this will cause data loss. The modal copy must make the consequence clear; the "现在重启" button should be phrased as a destructive action (consider using a `variant="destructive"` Button per the shadcn/ui convention).

### Risk R4: `CLAW_UNINSTALL_AGENT` env var forwarding requires `CLAW_*` allow-list

`bootstrap.ps1` previously only forwarded `INSTALLER_*` vars. The `CLAW_*` allow-list extension (CAP-5) is a forward-compat decision. Any future `CLAW_*` var added by other proposals will be auto-forwarded into WSL on Windows — ensure all future `CLAW_*` vars are safe to expose inside WSL (they should be, as they are already visible to the bash scripts on Unix).

### Risk R5: `-Preflight` elevation interaction

If `Assert-Elevated` is placed before the preflight early-return, the startup status probe would trigger a UAC dialog. The implementation note above specifies the correct placement. The developer must test the preflight path on a non-elevated PowerShell session to verify no UAC dialog appears.

---

## Open Questions — Resolved 2026-05-19

**OQ-1 → Resolved: static banner.**
During the elevated re-spawn / WSL feature install (when live stdout is unavailable),
the GUI shows a static banner: "正在安装 WSL 2，请在 UAC 对话框中授权…". After the
elevated child exits, the GUI transitions to the final state (reboot modal / success
/ error) and unifies the result display. No log tailing across processes; no spinner
animation requirement.

**OQ-2 → Resolved: preflight stays read-only.**
`bootstrap.ps1 -Preflight` MUST NEVER mutate system state and MUST NEVER trigger
UAC. When the preflight probe detects WSL is missing, it returns `needs-wsl-install`
to the GUI; the GUI then guides the user to click "Install" in the normal flow,
which is the only path that may trigger `Assert-Elevated` + auto-install.

**OQ-3 → Resolved: single modal with `kind` discriminator.**
The wire event becomes `RebootRequired { kind: "wsl-feature" | "distro-firstrun" }`.
The frontend uses ONE `RebootModal` component that switches title/body/button labels
based on `kind`. Less code duplication than two separate modals; the variants share
the dismiss + primary-action plumbing.

- `kind: "wsl-feature"` — title: "需要重启 Windows"; body: "WSL 2 安装完成…"; primary: "现在重启" (destructive); secondary: "稍后".
- `kind: "distro-firstrun"` — title: "需要完成 Ubuntu 首次设置"; body: "请在弹出的 Ubuntu 窗口中设置 Linux 用户名和密码，然后重新打开安装程序。"; primary: "我已完成" (closes modal); no reboot button.
