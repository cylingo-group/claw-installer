# claw-op-probe

End-to-end verification of the proposed op-dispatch architecture for
claw-installer. Runs on Windows; reports whether the new
`Rust → PowerShell glue → WSL bash → common.sh-aware op script` chain works
on the user's machine, BEFORE we touch production code.

## What it tests

```
E. ENVIRONMENT       — PowerShell major version (PS 5.1 vs 7+), wsl.exe
                       version, default distro, baseline PATH inside
                       `bash -lc`, and PATH after sourcing common.sh.

P. POWERSHELL PARSE  — Does our probe bootstrap-probe.ps1 parse on this
                       host's PowerShell? (Catches PS-7-only syntax.)

G. GLUE LAYER        — PS → wsl.exe → bash → op script. Dispatch-table
                       validation (rejects unknown op / agent mismatch).

S. STDIN TRANSPORT   — Payload travels via INSTALLER_OP_STDIN_B64 env var
                       → base64-decoded inside WSL → stdin of op script.
                       Tested with ASCII, UTF-8 (Chinese + newlines), ~5KB,
                       and empty.

N. COMMON.SH         — op script sources ~/claw-installer-src/lib/common.sh.
                       Verifies node + openclaw are findable AFTER sourcing
                       (this is the architectural fix for "exec: node: not
                       found").

X. END-TO-END        — apply-model-config-dry.sh runs the full chain
                       non-destructively: source common.sh, read stdin,
                       call `openclaw --version`, exit 0. Mirrors what the
                       real apply-model-config would do, minus the mutation.
```

## How to run

1. **Extract the zip** somewhere convenient (e.g. `C:\Users\you\Downloads\claw-op-probe\`).
2. **Make sure WSL + Ubuntu are working** — `wsl.exe` returns non-zero exit
   on a fresh distro until first-run completes.
3. **Make sure claw-installer has been installed at least once** so that
   `~/claw-installer-src/lib/common.sh` exists inside WSL. The probe needs
   that file to validate the source-then-PATH-compose mechanism.
4. **Double-click `claw-op-probe.exe`** OR run from cmd / PowerShell:

   ```cmd
   .\claw-op-probe.exe
   ```

5. Wait ~30 seconds. The probe writes a log next to the .exe named
   `claw-op-probe-<unix-ts>.log`.

6. **Paste the entire log file back into our conversation.**

## Optional: also parse the production bootstrap.ps1

To have the probe additionally parse-test your prod `bootstrap.ps1`:

```cmd
set CLAW_PROBE_PROD_PS1=C:\Path\To\shell\windows\bootstrap.ps1
.\claw-op-probe.exe
```

Scenario P2 will run on that file. Useful to confirm whether the prod file
still parses on your PowerShell.

## Optional: target a non-default WSL distro

By default the probe uses `wsl.exe` without `-d`, so your default distro is
used. Override via:

```cmd
set INSTALLER_WSL_DISTRO=Ubuntu-24.04
```

(Only affects the parts of the probe that build their own `wsl.exe`
invocations — bootstrap-probe.ps1 has its own `-Distro` argument that this
env var does NOT control. Add `-Distro <name>` manually if needed.)

## File layout (after extracting the zip)

```
claw-op-probe/
├── claw-op-probe.exe         # the probe binary
├── README.md                 # this file
└── shell-overlay/
    ├── bootstrap-probe.ps1   # PS 5.1-compatible glue layer
    └── ops/
        ├── noop.sh           # diagnostic — prints PATH + env
        ├── echo-stdin.sh     # stdin fidelity (byte count + md5)
        └── apply-model-config-dry.sh
                              # non-destructive E2E rehearsal
```

The probe finds `shell-overlay/` by looking next to its own .exe. Don't
separate them.

## What the results mean

| Result | Interpretation |
|---|---|
| All ✓ | Architecture is sound on this host. We re-apply Phase 1 with confidence. |
| E1 fails (PS 5.1) | Confirms we need to drop `??` and other PS-7-only syntax. |
| E7 fails (common.sh missing) | Re-run installer first; the architecture depends on it. |
| E8 fails | `source common.sh` itself is broken — deeper investigation needed. |
| G* fail | Glue layer transport has issues — base64 encoding, wsl.exe argv, or PS quoting. |
| S* fail | INSTALLER_OP_STDIN_B64 env-var transport doesn't survive — payload corruption. |
| N1 fails | The architectural fix doesn't actually fix it — common.sh sourcing inside op script ≠ command line. |
| X1 fails with "REPRODUCED THE BUG" | We've isolated the production bug; fix path is clear. |
