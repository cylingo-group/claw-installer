## Why

The Rust GUI reaches bash business logic via two inconsistent paths on Windows: service lifecycle operations (install / uninstall / start / stop / restart) flow through `bootstrap.ps1 → Invoke-WslBashStreamed -Login`, which sources `common.sh` and provides a fully-composed PATH including fnm-managed Node and pnpm; but config-patch and dashboard operations bypass `bootstrap.ps1` entirely, spawning `wsl.exe -- bash -lc` inline from Rust, which omits `common.sh` and leaves `node` missing from PATH — producing the user-visible error `exec: node: not found` when saving model config. Path B grew up ad-hoc; patching it by duplicating PATH logic is not sustainable because every tool `common.sh` learns to add will be missed again.

## What Changes

- **New glue-layer verb** in `shell/windows/bootstrap.ps1`: a new `-Service op` / `-Op <name> -Agent <id>` dispatch path that validates op + agent, builds the bash invocation, forwards env vars, and calls `Invoke-WslBashStreamed -Login` — the already-proven base64 transport that delivers a fully sourced environment. Adds stdin forwarding to the transport (new capability required by the config-patch ops).
- **New thin dispatcher** `shell/claw-op.sh` for macOS/Linux: mirrors the Windows glue so both OSes share the same Rust call shape.
- **New Rust helper** `dispatch_op(agent, op, stdin_bytes)` in `commands.rs`: selects the right transport per OS and replaces all three ad-hoc inline-shell-in-Rust functions.
- **Six new operation scripts** under `shell/agents/<agent>/`: `apply-model-config.sh` (openclaw and hermes), `open-dashboard.sh` (openclaw and hermes), `approve-latest-device.sh` (openclaw), `find-dashboard-port.sh` (hermes). Each sources `common.sh` and has a documented input/output contract in its file header.
- **Delete** `run_in_wsl_file_based`, its PATH preamble hack, and the inline shell-string-building in `apply_openclaw_model_config`, `apply_hermes_model_config`, and `dashboard.rs::run_capture` (Windows branch).

## Capabilities

### New Capabilities

- `op-dispatch-protocol`: The unified operation dispatch contract — the set of named operations, their per-OS glue invocation, input conventions (stdin for secrets/JSON, `INSTALLER_OP_*` env vars for scalar params, argv `--op`/`--agent` for routing), and the business-script template all op scripts must follow.

### Modified Capabilities

- `two-stream-contract`: The streamed WSL transport (`Invoke-WslBashStreamed`) gains a stdin-forwarding mechanism. Existing callers (service lifecycle) are unaffected; new op scripts rely on the extended transport to receive JSON patches and secrets over stdin.

## Impact

**Files modified:**
- `shell/windows/bootstrap.ps1` — new `-Op`/`-Agent` parameter set + `Invoke-WslBashStreamed` stdin extension + new dispatch block
- `gui/src-tauri/src/commands.rs` — `apply_openclaw_model_config` (Windows), `apply_hermes_model_config` (Windows), `run_in_wsl_file_based`, `run_in_wsl_with_stdin` replaced by `dispatch_op`
- `gui/src-tauri/src/dashboard.rs` — `run_capture` Windows branch, `hermes_port_from_running_process` Windows branch, `open_openclaw_dashboard`, `try_approve_latest_device`, `open_hermes_dashboard` (spawn / port-find logic) migrated to op scripts

**Files added:**
- `shell/claw-op.sh` (macOS/Linux dispatcher)
- `shell/agents/openclaw/apply-model-config.sh`
- `shell/agents/openclaw/open-dashboard.sh`
- `shell/agents/openclaw/approve-latest-device.sh`
- `shell/agents/hermes/apply-model-config.sh`
- `shell/agents/hermes/open-dashboard.sh`
- `shell/agents/hermes/find-dashboard-port.sh`

**Dependencies:** No new Cargo or npm packages. The existing `tauri-plugin-opener` and `tokio` remain unchanged. `Invoke-WslBashStreamed` stdin extension must be backward-compatible (existing service lifecycle callers pass no stdin).
