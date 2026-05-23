# wsl-probe-v2.ps1 — Test bash script transport from PowerShell/wsl.exe to
# WSL bash, without depending on openclaw or any installer-specific tooling.
# Uses only cat / wc / ls / echo — present in every WSL distro.
#
# Goal: figure out which way of shipping a multi-step bash script through
# wsl.exe actually works on the user's machine.
#
# Run on the Windows host:
#   powershell -ExecutionPolicy Bypass -File .\wsl-probe-v2.ps1
#
# Output: live to stdout, persisted to .\wsl-probe-v2.log (UTF-8).

$ErrorActionPreference = 'Continue'
$logPath = Join-Path (Get-Location) 'wsl-probe-v2.log'
# Force UTF-8 (without BOM) so the log is readable when pasted back.
[System.IO.File]::WriteAllText($logPath, '')
$env:WSL_UTF8 = '1'

function Append($msg) {
    $msg | Tee-Object -FilePath $logPath -Append | Out-Null
    Write-Host $msg
}
function Section($t) { Append "`n=== $t ===" }

function RunBash($title, $bashScript, $stdin) {
    Section $title
    Append '--- bash script (literal) ---'
    Append $bashScript
    Append '--- output (stdout + stderr merged) ---'
    $tmpOut = New-TemporaryFile
    if ($null -eq $stdin) {
        & wsl.exe -- bash -lc $bashScript *>&1 | Out-File -FilePath $tmpOut.FullName -Encoding utf8
    } else {
        $stdin | & wsl.exe -- bash -lc $bashScript *>&1 | Out-File -FilePath $tmpOut.FullName -Encoding utf8
    }
    $code = $LASTEXITCODE
    $content = Get-Content -Path $tmpOut.FullName -Raw -Encoding utf8
    Remove-Item $tmpOut.FullName -Force
    Append "exit=$code"
    if ($null -ne $content) { Append $content }
}

Section 'environment'
Append ("OS              : " + [System.Environment]::OSVersion.VersionString)
Append ("PowerShell      : " + $PSVersionTable.PSVersion)
Append ("PID             : $PID")

Section 'wsl.exe --version'
Append ((& wsl.exe --version | Out-String).TrimEnd())

# ─────────────────────────────────────────────────────────────────────────
# Probe A — single-line bash with `;` separators (proposed Method A).
# This is the simplest fix candidate. Each statement separated by `;` so the
# whole script fits on one line — sidesteps any multi-line arg corruption.
# ─────────────────────────────────────────────────────────────────────────
$tmpA = "/tmp/probeA-$PID.json"
$scriptA = "set -e; tmp=$tmpA; trap 'rm -f `"`$tmp`"' EXIT; umask 077; cat > `"`$tmp`"; echo bytes:`$(wc -c < `"`$tmp`"); ls -l `"`$tmp`"; echo content:; cat `"`$tmp`""
RunBash 'probe-A: SINGLE-LINE script with semicolons' $scriptA '{"hello":"world"}'

# ─────────────────────────────────────────────────────────────────────────
# Probe B — multi-line bash script (control — expected to fail like v1
# probe 5/6 did). Same logic, just with newlines.
# ─────────────────────────────────────────────────────────────────────────
$tmpB = "/tmp/probeB-$PID.json"
$scriptB = @"
set -e
tmp=$tmpB
trap 'rm -f "`$tmp"' EXIT
umask 077
cat > "`$tmp"
echo bytes:`$(wc -c < "`$tmp")
ls -l "`$tmp"
echo content:
cat "`$tmp"
"@
RunBash 'probe-B: MULTI-LINE script (control - expected to fail)' $scriptB '{"hello":"world"}'

# ─────────────────────────────────────────────────────────────────────────
# Probe C — two-step file-based approach (Method B fallback).
# Step 1: pipe the multi-line script body via stdin into a WSL-side
#         /tmp/probeC.sh — pure data transport, no parsing involved.
# Step 2: `bash -l /tmp/probeC.sh` reads + executes the script from a file,
#         with the JSON payload piped as the script's own stdin.
#
# If A fails too, this should still work.
# ─────────────────────────────────────────────────────────────────────────
$scriptPath = "/tmp/probeC-$PID.sh"
$dataTmp = "/tmp/probeC-data-$PID.json"
$scriptBody = @"
set -e
tmp=$dataTmp
trap 'rm -f "`$tmp"' EXIT
umask 077
cat > "`$tmp"
echo bytes:`$(wc -c < "`$tmp")
ls -l "`$tmp"
echo content:
cat "`$tmp"
"@

Section 'probe-C step 1: write script to /tmp/probeC.sh via stdin'
$step1Cmd = "cat > $scriptPath && chmod 755 $scriptPath && echo 'wrote: $scriptPath'"
Append "--- step 1 cmd ---"
Append $step1Cmd
Append "--- step 1 output ---"
$tmpOut = New-TemporaryFile
$scriptBody | & wsl.exe -- bash -lc $step1Cmd *>&1 | Out-File -FilePath $tmpOut.FullName -Encoding utf8
$code1 = $LASTEXITCODE
$content1 = Get-Content -Path $tmpOut.FullName -Raw -Encoding utf8
Remove-Item $tmpOut.FullName -Force
Append "exit=$code1"
if ($null -ne $content1) { Append $content1 }

Section 'probe-C step 2: exec the script with JSON on stdin'
$step2Cmd = "bash -l $scriptPath"
Append "--- step 2 cmd ---"
Append $step2Cmd
Append "--- step 2 output ---"
$tmpOut = New-TemporaryFile
'{"step":"two","approach":"file-based"}' | & wsl.exe -- bash -lc $step2Cmd *>&1 | Out-File -FilePath $tmpOut.FullName -Encoding utf8
$code2 = $LASTEXITCODE
$content2 = Get-Content -Path $tmpOut.FullName -Raw -Encoding utf8
Remove-Item $tmpOut.FullName -Force
Append "exit=$code2"
if ($null -ne $content2) { Append $content2 }

# Cleanup the leftover script file.
& wsl.exe -- bash -lc "rm -f $scriptPath" 2>&1 | Out-Null

# ─────────────────────────────────────────────────────────────────────────
# Probe D — what does PATH actually look like in `bash -lc`?
# Useful regardless, since the truncation in v1 probe-2 hid the answer.
# We squash the PATH onto a single output line and add explicit markers
# so it can't be truncated in transit.
# ─────────────────────────────────────────────────────────────────────────
$scriptD = "echo '<PATH-START>' && echo `"`$PATH`" | tr ':' '\n' && echo '<PATH-END>' && echo '<HOME-START>' && echo `"`$HOME`" && echo '<HOME-END>'"
RunBash 'probe-D: PATH contents (one entry per line)' $scriptD $null

Section 'done'
Append "log saved: $logPath"
Write-Host ""
Write-Host "Done. Please share $logPath."
