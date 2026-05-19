## Why

The GUI's 5-line log strip is unreadable for non-technical users because the shell scripts today emit raw technical output — `set gateway.port = 7841`, pnpm progress bars, English Hermes upstream lines — directly to stdout, while Rust's filter layer tries to translate and suppress noise after the fact. This approach is brittle, incomplete, and couples Rust to the exact format of every script's output. The fix moves authorship of what users see into the scripts themselves, where the author knows exactly what each step means.

## What Changes

- **`installer/lib/common.sh`**: Replace the existing `log()` / `warn()` / `die()` helpers with five new primitives — `display()`, `log()`, `run()`, `step()`, `die_step()` — and open fd 3 pointing at a per-session log file whose path is provided by Rust via the `CLAW_SESSION_LOG` env var.
- **`installer/lib/manifest.sh`**: Drop `setup_install_log()` and the `tee -a $CLAW_INSTALL_LOG` redirection; `CLAW_SESSION_LOG` is the sole session log path going forward.
- **`installer/install.sh`**: Add `--debug` flag; rewrite all `log` callsites to `display` / `log` / `run` / `step`; remove `setup_install_log` call.
- **`installer/install-openclaw.sh`**: Same as above — add `--debug`, rewrite callsites, drop `setup_install_log`.
- **`installer/install-hermes.sh`**: Same; wrap upstream installer via `run bash "$tmp" ...` so its output goes to the log only; emit Chinese `display` lines before/after.
- **`installer/uninstall.sh`**: Add `--debug` flag; rewrite `log` / `warn` callsites to the new primitives; `uninstall.sh` reads the manifest and does not generate a new install log, so it shares fd 3 for all output.
- **`installer/steps/*.sh`** (base-deps, fnm, node, hermes-node, pnpm, npmrc, shell-rc, system-tools, uv, python): Rewrite every `log` callsite — each step decides in Chinese what the user sees via `display` and what goes to the log via `log` / `run`.
- **`installer/windows/bootstrap.ps1`**: Add `-Debug` switch; add `Write-Display`, `Write-Log`, `Invoke-Logged` PowerShell equivalents of the shell primitives.
- **Rust `gui/src-tauri/src/`**: Delete `is_user_friendly`, `friendly_display`, `strip_ansi`, and the `==> step:` parser; replace with a single `@@step:` regex on stdout; set `CLAW_SESSION_LOG` env on spawn; stop writing the log file from Rust.
- **BREAKING** (Rust internal): `parse_step_line()` in `steps.rs` changes its expected pattern from `==> <key>:` to `@@step:<key>:<label>`.

## Capabilities

### New Capabilities

- `two-stream-contract`: The logging contract itself — `display` writes to stdout (user-visible), `log` writes to fd 3 (log file only), `run` executes a command with stdout+stderr redirected to fd 3. The `step()` convenience macro combines a `display "@@step:..."` sentinel with a `run` invocation. The `die_step()` helper emits a structured 3-line `✗` failure block to stdout and exits.
- `structured-step-sentinel`: The `@@step:<key>:<label>` stdout sentinel that Rust parses to emit `StepChanged` events. Replaces the old `==> <key>:` pattern. The label travels inline in the sentinel, so Rust's `step_label()` lookup table becomes optional.
- `cli-debug-mode`: `--debug` flag on each shell entry point (`install.sh`, `install-openclaw.sh`, `install-hermes.sh`, `uninstall.sh`) and `-Debug` switch on `bootstrap.ps1`. When active, the session log is tail-followed and output is forwarded to stderr in real time so terminal operators see everything.
- `structured-failure-output`: When any `run` command exits non-zero, `die_step` emits three `✗`-prefixed lines to stdout (step name, failing command + exit code, path to the session log) so the GUI can surface them prominently.
- `rust-passthrough`: Rust becomes a dumb stdout forwarder. No filter table, no ANSI stripping, no translation. Every stdout line is forwarded verbatim as a `LogLine` event except `@@step:` lines which become `StepChanged` events.

### Modified Capabilities

(none — no existing `openspec/specs/` files are defined for this project yet)

## Impact

- **Installer scripts** (all `.sh` files under `installer/`): significant rewrite of callsites; no change to the external env-var contract (`INSTALLER_*`) or manifest TSV schema.
- **`installer/lib/manifest.sh`**: `setup_install_log()` deleted; `CLAW_INSTALL_LOG` env var deprecated.
- **Rust `gui/src-tauri/src/commands.rs` and `steps.rs`**: filter helpers deleted, `@@step:` regex added, `CLAW_SESSION_LOG` env set on spawn.
- **`installer/windows/bootstrap.ps1`**: three new PowerShell functions, one new switch.
- **Frontend (`gui/src/`)**: no changes — `LogLine` / `LogPath` / `StepChanged` events are already handled; the content of `LogLine` simply becomes cleaner.
- **Existing `~/.claw-installer/install-*.log` files**: not migrated; new logs land in `$TMPDIR/claw-installer/`.
