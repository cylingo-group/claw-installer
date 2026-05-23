# wsl-probe.ps1 — Diagnose the WSL invocation path used by claw-installer's
# model-config save (commands.rs::apply_openclaw_model_config + apply_hermes_*).
#
# Run on the Windows host:
#   powershell -ExecutionPolicy Bypass -File .\wsl-probe.ps1
#
# Output:
#   - real-time log to stdout
#   - full transcript written to .\wsl-probe.log
#
# Each probe isolates one stage of the chain so we can pinpoint where it
# actually breaks: wsl.exe spawn → distro selection → bash -lc transport →
# PATH-in-login-shell → openclaw availability → stdin pipe → tmp-file write
# → openclaw config patch → openclaw config validate.

$ErrorActionPreference = 'Continue'
$logPath = Join-Path (Get-Location) 'wsl-probe.log'
'' | Set-Content -Encoding UTF8 $logPath
$env:WSL_UTF8 = '1'   # ask wsl.exe to emit its own errors as UTF-8

function Section($title) {
    $line = "`n=== $title ==="
    $line | Tee-Object -Append -FilePath $logPath
}
function Log($msg) {
    $msg | Tee-Object -Append -FilePath $logPath
}

Section 'environment'
Log ("OS              : " + [System.Environment]::OSVersion.VersionString)
Log ("PowerShell      : " + $PSVersionTable.PSVersion)
Log ("PID             : $PID")
Log ("WSL_UTF8        : $($env:WSL_UTF8)")
Log ("INSTALLER_WSL_DISTRO: $($env:INSTALLER_WSL_DISTRO)")

Section 'wsl.exe --version'
Log ((& wsl.exe --version 2>&1) -join "`n")

Section 'wsl.exe -l -v (installed distros)'
Log ((& wsl.exe -l -v 2>&1) -join "`n")

# RunBash $title $bashScript [$stdin]
#   $bashScript is a literal bash script — bash sees it verbatim.
#   $stdin (optional) is piped to bash via wsl.exe's stdin pipe.
function RunBash($title, $bashScript, $stdin) {
    Section $title
    Log '--- bash script (literal, as bash sees it) ---'
    Log $bashScript
    Log '--- output ---'
    if ($null -eq $stdin) {
        $out = (& wsl.exe -- bash -lc $bashScript 2>&1) -join "`n"
    } else {
        $out = ($stdin | & wsl.exe -- bash -lc $bashScript 2>&1) -join "`n"
    }
    Log "exit=$LASTEXITCODE"
    Log $out
}

# Probe 1 — does bash run at all?
RunBash 'probe-1: bash -lc echo' 'echo hello-from-bash' $null

# Probe 2 — what does $PATH look like in `bash -lc`, and is openclaw on it?
#   This is the single most likely failure mode for an installer-provisioned
#   distro: the .profile chain has to pull in the dir where pnpm installed
#   the openclaw bin.
RunBash 'probe-2: PATH + openclaw availability' @'
echo PATH="$PATH"
echo ---
type openclaw 2>&1 || echo "NOTFOUND: openclaw not on PATH"
openclaw --version 2>&1 || echo "openclaw exec failed"
'@ $null

# Probe 3 — multi-line script content survives wsl.exe arg transport.
#   If this loses lines, the bigger patch script won't work either.
RunBash 'probe-3: multi-line script' @'
set -e
echo line-1
echo line-2
echo line-3
exit 0
'@ $null

# Probe 4 — stdin pipe travels from PowerShell → wsl.exe → bash → cat.
#   Our patch flow depends on this.
RunBash 'probe-4: stdin -> cat' 'cat' 'hello-via-stdin'

# Probe 5 — write a stdin payload to a tmp file inside WSL using the SAME
#   shape our Rust code uses (inlined tmp path, umask 077, trap cleanup).
#   No openclaw involved yet — purely the file-write half.
$tmp5 = "/tmp/wsl-probe-$PID.json"
$script5 = @"
set -e
tmp=$tmp5
trap 'rm -f "`$tmp"' EXIT
umask 077
cat > "`$tmp"
echo "wrote: `$(wc -c < `"`$tmp`") bytes"
ls -l "`$tmp"
echo --- content ---
cat "`$tmp"
"@
RunBash 'probe-5: inline tmp + stdin write' $script5 '{"probe":"5"}'

# Probe 6 — end-to-end mimic of apply_openclaw_model_config: pipe a tiny
#   (FAKE) patch JSON through stdin, write to tmp, run `openclaw config
#   patch --file <tmp>`, then `openclaw config validate`.
#
# Note: this DOES modify your local openclaw config (writes deepseek
# provider with a fake API key 'sk-PROBE-FAKE'). If you've configured
# DeepSeek for real and care about that entry, edit / remove the
# `deepseek` block in this script before running. Most users testing
# the GUI flow won't have anything precious here yet.
$tmp6 = "/tmp/openclaw-patch-probe-$PID.json"
$script6 = @"
set -e
tmp=$tmp6
trap 'rm -f "`$tmp"' EXIT
umask 077
cat > "`$tmp"
echo --- patch file ready ---
ls -l "`$tmp"
echo --- patch content ---
cat "`$tmp"
echo --- running: openclaw config patch ---
openclaw config patch --file "`$tmp"
echo --- running: openclaw config validate ---
openclaw config validate
echo --- done ---
"@
$patchJson = '{"models":{"providers":{"deepseek":{"baseUrl":"https://api.deepseek.com","auth":"api-key","apiKey":"sk-PROBE-FAKE","api":"openai-completions"}}},"agents":{"defaults":{"model":"deepseek/deepseek-chat"}}}'
RunBash 'probe-6: end-to-end mock openclaw config patch' $script6 $patchJson

Section 'done'
Log "log saved: $logPath"
Write-Host ""
Write-Host "Done. Please share the contents of $logPath."
