# rust-passthrough Specification

## Purpose

Define the Rust (Tauri backend) event-loop contract for forwarding installer child-process output to the GUI: stdout lines are passed through verbatim as `LogLine` events except for `@@step:` sentinels which are consumed and re-emitted as structured `StepChanged` events. No filtering, ANSI stripping, or label translation is applied; the shell scripts are the single source of truth for user-facing strings.

## Requirements

### Requirement: Rust forwards all stdout lines verbatim as LogLine except @@step sentinels
The Rust event loop (`run_event_loop` or equivalent in `gui/src-tauri/src/commands.rs`) SHALL forward every line received from the child process stdout as `InstallerEvent::LogLine { line }` EXCEPT lines that match the `@@step:` regex. Lines that match SHALL be consumed to emit `StepChanged` and SHALL NOT be forwarded as `LogLine`.

#### Scenario: non-sentinel stdout line becomes LogLine
- **WHEN** the child emits `正在安装系统依赖…` on stdout
- **THEN** Rust emits `LogLine { line: "正在安装系统依赖…" }`

#### Scenario: sentinel line is consumed and not forwarded
- **WHEN** the child emits `@@step:node:正在配置 Node 运行时`
- **THEN** Rust emits `StepChanged { key: "node", label: "正在配置 Node 运行时", detail: "" }`
- **THEN** Rust does NOT emit `LogLine { line: "@@step:node:正在配置 Node 运行时" }`

### Requirement: Rust deletes is_user_friendly, friendly_display, and strip_ansi
The functions `is_user_friendly()`, `friendly_display()`, and `strip_ansi()` (or equivalently named helpers) in the Rust backend SHALL be deleted. No line filtering, no ANSI stripping, and no translation lookup SHALL be applied to stdout lines before forwarding as `LogLine`.

#### Scenario: raw line is forwarded without filtering
- **WHEN** the child emits any UTF-8 line on stdout that does not match `@@step:`
- **THEN** the exact bytes (as UTF-8 string) are forwarded as `LogLine`

### Requirement: Rust sets CLAW_SESSION_LOG on child process spawn
Before spawning the child process, Rust SHALL:
1. Compute the session log path as `temp_dir()/claw-installer/<install|uninstall>-<UTC-unix-timestamp>.log`.
2. Create the parent directory if it does not exist.
3. Create (or truncate) the log file.
4. Pass `CLAW_SESSION_LOG=<path>` as an environment variable to the child.
5. Emit `InstallerEvent::LogPath { path: <path> }` immediately after spawn (before the first stdout line is received).

#### Scenario: CLAW_SESSION_LOG is set on child env
- **WHEN** Rust spawns `bash install.sh`
- **THEN** the child process receives `CLAW_SESSION_LOG` set to the computed log path

#### Scenario: LogPath event is emitted at spawn time
- **WHEN** Rust spawns the child process
- **THEN** `InstallerEvent::LogPath { path: … }` is emitted before any `LogLine` event

### Requirement: parse_step_line is replaced by inline @@step: regex
`steps.rs` SHALL replace the `parse_step_line()` function (which parsed `==> <key>:`) with an inline regex match on `^@@step:([a-z][a-z0-9-]*):(.+)$`. The regex SHALL be compiled once (via `OnceLock<Regex>` or equivalent) and reused across all lines in the event loop.

#### Scenario: regex matches valid sentinel
- **WHEN** Rust applies the `@@step:` regex to `@@step:base-deps:正在安装系统依赖…`
- **THEN** match succeeds with key = `base-deps` and label = `正在安装系统依赖…`

#### Scenario: regex does not match non-sentinel lines
- **WHEN** Rust applies the `@@step:` regex to `pnpm add -g openclaw@latest`
- **THEN** match fails and the line is forwarded as `LogLine`

### Requirement: step_label lookup table is optional / can be slimmed
With labels traveling inline in the `@@step:` sentinel, the `step_label()` function in `steps.rs` is no longer required for `StepChanged` label population. Rust SHALL use the label from the sentinel directly. The `step_label()` function MAY be retained for stub mode / testing but SHALL NOT be called on the live event stream.

#### Scenario: StepChanged label comes from sentinel, not lookup table
- **WHEN** Rust parses `@@step:node:正在配置 Node 运行时（来自脚本）`
- **THEN** `StepChanged.label` is `正在配置 Node 运行时（来自脚本）`
- **THEN** `step_label("node")` is NOT called to override it

### Requirement: stderr from child process is NOT forwarded
The Rust event loop SHALL discard (or log to an internal debug channel) any `CommandEvent::Stderr` lines from the child process. Under the new contract, scripts do not emit user-visible content to stderr (only `warn()` uses it, and `warn()` is deprecated in favor of `log()`). Forwarding stderr would expose internal noise to the GUI.

**Note**: `warn()` in the old `common.sh` writes ANSI-colored text to stderr. In the new contract, `warn()` is replaced by `log()` (fd 3). Any residual stderr output (e.g., from `die_step_handler` calling `exit`) can be safely discarded.

#### Scenario: stderr lines are discarded and not forwarded
- **WHEN** the child process writes any line to stderr
- **THEN** Rust does NOT emit a `LogLine` event for that line
