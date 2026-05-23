# two-stream-contract Specification

## Purpose

Establish a strict two-stream logging contract for installer shell scripts: stdout (fd 1) carries only curated, user-facing display lines and step sentinels, while a session log (fd 3, backed by `$CLAW_SESSION_LOG`) captures the full verbose record including raw command output. The contract is implemented through four primitives in `installer/lib/common.sh` — `display`, `log`, `run`, and `step` — and replaces the old `tee`-based `setup_install_log` redirection.

## Requirements

### Requirement: display primitive writes to stdout and log
`display()` in `installer/lib/common.sh` SHALL write its argument to stdout (fd 1) using `printf '%s\n' "$*"` and SHALL also append the same text to fd 3 (the session log file).

#### Scenario: display emits to stdout
- **WHEN** a script calls `display "正在安装系统依赖…"`
- **THEN** the string `正在安装系统依赖…` followed by a newline is written to stdout

#### Scenario: display copies to log
- **WHEN** a script calls `display "正在安装系统依赖…"`
- **THEN** the same string is appended to the session log file referenced by fd 3

### Requirement: log primitive writes to log file only
`log()` in `installer/lib/common.sh` SHALL write its argument only to fd 3 (the session log file) and SHALL NOT write to stdout.

#### Scenario: log does not appear on stdout
- **WHEN** a script calls `log "token = abc123"`
- **THEN** no output appears on stdout

#### Scenario: log writes to session log
- **WHEN** a script calls `log "token = abc123"`
- **THEN** the string `token = abc123` is appended to the session log file

### Requirement: run primitive executes command with output to log only
`run()` in `installer/lib/common.sh` SHALL execute its argument list as a command, redirect both stdout and stderr of that command to fd 3, log the invoked command line to fd 3 before execution, and return the command's exit code.

#### Scenario: run command output goes to log only
- **WHEN** a script calls `run fnm install 22`
- **THEN** the output of `fnm install 22` does not appear on stdout
- **THEN** the output of `fnm install 22` is appended to the session log file

#### Scenario: run logs the command before executing
- **WHEN** a script calls `run fnm install 22`
- **THEN** a line `+ fnm install 22` is appended to the session log file before the command runs

#### Scenario: run returns exit code
- **WHEN** a script calls `run false` (a command that exits 1)
- **THEN** `run` returns exit code 1

### Requirement: step convenience macro combines display sentinel and run
`step()` in `installer/lib/common.sh` SHALL accept a Chinese label as its first argument, `--` as a separator, and a command with arguments after the separator. It SHALL emit `display "@@step:<auto-key>:<label>"` (where auto-key is derived from the label or passed as a named parameter) and then call `run <cmd> <args…>`.

**Note**: The preferred form for explicit key control is `display "@@step:<key>:<label>"` followed by `run <cmd>`, which authors may use directly when the step macro is insufficient.

#### Scenario: step macro emits sentinel and runs command
- **WHEN** a script calls `step "正在配置 Node 22" -- fnm install 22`
- **THEN** `@@step:<key>:正在配置 Node 22` is written to stdout
- **THEN** `fnm install 22` is executed with its output going to the log

### Requirement: fd 3 is opened against CLAW_SESSION_LOG at source time
`installer/lib/common.sh`, when sourced, SHALL execute `exec 3>>"$CLAW_SESSION_LOG"` to open fd 3 in append mode. If `CLAW_SESSION_LOG` is not set in the environment, `common.sh` SHALL auto-generate a fallback path under `$TMPDIR/claw-installer/cli-<timestamp>.log`, create the parent directory, and open fd 3 against that path.

#### Scenario: fd 3 opened when CLAW_SESSION_LOG is set
- **WHEN** `CLAW_SESSION_LOG=/tmp/claw/test.log` is set and `common.sh` is sourced
- **THEN** fd 3 is open and appending to `/tmp/claw/test.log`

#### Scenario: fd 3 falls back to temp file when CLAW_SESSION_LOG is unset
- **WHEN** `CLAW_SESSION_LOG` is not set and `common.sh` is sourced
- **THEN** fd 3 is open against a file under `$TMPDIR/claw-installer/`
- **THEN** the script continues without error

### Requirement: CLAW_SESSION_LOG is inherited by child bash invocations
Rust SHALL set `CLAW_SESSION_LOG` as an environment variable on the child process it spawns (e.g., `bash install.sh`). Sub-scripts invoked via `bash "$agent_script"` (as in `run_agent()` in `install.sh`) SHALL also receive `CLAW_SESSION_LOG` and SHALL open their own fd 3 when they source `common.sh`, appending to the same file.

#### Scenario: child agent script appends to same log file
- **WHEN** `install.sh` invokes `CLAW_SESSION_LOG="$CLAW_SESSION_LOG" bash install-openclaw.sh`
- **THEN** `install-openclaw.sh` opens fd 3 against the same path
- **THEN** log entries from both scripts appear in the same session log file

### Requirement: manifest.sh setup_install_log is removed
`installer/lib/manifest.sh` SHALL NOT contain `setup_install_log()` or the `exec > >(tee -a …) 2>&1` redirection. The `CLAW_INSTALL_LOG` env var SHALL be treated as deprecated and SHALL NOT be set or read by any installer script.

#### Scenario: no tee redirection on manifest sourcing
- **WHEN** `common.sh` is sourced (which sources `manifest.sh`)
- **THEN** stdout is not redirected through a `tee` process
- **THEN** `CLAW_INSTALL_LOG` is not set in the environment
