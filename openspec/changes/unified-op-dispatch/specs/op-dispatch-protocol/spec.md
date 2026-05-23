## ADDED Requirements

### Requirement: Glue layer is the sole WSL/login-shell boundary
The Rust GUI SHALL invoke bash business logic exclusively through the per-OS glue layer (`shell/windows/bootstrap.ps1` on Windows; `shell/claw-op.sh` on macOS/Linux). Rust SHALL NOT construct inline bash scripts or directly spawn `wsl.exe -- bash -lc` for any named operation listed in this spec.

#### Scenario: Windows op routed through bootstrap.ps1
- **WHEN** the Rust process dispatches op `apply-model-config` for agent `openclaw` on Windows
- **THEN** Rust invokes `powershell.exe … bootstrap.ps1 -Op apply-model-config -Agent openclaw` (not `wsl.exe` directly)
- **THEN** `bootstrap.ps1` calls `Invoke-WslBashStreamed -Login` which sources `common.sh` via the login shell
- **THEN** `_claw_compose_path` is called, making fnm-managed Node and pnpm available

#### Scenario: macOS/Linux op routed through claw-op.sh
- **WHEN** the Rust process dispatches op `apply-model-config` for agent `openclaw` on macOS
- **THEN** Rust invokes `bash shell/claw-op.sh --op apply-model-config --agent openclaw` with `login_env` applied
- **THEN** `claw-op.sh` execs `shell/agents/openclaw/apply-model-config.sh`

### Requirement: Op names and valid agents are defined by the protocol
The glue layer on both operating systems SHALL accept exactly the following op names and validate that the agent is one of `openclaw` or `hermes`. An unrecognized op or agent SHALL cause the glue layer to exit non-zero with a diagnostic message before any WSL or bash invocation occurs.

Valid op names: `apply-model-config`, `open-dashboard`, `approve-latest-device`, `find-dashboard-port`.

| Op | Valid agents |
|---|---|
| `apply-model-config` | `openclaw`, `hermes` |
| `open-dashboard` | `openclaw`, `hermes` |
| `approve-latest-device` | `openclaw` |
| `find-dashboard-port` | `hermes` |

#### Scenario: Invalid op rejected before WSL invocation
- **WHEN** Rust dispatches op `frobnicate` for agent `openclaw`
- **THEN** the glue layer exits non-zero
- **THEN** a diagnostic message naming the invalid op appears in stderr
- **THEN** no WSL process or bash session is started

#### Scenario: Op with wrong agent rejected
- **WHEN** Rust dispatches op `approve-latest-device` for agent `hermes`
- **THEN** the glue layer exits non-zero
- **THEN** a diagnostic message names the unsupported op+agent combination

### Requirement: Business scripts source common.sh as their first act
Every op script under `shell/agents/<agent>/<op-name>.sh` SHALL begin with the canonical source header (shebang, `set -euo pipefail`, `__SELF_DIR` derivation, `source "$__SELF_DIR/../../lib/common.sh"`) before performing any agent-specific work. This guarantees that `_claw_compose_path` has run and PATH includes all installer-managed tools.

#### Scenario: openclaw apply-model-config has node on PATH
- **WHEN** `apply-model-config.sh` for openclaw is invoked in a WSL session with fnm-managed Node installed
- **THEN** `command -v node` succeeds (node is on PATH)
- **THEN** `command -v openclaw` succeeds (openclaw is a pnpm-managed bin)

#### Scenario: hermes apply-model-config has hermes on PATH
- **WHEN** `apply-model-config.sh` for hermes is invoked
- **THEN** `command -v hermes` succeeds (`~/.local/bin/hermes` is on PATH via `_claw_compose_path`)

### Requirement: Secrets and structured input travel via stdin; scalar params via INSTALLER_OP_* env vars
Each op script's input contract SHALL classify each input as one of:
- **stdin**: API keys, auth tokens, JSON patch payloads (anything that must not appear in argv or env)
- **`INSTALLER_OP_*` env vars**: non-secret scalar parameters (provider name, model name, base URL, env var name)
- **argv** (`--op`, `--agent`): routing only, to the glue layer; op scripts themselves receive no argv

The glue layer SHALL forward all `INSTALLER_OP_*` env vars from the Rust process into the WSL environment unchanged. The glue layer SHALL NOT log the value of `INSTALLER_OP_*` env vars that may contain sensitive data.

#### Scenario: API key is not in ps output
- **WHEN** `apply-model-config.sh` for hermes is running and an observer runs `ps -eo args=`
- **THEN** the API key value does not appear in the process argument list

#### Scenario: Scalar provider params are forwarded
- **WHEN** Rust sets `INSTALLER_OP_PROVIDER=deepseek` and dispatches `apply-model-config` for hermes
- **THEN** inside the WSL bash session, `$INSTALLER_OP_PROVIDER` equals `deepseek`

### Requirement: Windows glue forwards stdin payload via base64-encoded env var
On Windows, the Rust `dispatch_op` function SHALL base64-encode the stdin bytes and pass them as env var `INSTALLER_OP_STDIN_B64` to `bootstrap.ps1`. The bootstrap.ps1 op-dispatch block SHALL decode `INSTALLER_OP_STDIN_B64` and write the decoded bytes to a `chmod 600` temp file inside WSL before invoking the op script. The op script SHALL read from that temp file (redirected to its stdin by the glue layer) rather than from process stdin directly.

When `INSTALLER_OP_STDIN_B64` is empty or unset, no temp file is created and the op script's stdin is `/dev/null`.

#### Scenario: JSON patch reaches apply-model-config.sh intact
- **WHEN** Rust dispatches `apply-model-config` for openclaw with a JSON string as the stdin payload
- **THEN** inside `apply-model-config.sh`, `cat` (reading from redirected stdin) yields exactly the same JSON bytes that Rust provided
- **THEN** no JSON bytes appear in `ps -eo args=` or in the WSL process environment visible to other users

#### Scenario: No-stdin ops receive /dev/null on stdin
- **WHEN** Rust dispatches `open-dashboard` for openclaw (no stdin payload)
- **THEN** `INSTALLER_OP_STDIN_B64` is empty
- **THEN** no temp file is created in WSL `/tmp`
- **THEN** the op script's stdin is `/dev/null`

### Requirement: op-script file header is the authoritative per-op contract
Every op script SHALL begin with a structured comment block immediately following the shebang that documents:
1. **stdin**: what the script reads from stdin (or "none")
2. **env vars read**: which `INSTALLER_OP_*` env vars the script consumes, with types and defaults
3. **stdout**: what the script emits to stdout and its format
4. **exit codes**: what exit 0 vs non-zero means for this op

#### Scenario: apply-model-config.sh header documents JSON stdin
- **WHEN** a developer reads `shell/agents/openclaw/apply-model-config.sh`
- **THEN** the file header states that stdin carries the JSON patch payload
- **THEN** the file header lists any `INSTALLER_OP_*` env vars consumed (e.g., replace-path list)

### Requirement: apply-model-config for openclaw patches and validates config
`shell/agents/openclaw/apply-model-config.sh` SHALL:
1. Read the JSON patch payload from stdin into a `chmod 600` temp file
2. Run `openclaw config patch --file <tmpfile> [--replace-path <p>]*` for each path in `INSTALLER_OP_REPLACE_PATHS` (space-separated)
3. Run `openclaw config validate`
4. Remove the temp file via an `EXIT` trap regardless of success or failure
5. Exit 0 only if both commands succeed

#### Scenario: Successful config patch
- **WHEN** stdin contains valid JSON and `openclaw config patch` + `validate` both exit 0
- **THEN** `apply-model-config.sh` exits 0
- **THEN** the temp file is removed

#### Scenario: Validation failure propagates non-zero exit
- **WHEN** `openclaw config validate` exits non-zero after a patch
- **THEN** `apply-model-config.sh` exits non-zero
- **THEN** the temp file is still removed (trap fires)

### Requirement: apply-model-config for hermes updates config and .env atomically
`shell/agents/hermes/apply-model-config.sh` SHALL:
1. Run `hermes config set model.provider`, `model.default`, `model.base_url` using values from `INSTALLER_OP_PROVIDER`, `INSTALLER_OP_MODEL`, `INSTALLER_OP_BASE_URL`
2. Read the API key from stdin
3. Atomically upsert `<INSTALLER_OP_ENV_VAR_NAME>=<api_key>` into `~/.hermes/.env` (write to `.env.tmp.$$`, then `mv`) with mode 0600
4. Exit 0 only if all steps succeed

#### Scenario: Hermes .env written atomically
- **WHEN** `apply-model-config.sh` for hermes runs successfully
- **THEN** `~/.hermes/.env` contains the upserted `<ENV_VAR>=<key>` line
- **THEN** `~/.hermes/.env` has permissions 0600
- **THEN** no partial write is visible (atomic `mv`)

### Requirement: open-dashboard for openclaw is a one-shot delegate
`shell/agents/openclaw/open-dashboard.sh` SHALL run `openclaw dashboard --yes` (which handles token auth + browser launch + clipboard copy internally) and exit when that command exits. The script SHALL NOT spawn background processes or poll.

#### Scenario: open-dashboard exits once openclaw dashboard exits
- **WHEN** `open-dashboard.sh` for openclaw is invoked
- **THEN** it execs `openclaw dashboard --yes`
- **THEN** the script exits with the same exit code as `openclaw dashboard --yes`

### Requirement: approve-latest-device for openclaw is a single attempt
`shell/agents/openclaw/approve-latest-device.sh` SHALL run `openclaw devices approve --latest` once and exit with that command's exit code. The polling loop (up to 45 attempts at 1-second intervals) is the responsibility of the Rust caller, not the script.

#### Scenario: approve exits 1 when no pending request
- **WHEN** `approve-latest-device.sh` runs and `openclaw devices approve --latest` exits 1
- **THEN** `approve-latest-device.sh` exits 1
- **THEN** no retry or loop occurs inside the script

### Requirement: open-dashboard for hermes spawns and detaches the daemon
`shell/agents/hermes/open-dashboard.sh` SHALL spawn `hermes dashboard --no-open` detached (via `nohup ... &`) and exit 0 immediately. It SHALL NOT block waiting for the dashboard to become ready. Port polling is the Rust caller's responsibility.

#### Scenario: open-dashboard exits before hermes is ready
- **WHEN** `open-dashboard.sh` for hermes is invoked and hermes is not yet running
- **THEN** the script spawns `nohup hermes dashboard --no-open` in the background
- **THEN** the script exits 0 within 1 second
- **THEN** `hermes dashboard` continues running as a detached process

### Requirement: find-dashboard-port for hermes reports the running port or exits silently
`shell/agents/hermes/find-dashboard-port.sh` SHALL inspect `ps -eo args=` for a running `hermes dashboard` process and parse its `--port` argument. If found, the script SHALL print the port number to stdout and exit 0. If no running `hermes dashboard` process is found, the script SHALL print nothing to stdout and exit 0. The Rust caller is responsible for applying the default port (9119) when stdout is empty.

#### Scenario: Running hermes dashboard with custom port
- **WHEN** `hermes dashboard --port 9200` is running
- **THEN** `find-dashboard-port.sh` prints `9200` to stdout and exits 0

#### Scenario: No running hermes dashboard
- **WHEN** no `hermes dashboard` process is running
- **THEN** `find-dashboard-port.sh` prints nothing to stdout and exits 0

### Requirement: Rust dispatch_op helper abstracts OS-level transport
A `dispatch_op(agent: &str, op: &str, stdin_bytes: &[u8]) -> Result<String, String>` function (or equivalent async form) SHALL exist in `gui/src-tauri/src/commands.rs` (or a new `ops.rs` module). It SHALL:
- On Windows: invoke `bootstrap.ps1` with `-Op <op> -Agent <agent>`, setting `INSTALLER_OP_STDIN_B64` to the base64 of `stdin_bytes`
- On macOS/Linux: invoke `shell/claw-op.sh --op <op> --agent <agent>` with `stdin_bytes` piped to process stdin and `login_env` applied
- Return `Ok(stdout)` on exit 0
- Return `Err(formatted_error)` on non-zero exit, including the op label and exit code in the error string

#### Scenario: dispatch_op returns stdout on success
- **WHEN** `dispatch_op("hermes", "find-dashboard-port", b"")` is called and the script prints `9200\n`
- **THEN** `dispatch_op` returns `Ok("9200\n")`

#### Scenario: dispatch_op returns Err on non-zero exit
- **WHEN** `dispatch_op("openclaw", "apply-model-config", patch_bytes)` runs and the script exits 1
- **THEN** `dispatch_op` returns `Err(...)` containing the exit code and captured stderr
