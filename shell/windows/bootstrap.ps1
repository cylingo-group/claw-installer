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
  # IMPORTANT: do NOT default this to `Split-Path -Parent $PSScriptRoot` directly
  # in the param block. Windows PowerShell 5.1 evaluates param default expressions
  # *before* $PSScriptRoot is populated, so when the user runs the script via
  # `powershell -File <path>` without setting $env:INSTALLER_REPO_DIR, Split-Path
  # gets an empty string and the script aborts at line 1. We resolve the default
  # below, in the script body, where $PSScriptRoot is reliable.
  [string]$RepoDir   = '',
  [string]$Agent     = '',    # 'openclaw' | 'hermes' | '' (all)
  [string]$Service   = '',    # 'start' | 'stop' | 'restart' | ''
  # Path to the shared session log file. The non-elevated parent and the UAC-
  # elevated child must write to the SAME file so the parent's tail-loop can
  # forward the child's Write-Display lines back to Tauri. process-scoped env
  # vars don't survive ShellExecuteEx runas, so Assert-Elevated explicitly
  # passes this as an argument instead of relying on $env:CLAW_SESSION_LOG.
  [string]$SessionLogPath = '',
  [switch]$DryRun,
  [switch]$Preflight,      # Run only preflight checks (1-3) and exit 0 if all pass
  [switch]$Uninstall,      # Run uninstall.sh instead of install.sh
  [switch]$InstallWslOnly, # Only install WSL features + target distro, then exit
  [switch]$DebugMode       # Tail the session log to stderr in real time
)

$ErrorActionPreference = 'Stop'

if (-not $RepoDir) {
  if ($env:INSTALLER_REPO_DIR) {
    $RepoDir = $env:INSTALLER_REPO_DIR
  } else {
    $RepoDir = Split-Path -Parent $PSScriptRoot
  }
}

# =============================================================================
# Force UTF-8 for stdout/stderr the GUI captures
# =============================================================================
# Tauri reads our stdout as UTF-8 (String::from_utf8_lossy). PowerShell 5.1 by
# default uses the system ANSI codepage for [Console]::OutputEncoding, so
# Chinese display strings become mojibake (U+FFFD…) on the GUI side.
# Forcing UTF-8 here is independent of script-source encoding (the BOM at the
# top handles that — see commit history if you find this file mysteriously
# rewritten without one).
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
  # Older PS hosts may reject this — non-fatal, garbled output is a UX bug
  # not a correctness bug.
}

# =============================================================================
# Session log
# =============================================================================
# Two roles for this file:
#   1. Operator-facing transcript (everything written via Write-Display lands here).
#   2. Cross-elevation progress bridge — when Assert-Elevated self-elevates via
#      Start-Process -Verb RunAs, the elevated child's stdout cannot pipe back
#      to the non-elevated parent (Windows security boundary). We instead have
#      both processes share this file path: the elevated child appends progress
#      lines via Write-Display, and the parent tails the file in real time,
#      forwarding new bytes to its own stdout — which Tauri *can* capture.
#
# The GUI (Rust side) computes the path and passes it via CLAW_SESSION_LOG so
# the GUI's "完整日志：<path>" UI points at the same file the script writes.
# If unset (manual CLI invocation), mint one. Either way, *write the resolved
# value back into the env var* so elevated children inherit the same path.
if ($SessionLogPath) {
  # Explicit -SessionLogPath wins (used by Assert-Elevated when re-spawning
  # under UAC, since runas does not inherit env vars).
  $env:CLAW_SESSION_LOG = $SessionLogPath
}
if (-not $env:CLAW_SESSION_LOG) {
  $_ts = (Get-Date -Format 'yyyyMMddTHHmmssZ')
  $env:CLAW_SESSION_LOG = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(),
    'claw-installer',
    "install-$_ts.log"
  )
}
$SessionLog = $env:CLAW_SESSION_LOG
New-Item -ItemType Directory -Force -Path (Split-Path $SessionLog) | Out-Null
# Touch the file now so the parent's tail loop has something to attach to
# immediately (Get-Content -Wait can't track a path that doesn't exist yet
# without a polling delay).
if (-not (Test-Path $SessionLog)) {
  [System.IO.File]::WriteAllBytes($SessionLog, @())
}

# =============================================================================
# Two-stream logging primitives (PowerShell equivalents of bash primitives)
# =============================================================================

# UTF-8 without BOM. Add-Content's default is the system ANSI codepage
# (CP936 on Chinese Windows), which would mojibake when the parent's file-tail
# forwards bytes to Tauri (decoded as UTF-8). Use .NET's AppendAllText with an
# explicit UTF8Encoding($false) to keep encoding consistent across the wire.
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Append a UTF-8 (no-BOM) line to the session log.
#
# `[System.IO.File]::AppendAllText` (the obvious one-liner) opens with
# FileShare=None, which races against the parent's Forward-SessionLogTail
# reader: every ~250ms the parent opens the file for reading, and any concurrent
# write from this side fails with IOException. With $ErrorActionPreference='Stop'
# that IOException becomes terminating and gets swallowed by the outer catch,
# which then exits 1 — masking the real failure that the script was about to
# exit cleanly with (e.g. firmware-virt exit 5 from Show-FirmwareVirtualizationHelp,
# which writes 10+ lines in rapid succession and is *very* likely to lose a race).
#
# Open the file ourselves with FileShare.ReadWrite so the reader can coexist,
# and retry briefly on the (now rare) IOException from antivirus or indexer
# scans that grab the file momentarily.
function Append-Utf8 {
  param([string]$Path, [string]$Text)
  $bytes = $script:Utf8NoBom.GetBytes($Text)
  $attempts = 0
  while ($true) {
    try {
      $fs = New-Object System.IO.FileStream(
        $Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite)
      try {
        $fs.Write($bytes, 0, $bytes.Length)
      } finally {
        $fs.Dispose()
      }
      return
    } catch [System.IO.IOException] {
      $attempts++
      if ($attempts -ge 5) { throw }
      Start-Sleep -Milliseconds 50
    }
  }
}

function Write-Display {
  param([string]$Msg)
  Write-Host $Msg
  Append-Utf8 $SessionLog ("{0}`r`n" -f $Msg)
}

# Debug-only line — goes to the session log file but is tagged with a [debug]
# prefix so the GUI can filter it out of the progress display. (Operator-facing
# lines go through Write-Display / Write-Step instead.)
function Write-Log {
  param([string]$Msg)
  Append-Utf8 $SessionLog ("[debug] {0}`r`n" -f $Msg)
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

# When self-elevating with Start-Process -Verb RunAs, the elevated child gets its
# own console; its stdout is not captured by the original (non-elevated) parent.
# So if the child wants to emit `@@reboot:<kind>` for the GUI, it must also write
# the kind to a shared marker file that the parent reads after the child exits.
function Emit-RebootSentinel {
  param([string]$Kind)
  Write-Host "@@reboot:$Kind"
  if ($env:CLAW_REBOOT_MARKER) {
    try {
      $dir = Split-Path -Parent $env:CLAW_REBOOT_MARKER
      if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      Set-Content -Path $env:CLAW_REBOOT_MARKER -Value $Kind -Encoding ASCII
    } catch {
      Write-Log "Failed to write reboot marker $($env:CLAW_REBOOT_MARKER): $_"
    }
  }
}

# Tail $SessionLog: read any bytes appended since the offset in $LastSize and
# write them to our stdout (which Tauri's spawn captures). $LastSize is taken
# by reference so the caller can poll in a loop without losing state.
#
# The file is shared between the (non-elevated) parent and the (elevated)
# child — both write via Write-Display / Add-Content. We never write here, we
# only read.
function Forward-SessionLogTail {
  param([ref]$LastSize)
  if (-not (Test-Path $SessionLog)) { return }
  $current = (Get-Item $SessionLog).Length
  if ($current -le $LastSize.Value) { return }
  try {
    $fs = [System.IO.File]::Open($SessionLog, 'Open', 'Read', 'ReadWrite')
    try {
      $fs.Position = $LastSize.Value
      $count = [int]($current - $LastSize.Value)
      $buf = New-Object byte[] $count
      $read = $fs.Read($buf, 0, $count)
      if ($read -gt 0) {
        # Add-Content writes UTF-8 (with optional BOM on creation). Decode as
        # UTF-8; stray non-UTF-8 bytes are tolerated by the lossy decoder.
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        # Write-Host without -NoNewline would inject extra newlines. Use raw
        # console write to preserve the on-disk byte layout.
        [Console]::Out.Write($text)
        [Console]::Out.Flush()
      }
    } finally {
      $fs.Dispose()
    }
    $LastSize.Value = $current
  } catch {
    Write-Log "Forward-SessionLogTail: read failed: $_"
  }
}

function Assert-Elevated {
  $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]$identity
  if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    return
  }
  Write-Display "需要管理员权限，正在请求 UAC 授权…"

  # Allocate a marker file the elevated child will write its reboot kind into,
  # so we can re-emit the @@reboot:<kind> sentinel from the parent (which IS
  # captured by Tauri) after the elevated process exits.
  $markerFile = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(),
    'claw-installer',
    "reboot-kind-$PID.txt"
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $markerFile) | Out-Null
  Remove-Item -Force $markerFile -ErrorAction SilentlyContinue
  [System.Environment]::SetEnvironmentVariable('CLAW_REBOOT_MARKER', $markerFile, 'Process')

  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  foreach ($kv in $PSBoundParameters.GetEnumerator()) {
    if ($kv.Key -eq 'SessionLogPath') { continue }  # forwarded explicitly below
    if ($kv.Value -is [switch]) {
      if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
    } else {
      $argList += "-$($kv.Key)", $kv.Value
    }
  }
  # Explicitly forward $SessionLog so the elevated child writes to the SAME
  # file we're about to tail. We can't rely on $env:CLAW_SESSION_LOG here:
  # ShellExecuteEx with verb "runas" gives the elevated child a fresh env
  # block, ignoring process-scoped env vars set in the parent.
  $argList += @('-SessionLogPath', $SessionLog)
  try {
    # -WindowStyle Hidden hides the elevated child's console window. -PassThru
    # gives us a Process object; we deliberately omit -Wait so we can tail the
    # shared session log while the child runs, forwarding new content to our
    # own stdout (which Tauri captures). This is the only way to surface the
    # elevated child's Write-Display output to the GUI — the UAC boundary
    # prevents direct stdout piping.
    $proc = Start-Process powershell -ArgumentList $argList `
      -Verb RunAs -WindowStyle Hidden -PassThru

    # Record current file size so we don't replay content the parent itself
    # wrote before elevation (e.g. the "需要管理员权限…" line above).
    $lastSize = 0
    if (Test-Path $SessionLog) { $lastSize = (Get-Item $SessionLog).Length }

    while (-not $proc.HasExited) {
      Forward-SessionLogTail ([ref]$lastSize)
      Start-Sleep -Milliseconds 250
    }
    # Final drain: catch anything written between the last poll and exit.
    Forward-SessionLogTail ([ref]$lastSize)

    if (Test-Path $markerFile) {
      try {
        $kind = (Get-Content $markerFile -Raw).Trim()
        if ($kind) { Write-Host "@@reboot:$kind" }
      } catch { }
      Remove-Item -Force $markerFile -ErrorAction SilentlyContinue
    }
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

# Functional probe: is WSL actually installed and working?
#
# Why we can't just use `Get-Command wsl.exe`: starting with Windows 11 build
# 22000, Microsoft ships a wsl.exe *stub* in System32 even on machines where
# the Linux subsystem feature has never been enabled. That stub satisfies
# Get-Command but, when invoked, prints "未安装适用于 Linux 的 Windows 子系统"
# to stderr and exits non-zero. So Get-Command alone is a false positive that
# makes the rest of the script blindly call wsl.exe and crash.
function Test-WslFunctional {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
  $r = Invoke-Wsl @('--status')
  return ($r.ExitCode -eq 0)
}

# Centralized wsl.exe invocation.
#
# Two reasons we route every wsl call through Start-Process:
#   1. PowerShell 5.1 + $ErrorActionPreference='Stop' treats native command
#      stderr captured via `2>&1` as terminating errors that try/catch can't
#      always intercept. Start-Process with -RedirectStandardError to a file
#      fully isolates the child's stderr from the PS error stream.
#   2. Some wsl.exe paths (notably `--install -d <distro>` on older Win11
#      builds) inherit the calling console and may spawn a Microsoft Store UI
#      window. -NoNewWindow keeps the child in our (hidden) process group, and
#      since we never call wsl.exe without --no-launch / -u root, no Ubuntu
#      first-run console pops up either.
#
# Encoding: wsl.exe historically emits UTF-16LE for its own subcommands when
# stdout is a console, and varies between UTF-16LE / UTF-8 when stdout is
# redirected (depending on WSL version). Set WSL_UTF8=1 to force UTF-8 on
# WSL 0.65+, and BOM-sniff the file content to stay compatible with older
# wsl.exe that ignores the env var.
function Invoke-Wsl {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $tag = [Guid]::NewGuid().ToString('N')
  $outFile = [System.IO.Path]::Combine($env:TEMP, "claw-wsl-$tag.out")
  $errFile = [System.IO.Path]::Combine($env:TEMP, "claw-wsl-$tag.err")
  $prevUtf8 = $env:WSL_UTF8
  $env:WSL_UTF8 = '1'
  try {
    $proc = Start-Process -FilePath 'wsl.exe' -ArgumentList $Arguments `
      -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    return [pscustomobject]@{
      ExitCode = $proc.ExitCode
      Stdout   = (Read-WslOutputFile $outFile)
      Stderr   = (Read-WslOutputFile $errFile)
    }
  } catch {
    Write-Log "Invoke-Wsl ($($Arguments -join ' ')) threw: $_"
    return [pscustomobject]@{ ExitCode = -1; Stdout = ''; Stderr = "$_" }
  } finally {
    if ($null -eq $prevUtf8) {
      Remove-Item Env:\WSL_UTF8 -ErrorAction SilentlyContinue
    } else {
      $env:WSL_UTF8 = $prevUtf8
    }
    Remove-Item -Force $outFile -ErrorAction SilentlyContinue
    Remove-Item -Force $errFile -ErrorAction SilentlyContinue
  }
}

# Decode a wsl.exe output capture, tolerating either UTF-16LE (with or without
# BOM, older wsl) or UTF-8 (modern wsl when WSL_UTF8=1). Strips stray NULs that
# some Win 10 wsl builds interleave even into UTF-8 output.
function Read-WslOutputFile {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return '' }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -eq 0) { return '' }
  # Explicit UTF-16LE BOM
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    return ([System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) -replace "`0", '')
  }
  # Heuristic: BOM-less UTF-16LE — ASCII bytes followed by zero bytes in
  # alternating pattern. Sample first 4 bytes to detect.
  if ($bytes.Length -ge 4 -and $bytes[0] -ne 0 -and $bytes[1] -eq 0 -and $bytes[3] -eq 0) {
    return ([System.Text.Encoding]::Unicode.GetString($bytes) -replace "`0", '')
  }
  # Default: UTF-8 (with WSL_UTF8=1 this is what modern wsl emits).
  return ([System.Text.Encoding]::UTF8.GetString($bytes) -replace "`0", '')
}

# Run a multi-line bash script inside a WSL distro.
#
# Why this exists instead of `& wsl.exe -- bash -c $script`:
# PowerShell 5.1's native-exe argument quoting is broken for any string
# containing newlines (or embedded quotes). When the script comes from an
# `@'...'@` here-string, PS builds a CommandLine that splits the script at
# whitespace/newlines, so wsl.exe forwards only the first fragment as bash's
# `-c` argument and the rest get reinterpreted as bash's positional args
# ($0, $1, ...). You then see errors like
#     already: -c: line 5: syntax error: unexpected end of file
# where "already" is whichever word PS happened to fall onto as $0.
#
# Workaround: base64-encode the script. The encoded form is a single
# whitespace-free token, which survives both PS's quoting and cmd.exe's
# CommandLine reparsing intact. On the bash side, we `base64 -d | bash` to
# run it. base64 / coreutils are present in every WSL distro we target.
function Invoke-WslBash {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$Script,
    [string]$User = '',     # '' => default distro user; pass 'root' for system writes
    [switch]$Login          # use `bash -l` (login shell) — needed when the
                            # script wants ~/.profile, nvm, fnm, etc.
  )
  # Normalize CRLF → LF: PowerShell here-strings on Windows produce \r\n, but
  # bash chokes on the stray \r at end of lines (treats it as part of a
  # command/var name). Strip them before base64-encoding.
  $lf = $Script -replace "`r`n", "`n"
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($lf)
  $b64 = [Convert]::ToBase64String($bytes)
  $shell = if ($Login) { 'bash -l' } else { 'bash' }
  $remote = "echo $b64 | base64 -d | $shell"

  $wslArgs = @('-d', $Name)
  if ($User) { $wslArgs += @('-u', $User) }
  $wslArgs += @('--', 'bash', '-c', $remote)

  $env:WSL_UTF8 = '1'
  $output = & wsl.exe @wslArgs 2>&1
  return [pscustomobject]@{
    Output   = ($output | Out-String)
    ExitCode = $LASTEXITCODE
  }
}

# Streamed version of Invoke-WslBash for long-running scripts (the agent
# installer / uninstaller / service actions). Output flows directly to the
# caller's stdout so the GUI's tail-loop sees progress lines in real time;
# we don't buffer through `2>&1 | Out-String`. Returns the exit code.
function Invoke-WslBashStreamed {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$Script,
    [switch]$Login
  )
  $lf = $Script -replace "`r`n", "`n"
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($lf)
  $b64 = [Convert]::ToBase64String($bytes)
  $shell = if ($Login) { 'bash -l' } else { 'bash' }
  $remote = "echo $b64 | base64 -d | $shell"
  $env:WSL_UTF8 = '1'
  & wsl.exe -d $Name -- bash -c $remote
  return $LASTEXITCODE
}

# Convert a Windows path (e.g. C:\Users\foo\bar) to its WSL mount equivalent
# (e.g. /mnt/c/Users/foo/bar). Replaces `wsl.exe -- wslpath -a <path>` which
# is broken because wsl.exe's argv reparser drops backslashes from sequences
# like `\U`, `\D`, `\c`, so wslpath inside the distro sees a mangled path.
#
# Handles:
#   * Drive-letter paths: C:\foo, D:/bar          → /mnt/c/foo, /mnt/d/bar
#   * Extended-length prefix: \\?\C:\foo          → /mnt/c/foo
#   * UNC paths to WSL itself: \\wsl$\Ubuntu\foo  → not supported (returns $null)
# Returns $null if the path can't be unambiguously mapped.
function ConvertTo-WslMountPath {
  param([Parameter(Mandatory)] [string]$WinPath)
  # Strip extended-length prefix so the regex below matches the drive letter.
  $p = $WinPath -replace '^\\\\\?\\', ''
  # Resolve to an absolute path (handles `.`, `..`, mixed separators).
  try {
    $p = (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path
  } catch {
    # Path doesn't exist (yet); fall back to manual normalization.
  }
  if ($p -match '^([A-Za-z]):[\\/](.*)$') {
    $drive = $Matches[1].ToLower()
    $rest  = $Matches[2] -replace '\\', '/'
    return "/mnt/$drive/$rest"
  }
  Write-Log "ConvertTo-WslMountPath: unable to map '$WinPath' (resolved: '$p')"
  return $null
}

# Does this wsl.exe support `--web-download` for the `--install` subcommand?
# Added in WSL 2.0.6 (mid-2023, ships with all current Win11 builds).
# Using web-download avoids the Microsoft Store UI window that pops up
# otherwise — critical for a fully background install experience.
$script:WslWebDownloadSupported = $null
function Test-WslWebDownloadSupport {
  if ($null -ne $script:WslWebDownloadSupported) { return $script:WslWebDownloadSupported }
  $r = Invoke-Wsl @('--help')
  $script:WslWebDownloadSupported = ($r.Stdout -match 'web-download' -or $r.Stderr -match 'web-download')
  return $script:WslWebDownloadSupported
}

# CPU-level virtualization probe (BIOS/UEFI setting).
#
# The Windows optional features (Microsoft-Windows-Subsystem-Linux,
# VirtualMachinePlatform) are *OS-level* knobs and can be flipped from
# PowerShell. But WSL 2's lightweight VM also needs hardware virtualization
# instructions (Intel VT-x / AMD SVM) which are gated by firmware settings the
# user must change manually in BIOS/UEFI. Without them, `wsl --install -d
# <distro>` fails with HCS_E_HYPERV_NOT_INSTALLED — a confusing error that
# blames "Hyper-V" rather than firmware. We pre-check via WMI so the user
# gets actionable guidance before the wsl.exe download runs.
function Test-FirmwareVirtualization {
  # Three independent signals — ANY of them being true means BIOS virt is on:
  #
  # 1. Win32_Processor.VirtualizationFirmwareEnabled — the obvious bit, but
  #    it lies (returns False) when Hyper-V / VBS / Memory Integrity is
  #    already running, because those services claim the virtualization
  #    extensions exclusively and the host OS can no longer see the firmware
  #    bit directly. We've seen this on Win11 25H2 machines with VBS on.
  #
  # 2. Win32_ComputerSystem.HypervisorPresent — True if a hypervisor is
  #    currently running. A hypervisor cannot launch without firmware-level
  #    VT-x / SVM, so this being True is a *proof* that BIOS virt is on,
  #    even if signal #1 disagrees.
  #
  # 3. SecondLevelAddressTranslationExtensions — same firmware gate; also
  #    survives the Hyper-V-exclusive case on some Intel chips.
  #
  # Returning true on ANY positive signal avoids the previous false-negative
  # where the script told users with VBS/Hyper-V already running to "go enable
  # VT-x in BIOS" — which they had already done.
  $signals = @()
  try {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    if ($cpu.VirtualizationFirmwareEnabled)              { $signals += 'VirtualizationFirmwareEnabled' }
    if ($cpu.SecondLevelAddressTranslationExtensions)    { $signals += 'SLAT' }
  } catch {
    Write-Log "Test-FirmwareVirtualization: Win32_Processor query failed: $_"
  }
  try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($cs.HypervisorPresent) { $signals += 'HypervisorPresent' }
  } catch {
    Write-Log "Test-FirmwareVirtualization: Win32_ComputerSystem query failed: $_"
  }
  if ($signals.Count -gt 0) {
    Write-Log "Test-FirmwareVirtualization: enabled (signals: $($signals -join ', '))"
    return $true
  }
  Write-Log "Test-FirmwareVirtualization: all signals negative — BIOS virt likely off"
  return $false
}

# Returns $true iff a hypervisor (Hyper-V, VBS, etc.) is currently active on
# the host. Useful for triage paths where we need to distinguish "BIOS off"
# from "BIOS on but something else is wrong" — if a hypervisor is running,
# BIOS *must* be on, so any HCS_E_HYPERV-style error must have a different
# root cause (VirtualMachinePlatform feature disabled, bcdedit hypervisor
# launch type off, corrupt WSL, etc.).
function Test-HypervisorRunning {
  try {
    return [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent
  } catch {
    return $false
  }
}

function Show-FirmwareVirtualizationHelp {
  # Headline goes through Write-Display so it surfaces in the GUI's progress
  # banner directly. (Write-Err2 was wrong here — it writes to the [debug]
  # stream, which the frontend filters out of the user-facing log.)
  Write-Display "CPU 虚拟化未启用 — 需要先在 BIOS / UEFI 里开启 Intel VT-x 或 AMD SVM 才能继续。"
  Write-Display ""
  Write-Display "WSL 2 需要 CPU 硬件虚拟化指令 (Intel VT-x / AMD SVM)，"
  Write-Display "这个开关只能在 BIOS 里打开，安装器无法替你完成。"
  Write-Display ""
  Write-Display "操作步骤："
  Write-Display "  1. 重启电脑，开机时按 F2 / Del / Esc（按主板不同）进入 BIOS / UEFI 设置。"
  Write-Display "  2. 在 CPU / Advanced / Virtualization 等菜单里，找到："
  Write-Display "       Intel: Intel Virtualization Technology (VT-x)"
  Write-Display "       AMD:   SVM Mode / AMD-V"
  Write-Display "  3. 设为 Enabled，保存并退出。"
  Write-Display "  4. 进入 Windows 后重新启动本安装器。"
  Write-Display ""
  Write-Display "详细帮助：https://aka.ms/enablevirtualization"
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
  # ALWAYS verify both required Windows features (Microsoft-Windows-Subsystem-Linux
  # and VirtualMachinePlatform) are enabled — `wsl --status` can return 0 on
  # machines where WSL 1 is functional but VirtualMachinePlatform is disabled,
  # in which case `wsl --install -d <distro>` later fails with
  # HCS_E_HYPERV_NOT_INSTALLED. Install-WslFeatures is idempotent (only acts on
  # features in Disabled state) so it's cheap to call unconditionally.
  Write-Display "正在检查 Windows 子系统功能…"
  Install-WslFeatures
  if ($script:NeedsReboot) {
    Write-Display "已启用所需 Windows 功能，需要重启 Windows 才能继续。"
    Emit-RebootSentinel 'wsl-feature'
    exit 2
  }

  # Firmware (BIOS/UEFI) virtualization is required for WSL 2 and can't be
  # toggled from Windows — if it's off, exit early with actionable guidance
  # rather than wading into the wsl.exe error path.
  if (-not (Test-FirmwareVirtualization)) {
    Show-FirmwareVirtualizationHelp
    exit 5
  }

  if (Test-WslFunctional) {
    Write-Step "wsl.exe found on PATH and functional."
    return
  }
  Write-Display "WSL 功能已就绪，正在补齐运行时…"
  # Features are already enabled (e.g. user already rebooted earlier) but the
  # kernel / store-side WSL package may still be missing. `wsl --install` with
  # no -d argument installs the WSL runtime (kernel + store package) without
  # bundling a distro. --no-launch + --web-download keep it fully silent:
  #   * --no-launch    : don't auto-launch any distro (Ubuntu first-run UX skipped)
  #   * --web-download : download via HTTPS instead of Microsoft Store UI
  $wslArgs = @('--install', '--no-launch')
  if (Test-WslWebDownloadSupport) { $wslArgs += '--web-download' }
  Write-Display "正在安装 WSL 运行时（后台下载，无需用户交互）…"
  Write-Log "Running: wsl.exe $($wslArgs -join ' ')"
  if (-not $DryRun) {
    $r = Invoke-Wsl $wslArgs
    Write-Log "wsl --install stdout: $($r.Stdout)"
    Write-Log "wsl --install stderr: $($r.Stderr)"
    if (($r.Stdout + $r.Stderr) -match 'restart|reboot|重启|重新启动') {
      $script:NeedsReboot = $true
    }
    if ($r.ExitCode -ne 0 -and -not $script:NeedsReboot) {
      Write-Err2 "wsl --install 失败 (exit $($r.ExitCode))：$($r.Stderr)"
      exit 3
    }
  }
  if ($script:NeedsReboot) {
    Write-Display "WSL 安装完成，需要重启 Windows 才能继续。"
    Emit-RebootSentinel 'wsl-feature'
    exit 2
  }
}

function Get-DistroVersion {
  param([string]$Name)
  # Returns 1 or 2 (WSL version of the resolved distro) or 0 if not installed.
  # Uses Resolve-InstalledDistro so 'Ubuntu' also matches 'Ubuntu-24.04' etc.
  $resolved = Resolve-InstalledDistro -Name $Name
  if (-not $resolved) { return 0 }
  $escaped = [regex]::Escape($resolved)
  $r = Invoke-Wsl @('--list', '--verbose')
  foreach ($line in ($r.Stdout -split "`r?`n")) {
    if ($line -match "^\s*\*?\s*$escaped\s+\S+\s+(\d+)\s*$") {
      return [int]$Matches[1]
    }
  }
  return 0
}

# Find the actually-installed distro that satisfies $Name.
#
# Microsoft ships Ubuntu under several distinct distro names:
#   * "Ubuntu"        — rolling, always current LTS
#   * "Ubuntu-24.04"  — pinned, ships from MS Store
#   * "Ubuntu-22.04", "Ubuntu-20.04", …
#
# `wsl -d Ubuntu` and `wsl -d Ubuntu-24.04` target *different* distros even
# though they're both Ubuntu. For our purposes (running the bash installer
# inside any Ubuntu), any of these satisfies the requirement. So when caller
# passes 'Ubuntu' and the list contains 'Ubuntu-24.04', treat the latter as
# the resolved target — and update $script:Distro so downstream `wsl -d ...`
# calls reach the right one.
function Resolve-InstalledDistro {
  param([string]$Name)
  $r = Invoke-Wsl @('--list', '--quiet')
  $list = $r.Stdout -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  if ($list -contains $Name) { return $Name }
  foreach ($d in $list) {
    if ($d -like "$Name-*") { return $d }
  }
  return $null
}

function Test-DistroInstalled {
  param([string]$Name)
  return $null -ne (Resolve-InstalledDistro -Name $Name)
}

function Ensure-Distro {
  param([string]$Name)
  if (Test-DistroInstalled -Name $Name) {
    Write-Step "WSL distro '$Name' present."
    return
  }
  # --no-launch suppresses Ubuntu's interactive first-run console; we'll do all
  # subsequent operations as root, which bypasses the OOBE entirely.
  # --web-download avoids the Microsoft Store progress window.
  $wslArgs = @('--install', '-d', $Name, '--no-launch')
  if (Test-WslWebDownloadSupport) { $wslArgs += '--web-download' }
  Write-Display "正在后台下载并安装 WSL 发行版 $Name …"
  Write-Log "Running: wsl.exe $($wslArgs -join ' ')"
  if (-not $DryRun) {
    $r = Invoke-Wsl $wslArgs
    Write-Log "wsl --install -d $Name stdout: $($r.Stdout)"
    Write-Log "wsl --install -d $Name stderr: $($r.Stderr)"
    if ($r.ExitCode -ne 0) {
      $combined = "$($r.Stdout)`n$($r.Stderr)"
      if ($combined -match 'HCS_E_HYPERV_NOT_INSTALLED' -or $combined -match 'enablevirtualization') {
        # See identical branch in main catch — HCS_E_HYPERV has multiple
        # causes. Only route to "fix BIOS" if no hypervisor is running; if
        # one is, BIOS is on and the issue lies in VMP / bcdedit / WSL itself.
        if (Test-HypervisorRunning) {
          Write-Display "WSL 2 启动失败，但 Hyper-V hypervisor 已在运行（BIOS 虚拟化已启用）。"
          Write-Display "请检查 VirtualMachinePlatform 功能与 bcdedit hypervisorlaunchtype 设置，"
          Write-Display "或在管理员 PowerShell 跑：wsl --update --web-download"
          exit 3
        }
        Show-FirmwareVirtualizationHelp
        exit 5
      }
      Write-Err2 "wsl --install -d $Name 失败 (exit $($r.ExitCode))：$($r.Stderr)"
      exit 3
    }
  }
  # Boot the distro once as root to materialize the rootfs WITHOUT triggering
  # Ubuntu's interactive OOBE (which is the thing that opens a console window
  # asking for username/password). Subsequent operations all use `-u root`.
  Write-Display "正在初始化 $Name 环境（无需用户输入）…"
  $r2 = Invoke-Wsl @('-d', $Name, '-u', 'root', '--', '/bin/true')
  Write-Log "First boot (root) exit code: $($r2.ExitCode)"
  Write-Step "WSL 发行版 $Name 已就绪。"
}

# Make sure new distros default to WSL 2 (cheap, idempotent).
# Skip when WSL isn't functional yet — on Win11 24H2 the wsl.exe stub exists
# even before the feature is enabled, so Get-Command alone is misleading. We
# also use `2>$null 1>$null` (not `2>&1 | Out-Null`) because the latter routes
# native stderr through the PS error stream and under
# $ErrorActionPreference='Stop' raises a terminating error that even try/catch
# can't reliably absorb in PS 5.1.
function Ensure-Wsl2Default {
  if ($DryRun) { Write-Host "  [dry-run] wsl --set-default-version 2"; return }
  if (-not (Test-WslFunctional)) {
    Write-Log "Ensure-Wsl2Default: WSL not functional yet, skipping (will retry after install)."
    return
  }
  $r = Invoke-Wsl @('--set-default-version', '2')
  if ($r.ExitCode -ne 0) {
    Write-Log "Ensure-Wsl2Default: wsl --set-default-version 2 exited $($r.ExitCode); ignoring."
  }
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
  if ($DryRun) { Write-Host "  [dry-run] wsl -d $Name -u root -- bash <write /etc/wsl.conf>"; return $false }
  $r = Invoke-WslBash -Name $Name -User 'root' -Script $script
  Write-Host "  $($r.Output.TrimEnd())"
  if ($r.ExitCode -ne 0) {
    Write-Err2 "Failed to update /etc/wsl.conf (exit $($r.ExitCode))."
    exit 3
  }
  $changed = $r.Output -match 'systemd=true written'
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
  #
  # Why we don't call `wsl.exe -- wslpath -a "$LocalPath"`:
  # wsl.exe's CommandLine reparser strips the `\` from sequences like `\U`,
  # `\D`, `\c` when forwarding args to the Linux side — bash receives
  # "C:UsersyanxuDesktop..." with the backslashes gone, and wslpath then
  # fails with that mangled path. The Win→WSL `/mnt/<drive>/...` mapping
  # is mechanical, so we just do it in PowerShell and never let the path
  # cross the wsl.exe argv boundary.
  $wslSrc = ConvertTo-WslMountPath -WinPath $LocalPath
  if (-not $wslSrc) {
    Write-Err2 "Could not translate '$LocalPath' to a WSL /mnt/ path."
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
  $r = Invoke-WslBash -Name $Name -Script $cp
  Write-Host "  $($r.Output.TrimEnd())"
  if ($r.ExitCode -ne 0) {
    Write-Err2 "Copy-RepoIntoWsl: bash returned exit $($r.ExitCode)."
    exit 3
  }
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

  return Invoke-WslBashStreamed -Name $Name -Script $script -Login
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
  if ($DryRun) { Write-Host "  [dry-run] wsl -d $Name -- bash <run uninstaller>"; return 0 }

  return Invoke-WslBashStreamed -Name $Name -Script $script -Login
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
  if ($DryRun) { Write-Host "  [dry-run] wsl -d $Name -- bash <$AgentName/$ServiceAction.sh>"; return 0 }

  return Invoke-WslBashStreamed -Name $Name -Script $script -Login
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
  # NOTE: Ensure-Wsl2Default is intentionally deferred until *after*
  # Ensure-WslInstalled below — it requires WSL to actually be installed (not
  # just the Win11 24H2 wsl.exe stub) and skips itself if not yet functional.
  Ensure-Wsl2Default

  $wslPresent = Test-WslFunctional
  if ($wslPresent) {
    # If the user asked for "Ubuntu" but only "Ubuntu-24.04" is installed,
    # quietly retarget so downstream commands address the right distro.
    $actual = Resolve-InstalledDistro -Name $Distro
    if ($actual -and $actual -ne $Distro) {
      Write-Step "Resolved '$Distro' to actually-installed distro '$actual'."
      $Distro = $actual
    }
  }
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
      Emit-RebootSentinel 'wsl-feature'
      exit 3
    }
    if (-not $distroPresent) {
      Emit-RebootSentinel 'distro-firstrun'
      exit 2
    }
    Write-Step "Preflight checks passed."
    exit 0
  }

  # Non-preflight paths require elevation (install, uninstall, service).
  Assert-Elevated

  Ensure-WslInstalled
  # Now that WSL is actually installed, set WSL2 as the default for new distros.
  # (The earlier call above was a no-op because Test-WslFunctional was false.)
  Ensure-Wsl2Default
  Ensure-Distro -Name $Distro

  # -InstallWslOnly stops after WSL + distro are present. The GUI uses this
  # mode for the "Install WSL" banner button: provision WSL/distro and let
  # the user re-trigger the agent install afterwards.
  if ($InstallWslOnly) {
    Write-Display "✓ WSL 与发行版已就绪"
    exit 0
  }

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
} catch {
  # Without this catch any terminating error (e.g. CommandNotFoundException when
  # wsl.exe isn't on PATH yet) exits the script with code 1 and prints nothing
  # the GUI can capture — the user sees "退出码 1" with no clue why. We do two
  # things here:
  #   1. Surface the full record into the [debug] log so install-<ts>.log
  #      contains the technical detail for triage.
  #   2. Sniff the exception (and recent log content) for *known* root-cause
  #      keywords and exit with the semantic code that matches, so the GUI
  #      banner shows a human-readable reason rather than the generic
  #      catch-all message. Order matters: most-specific match wins.
  $err = $_
  $msg = "$($err.Exception.Message)"
  # Also include script-level stack frames — sometimes the user-visible
  # message is generic ("Failed.") but the InvocationInfo line shows the
  # actual command that errored (e.g. "wsl.exe --install -d Ubuntu").
  $needle = ($msg + " " + $err.InvocationInfo.PositionMessage + " " + $err.ScriptStackTrace)

  Write-Log  ("Exception type:   {0}" -f $err.Exception.GetType().FullName)
  Write-Log  ("Exception msg:    {0}" -f $msg)
  Write-Log  ("Script location:  {0}" -f $err.InvocationInfo.PositionMessage)
  Write-Log  ("Stack trace:      {0}" -f $err.ScriptStackTrace)

  if ($needle -match 'HCS_E_HYPERV_NOT_INSTALLED' -or $needle -match 'enablevirtualization') {
    # HCS_E_HYPERV_NOT_INSTALLED has multiple causes; only one of them is
    # "BIOS VT-x off". If a hypervisor is currently running on the host then
    # BIOS virt is by definition on — point the user at the real culprits
    # (VirtualMachinePlatform feature, hypervisorlaunchtype, corrupt WSL)
    # instead of having them reboot into UEFI for no reason.
    if (Test-HypervisorRunning) {
      Write-Display "WSL 2 启动失败，但 Hyper-V hypervisor 已在运行（BIOS 虚拟化已启用）。"
      Write-Display ""
      Write-Display "可能原因（按概率）："
      Write-Display "  1. VirtualMachinePlatform Windows 功能未启用 — 在管理员 PowerShell 跑："
      Write-Display "       Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform"
      Write-Display "       然后重启。"
      Write-Display "  2. Hypervisor 启动类型不是 Auto — 检查："
      Write-Display "       bcdedit /enum | findstr hypervisorlaunchtype"
      Write-Display "       若非 Auto，跑：bcdedit /set hypervisorlaunchtype auto"
      Write-Display "  3. WSL 组件损坏 — 跑：wsl --update --web-download"
      exit 3
    }
    Show-FirmwareVirtualizationHelp
    exit 5
  }
  if ($needle -match 'CommandNotFoundException.*wsl' -or $needle -match "'wsl(\.exe)?' is not recognized") {
    Write-Display "未检测到 WSL 命令 — Windows 子系统功能可能尚未启用，请按提示重启电脑后重试。"
    exit 3
  }
  if ($needle -match 'The operation was canceled by the user' -or $needle -match '0x800704C7') {
    Write-Display '操作已取消（UAC 弹窗中点了「取消」或「否」）。'
    exit 4
  }

  # Generic fallback — keep it plain-language, not "Exception type / Stack
  # trace…". The technical detail already landed in the [debug] log above.
  Write-Display ("安装中途遇到未预期的错误：{0}" -f $msg)
  Write-Display '完整堆栈与上下文已写入会话日志（GUI 错误条下方的「完整日志」路径）。'
  exit 1
} finally {
  # Stop the debug tailing job on script exit (success or failure).
  if ($null -ne $DebugJob) {
    Stop-Job -Job $DebugJob -ErrorAction SilentlyContinue
    Remove-Job -Job $DebugJob -ErrorAction SilentlyContinue
  }
}
