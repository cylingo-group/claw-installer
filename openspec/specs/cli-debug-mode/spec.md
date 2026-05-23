# cli-debug-mode Specification

## Purpose

Provide an opt-in `--debug` mode for direct CLI users of the installer scripts that streams the session log to the terminal in real time, so developers and advanced users can see full command output without polluting the default friendly UX.

## Requirements

### Requirement: --debug flag on shell entry points
Each bash entry-point script (`install.sh`, `install-openclaw.sh`, `install-hermes.sh`, `uninstall.sh`) SHALL accept a `--debug` flag as a command-line argument. When `--debug` is present, the script SHALL start a background `tail -F "$CLAW_SESSION_LOG" >&2` process immediately after fd 3 is opened, store its PID, and register an EXIT trap to kill that process on script exit.

#### Scenario: debug mode starts tail process
- **WHEN** `./install.sh --debug` is invoked
- **THEN** a `tail -F <session-log>` process is started in the background
- **THEN** session log entries appear on stderr in real time as the install progresses

#### Scenario: tail process is killed on script exit
- **WHEN** `./install.sh --debug` completes (success or failure)
- **THEN** the background `tail` process is sent SIGTERM and exits
- **THEN** no orphan `tail` processes remain after the script exits

### Requirement: without --debug, terminal users see only display lines
When `--debug` is NOT passed, terminal (direct CLI) users SHALL see only the lines emitted by `display()` on stdout — no log details, no command output. This is the default behavior.

#### Scenario: no --debug means only friendly output
- **WHEN** `./install.sh` is run without `--debug` from a terminal
- **THEN** stdout contains only lines emitted via `display()`
- **THEN** stdout contains no raw command output (e.g., no pnpm progress bars)

### Requirement: --debug is forwarded to child agent scripts
When `install.sh` invokes `bash install-openclaw.sh` or `bash install-hermes.sh` with debug mode active, it SHALL pass the `--debug` flag (or equivalent env var) to the child invocations so the child scripts also tail the session log.

#### Scenario: debug flag propagates to child scripts
- **WHEN** `./install.sh --debug` is run
- **THEN** the child `install-openclaw.sh` and `install-hermes.sh` invocations also activate their `tail -F` processes

### Requirement: -DebugMode switch on bootstrap.ps1
`installer/windows/bootstrap.ps1` SHALL add a `-DebugMode [switch]` parameter. When active, after the session log path is determined, it SHALL start a background `Get-Content -Wait -Path $SessionLog` job and display its output to the host, stopping the job on script exit.

#### Scenario: -DebugMode streams session log on Windows
- **WHEN** `bootstrap.ps1 -DebugMode` is run
- **THEN** session log content is streamed to the PowerShell host in real time
- **THEN** the streaming job is stopped when the script exits

### Requirement: CLAW_SESSION_LOG is reported to the user in --debug mode
When `--debug` is active, the script SHALL print the session log path as a `display` line at startup (e.g., `display "日志文件：$CLAW_SESSION_LOG"`) so the user knows where to find the full log.

#### Scenario: session log path is displayed in debug mode
- **WHEN** `./install.sh --debug` is run
- **THEN** a line containing the session log path appears on stdout before any step output
