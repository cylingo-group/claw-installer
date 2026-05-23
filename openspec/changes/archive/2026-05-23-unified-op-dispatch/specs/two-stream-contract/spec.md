## MODIFIED Requirements

### Requirement: CLAW_SESSION_LOG is inherited by child bash invocations
Rust SHALL set `CLAW_SESSION_LOG` as an environment variable on the child process it spawns (e.g., `bash install.sh`, `bootstrap.ps1`, `claw-op.sh`). Sub-scripts invoked via `bash "$agent_script"` (as in `run_agent()` in `install.sh`, and now via the op-dispatch glue layer) SHALL also receive `CLAW_SESSION_LOG` and SHALL open their own fd 3 when they source `common.sh`, appending to the same file.

The op-dispatch glue layer (`bootstrap.ps1` `-Op` block on Windows; `claw-op.sh` on macOS/Linux) SHALL forward `CLAW_SESSION_LOG` into the WSL/bash environment the same way `Invoke-BashService` already forwards `CLAW_*` env vars (via the env-block pattern).

#### Scenario: child agent script appends to same log file
- **WHEN** `install.sh` invokes `CLAW_SESSION_LOG="$CLAW_SESSION_LOG" bash install-openclaw.sh`
- **THEN** `install-openclaw.sh` opens fd 3 against the same path
- **THEN** log entries from both scripts appear in the same session log file

#### Scenario: op-dispatch script appends to same session log
- **WHEN** Rust dispatches op `apply-model-config` for openclaw with `CLAW_SESSION_LOG` set
- **THEN** the glue layer forwards `CLAW_SESSION_LOG` into the bash environment
- **THEN** `apply-model-config.sh` sources `common.sh` and opens fd 3 against that path
- **THEN** log entries from the op script appear in the session log alongside installer entries
