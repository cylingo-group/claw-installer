# installer/windows/bootstrap.ps1
# Windows entry point for claw-installer. Single-source-of-truth design:
# we only do the Windows-specific bits (WSL preflight, distro check, systemd
# config, file shipment) and then hand off to the same bash installer that
# macOS / Linux / native-WSL users run.
#
# Standalone use (from the repo root):
#   powershell -ExecutionPolicy Bypass -File installer\windows\bootstrap.ps1
#
# GUI use:
#   The GUI sets $env:INSTALLER_* variables, then spawns this script. Any env
#   var starting with INSTALLER_ is forwarded into the bash invocation inside
#   WSL.
#
# Exit codes (so the GUI can branch):
#   0   success
#   2   user must reboot Windows / finish Ubuntu first-run setup, then rerun
#   3   user must take an action (install WSL from elevated terminal)
#   1   any other failure
#
# Parameters:
#   -Distro <name>      Override target WSL distro (default: Ubuntu)
#   -RepoDir <path>     Path to the installer directory containing install.sh
#                       + lib/ + steps/. Default: parent of this script
#                       (installer/), so installer\windows\bootstrap.ps1
#                       finds ..\install.sh.
#   -DryRun             Show what would happen, don't execute.
#   -DebugMode          Tail the session log to the host console in real time.
#                       (Note: use -DebugMode, not -Debug which is a PowerShell
#                        reserved common parameter.)

[CmdletBinding()]
param(
  [string]$Distro    = $(if ($env:INSTALLER_WSL_DISTRO) { $env:INSTALLER_WSL_DISTRO } else { 'Ubuntu' }),
  [string]$RepoDir   = $(if ($env:INSTALLER_REPO_DIR)  { $env:INSTALLER_REPO_DIR }  else { Split-Path -Parent $PSScriptRoot }),
  [string]$Agent     = '',    # 'openclaw' | 'hermes' | '' (all)
  [string]$Service   = '',    # 'start' | 'stop' | 'restart' | ''
  [switch]$DryRun,
  [switch]$Preflight,   # Run only preflight checks (1-3) and exit 0 if all pass
  [switch]$Uninstall,   # Run uninstall.sh instead of install.sh
  [switch]$DebugMode    # Tail the session log to stderr in real time
)

$ErrorActionPreference = 'Stop'

# =============================================================================
# Session log
# =============================================================================
$_ts = (Get-Date -Format 'yyyyMMddTHHmmssZ')
$SessionLog = [System.IO.Path]::Combine(
  [System.IO.Path]::GetTempPath(),
  'claw-installer',
  "install-$_ts.log"
)
New-Item -ItemType Directory -Force -Path (Split-Path $SessionLog) | Out-Null

# =============================================================================
# Two-stream logging primitives (PowerShell equivalents of bash primitives)
# =============================================================================

function Write-Display {
  param([string]$Msg)
  Write-Host $Msg
  Add-Content -Path $SessionLog -Value $Msg
}

function Write-Log {
  param([string]$Msg)
  Add-Content -Path $SessionLog -Value $Msg
}

function Invoke-Logged {
  param([scriptblock]$Cmd)
  & $Cmd 2>&1 | Add-Content -Path $SessionLog
}

# =============================================================================
# Legacy display helpers (kept for internal preflight messages)
# =============================================================================
function Write-Step  { param($Msg) Write-Display "[claw-installer] $Msg" }
function Write-Warn2 { param($Msg) Write-Host "[claw-installer] $Msg" -ForegroundColor Yellow; Write-Log "[claw-installer] $Msg" }
function Write-Err2  { param($Msg) Write-Host "[claw-installer] $Msg" -ForegroundColor Red;    Write-Log "[claw-installer] $Msg" }

# ---- 0. self-elevation --------------------------------------------------------
function Assert-Elevated {
  $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]$identity
  if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    return
  }
  Write-Display "需要管理员权限，正在请求 UAC 授权…"
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

# ---- 1. Windows preflight -------------------------------------------------
function Test-WindowsBuild {
  # WSL 2 needs Win10 build 19041 (2004) or higher, or any Win11. We don't
  # block — we warn. Newer builds (22H2+) get mirrored networking, which is
  # what makes WSL <-> Windows localhost feel seamless.
  $b = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber).CurrentBuildNumber
  Write-Step "Windows build: $b"
  if ($b -lt 19041) {
    Write-Err2 "Windows build $b is below 19041; WSL 2 isn't available. Update Windows first."
    exit 3
  }
  if ($b -lt 22621) {
    Write-Warn2 "Build < 22621: mirrored networking unavailable; localhost forwarding still works via legacy NAT mode."
  }
}

# ---- 2. WSL preflight -----------------------------------------------------

# Quick read-only check — does NOT exit, does NOT install.
# Used by the preflight path so UAC is never triggered.
function Test-WslAvailable_Quick {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Log "wsl.exe not found on PATH (will auto-install after elevation)."
  }
}

function Install-WslFeatures {
  $script:NeedsReboot = $false
  foreach ($feat in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
    try {
      $f = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction Stop
      if ($f.State -eq 'Disabled') {
        Write-Display "正在启用 Windows 功能：$feat …"
        if (-not $DryRun) {
          $r = Enable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart -ErrorAction Stop
          if ($r.RestartNeeded) { $script:NeedsReboot = $true }
        }
      }
    } catch {
      Write-Err2 "启用 Windows 功能时出错：$feat — $_"
      Write-Host "  请从管理员 PowerShell 手动运行："
      Write-Host "    wsl --install" -ForegroundColor Yellow
      exit 3
    }
  }
}

function Ensure-WslInstalled {
  if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    Write-Step "wsl.exe found on PATH."
    return
  }
  Write-Display "未检测到 WSL，正在自动安装…"
  Install-WslFeatures
  # Detect whether --no-launch is supported (requires modern WSL).
  $noLaunchFlag = ''
  try {
    $helpOut = & wsl.exe --help 2>&1
    if ($helpOut -match 'no-launch') { $noLaunchFlag = '--no-launch' }
  } catch { }
  Write-Log "Running: wsl.exe --install $noLaunchFlag -d $Distro"
  if (-not $DryRun) {
    try {
      $out = & wsl.exe --install $noLaunchFlag -d $Distro 2>&1
      Write-Log $out
      if ($out -match 'restart|reboot') { $script:NeedsReboot = $true }
    } catch {
      Write-Err2 "wsl --install 失败：$_"
      Write-Host "  请从管理员 PowerShell 手动运行："
      Write-Host "    wsl --install" -ForegroundColor Yellow
      exit 3
    }
  }
  if ($script:NeedsReboot) {
    Write-Display "WSL 安装完成，需要重启 Windows 才能继续。"
    Write-Host "@@reboot:wsl-feature"
    exit 2
  }
}

function Get-DistroVersion {
  param([string]$Name)
  # Returns 1 or 2 (WSL version of the named distro) or 0 if not installed.
  # `wsl --list --verbose` columns: "  NAME    STATE    VERSION".
  $prev = [Console]::OutputEncoding
  [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
  try {
    $raw = (wsl.exe --list --verbose 2>$null) -join "`n"
    $raw = $raw -replace "`0", ''
    $escaped = [regex]::Escape($Name)
    foreach ($line in ($raw -split "`r?`n")) {
      if ($line -match "^\s*\*?\s*$escaped\s+\S+\s+(\d+)\s*$") {
        return [int]$Matches[1]
      }
    }
    return 0
  } finally { [Console]::OutputEncoding = $prev }
}

function Test-DistroInstalled {
  param([string]$Name)
  # wsl.exe emits UTF-16LE; some Win 10 builds also interleave NUL bytes
  # into --list --quiet output. Force Unicode decoding and strip stray NULs
  # before splitting so a distro name match is reliable.
  $prev = [Console]::OutputEncoding
  [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
  try {
    $raw = (wsl.exe --list --quiet 2>$null) -join "`n"
    $raw = $raw -replace "`0", ''
    $list = $raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return ($list -contains $Name)
  } finally { [Console]::OutputEncoding = $prev }
}

function Ensure-Distro {
  param([string]$Name)
  if (Test-DistroInstalled -Name $Name) {
    Write-Step "WSL distro '$Name' present."
    return
  }
  Write-Display "WSL 发行版 '$Name' 未安装，正在自动安装…"
  if (-not $DryRun) {
    try {
      $out = & wsl.exe --install -d $Name --no-launch 2>&1
      Write-Log $out
    } catch {
      Write-Err2 "wsl --install -d $Name 失败：$_"
    }
  }
  Write-Display "发行版安装完成。请在弹出的 Ubuntu 窗口中完成用户名/密码设置，然后重新运行安装程序。"
  Write-Host "@@reboot:distro-firstrun"
  exit 2
}

# Make sure new distros default to WSL 2 (cheap, idempotent).
function Ensure-Wsl2Default {
  if ($DryRun) { Write-Host "  [dry-run] wsl --set-default-version 2"; return }
  & wsl.exe --set-default-version 2 2>&1 | Out-Null
}

# ---- 3. systemd in WSL distro ---------------------------------------------
function Ensure-Systemd {
  param([string]$Name)
  # /etc/wsl.conf is per-distro, not global. We write a minimal block; if the
  # user has other settings we leave them alone (rewriting only [boot]).
  $script = @'
set -e
conf=/etc/wsl.conf
if [ -f "$conf" ] && grep -qE '^systemd=true' "$conf"; then
  echo "systemd already enabled"
  exit 0
fi
tmp=$(mktemp)
if [ -f "$conf" ]; then
  awk '
    /^\[boot\]/ {in_boot=1; print; print "systemd=true"; next}
    /^\[/ {in_boot=0; print; next}
    in_boot && /^systemd=/ {next}
    {print}
  ' "$conf" > "$tmp"
  if ! grep -q '^\[boot\]' "$conf"; then
    printf '\n[boot]\nsystemd=true\n' >> "$tmp"
  fi
else
  printf '[boot]\nsystemd=true\n' > "$tmp"
fi
mv "$tmp" "$conf"
echo "systemd=true written to $conf"
'@
  Write-Step "Ensuring systemd is enabled in distro '$Name' (/etc/wsl.conf)"
  if ($DryRun) { Write-Host "  [dry-run] wsl -d $Name -u root -- bash -c <write /etc/wsl.conf>"; return $false }
  $out = & wsl.exe -d $Name -u root -- bash -c $script 2>&1
  Write-Host "  $out"
  $changed = $out -match 'systemd=true written'
  if ($changed) {
    Write-Step "wsl --shutdown to apply systemd"
    & wsl.exe --shutdown
    Start-Sleep -Seconds 2
  }
  return $changed
}

# ---- 4. ship installer files into the distro ------------------------------
function Copy-RepoIntoWsl {
  param([string]$Name, [string]$LocalPath)

  if (-not (Test-Path (Join-Path $LocalPath 'install.sh'))) {
    Write-Err2 "Expected install.sh not found in $LocalPath"
    Write-Host "  Override with -RepoDir <path> or set `$env:INSTALLER_REPO_DIR."
    exit 1
  }
  if (-not (Test-Path (Join-Path $LocalPath 'agents'))) {
    Write-Err2 "Expected agents/ directory not found in $LocalPath"
    exit 1
  }
  # Translate Windows path → WSL /mnt path so the distro can read it directly.
  $wslSrc = (& wsl.exe -d $Name -- wslpath -a "$LocalPath" 2>$null).Trim()
  if (-not $wslSrc) {
    Write-Err2 "Could not translate $LocalPath via wslpath."
    exit 1
  }
  Write-Step "Copying installer to WSL: $wslSrc → ~/claw-installer-src/"
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
  if ($DryRun) { Write-Host "  [dry-run] copy via bash heredoc"; return '$HOME/claw-installer-src' }
  $out = & wsl.exe -d $Name -- bash -c $cp 2>&1
  Write-Host "  $out"
  return '$HOME/claw-installer-src'
}

# ---- 5. forward INSTALLER_* env vars + run install.sh ---------------------
function Invoke-BashInstaller {
  param([string]$Name, [string]$DestDir)

  # Compute a Linux-compatible session log path inside WSL and pass it to bash.
  # We use /tmp/claw-installer/ inside WSL (not the Windows $SessionLog path).
  $_lts = (Get-Date -Format 'yyyyMMddTHHmmssZ')
  $wslSessionLog = "/tmp/claw-installer/install-$_lts.log"

  $entryPoint = if ($Agent) { "./agents/$Agent/install.sh" } else { "./install.sh" }

  $forward = @()
  Get-ChildItem env: | Where-Object {
    ($_.Name -like 'INSTALLER_*' -or $_.Name -like 'CLAW_*') -and
    $_.Name -ne 'INSTALLER_REPO_DIR' -and
    $_.Name -ne 'INSTALLER_WSL_DISTRO' -and
    $_.Name -ne 'CLAW_SESSION_LOG'
  } | ForEach-Object {
    # Single-quote escape: ' → '\''
    $v = $_.Value -replace "'", "'\''"
    $forward += ("export {0}='{1}'" -f $_.Name, $v)
  }
  # Always forward CLAW_SESSION_LOG so bash scripts append to the same log.
  $forward += "export CLAW_SESSION_LOG='$wslSessionLog'"
  $envBlock = $forward -join "`n"

  $debugFlag = if ($DebugMode) { '--debug' } else { '' }
  $script = @"
set -e
$envBlock
mkdir -p "`$(dirname '$wslSessionLog')"
cd "$DestDir"
$entryPoint $debugFlag
"@
  Write-Display "正在 WSL（$Name）中运行安装程序…"
  Write-Log "Session log (inside WSL): $wslSessionLog"
  if ($forward.Count -gt 0) {
    Write-Log "Forwarding env vars:"
    $forward | ForEach-Object { Write-Log ("  " + ($_ -replace '^export ', '')) }
  }
  if ($DryRun) { Write-Host "  [dry-run] wsl -d $Name -- bash -lc <run installer>"; return 0 }

  if ($DebugMode) {
    Write-Display "日志文件（WSL 内）：$wslSessionLog"
  }

  & wsl.exe -d $Name -- bash -lc $script
  return $LASTEXITCODE
}

# ---- 6. run uninstall.sh (mirrors Invoke-BashInstaller) -------------------
function Invoke-BashUninstaller {
  param([string]$Name, [string]$DestDir)

  $_lts = (Get-Date -Format 'yyyyMMddTHHmmssZ')
  $wslSessionLog = "/tmp/claw-installer/uninstall-$_lts.log"

  $forward = @()
  Get-ChildItem env: | Where-Object {
    ($_.Name -like 'INSTALLER_*' -or $_.Name -like 'CLAW_*') -and
    $_.Name -ne 'INSTALLER_REPO_DIR' -and
    $_.Name -ne 'INSTALLER_WSL_DISTRO' -and
    $_.Name -ne 'CLAW_SESSION_LOG'
  } | ForEach-Object {
    $v = $_.Value -replace "'", "'\''"
    $forward += ("export {0}='{1}'" -f $_.Name, $v)
  }
  $forward += "export CLAW_SESSION_LOG='$wslSessionLog'"
  $envBlock = $forward -join "`n"

  $debugFlag = if ($DebugMode) { '--debug' } else { '' }
  $script = @"
set -e
$envBlock
mkdir -p "`$(dirname '$wslSessionLog')"
cd "$DestDir"
./uninstall.sh --yes $debugFlag
"@
  Write-Display "正在 WSL（$Name）中运行卸载程序…"
  Write-Log "Session log (inside WSL): $wslSessionLog"
  if ($DryRun) { Write-Host "  [dry-run] wsl -d $Name -- bash -lc <run uninstaller>"; return 0 }

  & wsl.exe -d $Name -- bash -lc $script
  return $LASTEXITCODE
}

# ---- 7. run a service lifecycle action (start/stop/restart) ---------------
function Invoke-BashService {
  param([string]$Name, [string]$DestDir, [string]$AgentName, [string]$ServiceAction)

  switch ($AgentName) {
    { $_ -notin @('openclaw', 'hermes') } {
      Write-Err2 "Unknown agent '$AgentName'. Must be 'openclaw' or 'hermes'."
      exit 1
    }
  }
  switch ($ServiceAction) {
    { $_ -notin @('start', 'stop', 'restart') } {
      Write-Err2 "Unknown service action '$ServiceAction'. Must be 'start', 'stop', or 'restart'."
      exit 1
    }
  }

  $_lts = (Get-Date -Format 'yyyyMMddTHHmmssZ')
  $wslSessionLog = "/tmp/claw-installer/$ServiceAction-$AgentName-$_lts.log"

  $forward = @()
  Get-ChildItem env: | Where-Object {
    ($_.Name -like 'INSTALLER_*' -or $_.Name -like 'CLAW_*') -and
    $_.Name -ne 'INSTALLER_REPO_DIR' -and
    $_.Name -ne 'INSTALLER_WSL_DISTRO' -and
    $_.Name -ne 'CLAW_SESSION_LOG'
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

# ---- main -----------------------------------------------------------------

# -DebugMode: start background job to tail session log to host console.
$DebugJob = $null
if ($DebugMode) {
  Write-Display "日志文件：$SessionLog"
  # Start a job that tails the Windows-side log (if the bash side writes to it).
  # Note: bash logs to the WSL-internal path; the Windows session log captures
  # PowerShell-side output only.
  $DebugJob = Start-Job -ScriptBlock {
    param($Path)
    Get-Content -Wait -Path $Path 2>$null
  } -ArgumentList $SessionLog
}

try {
  Write-Host ""
  Write-Step "claw-installer Windows bootstrap (distro=$Distro, repo=$RepoDir)"
  Write-Host ""

  # Preflight order per spec Implementation Notes:
  #   1. Build check (exits 3 if too old)
  #   2. Quick WSL check — read-only, never triggers UAC
  #   3. Set WSL 2 as default (idempotent)
  #   4. Preflight early-return — no UAC prompt for probes
  # Non-preflight only (below early-return):
  #   5. Assert-Elevated — request UAC if needed
  #   6. Ensure-WslInstalled — auto-install if absent (may exit 2)
  #   7. Ensure-Distro — auto-install distro if absent (may exit 2)

  Test-WindowsBuild
  Test-WslAvailable_Quick
  Ensure-Wsl2Default

  $wslPresent = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
  $distroPresent = $wslPresent -and (Test-DistroInstalled -Name $Distro)

  if ($wslPresent -and $distroPresent) {
    $ver = Get-DistroVersion -Name $Distro
    if ($ver -ne 2) {
      Write-Err2 "Distro '$Distro' is running on WSL version $ver (need 2)."
      Write-Host "  Convert with:"
      Write-Host "    wsl --set-version $Distro 2" -ForegroundColor Yellow
      Write-Host "  (may take several minutes; needs the WSL 2 kernel update from https://aka.ms/wsl2kernel)"
      exit 3
    }
    Write-Step "Distro '$Distro' is WSL 2."
  }

  # -Preflight exits here — all checks that are safe to run without elevation.
  if ($Preflight) {
    if (-not $wslPresent) {
      Write-Host "@@reboot:wsl-feature"
      exit 3
    }
    if (-not $distroPresent) {
      Write-Host "@@reboot:distro-firstrun"
      exit 2
    }
    Write-Step "Preflight checks passed."
    exit 0
  }

  # Non-preflight paths require elevation (install, uninstall, service).
  Assert-Elevated

  Ensure-WslInstalled
  Ensure-Distro -Name $Distro

  if ($Agent -and $Agent -notin @('openclaw', 'hermes')) {
    Write-Err2 "Unknown agent '$Agent'. Must be 'openclaw' or 'hermes'."
    exit 1
  }

  $null = Ensure-Systemd -Name $Distro
  $destInWsl = Copy-RepoIntoWsl -Name $Distro -LocalPath $RepoDir

  # -Service dispatch: run a lifecycle action for a specific agent.
  if ($Service -and $Agent) {
    $rc = Invoke-BashService -Name $Distro -DestDir $destInWsl -AgentName $Agent -ServiceAction $Service
    exit $rc
  }

  # -Uninstall runs uninstall.sh instead of install.sh.
  if ($Uninstall) {
    $rc = Invoke-BashUninstaller -Name $Distro -DestDir $destInWsl
  } else {
    $rc = Invoke-BashInstaller -Name $Distro -DestDir $destInWsl
  }

  Write-Host ""
  if ($rc -eq 0) {
    Write-Display "✓ 安装完成"
    Write-Log "From this Windows host:"
    Write-Log "  • Open http://localhost:18789/ — WSL 2 forwards localhost to the gateway"
    Write-Log "  • Browse install state at: \\wsl.localhost\$Distro\home\<user>\.claw-installer\"
    Write-Log "  • Re-run safely; the manifest is idempotent"
    Write-Log "  • Uninstall: wsl -d $Distro -- bash -lc 'cd ~/claw-installer-src && ./uninstall.sh'"
    exit 0
  } else {
    Write-Err2 "Bash installer returned exit code $rc."
    Write-Log "  Inspect the install log inside WSL:"
    Write-Log "    wsl -d $Distro -- ls -la `$HOME/.claw-installer/"
    exit $rc
  }
} finally {
  # Stop the debug tailing job on script exit (success or failure).
  if ($null -ne $DebugJob) {
    Stop-Job -Job $DebugJob -ErrorAction SilentlyContinue
    Remove-Job -Job $DebugJob -ErrorAction SilentlyContinue
  }
}
