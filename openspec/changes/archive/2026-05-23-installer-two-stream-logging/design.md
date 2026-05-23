## Context

The claw-installer GUI renders a 5-line log strip driven by `LogLine` events streamed from Rust. Today Rust tries to filter and translate every raw stdout line from the shell scripts — suppressing ANSI codes, matching `==> step:` prefixes, calling `is_user_friendly()` and `friendly_display()` on every line to decide whether to pass it to the frontend. This filter logic is incomplete (it misses Hermes upstream's `→ ✓ ⚠` prefixes, pnpm's progress bars, `openclaw config set` echoes, etc.), brittle (any new step format breaks it silently), and wrong in principle (Rust cannot know what a shell script intends to say to the user without the script author's intent).

The current `installer/lib/common.sh` has a `log()` that emits ANSI-colored text to stdout and a `setup_install_log()` in `lib/manifest.sh` that uses `tee` to duplicate all stdout+stderr to `~/.claw-installer/install-*.log`. This means every color code, every pnpm progress bar character, and every upstream installer English line is both shown to the user and written to the log.

**Stakeholders**: non-technical end-users (see the GUI's 5-line strip), developer/power users (CLI direct execution), Rust backend (event parsing), and QA (log forensics).

## Goals / Non-Goals

**Goals:**

- Scripts become the single source of truth for what the user sees.
- Every user-visible string is explicitly authored in Chinese by the script author.
- Rust reduces to: (1) set `CLAW_SESSION_LOG` env, (2) forward stdout verbatim as `LogLine`, (3) match `@@step:` lines to emit `StepChanged`.
- The session log file (`CLAW_SESSION_LOG`) contains the complete forensic record: every `display` copy, every `log` detail line, every command run, and each command's full stdout+stderr.
- Terminal CLI users see only friendly Chinese lines by default; `--debug` gives them everything.
- Failures produce a structured 3-line `✗` block on stdout that the GUI can detect without custom parsing logic.

**Non-Goals:**

- Frontend `LogStrip` rendering changes (it already handles plain UTF-8 `LogLine` events).
- New Rust translation tables (the `step_label()` lookup can be slimmed — the label now travels inline in the sentinel — but no new entries are added).
- Migration of existing `~/.claw-installer/install-*.log` files.
- Service control (start/stop/restart) — v1.1 scope.
- Adding more step keys in `steps.rs` (the key now serves only as a unique ID for `StepChanged.key`; the label comes from the script).

## Decisions

### D1: Three primitives, not one

**Decision**: `display()`, `log()`, `run()` as three distinct shell functions, plus `step()` as a convenience macro and `die_step()` as the failure handler.

**Rationale**: A single unified function (`step "label" -- cmd`) forces the author to always produce a display line even for internal bookkeeping (e.g., recording a manifest entry). Separating the three concerns lets authors be granular: `log "token = $token_masked"` without emitting that to the user, `display "正在写入配置…"` without running a command, or `run openclaw config set key val` in a loop without a separate display per iteration.

**Alternative rejected**: A single `step "label" -- cmd` macro for everything. Rejected because some steps have no command (they compute and decide), some commands have no display (manifest bookkeeping), and forcing a display for every `run` would produce dozens of noisy Chinese lines per step.

The `step()` macro is additive: `step "正在配置 Node 22" -- fnm install 22` expands to `display "@@step:node:正在配置 Node 22" && run fnm install 22`. Authors can always drop down to the three primitives when the macro is insufficient.

### D2: `@@step:<key>:<label>` sentinel format

**Decision**: Use `@@step:<key>:<label>` as the stdout sentinel, parsed by Rust with the regex `^@@step:([a-z][a-z0-9-]*):(.+)$`.

**Rationale**: `@@` is visually distinctive and collides with nothing in normal command output. The colon-separated format is grep-friendly. Embedding the label in the sentinel means Rust's `step_label()` lookup table is no longer load-bearing — Rust can derive the `StepChanged.label` directly from the line, which makes the scripts self-describing without a matching Rust map update on every new step.

**Alternative rejected**: Keep `==> <key>:` prefix and translate in Rust. Rejected because the `==>` prefix appears in Hermes upstream output (its `→` arrows are different, but close enough to create ambiguity for future script authors) and because Rust still has to own a translation table for every step.

**Alternative rejected**: JSON-encoded sentinel (e.g., `@@{"type":"step","key":"node","label":"..."}`). Rejected as unnecessarily heavy for a log format read by humans and shell `grep`.

### D3: fd 3 for the log stream

**Decision**: `exec 3>>"$CLAW_SESSION_LOG"` opens fd 3 in `common.sh` immediately after sourcing. `log()` and `run()` write to `>&3`. `display()` writes to stdout and also copies to `>&3`.

**Rationale**: fd 3 is a process-level inherited file descriptor, so sub-scripts sourced via `source "$file"` inherit it automatically. Using a named file descriptor avoids re-opening the log file on every `log` call and is compatible with `run()` redirecting command output via `"$@" >&3 2>&3`. It does not conflict with fd 0/1/2 (stdin/stdout/stderr).

**Alternative rejected**: Reopen `$CLAW_SESSION_LOG` in each call via `>> "$CLAW_SESSION_LOG"`. Rejected because it creates a race condition if two sub-processes write simultaneously and is slower (file open on every call).

**Alternative rejected**: Pipe everything through a co-process. Rejected as complex and hard to debug.

**Guard**: `common.sh` checks `[[ -n "${CLAW_SESSION_LOG:-}" ]]` before `exec 3>>`; if unset (direct CLI without Rust), it falls back to fd 3 → `/dev/null` so scripts run safely from the terminal without a GUI.

### D4: Rust owns the log file lifecycle, passes path via env

**Decision**: Rust pre-creates `$TMPDIR/claw-installer/<install|uninstall>-<UTC>.log` before spawning the child, sets `CLAW_SESSION_LOG=<path>` in the child's environment, and keeps the path to include in the `InstallerEvent::LogPath` event it already sends.

**Rationale**: Rust creates the file so it can open it for reading (for the `LogPath` wiring that surfaces the failure banner in the GUI). The script appends to it. This ownership split is clean: Rust controls where the file lives; the script controls what goes in it.

**Alternative rejected**: Script creates the file, emits the path as a sentinel line. Rejected because Rust needs the path before the script emits it (to send `LogPath` at startup), and parsing a special sentinel just for the path is more fragile.

**Deprecated**: `setup_install_log()` in `lib/manifest.sh` and the `CLAW_INSTALL_LOG` env var. The `tee -a` redirection at line 57 of `manifest.sh` is removed. Existing `~/.claw-installer/install-*.log` files are left in place.

### D5: `--debug` implementation via background `tail -F`

**Decision**: When `--debug` is passed, after `exec 3>>"$CLAW_SESSION_LOG"`, run `tail -F "$CLAW_SESSION_LOG" >&2 &` and record the PID. On EXIT trap, kill the tail process.

**Rationale**: `tail -F` is available on macOS and all Linux targets. Background tail to stderr means the log stream appears interleaved with stdout in the terminal. This is standard behavior familiar to developers (`tail -f /var/log/...`).

**Alternative rejected**: `exec 2>&3` (merge stderr into fd 3) plus `set -x` for debug. Rejected because `set -x` adds noise and leaks secrets in `export` statements.

**Alternative rejected**: `tee` on fd 3. Rejected: `tee` can't forward an already-open fd; `tail -F` is simpler for this use case.

### D6: `die_step` — `trap ERR` + `$CURRENT_STEP` global

**Decision**: `display "@@step:<key>:<label>"` also sets `CURRENT_STEP="<label>"` in the caller's scope. A `trap 'die_step_handler' ERR` in each entry-point script calls `die_step_handler()` which emits the 3-line `✗` block using `$CURRENT_STEP` and the failing command from `$BASH_COMMAND`.

**Rationale**: Using `trap ERR` means even inline shell constructs that call `run` implicitly (e.g., `if run ...; then`) produce the structured failure block without any change at the call site. Authors do not need to wrap every `run` in error-checking boilerplate.

**Alternative rejected**: `run()` returns exit code and the caller checks it explicitly. Rejected because `set -euo pipefail` already causes the script to exit on first error; every callsite would need its own `|| die_step "..."` which is error-prone.

**Alternative rejected**: `run()` itself calls `die_step`. Rejected because `run()` does not know the current step label; adding that state to `run()` would couple it to `display`.

**`die_step` output format** (to stdout so Rust/GUI detects it):
```
✗ 失败步骤：<$CURRENT_STEP>
✗ 失败原因：<$BASH_COMMAND> 退出码 <$?>
✗ 详见完整日志：<$CLAW_SESSION_LOG>
```

### D7: Hermes upstream installer wrapped via `run`

**Decision**: Replace the current `run_with_timeout 1800 bash "$tmp" "${args[@]}" </dev/null` in `install-hermes.sh` with `run bash "$tmp" "${args[@]}" </dev/null` (or `run_with_timeout 1800 bash ...` with timeout still applied). Before this call, `display "正在运行 Hermes 上游安装脚本（首次约 2-5 分钟）…"`. After success, `display "✓ Hermes 上游安装完成"`.

**Rationale**: Wrapping via `run` ensures the upstream's `→ ✓ ⚠ ✗` English output goes only to the log (fd 3). The user sees only the single Chinese status line. The `run_with_timeout` wrapper needs a small adjustment: it must also redirect the child's stdout+stderr to fd 3.

**Note on `run_with_timeout` compatibility**: `run_with_timeout` forks the command to a background subshell. After this change, the caller should use `run run_with_timeout 1800 bash "$tmp" ...` or inline the timeout logic inside `run()`. The simplest approach: add a `run_with_timeout_logged` variant that does the same as `run_with_timeout` but redirects to fd 3. This avoids changing `run()`'s interface.

### D8: PowerShell equivalents

**Decision**: Add three functions to `bootstrap.ps1`:
- `Write-Display $msg`: writes to stdout (console host) and appends `"[display] $msg"` to the session log file.
- `Write-Log $msg`: appends `$msg` to the session log file only.
- `Invoke-Logged $cmd`: runs a scriptblock, redirecting its output to the session log file.

The `-Debug` switch (PowerShell native parameter conflicts; use `-DebugMode` to avoid collision with PowerShell's built-in `-Debug`) enables `Get-Content -Wait -Path $sessionLog` tailing to stderr.

**Note**: PowerShell's `-Debug` is a reserved common parameter. Rename to `-DebugMode [switch]` to avoid conflict.

## Risks / Trade-offs

**[Risk] `trap ERR` interaction with `set -euo pipefail`** → In bash, `trap ERR` fires on any non-zero exit from a simple command when `set -e` is active. However, it does NOT fire inside functions called from conditionals (e.g., `if my_fn; then`). If a `run` call is inside a conditional, `die_step_handler` will not fire. **Mitigation**: Document this as a known limitation. For commands that legitimately return non-zero (e.g., `grep` used for a test), authors use `run cmd || true` explicitly, which suppresses the trap. The `run()` function should document this contract.

**[Risk] fd 3 inheritance through sub-scripts** → All step scripts are `source`d (not spawned), so they inherit fd 3. However, `run_with_timeout` spawns a background sub-shell; that subshell also inherits fd 3 since the fd is open before the fork. This is correct behavior, but if a step is run in a completely separate bash invocation (e.g., `bash step.sh`), fd 3 will not be open. **Mitigation**: All step scripts are sourced, not exec'd. The `run_agent` function in `install.sh` calls `INSTALLER_SKIP_ENV=1 CLAW_SESSION_LOG="..." bash "$script"` — the child bash will open its own fd 3 because it sources `common.sh`. This is correct.

**[Risk] `CLAW_SESSION_LOG` unset in direct CLI use** → If a developer runs `./install.sh` from the terminal without setting `CLAW_SESSION_LOG`, `exec 3>>` will fail. **Mitigation**: `common.sh` checks `${CLAW_SESSION_LOG:-}` and falls back to a temp file auto-generated in `$TMPDIR/claw-installer/cli-<ts>.log`, then opens fd 3 against that. This ensures the script always has a working log file even without Rust.

**[Risk] `@@step:` pattern in legitimate script output** → If a command run via `run()` emits a line starting with `@@step:`, Rust will misinterpret it as a step transition. **Mitigation**: `@@step:` is designed to be uncommon in real command output. The pattern requires the `@@` prefix, which does not appear in standard Unix tool output. Accept this theoretical risk; document it as a contract.

**[Risk] Tail-F race on `--debug`** → The `tail -F` process is started after fd 3 is open but before any log writes; on very fast steps the first few log lines might appear after the matching stdout display line. **Mitigation**: This is cosmetic only; `tail -F` is eventually consistent and the full log is always complete.

**[Risk] Dropping `tee` breaks existing `CLAW_INSTALL_LOG` consumers** → If any external tooling reads `CLAW_INSTALL_LOG` from the env to find the log file, removing `setup_install_log` breaks them. **Mitigation**: `CLAW_INSTALL_LOG` is an internal variable not documented as a public contract. The GUI reads `InstallerEvent::LogPath` (set by Rust from `CLAW_SESSION_LOG`), not `CLAW_INSTALL_LOG`. Accept the break; no external consumers are known.

## Migration Plan

1. Rust ships the updated `CLAW_SESSION_LOG` env injection and `@@step:` parser in the same release as the script changes. The two changes must be in the same PR or release branch — one without the other will break the installer.
2. Scripts with the new primitives must not be run via older Rust builds (which expect `==> step:` markers). The easiest guard: bump a `CLAW_INSTALLER_CONTRACT=2` env var that Rust checks; if absent (old Rust), Rust falls back to the old parser. This is optional for v1 since the team controls both sides.
3. Old `~/.claw-installer/install-*.log` files remain. New logs land in `$TMPDIR/claw-installer/`. No migration tooling is needed.
4. Rollback: revert the `installer/lib/common.sh` change and the Rust diff together. The manifest TSV schema is unchanged, so rollback does not affect install state.

## Open Questions

**OQ-1: `run_with_timeout` + fd 3 compatibility.** The current `run_with_timeout` in `common.sh` forks a background subshell that inherits fd 3. Does fd 3 flush correctly if the timeout killer sends `SIGTERM` to the command? In bash, file descriptor writes are not buffered at the shell level (each `printf >&3` is a direct `write(2)` syscall), so truncation on SIGTERM is unlikely but possible at the kernel level. **Decision needed before implementation**: add an explicit `exec 3>&-` in the killer's trap to force flush, or accept the edge case.

**OQ-2: `step()` macro and `CURRENT_STEP` scoping.** The `step()` function sets `CURRENT_STEP` in the caller's scope. In bash, functions do not have their own scope for exported variables — the assignment is global. If two concurrent steps were running (they don't today, but could in a future parallel install), `CURRENT_STEP` would be shared. **Current stance**: single-threaded install, accept the shared global. Document the constraint.

**OQ-3: `bootstrap.ps1 -DebugMode` vs `-Debug`.** PowerShell's `[CmdletBinding()]` reserves `-Debug` as a common parameter. The proposed replacement `-DebugMode` must be validated that it is not also reserved. Confirm before implementation.
