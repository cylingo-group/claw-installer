## Context

The claw-installer GUI is a Tauri app (Rust + React) that orchestrates bash-based business logic for two AI agents: openclaw and hermes. On Windows both agents run inside WSL; on macOS/Linux they run natively.

Today there are two execution paths from Rust to bash:

**Path A** (service lifecycle — working): Rust calls `powershell.exe shell/windows/bootstrap.ps1 -Service start -Agent openclaw`. PowerShell runs `Invoke-WslBashStreamed -Login`, which base64-encodes a bash script and pipes it through `wsl.exe bash -c "echo $b64 | base64 -d | bash -l"`. The `-l` (login) flag sources `~/.profile` and then `common.sh` is sourced by the agent script, which calls `_claw_compose_path` — giving PATH all of fnm-managed Node, pnpm, uv, brew.

**Path B** (config-patch, dashboard — broken on Windows): Rust directly spawns `wsl.exe -- bash -lc "<inline-script>"`. `-l` does invoke login init, but Ubuntu's `.bashrc` has an early-exit guard for non-interactive shells, so `fnm env` is never evaluated, and Node's versioned bin directory (inside `$FNM_DIR/node-versions/<ver>/installation/bin`) is never added to PATH. `run_in_wsl_file_based` tried to patch this with `export PNPM_HOME=...`, which fixes pnpm's script runner — but pnpm's script runner itself calls `node`, which is still missing. Hence exit=127.

This is a structural problem: Path B will keep diverging from Path A every time `common.sh` learns about a new tool. The fix is to eliminate Path B by routing every Rust→bash call through the same glue layer Path A already uses.

## Goals / Non-Goals

**Goals:**
- One canonical execution path: Rust → per-OS glue layer → business script under `shell/agents/<agent>/<op>.sh`
- The glue layer is the only code that knows about base64 transport, WSL quoting, `WSL_UTF8`, and login-vs-interactive shell distinctions
- Every business script sources `common.sh` first, inheriting the fully-composed PATH
- Stdin forwarding through the glue layer for secrets and structured input (JSON patches, API keys)
- Backward compatibility: existing service lifecycle callers (install, uninstall, start, stop, restart) are not modified
- The specific regression "On Windows with fnm-managed node, save model config fails exit=127" is fixed

**Non-Goals:**
- Changing the macOS/Linux execution path for service lifecycle operations (they already work)
- Modifying agent business logic (what the scripts do once they have a good PATH)
- Changing the `read_installer_state` / `wsl.exe cat` manifest read path — that's a pure file read, not an op dispatch
- Adding new agent operations beyond the six listed in the proposal
- Any frontend (TypeScript/React) changes

## Decisions

### D1: Extend `bootstrap.ps1` with a new `-Op`/`-Agent` verb, not a separate PowerShell script

**Decision**: Add the new dispatch block to `bootstrap.ps1` alongside `Invoke-BashService`, using the existing parameter set pattern.

**Rationale**: `bootstrap.ps1` already contains the proven base64 transport (`Invoke-WslBashStreamed`) and all the distro-resolution, env-forwarding, and error-handling plumbing. A separate script would duplicate all of that. `Invoke-BashService` (lines 995–1037) is the exact template to follow: it validates inputs, builds an env-block, constructs a bash script, and calls `Invoke-WslBashStreamed -Login`. The new `-Op` verb does the same — the only structural difference is the script body and the stdin payload.

**Alternative considered**: A standalone `claw-op.ps1` that imports helpers from `bootstrap.ps1`. Rejected because PowerShell dot-sourcing across files is fragile (relative paths change depending on caller cwd) and bootstrap.ps1 is the single authoritative entry point Rust already invokes.

### D2: Stdin forwarding via base64 — encode the payload on the Rust side, decode inside WSL

**Decision**: The Rust `dispatch_op` function base64-encodes the `stdin_bytes` payload and passes it as an env var `INSTALLER_OP_STDIN_B64` to PowerShell. PowerShell writes it to a temp file inside WSL via a one-liner `echo $b64 | base64 -d > <tmpfile>`, then the business script reads from that temp file instead of process stdin.

**Rationale**: `Invoke-WslBashStreamed` currently uses `& wsl.exe -d $Name -- bash -c $remote` with no stdin pipe — the PowerShell process's own stdin is not connected. Wiring a real pipe from PowerShell to `wsl.exe` requires `[System.Diagnostics.Process]` with `RedirectStandardInput=true`, which is significantly more complex and interacts poorly with PowerShell's job model. The base64-env approach is a minimal extension of the pattern already used for the script body itself, keeps `Invoke-WslBashStreamed` simple, and is safe because `INSTALLER_OP_STDIN_B64` is an env var on the PowerShell process (not exposed in `ps` to other WSL processes).

**Security note**: The decoded payload is written to a `chmod 600` temp file inside WSL's private `/tmp` (Linux FS). The env var holding the base64 is visible in `Get-ChildItem env:` on the Windows side for the duration of the PowerShell process. For API keys this is acceptable — the Windows process is the Tauri app itself, and the key already lives in the Tauri process memory. The alternative (writing a Windows temp file and using `wslpath`) was previously rejected in `apply_openclaw_model_config`'s comment for `/mnt/c/...` path-translation hazards.

**Alternative considered**: Extending `Invoke-WslBashStreamed` to accept a `-Stdin` string parameter and pipe it via `Start-Process -RedirectStandardInput`. Rejected due to complexity and the `& wsl.exe` vs `Start-Process` behavioral differences with signal handling.

### D3: macOS/Linux glue is `shell/claw-op.sh`, not direct `bash agents/<agent>/<op>.sh` from Rust

**Decision**: A thin `shell/claw-op.sh` dispatcher script is the macOS/Linux glue. Rust invokes `bash /path/to/shell/claw-op.sh --op <op> --agent <agent>` (with `login_env` applied, same as today's `run_capture`).

**Rationale**: Symmetry — both OSes have the same Rust call shape: one function, one set of arguments, one return contract. The dispatcher knows where `shell/` lives and can `cd` to the right place before invoking the op script, which is the same thing `bootstrap.ps1` does with `$DestDir`. Rust does not need to know the absolute path of individual op scripts. A dispatcher also gives us a single place to add future cross-cutting concerns (tracing, retries) without touching every op script.

**Alternative considered**: Rust directly computes the op script path (`<app_resource_dir>/shell/agents/<agent>/<op>.sh`) and execs it. Rejected because the path computation in Rust is brittle (resource dir layout differs between dev and production builds) and puts OS-path knowledge in Rust that belongs in the shell layer.

### D4: Input conventions — stdin for secrets/JSON, `INSTALLER_OP_*` env vars for scalar params

**Decision**:
- Secrets (API keys, tokens) → always stdin
- Multi-line structured input (JSON patch) → stdin
- Simple scalar params (provider name, model name, base URL) → env vars prefixed `INSTALLER_OP_*`
- Op/agent selection → argv to glue layer (`--op X --agent Y`)

**Rationale**: Argv is visible in `ps -eo args=` and `/proc/<pid>/cmdline`; env vars are visible in `/proc/<pid>/environ` to root but not to other non-root processes on the same system. Stdin is private. Secrets MUST go via stdin. Non-secret scalars via env vars is simpler than positional args (avoids the `set --` clobber issue that motivated `run_in_wsl_file_based` in the first place) and easier to document per-op. `INSTALLER_OP_*` is chosen over `INSTALLER_*` to namespace op-specific vars away from the existing installer env var convention.

### D5: Business-script file header is the contract document

**Decision**: Each op script's file header (lines after the shebang) documents: what stdin holds, which `INSTALLER_OP_*` env vars it reads, what stdout emits, and what exit codes mean. This is the authoritative input/output contract — no separate spec file per script.

**Rationale**: The spec file (`specs/op-dispatch-protocol/spec.md`) defines the template and invariants. Per-script contracts are implementation-level detail that belongs in the script itself, adjacent to the code. This follows the pattern established by `start.sh` and `install.sh`, which document their behavior in their headers.

### D6: `run_in_wsl_file_based` and `run_in_wsl_with_stdin` are deleted in Phase 3

**Decision**: Both helpers are deleted once all callers are migrated. `run_in_wsl_with_stdin` is also used transitively through `run_in_wsl_file_based` but has no direct callers otherwise.

**Rationale**: Leaving dead helpers in `commands.rs` creates confusion about which path is canonical. The migration safety net is the phased rollout — Phase 1 proves the new transport on one op before Phase 3 deletes the old helpers.

## Risks / Trade-offs

**[R1] Base64-env stdin size limit** → The Windows environment block has a ~32 KB limit per variable. A model-config JSON patch is typically <4 KB; an API key is <1 KB. This is not a practical constraint, but if a future op needs to pass large payloads, the base64-env approach will need to change. Mitigation: document the approach and the size assumption in `dispatch_op`'s code comment.

**[R2] `Invoke-WslBashStreamed` is currently fire-and-forget with no stdin pipe** → Adding the stdin-via-env-var mechanism means the business script must decode `$INSTALLER_OP_STDIN_B64` itself. If `INSTALLER_OP_STDIN_B64` is unset (e.g., for ops that take no stdin), the script must handle the empty case gracefully. Mitigation: the business-script template decodes the variable only if it is non-empty; ops that take no stdin leave the variable unset and skip the decode step.

**[R3] Phase 1 introduces a parallel code path temporarily** → During Phase 1, `apply_openclaw_model_config` (Windows) is migrated while `apply_hermes_model_config` (Windows) still uses the old path. The two paths coexist in `commands.rs`. Mitigation: Phase 1 is scoped to exactly one op per the phased plan; Phase 2 migrates the rest before Phase 3 deletes the old path. The CI build catches type errors; manual smoke testing of both ops is listed as a Phase 2 acceptance criterion.

**[R4] `open-dashboard.sh` (hermes) spawns a long-running process** → The current `open_hermes_dashboard` in Rust handles the async poll loop. The `open-dashboard.sh` op script must replicate the semantics: spawn `hermes dashboard --no-open` detached and return immediately so the Rust caller can poll the port. A script that blocks on the dashboard process would deadlock the GUI. Mitigation: the script uses `nohup ... &` and exits 0 immediately; the Rust `dispatch_op` caller resumes the async port-poll loop.

**[R5] `find-dashboard-port.sh` races with process startup** → If hermes is still starting, `ps -eo args=` may not show the `--port` argument yet. The current behavior (`hermes_port_from_running_process` returning `None` → fallback to default 9119) is preserved: if `find-dashboard-port.sh` finds no running hermes process, it exits 0 with no stdout, and the Rust caller uses `HERMES_DEFAULT_PORT`. Mitigation: document this fallback contract in the script header.

## Migration Plan

**Phase 1 — Foundation (1 op proof-of-concept):**
1. Extend `Invoke-WslBashStreamed` in `bootstrap.ps1` with stdin-via-env-var support
2. Add the `-Op`/`-Agent` dispatch block to `bootstrap.ps1` (validates op name, builds env-block + bash script, calls extended `Invoke-WslBashStreamed -Login`)
3. Add `shell/claw-op.sh` dispatcher for macOS/Linux
4. Add `shell/agents/openclaw/apply-model-config.sh` (sources `common.sh`, decodes stdin to temp file, runs `openclaw config patch` + `openclaw config validate`)
5. Add `dispatch_op(agent, op, stdin_bytes)` Rust helper in `commands.rs`
6. Migrate `apply_openclaw_model_config` (Windows) to use `dispatch_op`
7. Smoke test: on a Windows machine with fnm-managed Node, save openclaw model config — verify no exit=127

**Phase 2 — Migrate remaining ops:**
8. `shell/agents/hermes/apply-model-config.sh` + migrate `apply_hermes_model_config` (Windows)
9. `shell/agents/openclaw/open-dashboard.sh` + `shell/agents/openclaw/approve-latest-device.sh` + migrate `open_openclaw_dashboard` + `try_approve_latest_device`
10. `shell/agents/hermes/open-dashboard.sh` + `shell/agents/hermes/find-dashboard-port.sh` + migrate `open_hermes_dashboard` + `hermes_port_from_running_process` (Windows)
11. Smoke test all six ops on Windows; regression test service lifecycle ops are unaffected

**Phase 3 — Cleanup:**
12. Delete `run_in_wsl_file_based` from `commands.rs`
13. Delete `run_in_wsl_with_stdin` from `commands.rs` (confirm no remaining callers)
14. Delete the PATH-preamble inline string from the deleted `run_in_wsl_file_based`
15. Delete `run_capture` Windows branch from `dashboard.rs` (replaced by `dispatch_op`)
16. Verify `cargo build --target x86_64-pc-windows-msvc` (or cross-compile check) passes
17. Verify `cargo build` on macOS passes

**Rollback**: Phase 1 and 2 can be reverted by restoring `commands.rs` to the pre-migration state and deleting the new op scripts. Phase 3 deletions should only land once Phase 2 smoke tests pass. No database migrations, no user-visible data format changes — rollback is a pure code revert.

## Open Questions

**OQ-1 — RESOLVED (Phase 1)**: `dispatch_op` on macOS/Linux uses `login_env::login_env()` applied in Rust before spawning `bash claw-op.sh`. `claw-op.sh` does not re-source login init. This is consistent with the existing `run_capture` approach and keeps Rust in control of the environment setup. `claw-op.sh` execs the op script directly with the inherited environment.

**OQ-2**: The `open_hermes_dashboard` async poll loop currently lives in Rust (tokio). After migration, the `open-dashboard.sh` script exits immediately (detaching the daemon). The Rust caller must still poll `is_listening(port)`. Should `dispatch_op` be `async` or should the caller handle the async poll separately? Recommendation: `dispatch_op` is synchronous (blocking); the async poll stays in `open_hermes_dashboard` in Rust, calling `dispatch_op("hermes", "find-dashboard-port", b"")` to find the port, then polling `is_listening` as today.

**OQ-3**: For `approve-latest-device`, the current polling loop (75 × 400ms) spawns a background thread. After migration, each poll iteration calls `dispatch_op("openclaw", "approve-latest-device", b"")`, which invokes PowerShell → WSL → bash. The per-call overhead on Windows is ~500ms–1s. With 75 iterations at 400ms sleep, the total wall time could exceed 30s even if all iterations succeed early due to WSL startup latency. Should the poll interval be increased, or should the approve logic move into a longer-running script with its own loop? Recommendation: increase poll interval to 1s (75 × 1s = 75s budget, still reasonable) and reduce iterations to 45 (45s budget). This is a parameter change, not a design change — note it in the tasks for the developer.
