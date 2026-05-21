# debug-install-wsl.ps1
# Standalone WSL installer + diagnostic dump. Runs independently of the
# claw-installer GUI / bootstrap.ps1 so you can isolate whether the WSL
# install itself is the failing component.
#
# USAGE (in an Administrator PowerShell window):
#   powershell -ExecutionPolicy Bypass -File debug-install-wsl.ps1
#
# Or to skip the actual install and only print diagnostics:
#   powershell -ExecutionPolicy Bypass -File debug-install-wsl.ps1 -DiagnoseOnly
#
# Output is saved to debug-install-wsl.log next to the script so you can
# paste it back in one go.

[CmdletBinding()]
param(
  [switch]$DiagnoseOnly,
  [string]$Distro = 'Ubuntu'
)

$ErrorActionPreference = 'Continue'   # we want to SEE errors, not abort on them

# Force UTF-8 so Chinese error messages from wsl.exe don't mojibake.
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding           = [System.Text.Encoding]::UTF8
  chcp 65001 | Out-Null
} catch { }

$LogPath = Join-Path $PSScriptRoot 'debug-install-wsl.log'
"" | Set-Content -Path $LogPath -Encoding UTF8

function Log {
  param([string]$Msg)
  Write-Host $Msg
  Add-Content -Path $LogPath -Value $Msg -Encoding UTF8
}

function Section {
  param([string]$Title)
  Log ""
  Log "=========================================================================="
  Log "  $Title"
  Log "=========================================================================="
}

function Capture {
  param([string]$Label, [scriptblock]$Cmd)
  Log ""
  Log "-- $Label --"
  try {
    $out = & $Cmd 2>&1 | Out-String
    Log $out.TrimEnd()
  } catch {
    Log "[error] $($_.Exception.Message)"
  }
}

Section "0. Elevation & environment"

$identity   = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal  = [Security.Principal.WindowsPrincipal]$identity
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log "Elevated:        $isElevated"
Log "PSVersion:       $($PSVersionTable.PSVersion)"
Log "PSEdition:       $($PSVersionTable.PSEdition)"
Log "OS:              $([System.Environment]::OSVersion.VersionString)"
$build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber).CurrentBuildNumber
Log "Windows build:   $build"
$displayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
Log "DisplayVersion:  $displayVersion"

if (-not $isElevated) {
  Log ""
  Log "[!] This script needs an ADMIN PowerShell window to install WSL."
  Log "    Diagnostics will still run, but the install step will be skipped."
  Log "    Right-click PowerShell → 'Run as administrator' and re-run."
}

Section "1. CPU virtualization (firmware-level VT-x / SVM)"

Capture "Win32_Processor (VirtualizationFirmwareEnabled / SLAT)" {
  Get-CimInstance Win32_Processor |
    Select-Object Name, NumberOfCores, NumberOfLogicalProcessors,
                  VirtualizationFirmwareEnabled,
                  SecondLevelAddressTranslationExtensions |
    Format-List
}

Capture "systeminfo (Hyper-V Requirements block)" {
  systeminfo | Select-String -Pattern 'Hyper-V|Virtualization|VM Monitor|Second Level'
}

Section "2. Windows optional features (must both be Enabled for WSL 2)"

Capture "Microsoft-Windows-Subsystem-Linux" {
  Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux |
    Select-Object FeatureName, State | Format-List
}

Capture "VirtualMachinePlatform" {
  Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform |
    Select-Object FeatureName, State | Format-List
}

Capture "HypervisorPlatform (HVCI / VBS dependency)" {
  Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction SilentlyContinue |
    Select-Object FeatureName, State | Format-List
}

Section "3. Hypervisor launch type (must be Auto for WSL 2)"

Capture "bcdedit hypervisorlaunchtype" {
  bcdedit /enum | Select-String -Pattern 'hypervisorlaunchtype|description'
}

Section "4. WSL.exe presence + version"

$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
if ($wslCmd) {
  Log "wsl.exe path:    $($wslCmd.Source)"
} else {
  Log "wsl.exe path:    <not found on PATH>"
}

Capture "wsl --version" { wsl --version }
Capture "wsl --status"  { wsl --status }
Capture "wsl -l -v"     { wsl -l -v }
Capture "wsl --help (web-download support?)" {
  $h = (wsl --help 2>&1 | Out-String)
  if ($h -match 'web-download') {
    "Supports --web-download flag: YES"
  } else {
    "Supports --web-download flag: NO  (wsl.exe is older than 2.0.6)"
  }
}

if ($DiagnoseOnly) {
  Section "DONE (diagnose-only mode)"
  Log ""
  Log "Diagnostics written to: $LogPath"
  Log "Paste the contents back to the developer."
  exit 0
}

if (-not $isElevated) {
  Section "SKIPPED install (not elevated)"
  Log "Diagnostics written to: $LogPath"
  exit 0
}

Section "5. Attempting wsl --install -d $Distro --no-launch (full stdout/stderr)"

# Use --web-download if available, --no-launch to skip first-boot UX.
$wslArgs = @('--install', '-d', $Distro, '--no-launch')
if ((wsl --help 2>&1 | Out-String) -match 'web-download') {
  $wslArgs += '--web-download'
}
Log "Command:  wsl.exe $($wslArgs -join ' ')"
Log ""

# Hold WSL_UTF8=1 so wsl.exe's own output is UTF-8 (not UTF-16LE) — avoids
# mojibake in the log file.
$env:WSL_UTF8 = '1'

# Run in-process so we see the live output. Capture exit code separately.
$stdoutPath = Join-Path $env:TEMP "wsl-install-stdout-$PID.txt"
$stderrPath = Join-Path $env:TEMP "wsl-install-stderr-$PID.txt"
$proc = Start-Process -FilePath wsl.exe -ArgumentList $wslArgs `
                      -NoNewWindow -Wait -PassThru `
                      -RedirectStandardOutput $stdoutPath `
                      -RedirectStandardError  $stderrPath
$exit = $proc.ExitCode

$stdout = Get-Content -Raw -Path $stdoutPath -ErrorAction SilentlyContinue
$stderr = Get-Content -Raw -Path $stderrPath -ErrorAction SilentlyContinue
Remove-Item $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

Log "Exit code: $exit"
Log ""
Log "-- stdout --"
if ($stdout) { Log $stdout.TrimEnd() } else { Log "<empty>" }
Log ""
Log "-- stderr --"
if ($stderr) { Log $stderr.TrimEnd() } else { Log "<empty>" }

Section "VERDICT"

if ($exit -eq 0) {
  Log "wsl --install reported SUCCESS. You may still need to reboot before the"
  Log "distro can be launched. After reboot run:  wsl -d $Distro -u root -- /bin/true"
} else {
  $combined = "$stdout`n$stderr"
  Log ""
  Log "Decoding the error code(s) we found:"
  if ($combined -match 'HCS_E_HYPERV_NOT_INSTALLED') {
    Log "  • HCS_E_HYPERV_NOT_INSTALLED"
    Log "    => Hyper-V Host Compute Service can't create a VM. Possible causes,"
    Log "       in order of likelihood given the Section 1-3 outputs above:"
    Log "         (a) VirtualMachinePlatform feature is Disabled (Section 2)"
    Log "         (b) hypervisorlaunchtype is not Auto         (Section 3)"
    Log "         (c) BIOS / UEFI VT-x or AMD SVM is off       (Section 1)"
    Log "         (d) VBS / Memory Integrity is grabbing it    (advanced)"
  }
  if ($combined -match 'enablevirtualization') {
    Log "  • aka.ms/enablevirtualization referenced — same family as HCS_E_HYPERV_NOT_INSTALLED"
  }
  if ($combined -match 'WSL_E_') {
    Log "  • One or more WSL_E_* error codes — check stderr above for the exact one"
  }
  if ($combined -match '0x80370102') {
    Log "  • 0x80370102 — hypervisor isn't running. Usually fixed by:"
    Log "      bcdedit /set hypervisorlaunchtype auto   (then reboot)"
  }
  Log ""
  Log "Full diagnostics + raw command output written to:"
  Log "  $LogPath"
  Log ""
  Log "Paste the entire log file back to the developer for triage."
}

exit $exit
