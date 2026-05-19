# Tasks: installer-two-stream-logging

Ordered implementation sequence. Tasks within a phase may be committed independently. Dependencies are noted where a later task requires an earlier one.

---

## 1. lib/common.sh — Core Primitives

- [ ] 1.1 Delete the existing `log()`, `warn()`, and `die()` functions from `installer/lib/common.sh`.
- [ ] 1.2 Add fd-3 setup block at the top of `common.sh` (after env-var defaults, before function definitions): check `${CLAW_SESSION_LOG:-}` — if set, run `exec 3>>"$CLAW_SESSION_LOG"`; if unset, auto-generate a fallback path under `${TMPDIR:-/tmp}/claw-installer/cli-$(date -u +%Y%m%dT%H%M%SZ).log`, create its parent directory with `mkdir -p`, and open fd 3 against that file.
- [ ] 1.3 Implement `display()`: `printf '%s\n' "$*"` to stdout, and `printf '%s\n' "$*" >&3` to fd 3. Before writing to stdout, check if the argument matches `^@@step:([a-z][a-z0-9-]*):(.+)$` (using a bash `[[ $* =~ ]]` match); if so, extract the label and set `CURRENT_STEP="<label>"`.
- [ ] 1.4 Implement `log()`: `printf '%s\n' "$*" >&3` only (no stdout).
- [ ] 1.5 Implement `run()`: `log "+ $*"` then `"$@" >&3 2>&3` and return the exit code.
- [ ] 1.6 Implement `step()` convenience macro: accept a label as `$1`, assert `$2 == "--"`, then run `display "@@step:<derived-key>:<label>"` and `run "${@:3}"`. Derive the key from the label by lowercasing and replacing non-alnum with `-`, truncated to 30 chars; or accept an explicit `--key <name>` syntax before `--`.
- [ ] 1.7 Implement `die_step_handler()`: reads `$CURRENT_STEP` and `$BASH_COMMAND` from caller scope; emits `✗ 失败步骤：$CURRENT_STEP`, `✗ 失败原因：$BASH_COMMAND 退出码 $?`, `✗ 详见完整日志：$CLAW_SESSION_LOG` to stdout; also writes the same three lines to fd 3; then calls `exit 1`.
- [ ] 1.8 Implement `die_step()` (explicit call variant): takes `<step-label> <command-description> <exit-code>` as positional args; emits the same 3-line `✗` block using those args rather than shell globals.
- [ ] 1.9 Keep `run_as_root()`, `detect_platform()`, `run_steps()`, `agent_env_steps()`, `run_with_timeout()`, and `resolve_fnm_dir()` unchanged except: replace any internal `log` calls in those functions with the new `log()` primitive.
- [ ] 1.10 Update `detect_platform()` to use `display "@@step:detect-platform:正在检测系统平台…"` before the uname check, and `log "Detected platform: $PLATFORM ($(uname -sm))"` for the technical detail.

---

## 2. lib/manifest.sh — Remove tee Logging

- [ ] 2.1 Delete `setup_install_log()` from `installer/lib/manifest.sh` entirely (lines 48–60).
- [ ] 2.2 Remove all references to `CLAW_INSTALL_LOG` inside `manifest.sh` (the variable declaration, the `export`, and its use in `exec > >(tee ...)`).
- [ ] 2.3 Replace the remaining `log` call in `manifest_init()` (`log "Install log: …"`, `log "Manifest: …"`) with `log()` — confirm no calls to the old ANSI-colored `log` remain (those are now deleted; the new `log()` in `common.sh` writes only to fd 3).

---

## 3. steps/base-deps.sh

- [ ] 3.1 Add `display "@@step:base-deps:正在安装基础依赖…"` at the start of `step_base_deps()`, before the platform `case`.
- [ ] 3.2 Replace `log "brew install: ${missing[*]}"` with `log "brew install: ${missing[*]}"` (keep as `log`) and wrap `brew install "${missing[@]}"` in `run brew install "${missing[@]}"`.
- [ ] 3.3 Replace `log "Base deps already present"` with `display "基础依赖已就绪，跳过安装"`.
- [ ] 3.4 Apply the same display/log/run pattern for the debian and rhel branches: `run run_as_root apt-get update -y`, `run run_as_root apt-get install -y …`, `run run_as_root "$pm" install -y …`.
- [ ] 3.5 Replace `die "Homebrew is required …"` with `die_step "基础依赖检查" "Homebrew not found" 1` (or keep as `die_step` via `die_step_handler` if ERR trap is registered at the entry-point level).

---

## 4. steps/fnm.sh

- [ ] 4.1 Read `installer/steps/fnm.sh` (not in the modified list but is sourced via `run_steps`); add `display "@@step:fnm:正在安装 fnm（Node 版本管理器）…"` at the start of `step_fnm()`.
- [ ] 4.2 Replace every `log` call with `log()` (they are now log-only; authors decide what is user-visible).
- [ ] 4.3 Wrap the fnm download/install command with `run` so its output goes to fd 3 only.
- [ ] 4.4 Add a `display "fnm 已就绪：$(fnm --version)"` (or similar) after a successful fast-path.

---

## 5. steps/node.sh

- [ ] 5.1 Add `display "@@step:node:正在配置 Node ${NODE_VERSION} 运行时…"` at the start of `step_node()`.
- [ ] 5.2 Replace `log "Node v$NODE_VERSION already installed and active: …"` with `display "Node v$NODE_VERSION 已安装并激活，跳过"`.
- [ ] 5.3 Replace `log "Installing Node.js v$NODE_VERSION via fnm"` with `log "Installing Node.js v$NODE_VERSION via fnm"`.
- [ ] 5.4 Wrap `fnm install "$NODE_VERSION"`, `fnm default "$NODE_VERSION"`, `fnm use "$NODE_VERSION"` each in `run`: `run fnm install "$NODE_VERSION"`, `run fnm default "$NODE_VERSION"`, `run fnm use "$NODE_VERSION"`.
- [ ] 5.5 Replace `log "Active Node: $node_v"` with `display "✓ Node $node_v 已激活"`.
- [ ] 5.6 The `die "Node $node_v is below required …"` call remains as-is (it will trigger `die_step_handler` via the ERR trap registered at the entry point).

---

## 6. steps/pnpm.sh

- [ ] 6.1 Add `display "@@step:pnpm:正在准备 pnpm 包管理器…"` at the start of `step_pnpm()`.
- [ ] 6.2 Replace `log "pnpm already activated: …"` with `display "pnpm $(pnpm --version) 已激活，跳过"`.
- [ ] 6.3 Replace `log "Enabling pnpm via corepack …"` with `log "Enabling pnpm via corepack (registry=$NPM_REGISTRY)"`.
- [ ] 6.4 Wrap `corepack enable` and `corepack prepare pnpm@latest --activate` in `run`.
- [ ] 6.5 Replace `log "pnpm version: …"` with `display "✓ pnpm $(pnpm --version) 已就绪"`.
- [ ] 6.6 Wrap `SHELL="${SHELL:-/bin/bash}" pnpm setup` in `run … || true`.

---

## 7. steps/npmrc.sh

- [ ] 7.1 Add `display "@@step:npmrc:正在写入 npm 镜像源配置…"` at the start of `step_npmrc()`.
- [ ] 7.2 Replace `log "Skipping ~/.npmrc update …"` with `display "跳过 ~/.npmrc 更新（INSTALLER_SKIP_USER_NPMRC 已设置）"`.
- [ ] 7.3 Replace `log "$rc already has registry=…"` with `display "~/.npmrc 镜像源配置已是最新，跳过"`.
- [ ] 7.4 The file-write logic (awk + mv) is a shell operation, not a command; keep it as-is but wrap the final `mv "$tmp" "$rc"` step in a `log "Updated $rc → registry=$NPM_REGISTRY (managed block)"`.
- [ ] 7.5 Add `display "✓ ~/.npmrc 镜像源已更新：$NPM_REGISTRY"` after a successful write.

---

## 8. steps/shell-rc.sh

- [ ] 8.1 Add `display "@@step:shell-rc:正在配置 Shell 环境路径…"` at the start of `step_shell_rc()`.
- [ ] 8.2 Replace `log "$rc managed block already up to date …"` with `display "$rc 路径配置已是最新，跳过"`.
- [ ] 8.3 Replace `log "Updated $rc (managed block: fnm + pnpm PATH)"` with `display "✓ $rc 路径配置已更新"`.
- [ ] 8.4 The awk + mv file writes are shell operations; no `run` wrapping needed (they don't emit output).

---

## 9. steps/system-tools.sh

- [ ] 9.1 Add `display "@@step:system-tools:正在安装系统工具（ripgrep / ffmpeg）…"` at the start of `step_system_tools()`.
- [ ] 9.2 Replace `log "brew install: ${missing[*]}"` with `log` and wrap `brew install "${missing[@]}"` in `run`.
- [ ] 9.3 Replace `log "system-tools already present"` with `display "系统工具已就绪，跳过安装"`.
- [ ] 9.4 Apply the same pattern for debian (`run run_as_root apt-get …`) and rhel (`run run_as_root "$pm" install …`).

---

## 10. steps/uv.sh and steps/python.sh

- [ ] 10.1 In `steps/uv.sh`: add `display "@@step:uv:正在安装 uv（Python 包管理器）…"` at step start; wrap the uv download/install command in `run`; replace progress `log` calls with `log` (detail) or `display` (status).
- [ ] 10.2 In `steps/python.sh`: add `display "@@step:python:正在安装 Python 3.11…"` at step start; wrap `uv python install` in `run`; replace `log` progress with `log` (detail).

---

## 11. steps/hermes-node.sh

- [ ] 11.1 In `steps/hermes-node.sh`: add `display "@@step:hermes-node:正在配置 Hermes 专属 Node 运行时…"` at step start; wrap symlink/copy operations in `run` where they invoke external commands; replace `log` with appropriate `display`/`log` split.

---

## 12. install-openclaw.sh — Rewrite callsites

- [ ] 12.1 Add `--debug` flag parsing in `main()`: check for `--debug` in `"$@"`, set `DEBUG_MODE=1`; after `source common.sh`, if `DEBUG_MODE=1`, run `tail -F "$CLAW_SESSION_LOG" >&2 & TAIL_PID=$!` and register `trap 'kill "$TAIL_PID" 2>/dev/null || true' EXIT`.
- [ ] 12.2 Add `display "日志文件：$CLAW_SESSION_LOG"` at the top of `main()` when `DEBUG_MODE=1`.
- [ ] 12.3 Register `trap 'die_step_handler' ERR` in `main()` after sourcing `common.sh`.
- [ ] 12.4 Remove the call to `setup_install_log` from `main()`.
- [ ] 12.5 Replace `log "=== Installing agent: openclaw ==="` (or equivalent banner) with `display "@@step:openclaw-start:正在安装 OpenClaw 代理…"`.
- [ ] 12.6 In `install_openclaw_package()`: add `display "@@step:openclaw-pkg:正在安装 OpenClaw 软件包…"` at start; replace `log "openclaw already on PATH …"` with `display "OpenClaw 已安装，跳过（版本 $(openclaw --version 2>/dev/null)）"`.
- [ ] 12.7 In `install_openclaw_package()`: replace `log "pnpm add -g openclaw@latest …"` with `log` (detail); wrap `pnpm add -g openclaw@latest </dev/null` in `run pnpm add -g openclaw@latest </dev/null`; replace `log "openclaw installed: …"` with `display "✓ OpenClaw 已安装：$(command -v openclaw)"`.
- [ ] 12.8 In `write_openclaw_config()`: add `display "@@step:openclaw-config:正在写入 OpenClaw 配置…"` at start; replace all `log "  set $key = $display"` and `log "  keep $key = …"` with `log` calls (these are technical details, not user-visible); replace `log "Validating config"` and `log "Config file: …"` with `log`; add `display "✓ OpenClaw 配置已写入"` at the end.
- [ ] 12.9 In `start_openclaw_service()`, daemon branch: add `display "@@step:openclaw-service:正在启动 OpenClaw 网关服务…"` at start; wrap `run_with_timeout 60 openclaw gateway install </dev/null` with `run run_with_timeout 60 openclaw gateway install </dev/null`; wrap `run_with_timeout 60 openclaw doctor --repair </dev/null` similarly; wrap `openclaw gateway status`, `openclaw gateway start`, `openclaw doctor` invocations with `run` or `run_with_timeout`; replace all `log` and `warn` in this function with `log` (detail-only).
- [ ] 12.10 In `start_openclaw_service()`, add `display "✓ OpenClaw 网关服务已启动"` on success and `display "⚠ 网关启动超时或失败，请运行 openclaw doctor 排查"` on the warn branch.
- [ ] 12.11 Pass `--debug` down to child invocations: in `run_agent()` in `install.sh`, check if `DEBUG_MODE` is set and append `--debug` to the child `bash "$script"` invocation if so.
- [ ] 12.12 Remove `print_openclaw_summary` from the daemon start path OR convert the heredoc to a series of `display` calls (so the summary appears in the log strip too); recommended: keep as `display` calls for key fields (URL, token hint) and `log` for the full block.

---

## 13. install-hermes.sh — Rewrite callsites

- [ ] 13.1 Add `--debug` flag parsing in `main()` (same pattern as task 12.1).
- [ ] 13.2 Register `trap 'die_step_handler' ERR` in `main()`.
- [ ] 13.3 Remove the call to `setup_install_log` from `main()`.
- [ ] 13.4 In `prepare_hermes_repo()`: add `display "@@step:hermes-repo:正在预克隆 Hermes 代码仓库…"` at start; replace `log "Hermes repo already present …"` with `display "Hermes 仓库已存在，跳过克隆"`.
- [ ] 13.5 In `prepare_hermes_repo()`: wrap `git clone --branch … </dev/null` in `run git clone …`.
- [ ] 13.6 In `run_upstream_hermes_installer()`: add `display "@@step:hermes-upstream:正在运行 Hermes 上游安装脚本（首次约 2-5 分钟）…"` before the upstream invocation.
- [ ] 13.7 In `run_upstream_hermes_installer()`: replace `log "Fetching upstream installer: …"` with `log`; wrap `curl -fsSL … -o "$tmp"` in `run curl -fsSL "$HERMES_INSTALL_URL" -o "$tmp"`; wrap `run_with_timeout 1800 bash "$tmp" "${args[@]}" </dev/null` in `run run_with_timeout 1800 bash "$tmp" "${args[@]}" </dev/null`.
- [ ] 13.8 After the upstream installer returns in `install_hermes_agent()`: on success, add `display "✓ Hermes 上游安装完成"`; on non-zero rc, let `die_step_handler` fire (the `run` inside `run_upstream_hermes_installer` will exit non-zero and `set -e` will propagate to the ERR trap).
- [ ] 13.9 In `install_hermes_agent()` fast-path: replace `log "Hermes already installed …"` with `display "Hermes 已安装，跳过上游安装（版本 $hv）"`.
- [ ] 13.10 Replace `print_hermes_summary` heredoc with `display` calls for user-relevant lines and `log` for the rest.

---

## 14. install.sh — Rewrite callsites

- [ ] 14.1 Add `--debug` flag parsing in `main()` (same pattern as task 12.1, sets `DEBUG_MODE=1` and starts `tail -F`).
- [ ] 14.2 Register `trap 'die_step_handler' ERR` in `main()`.
- [ ] 14.3 Remove the call to `setup_install_log` from `main()`.
- [ ] 14.4 Replace `log "claw-installer: full install (agents: …)"` with `display "@@step:start:正在初始化安装程序…"`.
- [ ] 14.5 Replace `log "Env steps for selected agents: ${steps[*]}"` with `log` (detail only).
- [ ] 14.6 Replace `log "=== Installing agent: $agent ==="` in `run_agent()` with `display "@@step:agent-${agent}:正在安装 ${agent} 代理…"`.
- [ ] 14.7 In `run_agent()`, pass `DEBUG_MODE` down: if `[[ "${DEBUG_MODE:-0}" == "1" ]]`, append `--debug` to the `bash "$script"` invocation.
- [ ] 14.8 Replace `log "claw-installer: done. Manifest: $CLAW_MANIFEST"` with `display "✓ 全部安装完成"` and `log "Manifest: $CLAW_MANIFEST"`.

---

## 15. uninstall.sh — Add --debug, rewrite callsites

- [ ] 15.1 Add `--debug` to the `for arg in "$@"` parser: `--debug) DEBUG_MODE=1 ;;`.
- [ ] 15.2 After sourcing `common.sh` in `main()`, if `DEBUG_MODE=1`, start `tail -F "$CLAW_SESSION_LOG" >&2 & TAIL_PID=$!` with EXIT trap to kill it.
- [ ] 15.3 Register `trap 'die_step_handler' ERR` in `main()` (note: `uninstall.sh` uses `run_cmd` for dry-run safety; replace `run_cmd` calls with a new `run_cmd` that internally uses `run` or `log` + the actual command).
- [ ] 15.4 In `plan_summary()`: replace `echo` calls that show the plan with `display` for top-level status lines and `log` for detailed rows (or keep the plan_summary output as display since it is user-facing).
- [ ] 15.5 In `apply_uninstall()`: replace all `log "  $*"` inside `run_cmd` with `log`; wrap the actual deletion commands in `run`: e.g., `run rm -rf "$target"`, `run fnm uninstall "$target"`, `run pnpm rm -g "$target"`.
- [ ] 15.6 Replace `warn` calls throughout `uninstall.sh` with `log` (detail to log file) and optionally `display "⚠ …"` for user-visible warnings.
- [ ] 15.7 In `print_followup()`: convert `echo` statements to `display` for the top-level summary and `log` for the detail lines about system packages.
- [ ] 15.8 Note: `uninstall.sh` does not create a manifest, so it does not need `setup_install_log`. The `CLAW_SESSION_LOG` fallback in `common.sh` (task 1.2) covers CLI invocation without Rust.

---

## 16. windows/bootstrap.ps1 — PowerShell equivalents

- [ ] 16.1 Add `[switch]$DebugMode` to the `param()` block (use `DebugMode` not `Debug` to avoid collision with PowerShell's reserved common parameter).
- [ ] 16.2 Add `$SessionLog` variable computation: `$SessionLog = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "claw-installer", "install-$(Get-Date -Format 'yyyyMMddTHHmmssZ').log")`. Create the directory: `New-Item -ItemType Directory -Force -Path (Split-Path $SessionLog) | Out-Null`.
- [ ] 16.3 Implement `Write-Display [string]$Msg`: writes `$Msg` to `Write-Host`; appends `"$Msg"` to `$SessionLog` via `Add-Content`.
- [ ] 16.4 Implement `Write-Log [string]$Msg`: appends `$Msg` to `$SessionLog` only.
- [ ] 16.5 Implement `Invoke-Logged [scriptblock]$Cmd`: runs `& $Cmd 2>&1 | Add-Content -Path $SessionLog`.
- [ ] 16.6 When `-DebugMode`: start a background job `Start-Job { Get-Content -Wait -Path $SessionLog }` and pipe its output to `Write-Host`; register a `finally` block or `trap` to stop the job.
- [ ] 16.7 Replace existing `Write-Step`, `Write-Warn2`, `Write-Err2` calls in `Invoke-BashInstaller` and `Invoke-BashUninstaller` with `Write-Display` / `Write-Log` as appropriate.
- [ ] 16.8 Pass `CLAW_SESSION_LOG` into the bash invocation inside WSL: add `"export CLAW_SESSION_LOG='/tmp/claw-installer/install-<ts>.log'"` to the `$envBlock` string in `Invoke-BashInstaller` and `Invoke-BashUninstaller`. (The WSL path must be a Linux path, not the Windows `$SessionLog` path; use a fixed temp path inside WSL, e.g., `/tmp/claw-installer/<ts>.log`.)

---

## 17. Rust — Delete filter helpers and update event loop

- [ ] 17.1 Delete `is_user_friendly()`, `friendly_display()`, and `strip_ansi()` (or equivalently named functions) from `gui/src-tauri/src/commands.rs` (or wherever they live).
- [ ] 17.2 Delete `parse_step_line()` from `gui/src-tauri/src/steps.rs` (the `==> <key>:` parser).
- [ ] 17.3 Add a `OnceLock<Regex>` (using the `regex` crate) for the pattern `^@@step:([a-z][a-z0-9-]*):(.+)$` in `commands.rs` or a new `sentinel.rs` module.
- [ ] 17.4 In `run_event_loop` (or `run_installer` command): replace the old `parse_step_line` call with a match against the new `@@step:` regex; on match, emit `StepChanged { key, label, detail: "".into() }` and continue without emitting `LogLine`; on no match, emit `LogLine { line }` verbatim.
- [ ] 17.5 In the `Stderr` arm of the event loop: discard the line (do not emit `LogLine`). Add a debug-level internal log if the `tracing` crate is in use.
- [ ] 17.6 Before spawning the child process, compute `CLAW_SESSION_LOG`: `format!("{}/claw-installer/{}-{}.log", std::env::temp_dir().display(), operation, unix_ts)` where `operation` is `"install"` or `"uninstall"`. Create the parent directory with `std::fs::create_dir_all`. Pass as `.env("CLAW_SESSION_LOG", &log_path)` on the command builder.
- [ ] 17.7 Emit `InstallerEvent::LogPath { path: log_path.to_string_lossy().into() }` immediately after spawn (before entering the event loop).
- [ ] 17.8 Slim `step_label()` in `steps.rs`: it is no longer called on the live event stream. Either delete it entirely (and update stub mode to not use it) or retain it only for the frontend stub simulation, with a comment indicating it is not used in production.
- [ ] 17.9 Update the `run_agent` child invocation in `install.sh` (Rust side, the command builder in `build_command()`): ensure `CLAW_SESSION_LOG` is propagated to sub-agent scripts (it is inherited via env, so no extra step needed if the top-level script re-exports it — but verify the `bash install-openclaw.sh` invocation inside `install.sh` sees the env var).

---

## 18. Integration Verification

- [ ] 18.1 Run `./installer/install.sh --debug` in a Docker container (use `installer/docker/`) and verify: (a) only `display` lines appear on stdout without `--debug`; (b) with `--debug`, the session log streams to stderr; (c) `@@step:` lines on stdout are clean (no ANSI codes).
- [ ] 18.2 Run the Tauri GUI in dev mode (`INSTALLER_REPO_DIR=... pnpm dev:gui`) and trigger a full install: verify `StepChanged` events arrive with the correct Chinese labels from the scripts, `LogLine` events contain only clean text, and the 5-line log strip is readable.
- [ ] 18.3 Simulate a step failure: set `INSTALLER_FORCE_REINSTALL=1` and break `fnm install` (e.g., by pointing `fnm` to a non-existent binary); verify the 3-line `✗` block appears on stdout and is displayed in the GUI.
- [ ] 18.4 Verify the session log file is created under `$TMPDIR/claw-installer/` and contains: all `display` lines, all `log` detail lines, all `run` command output, and the `+ command` prefix lines.
- [ ] 18.5 Run `./installer/uninstall.sh --yes` directly from the CLI (without Rust) and verify it completes without error (testing the `CLAW_SESSION_LOG` fallback auto-generation in `common.sh`).
- [ ] 18.6 Verify no `shellcheck` errors on `lib/common.sh`, `install.sh`, `install-openclaw.sh`, `install-hermes.sh`, `uninstall.sh`, and all files under `steps/`.
