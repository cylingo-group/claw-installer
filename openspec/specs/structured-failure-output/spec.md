# structured-failure-output Specification

## Purpose

Define a uniform, machine-parseable failure block that installer scripts emit when a step fails, so both terminal users and the Tauri GUI receive a consistent, prominent indication of which step failed, why, and where to find full logs. The block is implemented by `die_step()` / `die_step_handler` in shell, propagates through Rust unchanged, and is surfaced by the GUI's existing `LogStrip`.

## Requirements

### Requirement: die_step emits a 3-line failure block to stdout
`die_step()` in `installer/lib/common.sh` SHALL emit exactly three lines to stdout, each prefixed with `✗ `, before calling `exit 1`:

```
✗ 失败步骤：<step-label>
✗ 失败原因：<command> 退出码 <exit-code>
✗ 详见完整日志：<CLAW_SESSION_LOG-path>
```

`die_step` SHALL also append the same three lines to the session log (fd 3).

#### Scenario: die_step produces three ✗-prefixed lines
- **WHEN** `die_step "正在配置 Node 运行时" "fnm install 22" 1` is called
- **THEN** stdout receives `✗ 失败步骤：正在配置 Node 运行时`
- **THEN** stdout receives `✗ 失败原因：fnm install 22 退出码 1`
- **THEN** stdout receives `✗ 详见完整日志：<session-log-path>`
- **THEN** the script exits with code 1

#### Scenario: die_step appends failure block to session log
- **WHEN** `die_step` is called
- **THEN** the three `✗` lines are also appended to the session log file

### Requirement: CURRENT_STEP global is updated by display sentinel
When `display "@@step:<key>:<label>"` is called (directly or via the `step()` macro), the shell variable `CURRENT_STEP` SHALL be set to `<label>` in the calling scope so that `die_step_handler` can reference it without additional arguments.

#### Scenario: CURRENT_STEP is set on sentinel display
- **WHEN** a script executes `display "@@step:node:正在配置 Node 运行时"`
- **THEN** the variable `CURRENT_STEP` equals `正在配置 Node 运行时` in the script's scope

### Requirement: trap ERR calls die_step_handler automatically
Each entry-point script (`install.sh`, `install-openclaw.sh`, `install-hermes.sh`, `uninstall.sh`) SHALL register `trap 'die_step_handler' ERR` after sourcing `common.sh`. `die_step_handler()` in `common.sh` SHALL emit the 3-line failure block using `$CURRENT_STEP` and `$BASH_COMMAND` and then re-exit with the failing command's exit code.

#### Scenario: ERR trap fires on failing run command
- **WHEN** `set -euo pipefail` is active and `run fnm install 22` exits non-zero
- **THEN** `die_step_handler` is invoked automatically
- **THEN** the 3-line `✗` block is emitted to stdout before the script exits

#### Scenario: ERR trap does not fire on intentional non-zero inside || true
- **WHEN** a script executes `run some-cmd || true`
- **THEN** `die_step_handler` is NOT invoked even if `some-cmd` exits non-zero

### Requirement: Rust GUI surfaces ✗-prefixed lines prominently
The Rust event loop SHALL recognize lines beginning with `✗ ` as failure indicator lines and SHALL forward them as `LogLine` events. The frontend's existing `LogStrip` already renders `LogLine` events; no new event type is required. Rust MAY additionally send a `Finished { success: false, message: <first ✗ line> }` event on process termination to trigger the error banner.

#### Scenario: failure lines reach the GUI as LogLine events
- **WHEN** the child process emits `✗ 失败步骤：正在配置 Node 运行时` on stdout
- **THEN** Rust emits `LogLine { line: "✗ 失败步骤：正在配置 Node 运行时" }`
- **THEN** the frontend's LogStrip displays the line

### Requirement: Hermes upstream installer failure is handled via die_step
In `install-hermes.sh`, if `run bash "$tmp" "${args[@]}"` (the upstream installer invocation) exits non-zero, `die_step` SHALL be called with the current step label (`$CURRENT_STEP`) and a message indicating the upstream installer failure. The script SHALL NOT continue to the manifest recording or summary steps after a failed upstream install.

#### Scenario: upstream installer failure triggers die_step
- **WHEN** the Hermes upstream installer exits with code 1
- **THEN** `die_step` emits the 3-line failure block referencing the Hermes install step
- **THEN** the script exits with code 1 without calling `print_hermes_summary`
