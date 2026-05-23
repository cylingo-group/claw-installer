# structured-step-sentinel Specification

## Purpose

Define a single, regex-parseable sentinel format (`@@step:<key>:<label>`) that installer scripts emit on stdout to mark step transitions. The sentinel carries both the machine-readable step key and the human-readable label inline, eliminating the need for a separate label lookup table in Rust and giving shell scripts full control over user-facing wording.

## Requirements

### Requirement: step sentinel format is @@step:<key>:<label>
Every step transition emitted to stdout by installer scripts SHALL use the format `@@step:<key>:<label>` where `<key>` is a lowercase kebab-case ASCII identifier and `<label>` is a human-readable Chinese (or mixed) string describing what is happening. The sentinel SHALL be written via `display "@@step:<key>:<label>"` so it also appears in the session log.

#### Scenario: sentinel is emitted on stdout
- **WHEN** a script executes `display "@@step:node:正在配置 Node 运行时"`
- **THEN** the exact string `@@step:node:正在配置 Node 运行时` followed by a newline appears on stdout

#### Scenario: sentinel format is parseable by regex
- **WHEN** Rust applies the regex `^@@step:([a-z][a-z0-9-]*):(.+)$` to the line `@@step:node:正在配置 Node 运行时`
- **THEN** capture group 1 is `node`
- **THEN** capture group 2 is `正在配置 Node 运行时`

### Requirement: Rust emits StepChanged on matching sentinel
When Rust's event loop receives a stdout line matching `^@@step:([a-z][a-z0-9-]*):(.+)$`, it SHALL emit an `InstallerEvent::StepChanged { key, label, detail: "" }` event and SHALL NOT forward that line as a `LogLine` event.

#### Scenario: StepChanged is emitted and line is not forwarded as LogLine
- **WHEN** Rust reads `@@step:pnpm:正在准备 pnpm…` from the child stdout
- **THEN** Rust emits `StepChanged { key: "pnpm", label: "正在准备 pnpm…", detail: "" }`
- **THEN** Rust does NOT emit `LogLine { line: "@@step:pnpm:正在准备 pnpm…" }`

### Requirement: all step scripts must emit a sentinel at step start
Each `step_<name>()` function in `installer/steps/*.sh` SHALL emit at minimum one `display "@@step:<key>:<label>"` call at the start of meaningful work (before the first `run` call), so the GUI can reflect the current step in real time. Steps that fast-path (e.g., "already installed") SHALL emit the sentinel and then a `display` or `log` line indicating the fast-path reason.

#### Scenario: step sentinel emitted before first run
- **WHEN** `step_node()` is called
- **THEN** `@@step:node:<label>` appears on stdout before any command output

#### Scenario: fast-path step still emits sentinel
- **WHEN** `step_node()` is called and Node is already installed and active
- **THEN** `@@step:node:<label>` appears on stdout
- **THEN** a `display` line indicating the fast-path follows

### Requirement: old ==> step markers are removed
Installer scripts SHALL NOT emit lines matching `^==> \S+:` (the previous step marker pattern). All step transitions SHALL use the `@@step:` sentinel exclusively.

#### Scenario: no old-style step markers in output
- **WHEN** any installer script is run
- **THEN** stdout contains no lines matching the pattern `^==> [a-zA-Z]`
