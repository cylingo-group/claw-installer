# bootstrap-probe.ps1 — Minimal glue layer for the new architecture.
#
# Mirrors what shell/windows/bootstrap.ps1 would do for a single -Op verb,
# but stripped to the bare minimum so we can validate the chain end-to-end
# without dragging in the full installer logic (Assert-Elevated, distro
# detection, manifest copying, etc.).
#
# DELIBERATELY PS 5.1 COMPATIBLE:
#   - No `??` null-coalescing operator
#   - No ternary `?:`
#   - No `&` background pipeline
#   - No `using namespace` requiring PS 5.0+
#   - All param defaults are literal strings, not expressions
#
# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File bootstrap-probe.ps1 `
#       -Op <op> -Agent <agent> [-DryRun] [-Distro <name>]
#
# stdin payload: comes from the INSTALLER_OP_STDIN_B64 env var (base64).
# Op-script env: any env var named INSTALLER_OP_* is forwarded into WSL.
#
# Op scripts live at <script-dir>/ops/<op>.sh and run inside WSL via a
# Windows-mount path (/mnt/c/... etc.) — no copying into WSL needed.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Op,
    [Parameter(Mandatory)] [string]$Agent,
    [string]$Distro = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ───────────────────────────────────────────────────────────────────────────
# Dispatch table: op → list of valid agents
# Mirrors the architecture's $script:OpAgentTable but lists only probe ops.
$OpAgentTable = @{
    'noop'                       = @('test', 'openclaw', 'hermes')
    'echo-stdin'                 = @('test')
    'apply-model-config-dry'     = @('openclaw')
    'fnm-state'                  = @('test')
    'pollution'                  = @('test')
    'verify-fnm-fix'             = @('openclaw')
}

function Write-Line {
    param([string]$Msg)
    Write-Host $Msg
}

function Fail {
    param([string]$Msg, [int]$Code)
    Write-Host "[probe-glue] FAIL: $Msg" -ForegroundColor Red
    exit $Code
}

# ───────────────────────────────────────────────────────────────────────────
# Validate Op / Agent against the dispatch table.
if (-not $OpAgentTable.ContainsKey($Op)) {
    $valid = ($OpAgentTable.Keys | Sort-Object) -join ', '
    Fail "Unknown op '$Op'. Valid: $valid" 11
}
$agents = $OpAgentTable[$Op]
if ($agents -notcontains $Agent) {
    $valid = ($agents | Sort-Object) -join ', '
    Fail "Op '$Op' does not support agent '$Agent'. Valid: $valid" 12
}

# ───────────────────────────────────────────────────────────────────────────
# Locate the op script. We assume it lives at <script-dir>/ops/<op>.sh.
$scriptDir = Split-Path -Parent $PSCommandPath
$opScriptWin = Join-Path $scriptDir "ops/$Op.sh"
if (-not (Test-Path $opScriptWin)) {
    Fail "op script not found at $opScriptWin" 13
}

# Translate Windows path → WSL /mnt/<drive>/... so the script is readable
# from inside WSL via the default Windows-filesystem mount.
function To-WslPath {
    param([string]$WinPath)
    $abs = (Resolve-Path -LiteralPath $WinPath).Path
    if ($abs -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $matches[1].ToLower()
        $rest = $matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    Fail "cannot translate '$abs' to WSL path" 14
}
$opScriptWsl = To-WslPath $opScriptWin

# ───────────────────────────────────────────────────────────────────────────
# Collect INSTALLER_OP_* env vars to forward into WSL.
$forward = @()
Get-ChildItem env: | Where-Object { $_.Name -like 'INSTALLER_OP_*' -and $_.Name -ne 'INSTALLER_OP_STDIN_B64' } | ForEach-Object {
    $v = $_.Value -replace "'", "'\''"
    $forward += ("export {0}='{1}'" -f $_.Name, $v)
}
$envBlock = $forward -join "`n"

# Pull stdin payload (if any).
$stdinB64 = $env:INSTALLER_OP_STDIN_B64
if ($null -eq $stdinB64) { $stdinB64 = '' }

# ───────────────────────────────────────────────────────────────────────────
# Build the bash payload. Two cases:
#   A) no stdin   → run the op script with stdin = /dev/null
#   B) stdin set  → decode INSTALLER_OP_STDIN_B64 into chmod-600 temp file,
#                   then run the op script with stdin redirected from it.
#
# Both cases set INSTALLER_OP_AGENT and source the op script via `bash -l`
# so $HOME, locale, etc. are populated.
#
# NB: We DON'T `cd` anywhere — the op script handles its own working dir.

# IMPORTANT(PS 5.1): use single-quoted here-strings + manual substitution to
# avoid any chance of `??` or other PS-7-only syntax sneaking in.

$header = @"
set -euo pipefail
export INSTALLER_OP_AGENT='__AGENT__'
__ENVBLOCK__
"@
$header = $header -replace '__AGENT__', $Agent
$header = $header -replace '__ENVBLOCK__', $envBlock

if ($stdinB64 -ne '') {
    $body = @"
_stmp="/tmp/claw-op-probe-stdin-`$`$"
trap 'rm -f "`$_stmp"' EXIT
printf '%s' __B64__ | base64 -d > "`$_stmp"
chmod 600 "`$_stmp"
bash -l __SCRIPT__ < "`$_stmp"
"@
    $body = $body -replace '__B64__', $stdinB64
    $body = $body -replace '__SCRIPT__', $opScriptWsl
} else {
    $body = @"
bash -l __SCRIPT__ < /dev/null
"@
    $body = $body -replace '__SCRIPT__', $opScriptWsl
}

$bashPayload = ($header + "`n" + $body) -replace "`r`n", "`n"

# Base64-encode the payload so it survives wsl.exe's argv reparser.
$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($bashPayload)
$payloadB64 = [Convert]::ToBase64String($payloadBytes)
$remote = "echo $payloadB64 | base64 -d | bash"

# ───────────────────────────────────────────────────────────────────────────
# Build wsl.exe argv.
$wslArgs = @()
if ($Distro -ne '') {
    $wslArgs += @('-d', $Distro)
}
$wslArgs += @('--', 'bash', '-c', $remote)

Write-Line "[probe-glue] op=$Op agent=$Agent script=$opScriptWsl distro=$Distro dryrun=$DryRun"
if ($stdinB64 -ne '') {
    Write-Line "[probe-glue] stdin: $($stdinB64.Length) base64 chars (~$([Math]::Floor($stdinB64.Length * 3 / 4)) bytes)"
} else {
    Write-Line "[probe-glue] stdin: (none)"
}

if ($DryRun) {
    Write-Line "[probe-glue] DRY-RUN — would execute: wsl.exe $($wslArgs -join ' ')"
    exit 0
}

$env:WSL_UTF8 = '1'
& wsl.exe @wslArgs
exit $LASTEXITCODE
