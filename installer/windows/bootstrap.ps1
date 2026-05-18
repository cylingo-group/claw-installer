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

[CmdletBinding()]
param(
  [string]$Distro    = $(if ($env:INSTALLER_WSL_DISTRO) { $env:INSTALLER_WSL_DISTRO } else { 'Ubuntu' }),
  [string]$RepoDir   = $(if ($env:INSTALLER_REPO_DIR)  { $env:INSTALLER_REPO_DIR }  else { Split-Path -Parent $PSScriptRoot }),
  [switch]$DryRun,
  [switch]$Preflight,  # NEW: run only preflight checks (1-3) and exit 0 if all pass
  [switch]$Uninstall   # NEW: run uninstall.sh instead of install.sh
)

$ErrorActionPreference = 'Stop'

function Write-Step  { param($Msg) Write-Host "[claw-installer] $Msg" -ForegroundColor Cyan }
function Write-Warn2 { param($Msg) Write-Host "[claw-installer] $Msg" -ForegroundColor Yellow }
function Write-Err2  { param($Msg) Write-Host "[claw-installer] $Msg" -ForegroundColor Red }

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
function Test-WslAvailable {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Err2 "wsl.exe not found on PATH. Run from an elevated PowerShell:"
    Write-Host "    wsl --install" -ForegroundColor Yellow
    Write-Host "  Reboot when prompted, finish the Ubuntu first-run setup, then rerun this script."
    exit 3
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
  Write-Warn2 "WSL distro '$Name' not installed."
  Write-Host  "  Run from an elevated PowerShell:"
  Write-Host  "    wsl --install -d $Name" -ForegroundColor Yellow
  Write-Host  "  Complete the Ubuntu first-run setup (create a Linux username/password)"
  Write-Host  "  in the window that appears, then rerun this script."
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
  # Translate Windows path → WSL /mnt path so the distro can read it directly.
  # Avoids an extra cp from /mnt; we cp inside WSL so file mode + line endings
  # land on ext4 (faster) instead of staying on the 9p mount.
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
cp -R "$wslSrc/install.sh" "$wslSrc/install-openclaw.sh" "$wslSrc/install-hermes.sh" "$wslSrc/uninstall.sh" "`$dest/"
cp -R "$wslSrc/lib"   "`$dest/"
cp -R "$wslSrc/steps" "`$dest/"
if [ -d "$wslSrc/vendor" ]; then cp -R "$wslSrc/vendor" "`$dest/"; fi
chmod +x "`$dest"/*.sh "`$dest"/steps/*.sh 2>/dev/null || true
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

  $forward = @()
  Get-ChildItem env: | Where-Object { $_.Name -like 'INSTALLER_*' -and $_.Name -ne 'INSTALLER_REPO_DIR' -and $_.Name -ne 'INSTALLER_WSL_DISTRO' } | ForEach-Object {
    # Single-quote escape: ' → '\''
    $v = $_.Value -replace "'", "'\''"
    $forward += ("export {0}='{1}'" -f $_.Name, $v)
  }
  $envBlock = $forward -join "`n"

  $script = @"
set -e
$envBlock
cd "$DestDir"
./install.sh
"@
  Write-Step "Running ./install.sh inside WSL distro '$Name'"
  if ($forward.Count -gt 0) {
    Write-Host "  Forwarding env vars:"
    $forward | ForEach-Object { Write-Host ("    " + ($_ -replace '^export ', '')) }
  }
  if ($DryRun) { Write-Host "  [dry-run] wsl -d $Name -- bash -lc <run installer>"; return 0 }

  & wsl.exe -d $Name -- bash -lc $script
  return $LASTEXITCODE
}

# ---- 6. run uninstall.sh (mirrors Invoke-BashInstaller) -------------------
function Invoke-BashUninstaller {
  param([string]$Name, [string]$DestDir)

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

# ---- main -----------------------------------------------------------------
Write-Host ""
Write-Step "claw-installer Windows bootstrap (distro=$Distro, repo=$RepoDir)"
Write-Host ""

Test-WindowsBuild
Test-WslAvailable
Ensure-Wsl2Default
Ensure-Distro -Name $Distro

$ver = Get-DistroVersion -Name $Distro
if ($ver -ne 2) {
  Write-Err2 "Distro '$Distro' is running on WSL version $ver (need 2)."
  Write-Host "  Convert with:"
  Write-Host "    wsl --set-version $Distro 2" -ForegroundColor Yellow
  Write-Host "  (may take several minutes; needs the WSL 2 kernel update from https://aka.ms/wsl2kernel)"
  exit 3
}
Write-Step "Distro '$Distro' is WSL 2."

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

Write-Host ""
if ($rc -eq 0) {
  Write-Step "Install finished. From this Windows host:"
  Write-Host  "  • Open http://localhost:18789/ — WSL 2 forwards localhost to the gateway"
  Write-Host  "  • Browse install state at: \\wsl.localhost\$Distro\home\<user>\.claw-installer\"
  Write-Host  "  • Re-run safely; the manifest is idempotent"
  Write-Host  "  • Uninstall: wsl -d $Distro -- bash -lc 'cd ~/claw-installer-src && ./uninstall.sh'"
  exit 0
} else {
  Write-Err2 "Bash installer returned exit code $rc."
  Write-Host  "  Inspect the install log inside WSL:"
  Write-Host  "    wsl -d $Distro -- ls -la `$HOME/.claw-installer/"
  exit $rc
}
