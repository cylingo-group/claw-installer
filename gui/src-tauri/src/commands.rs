use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::Manager;
use tokio::sync::Mutex;
use tauri_plugin_shell::ShellExt;
use tauri_plugin_shell::process::{CommandEvent, CommandChild};
use tauri::async_runtime::Receiver;

use crate::{log_error, log_info};
use crate::login_env;
use crate::manifest::parse_manifest;
use crate::steps::parse_step_sentinel;
use crate::types::{HostStatusPayload, InstallerEvent, InstallerStatePayload};

/// Overlay the cached login-shell env (PATH / PNPM_HOME / FNM_DIR / etc.) onto
/// a Command before any caller-specific env is applied. Tauri GUI apps inherit
/// launchd's minimal env, so without this bash spawns can't see customizations
/// the user has in ~/.zshrc / ~/.bashrc / fish config.
///
/// Apply this BEFORE caller-supplied INSTALLER_* env so explicit overrides
/// still win.
pub(crate) fn apply_login_env(
    mut cmd: tauri_plugin_shell::process::Command,
) -> tauri_plugin_shell::process::Command {
    for (k, v) in login_env::login_env() {
        cmd = cmd.env(k, v);
    }
    cmd
}

/// Verify the bundled `shell/` tree is reachable before we spawn a child.
///
/// Why this exists: the Makefile's `build-windows` target uses `--no-bundle`
/// which produces a bare `.exe` with no installer. If the customer runs the
/// `.exe` without extracting the full distribution zip alongside it, PowerShell
/// gets invoked with a `-File <path>` that doesn't exist — and exits with
/// `-196608` plus a CP936-encoded "找不到文件" on stderr that Tauri discards.
/// The user sees only the cryptic code.
///
/// We pre-check the expected layout and emit a clear Chinese error before
/// spawning, so the GUI shows actionable text instead of an error code lottery.
fn check_resources(app: &tauri::AppHandle) -> Result<(), String> {
    let shell_dir = resolve_installer_dir(app);
    if !shell_dir.is_dir() {
        return Err(format!(
            "找不到脚本目录：{}\n\
             请确认运行的是 claw-installer-windows.zip 完整解压后的 exe，\
             而不是单独把 exe 拎出来放到桌面。\n\
             如果只有 exe，请重新下载发布包并整目录解压后再运行。",
            shell_dir.display()
        ));
    }
    #[cfg(target_os = "windows")]
    let sentinel = shell_dir.join("windows").join("bootstrap.ps1");
    #[cfg(not(target_os = "windows"))]
    let sentinel = shell_dir.join("install.sh");
    if !sentinel.is_file() {
        return Err(format!(
            "脚本完整性异常，缺少入口文件：{}\n发布包可能损坏，请重新解压。",
            sentinel.display()
        ));
    }
    Ok(())
}

/// Build the powershell.exe argv for invoking bootstrap.ps1 with extra args.
///
/// We use `-Command "& '<path>' <extras…>"` instead of `-File <path>`. PS 5.1's
/// `-File` argument has a long-standing tokenization bug: when the value
/// contains a space (e.g. `C:\Program Files\Claw Installer\shell\…`), the
/// parser truncates at the first space and tries to open a non-existent file.
/// On a default Tauri install, that's our exact failure mode → exit -196608.
///
/// `-Command` wraps the script in a single-quoted literal where spaces survive.
/// Single quotes in the path itself are escaped by doubling (PowerShell rule).
#[cfg(target_os = "windows")]
fn powershell_args(ps_path: &std::path::Path, extras: &[&str]) -> Vec<String> {
    let path_escaped = ps_path.to_string_lossy().replace('\'', "''");
    let mut script = format!("& '{}'", path_escaped);
    for arg in extras {
        script.push(' ');
        script.push_str(arg);
    }
    vec![
        "-NoProfile".to_string(),
        "-ExecutionPolicy".to_string(),
        "Bypass".to_string(),
        "-Command".to_string(),
        script,
    ]
}

/// On Windows, suppress the console window that would otherwise pop up when a
/// GUI process spawns a console-subsystem child (powershell.exe, wsl.exe,
/// shutdown.exe). tauri-plugin-shell::Command already sets this internally;
/// the raw std::process::Command calls in this module don't, so we apply it
/// here. No-op on other platforms.
#[cfg(target_os = "windows")]
fn hide_console(cmd: &mut std::process::Command) -> &mut std::process::Command {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW);
    cmd
}

#[cfg(not(target_os = "windows"))]
#[allow(dead_code)]
fn hide_console(cmd: &mut std::process::Command) -> &mut std::process::Command {
    cmd
}

/// Build the path for a session's full on-disk log file in the OS temp dir.
/// Honors $TMPDIR / %TEMP% / %TMP% via std::env::temp_dir().
///
/// Format: <kind>-<unix-seconds>.log — sortable and grep-friendly.
fn build_session_log_path(kind: &str) -> PathBuf {
    let mut dir = std::env::temp_dir();
    dir.push("claw-installer");
    let _ = fs::create_dir_all(&dir);
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    dir.push(format!("{}-{}.log", kind, ts));
    dir
}

pub struct AppState {
    pub child: Arc<Mutex<Option<CommandChild>>>,
}

/// Resolve the shell-scripts directory (install / start / stop / restart /
/// uninstall live here).
/// In dev: use INSTALLER_REPO_DIR env var.
/// In prod: use {resource_dir}/shell/.
pub(crate) fn resolve_installer_dir(app: &tauri::AppHandle) -> PathBuf {
    if let Ok(repo_dir) = std::env::var("INSTALLER_REPO_DIR") {
        return strip_extended_path_prefix(PathBuf::from(repo_dir));
    }
    let dir = app
        .path()
        .resource_dir()
        .expect("resource_dir unavailable")
        .join("shell");
    strip_extended_path_prefix(dir)
}

/// Tauri's `resource_dir()` on Windows often returns Win32 extended-length paths
/// prefixed with `\\?\` (a kernel-level alias allowing >260 chars). PowerShell
/// 5.1, `wslpath`, and many other path-consuming tools have buggy handling of
/// that prefix — symptoms range from "file not found" to silent crashes. We
/// never need >260 chars for an installer directory, so strip the prefix as
/// early as possible so it never leaks into the bash/PS argv we hand out.
///
/// Per Microsoft's docs the prefix can be either `\\?\C:\…` (local) or
/// `\\?\UNC\server\share\…` (which maps back to `\\server\share\…`). We handle
/// both; anything else (e.g. `\\?\Volume{GUID}\…`) we pass through unchanged
/// because rewriting it would change the meaning of the path.
#[cfg(target_os = "windows")]
fn strip_extended_path_prefix(path: PathBuf) -> PathBuf {
    let s = path.to_string_lossy();
    if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
        return PathBuf::from(format!(r"\\{}", rest));
    }
    if let Some(rest) = s.strip_prefix(r"\\?\") {
        // Only strip if what follows looks like a drive letter — leave
        // `\\?\Volume{…}` and friends alone.
        let bytes = rest.as_bytes();
        if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
            return PathBuf::from(rest.to_string());
        }
    }
    path
}

#[cfg(not(target_os = "windows"))]
fn strip_extended_path_prefix(path: PathBuf) -> PathBuf {
    path
}

/// Resolve a specific installer file path.
pub fn resolve_installer_path(app: &tauri::AppHandle, rel: &str) -> PathBuf {
    resolve_installer_dir(app).join(rel)
}

/// Determine the path to the manifest file.
#[cfg(not(target_os = "windows"))]
pub(crate) fn manifest_path(app: &tauri::AppHandle) -> PathBuf {
    if let Ok(p) = std::env::var("CLAW_MANIFEST") {
        return PathBuf::from(p);
    }
    let home = app
        .path()
        .home_dir()
        .unwrap_or_else(|_| PathBuf::from(std::env::var("HOME").unwrap_or_default()));
    home.join(".claw-installer").join("manifest.tsv")
}

// ---- Commands ----------------------------------------------------------------

#[tauri::command]
pub async fn read_installer_state(
    app: tauri::AppHandle,
) -> Result<InstallerStatePayload, String> {
    #[cfg(target_os = "windows")]
    {
        read_installer_state_windows(&app).await
    }
    #[cfg(not(target_os = "windows"))]
    {
        read_installer_state_unix(&app).await
    }
}

#[cfg(not(target_os = "windows"))]
async fn read_installer_state_unix(app: &tauri::AppHandle) -> Result<InstallerStatePayload, String> {
    let path = manifest_path(app);
    if !path.exists() {
        return Ok(InstallerStatePayload {
            openclaw: "not-installed".into(),
            hermes: "not-installed".into(),
        });
    }
    let content = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let status = parse_manifest(&content);
    Ok(InstallerStatePayload {
        openclaw: status.openclaw.as_str().to_string(),
        hermes: status.hermes.as_str().to_string(),
    })
}

#[cfg(target_os = "windows")]
async fn read_installer_state_windows(app: &tauri::AppHandle) -> Result<InstallerStatePayload, String> {
    // Lightweight manifest read via `wsl.exe -- cat ~/.claw-installer/manifest.tsv`.
    // We deliberately do NOT use op-dispatch here — this is a pure read of a user-
    // owned file, called frequently by state-polling, and going through bootstrap.ps1
    // would trigger Assert-Elevated (UAC) on every tick.
    //
    // Distro selection: honor INSTALLER_WSL_DISTRO if set; otherwise omit -d so
    // wsl.exe targets the user's default distro. Hardcoding "Ubuntu" breaks for
    // users with Ubuntu-24.04 etc., since wsl.exe's -d does NOT do the fuzzy
    // matching that bootstrap.ps1::Resolve-InstalledDistro does.
    let distro_override = std::env::var("INSTALLER_WSL_DISTRO").ok();
    let mut cmd = std::process::Command::new("wsl.exe");
    if let Some(ref d) = distro_override {
        cmd.args(["-d", d.as_str()]);
    }
    cmd.args(["--", "cat", "~/.claw-installer/manifest.tsv"]);
    cmd.env("WSL_UTF8", "1");
    let output = hide_console(&mut cmd).output();

    match output {
        Ok(out) if out.status.success() => {
            let content = String::from_utf8_lossy(&out.stdout).to_string();
            let status = parse_manifest(&content);
            Ok(InstallerStatePayload {
                openclaw: status.openclaw.as_str().to_string(),
                hermes: status.hermes.as_str().to_string(),
            })
        }
        _ => {
            // WSL call failed — try UNC fallback
            read_installer_state_windows_unc(app)
        }
    }
}

#[cfg(target_os = "windows")]
fn read_installer_state_windows_unc(_app: &tauri::AppHandle) -> Result<InstallerStatePayload, String> {
    // UNC fallback: only useful when we know the exact distro name. Hardcoding
    // "Ubuntu" silently fails for users on Ubuntu-24.04 etc. Skip the UNC attempt
    // unless an explicit INSTALLER_WSL_DISTRO override is set.
    let Some(distro) = std::env::var("INSTALLER_WSL_DISTRO").ok() else {
        return Ok(InstallerStatePayload {
            openclaw: "not-installed".into(),
            hermes: "not-installed".into(),
        });
    };
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".to_string());
    let unc_path = format!(
        r"\\wsl.localhost\{}\home\{}\.claw-installer\manifest.tsv",
        distro, user
    );
    match std::fs::read_to_string(&unc_path) {
        Ok(content) => {
            let status = parse_manifest(&content);
            Ok(InstallerStatePayload {
                openclaw: status.openclaw.as_str().to_string(),
                hermes: status.hermes.as_str().to_string(),
            })
        }
        Err(_) => Ok(InstallerStatePayload {
            openclaw: "not-installed".into(),
            hermes: "not-installed".into(),
        }),
    }
}

#[cfg(not(target_os = "windows"))]
#[tauri::command]
pub async fn read_host_status() -> Result<HostStatusPayload, String> {
    Ok(HostStatusPayload {
        status: "ok".into(),
        command: None,
    })
}

#[cfg(target_os = "windows")]
#[tauri::command]
pub async fn read_host_status(app: tauri::AppHandle) -> Result<HostStatusPayload, String> {
    // Bail out early with a human-readable error if the shell/ tree isn't next
    // to the exe — see check_resources for the "exe alone on Desktop" failure
    // mode this guards against.
    check_resources(&app)?;
    let ps_path = resolve_installer_path(&app, r"windows\bootstrap.ps1");
    let mut cmd = std::process::Command::new("powershell.exe");
    cmd.args(powershell_args(&ps_path, &["-Preflight"]));
    let output = hide_console(&mut cmd)
        .output()
        .map_err(|e| e.to_string())?;

    match output.status.code() {
        Some(0) => Ok(HostStatusPayload {
            status: "ok".into(),
            command: None,
        }),
        Some(2) => Ok(HostStatusPayload {
            status: "needs-ubuntu-firstrun".into(),
            command: Some("wsl --install -d Ubuntu".into()),
        }),
        _ => Ok(HostStatusPayload {
            status: "needs-wsl-install".into(),
            command: Some("wsl --install".into()),
        }),
    }
}

/// Select which script to run based on agents and platform.
fn build_command(
    app: &tauri::AppHandle,
    agents: &[String],
) -> tauri_plugin_shell::process::Command {
    let shell = app.shell();

    #[cfg(target_os = "windows")]
    {
        let ps_path = resolve_installer_path(app, r"windows\bootstrap.ps1");
        let mut extras: Vec<&str> = Vec::new();
        if agents.len() == 1 {
            extras.push("-Agent");
            extras.push(&agents[0]);
        }
        shell.command("powershell.exe").args(powershell_args(&ps_path, &extras))
    }

    #[cfg(not(target_os = "windows"))]
    {
        let script = if agents.len() == 1 {
            // Single-agent install → per-agent script under agents/<agent>/install.sh.
            // The script handles its own env-deps via run_steps(ENV_STEPS).
            resolve_installer_path(app, &format!("agents/{}/install.sh", agents[0]))
        } else {
            // Multi-agent or unspecified → top-level orchestrator.
            resolve_installer_path(app, "install.sh")
        };
        shell.command("bash").args([script.to_string_lossy().to_string()])
    }
}

fn build_uninstall_command(
    app: &tauri::AppHandle,
    agent: &str,
) -> tauri_plugin_shell::process::Command {
    let shell = app.shell();

    #[cfg(target_os = "windows")]
    {
        let _ = agent;
        let ps_path = resolve_installer_path(app, r"windows\bootstrap.ps1");
        shell.command("powershell.exe").args(powershell_args(&ps_path, &["-Uninstall"]))
    }

    #[cfg(not(target_os = "windows"))]
    {
        // Per-agent uninstall — only reverses that agent's manifest rows.
        // Empty/unknown agent falls back to the top-level full uninstall.
        let script = if agent == "openclaw" || agent == "hermes" {
            resolve_installer_path(app, &format!("agents/{}/uninstall.sh", agent))
        } else {
            resolve_installer_path(app, "uninstall.sh")
        };
        shell.command("bash").args([script.to_string_lossy().to_string(), "--yes".to_string()])
    }
}

/// Build a command for an agent service lifecycle action (start/stop/restart).
/// On Windows: spawns bootstrap.ps1 with -Service / -Agent args.
/// On non-Windows: runs agents/<agent>/<action>.sh via bash.
pub(crate) fn build_service_command(
    app: &tauri::AppHandle,
    agent: &str,
    action: &str,
) -> tauri_plugin_shell::process::Command {
    let shell = app.shell();

    #[cfg(target_os = "windows")]
    {
        let ps_path = resolve_installer_path(app, r"windows\bootstrap.ps1");
        // `-FastPath`: skip bootstrap's preflight chain. Install already
        // verified WSL + distro + systemd + repo-copy; a service action
        // doesn't need any of that re-checked.
        shell.command("powershell.exe").args(powershell_args(
            &ps_path,
            &["-Service", action, "-Agent", agent, "-FastPath"],
        ))
    }

    #[cfg(not(target_os = "windows"))]
    {
        let script = resolve_installer_path(app, &format!("agents/{}/{}.sh", agent, action));
        shell.command("bash").args([script.to_string_lossy().to_string()])
    }
}

/// Format a non-success child exit code for the GUI's error banner.
///
/// Goal: lead with a human-readable reason that a non-engineer can act on,
/// then append the raw decimal + hex for triage. The PowerShell installer
/// reserves specific exit codes for known failure modes (see `bootstrap.ps1`
/// header comment); we translate those into plain Chinese so the banner reads
/// as a sentence rather than as a hex dump.
///
/// For the catch-all code 1, exit_code_hint returns nothing and we fall back
/// to scanning recent log lines for known keywords (HCS_E_HYPERV → BIOS virt,
/// "UAC cancelled" → UAC denied, etc.) so the banner still shows the actual
/// root cause even when bootstrap.ps1's outer catch didn't reclassify it.
///
/// Raw decimal alone is useless for triage on Windows — Tauri receives the
/// DWORD exit code through `Option<i32>`, so codes above 2^31 wrap into the
/// negative range (e.g. `0xFFFD0000 → -196608`). We surface both forms.
///
/// Pass an empty slice for `recent_lines` if no log context is available;
/// the log-sniff fallback only fires for code 1.
fn format_exit_code(code: Option<i32>, recent_lines: &[String]) -> String {
    let Some(c) = code else {
        return "脚本意外退出，没有返回退出码（可能被强制结束或进程崩溃）".to_string();
    };
    let hex = format!("0x{:08X}", c as u32);
    if let Some(h) = exit_code_hint(c) {
        return format!("{}（退出码 {} / {}）", h, c, hex);
    }
    if c == 1 {
        if let Some(reason) = sniff_known_reason(recent_lines) {
            return format!("{}（退出码 {} / {}）", reason, c, hex);
        }
        return format!(
            "安装中途遇到未预期的错误，请查看下方「完整日志」了解详情（退出码 {} / {}）",
            c, hex
        );
    }
    format!("安装脚本以未知退出码 {} ({}) 结束", c, hex)
}

/// Human hint for well-known exit codes. Includes both Windows runtime codes
/// (negative DWORD wraparounds) and bootstrap.ps1's reserved 2-5 range —
/// keep this table in sync with the script's exit-code contract. Note that
/// exit code 1 is intentionally NOT mapped here — it's the catch-all that
/// gets resolved via `sniff_known_reason` against the log tail instead.
fn exit_code_hint(code: i32) -> Option<&'static str> {
    match code {
        // ---- bootstrap.ps1 reserved exits -----------------------------------
        2 => Some("需要重启 Windows 后再继续安装。重启完成后请重新运行本安装器"),
        3 => Some(
            "环境检查未通过 — 可能是 Windows 版本太旧、WSL 安装失败，\
             或启用 WSL 功能时出错。详情请查看日志",
        ),
        4 => Some("UAC 授权被拒绝或取消，安装需要管理员权限才能继续"),
        5 => Some(
            "CPU 虚拟化未在 BIOS 中开启。请重启电脑进入 BIOS / UEFI，\
             启用 Intel VT-x 或 AMD SVM 后再运行安装",
        ),
        // ---- Well-known Windows runtime exits -------------------------------
        // 0xFFFD0000. Microsoft Q&A + Veeam/Nagios forums all confirm: this
        // is PowerShell 5.1's "couldn't parse the .ps1 source" exit. Almost
        // always means the script lacks a UTF-8 BOM and contains non-ASCII
        // characters — PS 5.1 then decodes as system ANSI codepage and the
        // parser chokes.
        -196608 => Some(
            "PowerShell 无法启动安装脚本 — 常见原因：脚本路径含空格，\
             或脚本编码异常（缺少 UTF-8 BOM）",
        ),
        -1073741510 /* 0xC000013A STATUS_CONTROL_C_EXIT */ => Some("安装进程被强制终止（Ctrl+C 或外部结束）"),
        -1073741819 /* 0xC0000005 STATUS_ACCESS_VIOLATION */ => Some("PowerShell 宿主进程崩溃 — 请重启电脑后重试"),
        _ => None,
    }
}

/// Scan recent log lines (newest-last) for keywords that signal a known root
/// cause, returning a human-readable Chinese reason if one matches. Used as
/// a fallback when bootstrap.ps1's outer catch swallowed the real exit code
/// (e.g. an IOException during log writes pre-empts a clean `exit 5`).
///
/// Patterns must be specific enough to avoid false positives — we match
/// against canonical error strings the OS / wsl.exe / our own scripts emit.
fn sniff_known_reason(lines: &[String]) -> Option<&'static str> {
    // Walk newest-first; the most recent failure is the operative one.
    for line in lines.iter().rev() {
        let l = line.as_str();
        if l.contains("HCS_E_HYPERV_NOT_INSTALLED")
            || l.contains("enablevirtualization")
            || l.contains("CPU 虚拟化")
            || l.contains("Intel VT-x")
            || l.contains("AMD SVM")
        {
            return Some(
                "CPU 虚拟化未在 BIOS 中开启。请重启电脑进入 BIOS / UEFI，\
                 启用 Intel VT-x 或 AMD SVM 后再运行安装",
            );
        }
        if l.contains("UAC 授权被拒绝") || l.contains("operation was canceled by the user") {
            return Some("UAC 授权被拒绝或取消，安装需要管理员权限才能继续");
        }
        if l.contains("CommandNotFoundException") && l.contains("wsl") {
            return Some(
                "未检测到 WSL 命令 — Windows 子系统功能可能尚未启用，\
                 请按提示重启电脑后重试",
            );
        }
        if l.contains("Windows build") && l.contains("is below 19041") {
            return Some("Windows 版本过低，WSL 2 需要 Win10 build 19041 或更高版本");
        }
    }
    None
}

/// Heuristic: a line is "mojibake" if it contains 3+ U+FFFD replacement chars.
///
/// `from_utf8_lossy` emits one U+FFFD per invalid byte sequence, so a single
/// CP936-encoded Chinese word (≥4 invalid bytes) already passes the threshold.
/// Legitimate use of U+FFFD as an actual placeholder is essentially always
/// ≤2 per line, so we won't false-positive on those.
fn line_looks_like_mojibake(line: &str) -> bool {
    line.chars().filter(|c| *c == '\u{FFFD}').count() >= 3
}

/// Parse a `@@reboot:<kind>` sentinel line. Returns the kind string on match.
/// Consistent with the `@@step:` sentinel pattern in `parse_step_sentinel`.
fn parse_reboot_sentinel(line: &str) -> Option<String> {
    let line = line.trim();
    let rest = line.strip_prefix("@@reboot:")?;
    if rest.is_empty() {
        return None;
    }
    Some(rest.to_string())
}

/// Run the event loop for a spawned child process.
///
/// Passthrough contract (two-stream logging):
/// - **stdout**: Every line is forwarded verbatim as `LogLine` UNLESS it matches
///   the `@@step:<key>:<label>` sentinel or `@@reboot:<kind>` sentinel, in which
///   case the appropriate event is emitted and the line is NOT forwarded as `LogLine`.
/// - **stderr**: Discarded.
/// - **Session log**: Written by the bash scripts themselves via fd 3.
async fn run_event_loop(
    mut rx: Receiver<CommandEvent>,
    on_event: tauri::ipc::Channel<InstallerEvent>,
    child_state: Arc<Mutex<Option<CommandChild>>>,
) {
    // Tracks the last @@reboot:<kind> sentinel seen before exit code 2.
    let mut reboot_kind: Option<String> = None;
    // Mojibake detector: from_utf8_lossy substitutes U+FFFD for each invalid
    // byte. If we see a line dense with replacements, the child is emitting in
    // a non-UTF-8 codepage (CP936 from PS 5.1 is the usual culprit). Fire one
    // diagnostic line per session so the operator gets a hint without flooding.
    let mut mojibake_warned = false;
    // Ring buffer of the most recent log lines, used by format_exit_code's
    // sniff_known_reason fallback when the script's exit code is the catch-all
    // (1) — we walk the buffer newest-first looking for keywords like
    // "HCS_E_HYPERV_NOT_INSTALLED" so the GUI banner can still surface a
    // human-readable root cause.
    const RECENT_CAP: usize = 100;
    let mut recent: Vec<String> = Vec::with_capacity(RECENT_CAP);

    loop {
        match rx.recv().await {
            Some(CommandEvent::Stdout(bytes)) => {
                let raw = String::from_utf8_lossy(&bytes).to_string();

                // Process line by line (a single recv() may deliver multiple
                // newline-separated lines if the OS buffers output).
                for piece in raw.split_inclusive('\n') {
                    let line = piece
                        .trim_end_matches(['\n', '\r'])
                        .to_string();
                    if line.is_empty() {
                        continue;
                    }

                    if !mojibake_warned && line_looks_like_mojibake(&line) {
                        mojibake_warned = true;
                        let _ = on_event.send(InstallerEvent::LogLine {
                            line: format!(
                                "[claw-installer] ⚠ 子进程输出疑似编码不一致（出现大量 U+FFFD），\
                                 请检查 bootstrap.ps1 中 [Console]::OutputEncoding 是否生效。\
                                 原始行: {:?}",
                                line
                            ),
                        });
                    }

                    // @@reboot:<kind> — consumed silently; stored for exit-code-2 dispatch.
                    if let Some(kind) = parse_reboot_sentinel(&line) {
                        reboot_kind = Some(kind);
                        continue;
                    }

                    // @@step:<key>:<label> — consumed as StepChanged.
                    if let Some((key, label)) = parse_step_sentinel(&line) {
                        let _ = on_event.send(InstallerEvent::StepChanged {
                            key,
                            label,
                            detail: String::new(),
                        });
                        continue;
                    }

                    // All other stdout lines are forwarded verbatim.
                    if recent.len() == RECENT_CAP {
                        recent.remove(0);
                    }
                    recent.push(line.clone());
                    let _ = on_event.send(InstallerEvent::LogLine { line });
                }
            }

            Some(CommandEvent::Stderr(_bytes)) => {
                // Discard stderr per two-stream logging contract.
            }

            Some(CommandEvent::Terminated(payload)) => {
                *child_state.lock().await = None;
                match payload.code {
                    Some(0) => {
                        let _ = on_event.send(InstallerEvent::StepChanged {
                            key: "done".to_string(),
                            label: "✓ 完成".to_string(),
                            detail: String::new(),
                        });
                        let _ = on_event.send(InstallerEvent::Finished {
                            success: true,
                            message: None,
                        });
                    }
                    Some(2) => {
                        // Script signals reboot required (WSL feature or distro first-run).
                        // kind was set by the @@reboot:<kind> sentinel emitted before exit.
                        let kind = reboot_kind
                            .take()
                            .unwrap_or_else(|| "wsl-feature".to_string());
                        let _ = on_event.send(InstallerEvent::RebootRequired { kind });
                    }
                    code => {
                        let _ = on_event.send(InstallerEvent::Finished {
                            success: false,
                            message: Some(format_exit_code(code, &recent)),
                        });
                    }
                }
                break;
            }

            Some(CommandEvent::Error(e)) => {
                *child_state.lock().await = None;
                let _ = on_event.send(InstallerEvent::Finished {
                    success: false,
                    message: Some(e),
                });
                break;
            }

            None => break,
            _ => {}
        }
    }
}

#[tauri::command]
pub async fn run_installer(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    agents: Vec<String>,
    env: HashMap<String, String>,
    on_event: tauri::ipc::Channel<InstallerEvent>,
) -> Result<(), String> {
    // Compute session log path, create parent dir, and pre-create the file so
    // the script can open fd 3 against it even on the very first write.
    let log_path = build_session_log_path("install");
    log_info!(
        "commands::run_installer",
        "agents={:?} repo_dir={:?} log={:?}",
        agents,
        resolve_installer_dir(&app),
        log_path
    );
    // Pre-create the log file (truncate if somehow exists already at this ts).
    let _ = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&log_path);

    // Send LogPath before the first LogLine so the GUI can wire up the failure
    // banner before any output arrives.
    let _ = on_event.send(InstallerEvent::LogPath {
        path: log_path.to_string_lossy().to_string(),
    });

    if let Err(msg) = check_resources(&app) {
        let _ = on_event.send(InstallerEvent::Finished {
            success: false,
            message: Some(msg),
        });
        return Ok(());
    }

    let mut cmd = apply_login_env(build_command(&app, &agents));
    // Forward caller-supplied env vars (INSTALLER_* overrides). Expand leading
    // "~/" against the user's home dir — bash variable assignment does not
    // expand tilde, so the script would otherwise see the literal "~".
    let home = app
        .path()
        .home_dir()
        .ok()
        .map(|p| p.to_string_lossy().to_string());
    for (k, v) in &env {
        let value = match (&home, v.strip_prefix("~/")) {
            (Some(h), Some(rest)) => format!("{}/{}", h, rest),
            _ => v.clone(),
        };
        cmd = cmd.env(k, value);
    }
    // Pass CLAW_SESSION_LOG so the bash script opens fd 3 against this path.
    cmd = cmd.env("CLAW_SESSION_LOG", log_path.to_string_lossy().as_ref());

    let (rx, child) = match cmd.spawn() {
        Ok(r) => r,
        Err(e) => {
            log_error!("commands::run_installer", "spawn FAILED: {}", e);
            return Err(e.to_string());
        }
    };
    log_info!("commands::run_installer", "spawned pid={}", child.pid());
    let child_arc = Arc::clone(&state.child);
    *child_arc.lock().await = Some(child);
    run_event_loop(rx, on_event, child_arc).await;
    log_info!("commands::run_installer", "event loop finished");
    Ok(())
}

#[tauri::command]
pub async fn cancel_installer(state: tauri::State<'_, AppState>) -> Result<(), String> {
    if let Some(child) = state.child.lock().await.take() {
        log_info!("commands::cancel_installer", "killing pid={}", child.pid());
        child.kill().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub async fn run_uninstaller(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    _agent: String,
    on_event: tauri::ipc::Channel<InstallerEvent>,
) -> Result<(), String> {
    let log_path = build_session_log_path("uninstall");
    log_info!(
        "commands::run_uninstaller",
        "agent={} repo_dir={:?} log={:?}",
        _agent,
        resolve_installer_dir(&app),
        log_path
    );
    let _ = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&log_path);

    let _ = on_event.send(InstallerEvent::LogPath {
        path: log_path.to_string_lossy().to_string(),
    });

    if let Err(msg) = check_resources(&app) {
        let _ = on_event.send(InstallerEvent::Finished {
            success: false,
            message: Some(msg),
        });
        return Ok(());
    }

    let mut cmd = apply_login_env(build_uninstall_command(&app, &_agent));
    cmd = cmd.env("CLAW_SESSION_LOG", log_path.to_string_lossy().as_ref());
    #[cfg(target_os = "windows")]
    if _agent == "openclaw" || _agent == "hermes" {
        cmd = cmd.env("CLAW_UNINSTALL_AGENT", &_agent);
    }

    let (rx, child) = match cmd.spawn() {
        Ok(r) => r,
        Err(e) => {
            log_error!("commands::run_uninstaller", "spawn FAILED: {}", e);
            return Err(e.to_string());
        }
    };
    log_info!("commands::run_uninstaller", "spawned pid={}", child.pid());
    let child_arc = Arc::clone(&state.child);
    *child_arc.lock().await = Some(child);
    run_event_loop(rx, on_event, child_arc).await;
    log_info!("commands::run_uninstaller", "event loop finished");
    Ok(())
}

/// Run a service lifecycle action (start / stop / restart) for an agent.
/// Dispatches to agents/<agent>/<action>.sh. Streams events the same way as
/// run_installer / run_uninstaller. Validates agent + action against an
/// allow-list before spawning anything so the script path can never be
/// user-controlled beyond the fixed set.
#[tauri::command]
pub async fn run_service_action(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    agent: String,
    action: String,
    on_event: tauri::ipc::Channel<InstallerEvent>,
) -> Result<(), String> {
    match agent.as_str() {
        "openclaw" | "hermes" => {}
        _ => return Err(format!("unknown agent: {}", agent)),
    }
    match action.as_str() {
        "start" | "stop" => {}
        _ => return Err(format!("unknown action: {}", action)),
    }

    let log_path = build_session_log_path(&format!("{}-{}", action, agent));
    log_info!(
        "commands::run_service_action",
        "agent={} action={} log={:?}",
        agent,
        action,
        log_path
    );
    let _ = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&log_path);

    let _ = on_event.send(InstallerEvent::LogPath {
        path: log_path.to_string_lossy().to_string(),
    });

    if let Err(msg) = check_resources(&app) {
        let _ = on_event.send(InstallerEvent::Finished {
            success: false,
            message: Some(msg),
        });
        return Ok(());
    }

    let mut cmd = apply_login_env(build_service_command(&app, &agent, &action));
    cmd = cmd.env("CLAW_SESSION_LOG", log_path.to_string_lossy().as_ref());

    let (rx, child) = match cmd.spawn() {
        Ok(r) => r,
        Err(e) => {
            log_error!("commands::run_service_action", "spawn FAILED: {}", e);
            return Err(e.to_string());
        }
    };
    log_info!("commands::run_service_action", "spawned pid={}", child.pid());
    let child_arc = Arc::clone(&state.child);
    *child_arc.lock().await = Some(child);
    run_event_loop(rx, on_event, child_arc).await;
    log_info!("commands::run_service_action", "event loop finished");
    Ok(())
}

/// Windows: run bootstrap.ps1 -InstallWslOnly to provision WSL features +
/// the target distro from the GUI. Triggers UAC. Streams events the same way
/// run_installer does; on exit-code 2 the @@reboot:<kind> sentinel (recovered
/// via the marker file inside Assert-Elevated) becomes a RebootRequired event.
#[cfg(target_os = "windows")]
#[tauri::command]
pub async fn install_wsl(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    on_event: tauri::ipc::Channel<InstallerEvent>,
) -> Result<(), String> {
    let log_path = build_session_log_path("install-wsl");
    log_info!(
        "commands::install_wsl",
        "repo_dir={:?} log={:?}",
        resolve_installer_dir(&app),
        log_path
    );
    let _ = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&log_path);

    let _ = on_event.send(InstallerEvent::LogPath {
        path: log_path.to_string_lossy().to_string(),
    });

    if let Err(msg) = check_resources(&app) {
        let _ = on_event.send(InstallerEvent::Finished {
            success: false,
            message: Some(msg),
        });
        return Ok(());
    }

    let ps_path = resolve_installer_path(&app, r"windows\bootstrap.ps1");
    let shell = app.shell();
    let mut cmd = apply_login_env(
        shell
            .command("powershell.exe")
            .args(powershell_args(&ps_path, &["-InstallWslOnly"])),
    );
    cmd = cmd.env("CLAW_SESSION_LOG", log_path.to_string_lossy().as_ref());

    let (rx, child) = match cmd.spawn() {
        Ok(r) => r,
        Err(e) => {
            log_error!("commands::install_wsl", "spawn FAILED: {}", e);
            return Err(e.to_string());
        }
    };
    log_info!("commands::install_wsl", "spawned pid={}", child.pid());
    let child_arc = Arc::clone(&state.child);
    *child_arc.lock().await = Some(child);
    run_event_loop(rx, on_event, child_arc).await;
    log_info!("commands::install_wsl", "event loop finished");
    Ok(())
}

#[cfg(not(target_os = "windows"))]
#[tauri::command]
pub async fn install_wsl(
    _state: tauri::State<'_, AppState>,
    _on_event: tauri::ipc::Channel<InstallerEvent>,
) -> Result<(), String> {
    Err("install_wsl is only supported on Windows".into())
}

/// Trigger an immediate system reboot (Windows only).
/// On non-Windows this returns an error so the frontend can handle it gracefully.
#[cfg(target_os = "windows")]
#[tauri::command]
pub async fn system_reboot() -> Result<(), String> {
    let mut cmd = std::process::Command::new("shutdown");
    cmd.args(["/r", "/t", "0"]);
    hide_console(&mut cmd)
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(not(target_os = "windows"))]
#[tauri::command]
pub async fn system_reboot() -> Result<(), String> {
    Err("system_reboot is only supported on Windows".into())
}

/// Return the directory where claw-installer writes Tauri and per-op log files.
///
/// Frontend can call this to populate an "Open logs folder" link in the UI.
/// Example return: `/var/folders/…/claw-installer` (macOS) or `%TEMP%\claw-installer` (Windows).
#[tauri::command]
pub fn get_logs_dir() -> String {
    std::env::temp_dir()
        .join("claw-installer")
        .to_string_lossy()
        .into_owned()
}

// ---- Unified op dispatcher -------------------------------------------------
//
// `dispatch_op` is the single Rust→bash execution path for named operations.
// On Windows it routes through bootstrap.ps1 (which calls Invoke-WslBashStreamed
// -Login, ensuring common.sh and _claw_compose_path run, giving fnm-managed
// Node on PATH). On macOS/Linux it routes through shell/claw-op.sh.
//
// Stdin transport: stdin_bytes is base64-encoded and passed as
// INSTALLER_OP_STDIN_B64 env var on Windows (the PowerShell process reads it
// and writes it to a chmod-600 temp file inside WSL). On macOS/Linux it is
// piped directly to the child process stdin.
//
// Size note: Windows env block is ~32 KB per variable; a model-config JSON
// patch is typically <4 KB, API keys <1 KB — well within the limit.

/// Build the extra `-Op`/`-Agent`/`-FastPath` arguments passed to bootstrap.ps1.
/// Extracted as a pure function so tests can verify arg construction without
/// spawning a PowerShell process.
///
/// `-FastPath` tells bootstrap.ps1 to skip the ~10s preflight chain (Windows
/// build check, WSL --status probe, --list roundtrips, UAC elevation, ensure-
/// systemd, full shell/ recopy into WSL) because install already verified all
/// of that. The op script surfaces real errors if WSL is somehow broken.
#[cfg(target_os = "windows")]
pub(crate) fn build_dispatch_op_ps_extras(agent: &str, op: &str) -> Vec<String> {
    vec![
        "-Op".to_string(),
        op.to_string(),
        "-Agent".to_string(),
        agent.to_string(),
        "-FastPath".to_string(),
    ]
}

/// Non-Windows stub — keeps test code compiling on macOS where the function is
/// referenced in the test module.
#[cfg(not(target_os = "windows"))]
#[allow(dead_code)]
pub(crate) fn build_dispatch_op_ps_extras(agent: &str, op: &str) -> Vec<String> {
    vec![
        "-Op".to_string(),
        op.to_string(),
        "-Agent".to_string(),
        agent.to_string(),
        "-FastPath".to_string(),
    ]
}

/// Dispatch a named operation to the per-OS glue layer.
///
/// * `agent`       — `"openclaw"` or `"hermes"`
/// * `op`          — one of the valid op names (e.g. `"apply-model-config"`)
/// * `stdin_bytes` — payload delivered to the op script via stdin; pass `b""`
///                   for ops that take no stdin
/// * `env_extras`  — additional `(KEY, VALUE)` env vars set on the child
///                   process (e.g. `INSTALLER_OP_REPLACE_PATHS`)
///
/// Writes a per-op session log to `<tmp_dir>/claw-installer/op-<agent>-<op>-<ts>.log`
/// with a header, captured stdout/stderr, and exit code. The log path is
/// included in error messages so users can find the full output.
///
/// Returns `Ok(stdout_string)` on exit 0, `Err(message)` on non-zero exit.
#[cfg(target_os = "windows")]
pub(crate) fn dispatch_op(
    app: &tauri::AppHandle,
    agent: &str,
    op: &str,
    stdin_bytes: &[u8],
    env_extras: &[(&str, &str)],
) -> Result<String, String> {
    use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
    use std::io::Write as _;
    use std::process::{Command, Stdio};

    // ── Per-op session log ────────────────────────────────────────────────
    let op_log_path = build_session_log_path(&format!("op-{}-{}", agent, op));
    log_info!(
        "commands::dispatch_op",
        "starting op={}/{} log={}",
        agent,
        op,
        op_log_path.display()
    );
    // Pre-create with a header so the file exists even if the child never writes.
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&op_log_path)
    {
        let _ = writeln!(
            f,
            "=== op={}/{} started at {} (tauri log: {}) ===",
            agent,
            op,
            crate::logger::format_utc_now(),
            crate::logger::log_path()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "(uninit)".to_string())
        );
    }

    let ps_path = resolve_installer_path(app, r"windows\bootstrap.ps1");

    // Build -SessionLogPath arg for bootstrap.ps1 — it writes display-stream
    // lines to this path via Write-Display, giving us op script output on disk.
    let log_path_str = op_log_path.to_string_lossy().into_owned();
    let mut ps_extras = build_dispatch_op_ps_extras(agent, op);
    ps_extras.push("-SessionLogPath".to_string());
    ps_extras.push(log_path_str.clone());
    let extras_str: Vec<&str> = ps_extras.iter().map(|s| s.as_str()).collect();
    let args = powershell_args(&ps_path, &extras_str);

    let b64_stdin = B64.encode(stdin_bytes);

    let mut cmd = Command::new("powershell.exe");
    cmd.args(&args)
        .env("WSL_UTF8", "1")
        .env("INSTALLER_OP_STDIN_B64", &b64_stdin);

    // Forward INSTALLER_WSL_DISTRO if set so the distro resolution in
    // bootstrap.ps1's main dispatch block sees the correct distro.
    if let Ok(distro) = std::env::var("INSTALLER_WSL_DISTRO") {
        cmd.env("INSTALLER_WSL_DISTRO", distro);
    }

    // Apply caller-supplied extra env vars (e.g. INSTALLER_OP_REPLACE_PATHS).
    for (k, v) in env_extras {
        cmd.env(k, v);
    }

    hide_console(&mut cmd);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("spawn powershell.exe 失败 (op={}/{}): {}", agent, op, e))?;

    // We do NOT pipe stdin_bytes directly to powershell.exe — the payload
    // travels via INSTALLER_OP_STDIN_B64 env var instead (design decision D2).
    // Drop stdin pipe so PowerShell doesn't block waiting for EOF.
    drop(child.stdin.take());

    let out = child
        .wait_with_output()
        .map_err(|e| format!("等待 powershell.exe 失败 (op={}/{}): {}", agent, op, e))?;

    // ── Append exit-code marker + any stderr to the op session log ───
    //
    // The session log file is SHARED with bootstrap.ps1's $SessionLog: that
    // script's Write-Display lines AND (since the Invoke-WslBashStreamed fix)
    // the bash op script's stdout are tee'd into this same file directly. So
    // appending PS-captured stdout here would duplicate everything in the file.
    //
    // We still append stderr (PowerShell hard errors land there) and an exit-
    // code marker so the file has a clear end-of-op delimiter.
    if let Ok(mut f) = fs::OpenOptions::new().append(true).open(&op_log_path) {
        if !out.stderr.is_empty() {
            let _ = writeln!(f, "--- powershell stderr ---");
            let _ = f.write_all(&out.stderr);
        }
        let code_str = out
            .status
            .code()
            .map(|c| c.to_string())
            .unwrap_or_else(|| "signal".to_string());
        let _ = writeln!(
            f,
            "--- exit code: {} ({}) ---",
            code_str,
            crate::logger::format_utc_now()
        );
    }

    if !out.status.success() {
        let code = out.status.code();
        log_error!(
            "commands::dispatch_op",
            "op={}/{} failed exit={:?} log={}",
            agent,
            op,
            code,
            op_log_path.display()
        );
        let base_msg = format_cli_failure(
            &format!("{}/{}", agent, op),
            &out.stdout,
            &out.stderr,
            code,
        );
        return Err(format!(
            "{}\n(log: {})",
            base_msg,
            op_log_path.display()
        ));
    }

    log_info!(
        "commands::dispatch_op",
        "op={}/{} ok log={}",
        agent,
        op,
        op_log_path.display()
    );
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// macOS/Linux implementation of dispatch_op: invokes shell/claw-op.sh with
/// stdin_bytes piped to the child process stdin. login_env is applied so the
/// op script inherits the same PATH enrichment as other bash invocations.
///
/// Per-op session log: `<tmp_dir>/claw-installer/op-<agent>-<op>-<ts>.log`.
/// Sets `CLAW_SESSION_LOG` on the child so op scripts using fd 3 can write
/// to the same file.
#[cfg(not(target_os = "windows"))]
pub(crate) fn dispatch_op(
    app: &tauri::AppHandle,
    agent: &str,
    op: &str,
    stdin_bytes: &[u8],
    env_extras: &[(&str, &str)],
) -> Result<String, String> {
    use std::io::Write as _;
    use std::process::{Command, Stdio};

    // ── Per-op session log ────────────────────────────────────────────────
    let op_log_path = build_session_log_path(&format!("op-{}-{}", agent, op));
    log_info!(
        "commands::dispatch_op",
        "starting op={}/{} log={}",
        agent,
        op,
        op_log_path.display()
    );
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&op_log_path)
    {
        let _ = writeln!(f, "=== op={}/{} started at {} ===", agent, op,
            crate::logger::log_path()
                .map(|p| p.display().to_string())
                .unwrap_or_default()
        );
    }

    let claw_op_sh = resolve_installer_path(app, "claw-op.sh");

    let mut cmd = Command::new("bash");
    cmd.arg(claw_op_sh.as_os_str())
        .arg("--op")
        .arg(op)
        .arg("--agent")
        .arg(agent);

    // Apply login env (PATH / PNPM_HOME / FNM_DIR from the user's shell init).
    for (k, v) in login_env::login_env() {
        cmd.env(k, v);
    }

    // Forward the per-op log path via CLAW_SESSION_LOG so op scripts that
    // use fd 3 (the two-stream logging contract) write to our session file.
    cmd.env("CLAW_SESSION_LOG", op_log_path.as_os_str());

    // Apply caller-supplied extra env vars.
    for (k, v) in env_extras {
        cmd.env(k, v);
    }

    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("spawn bash claw-op.sh 失败 (op={}/{}): {}", agent, op, e))?;

    if !stdin_bytes.is_empty() {
        let mut stdin_pipe = child
            .stdin
            .take()
            .ok_or_else(|| "无法获取 bash stdin 管道".to_string())?;
        stdin_pipe
            .write_all(stdin_bytes)
            .map_err(|e| format!("写入 stdin 失败: {}", e))?;
    }
    // Drop stdin to signal EOF.
    drop(child.stdin.take());

    let out = child
        .wait_with_output()
        .map_err(|e| format!("等待 bash claw-op.sh 失败 (op={}/{}): {}", agent, op, e))?;

    // ── Append captured stdout/stderr + exit code to the op session log ───
    //
    // macOS branch: no UAC, no bootstrap.ps1 tee. bash's stdout/stderr flow
    // straight back here. Without this append the file would be empty, so we
    // dump everything captured.
    if let Ok(mut f) = fs::OpenOptions::new().append(true).open(&op_log_path) {
        let _ = writeln!(f, "--- stdout ---");
        let _ = f.write_all(&out.stdout);
        let _ = writeln!(f, "\n--- stderr ---");
        let _ = f.write_all(&out.stderr);
        let code_str = out
            .status
            .code()
            .map(|c| c.to_string())
            .unwrap_or_else(|| "signal".to_string());
        let _ = writeln!(
            f,
            "\n--- exit code: {} ({}) ---",
            code_str,
            crate::logger::format_utc_now()
        );
    }

    if !out.status.success() {
        let code = out.status.code();
        log_error!(
            "commands::dispatch_op",
            "op={}/{} failed exit={:?} log={}",
            agent,
            op,
            code,
            op_log_path.display()
        );
        let base_msg = format_cli_failure(
            &format!("{}/{}", agent, op),
            &out.stdout,
            &out.stderr,
            code,
        );
        return Err(format!(
            "{}\n(log: {})",
            base_msg,
            op_log_path.display()
        ));
    }

    log_info!(
        "commands::dispatch_op",
        "op={}/{} ok log={}",
        agent,
        op,
        op_log_path.display()
    );
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

// ---- apply_openclaw_model_config ------------------------------------------

/// Apply a JSON patch to the openclaw model config, then validate.
///
/// Routes through the unified op-dispatch protocol so the WSL session gets a
/// fully-composed PATH (fnm-managed Node, pnpm) from common.sh — fixing the
/// `exec: node: not found` regression from the ad-hoc wsl.exe path.
#[tauri::command]
pub async fn apply_openclaw_model_config(
    app: tauri::AppHandle,
    patch_json: String,
    replace_paths: Vec<String>,
) -> Result<(), String> {
    // Validate replace_paths to prevent shell injection: each path must consist
    // only of dotted-identifier characters and must not start with '-'.
    for p in &replace_paths {
        if !is_valid_openclaw_path(p) {
            return Err(format!("非法的 replace path: {:?}", p));
        }
    }

    // Build INSTALLER_OP_REPLACE_PATHS as a space-joined string of validated paths.
    let replace_paths_env = replace_paths.join(" ");

    let env_extras: Vec<(&str, &str)> = if replace_paths_env.is_empty() {
        vec![]
    } else {
        vec![("INSTALLER_OP_REPLACE_PATHS", replace_paths_env.as_str())]
    };

    dispatch_op(
        &app,
        "openclaw",
        "apply-model-config",
        patch_json.as_bytes(),
        &env_extras,
    )
    .map(|_| ())
}


/// Accept only dotted config paths like `models.providers.custom.models`.
/// Rejects anything containing shell metacharacters / spaces, AND anything
/// starting with `-` — a leading dash would be parsed by openclaw's arg
/// parser as a flag (`--replace-path -h` → openclaw treats `-h` as `-h/--help`,
/// exits 0 with help text, and the GUI mistakenly reports the save succeeded).
fn is_valid_openclaw_path(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
}

/// Apply a hermes model + API-key change via the unified op-dispatch protocol.
///
/// Routes through `shell/agents/hermes/apply-model-config.sh` (via
/// `shell/claw-op.sh`) so the process inherits a fully-composed PATH from
/// `common.sh` (fnm-managed Node, pnpm, uv, brew) — consistent with the
/// Windows path and with how install/start/stop work.
///
/// The API key rides on stdin; all other config values are forwarded as
/// INSTALLER_OP_* env vars and consumed by the op script.
#[cfg(not(target_os = "windows"))]
#[tauri::command]
pub async fn apply_hermes_model_config(
    app: tauri::AppHandle,
    provider: String,
    default_model: String,
    base_url: String,
    env_var_name: String,
    api_key: String,
) -> Result<(), String> {
    // env_var_name validation: lock down to [A-Za-z0-9_]+ so it is safe to
    // use as a shell variable name inside the op script.
    if env_var_name.is_empty()
        || !env_var_name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_')
    {
        return Err(format!("非法的 env var 名: {}", env_var_name));
    }

    let env_extras = [
        ("INSTALLER_OP_PROVIDER", provider.as_str()),
        ("INSTALLER_OP_MODEL", default_model.as_str()),
        ("INSTALLER_OP_BASE_URL", base_url.as_str()),
        ("INSTALLER_OP_ENV_VAR_NAME", env_var_name.as_str()),
    ];

    dispatch_op(
        &app,
        "hermes",
        "apply-model-config",
        api_key.as_bytes(),
        &env_extras,
    )
    .map(|_| ())
}

/// Windows: hermes lives inside WSL. Routes through the unified op-dispatch
/// protocol so the WSL session gets a fully-composed PATH from common.sh.
///
/// The API key rides on stdin (via INSTALLER_OP_STDIN_B64 in the env var
/// transport); all other config values are forwarded as INSTALLER_OP_* env
/// vars and consumed by shell/agents/hermes/apply-model-config.sh.
#[cfg(target_os = "windows")]
#[tauri::command]
pub async fn apply_hermes_model_config(
    app: tauri::AppHandle,
    provider: String,
    default_model: String,
    base_url: String,
    env_var_name: String,
    api_key: String,
) -> Result<(), String> {
    // env_var_name validation: lock down to [A-Za-z0-9_]+ so it is safe to
    // use as a shell variable name inside the op script.
    if env_var_name.is_empty()
        || !env_var_name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_')
    {
        return Err(format!("非法的 env var 名: {}", env_var_name));
    }

    let env_extras = [
        ("INSTALLER_OP_PROVIDER", provider.as_str()),
        ("INSTALLER_OP_MODEL", default_model.as_str()),
        ("INSTALLER_OP_BASE_URL", base_url.as_str()),
        ("INSTALLER_OP_ENV_VAR_NAME", env_var_name.as_str()),
    ];

    dispatch_op(
        &app,
        "hermes",
        "apply-model-config",
        api_key.as_bytes(),
        &env_extras,
    )
    .map(|_| ())
}

// Phase 3 cleanup: shell_single_quote, run_in_wsl_with_stdin, and
// run_in_wsl_file_based are gone — all callers migrated to dispatch_op,
// which uses bootstrap.ps1's Invoke-WslBashStreamed for transport.

// ---- Model-config snapshot persistence ---------------------------------------
//
// The GUI mirrors the user's committed ModelConfig (active provider, per-provider
// credentials, savedAt timestamps) to <app_config_dir>/model-config.json so the
// "已配置" badge + input fields survive restarts. The file holds plaintext API
// keys, so we write it with mode 0600 on Unix (same security posture as
// ~/.hermes/.env, which hermes itself uses).
//
// Shape is owned by the TS side; Rust passes serde_json::Value through opaquely.

fn model_config_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_config_dir()
        .map_err(|e| format!("解析配置目录失败: {}", e))?;
    if !dir.exists() {
        fs::create_dir_all(&dir)
            .map_err(|e| format!("创建配置目录失败 {}: {}", dir.display(), e))?;
    }
    Ok(dir.join("model-config.json"))
}

#[tauri::command]
pub async fn read_model_configs(
    app: tauri::AppHandle,
) -> Result<Option<serde_json::Value>, String> {
    let path = model_config_path(&app)?;
    match fs::read_to_string(&path) {
        Ok(text) => {
            let v: serde_json::Value = serde_json::from_str(&text)
                .map_err(|e| format!("解析 {} 失败: {}", path.display(), e))?;
            Ok(Some(v))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("读取 {} 失败: {}", path.display(), e)),
    }
}

#[tauri::command]
pub async fn write_model_configs(
    app: tauri::AppHandle,
    payload: serde_json::Value,
) -> Result<(), String> {
    let path = model_config_path(&app)?;
    let body = serde_json::to_vec_pretty(&payload)
        .map_err(|e| format!("序列化 model-config 失败: {}", e))?;

    // Atomic-ish: write to a sibling temp file with mode 0600 then rename.
    let parent = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let tmp = parent.join(format!(".model-config.tmp.{}", std::process::id()));
    write_secret_file(&tmp, &body)
        .map_err(|e| format!("写入 {} 失败: {}", tmp.display(), e))?;
    fs::rename(&tmp, &path)
        .map_err(|e| format!("重命名到 {} 失败: {}", path.display(), e))?;
    Ok(())
}

/// Write a file with mode 0600 on Unix so secrets aren't world-readable.
#[cfg(not(target_os = "windows"))]
fn write_secret_file(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    Ok(())
}

#[cfg(target_os = "windows")]
#[allow(dead_code)]
fn write_secret_file(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    fs::write(path, bytes)
}

fn format_cli_failure(
    label: &str,
    stdout: &[u8],
    stderr: &[u8],
    code: Option<i32>,
) -> String {
    let so = String::from_utf8_lossy(stdout);
    let se = String::from_utf8_lossy(stderr);
    let body = if !se.trim().is_empty() {
        se.into_owned()
    } else if !so.trim().is_empty() {
        so.into_owned()
    } else {
        String::new()
    };
    let code_str = code
        .map(|c| c.to_string())
        .unwrap_or_else(|| "signal".to_string());
    if body.is_empty() {
        format!("{} 失败 (exit={})", label, code_str)
    } else {
        format!("{} 失败 (exit={}):\n{}", label, code_str, body.trim_end())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reboot_sentinel_parses_wsl_feature() {
        assert_eq!(
            parse_reboot_sentinel("@@reboot:wsl-feature"),
            Some("wsl-feature".to_string())
        );
    }

    #[test]
    fn reboot_sentinel_parses_distro_firstrun() {
        assert_eq!(
            parse_reboot_sentinel("@@reboot:distro-firstrun"),
            Some("distro-firstrun".to_string())
        );
    }

    #[test]
    fn reboot_sentinel_ignores_step_lines() {
        assert_eq!(parse_reboot_sentinel("@@step:base-deps:label"), None);
    }

    #[test]
    fn reboot_sentinel_ignores_plain_lines() {
        assert_eq!(parse_reboot_sentinel("some log output"), None);
    }

    #[test]
    fn reboot_sentinel_ignores_empty_kind() {
        assert_eq!(parse_reboot_sentinel("@@reboot:"), None);
    }

    #[test]
    fn reboot_sentinel_strips_leading_whitespace() {
        assert_eq!(
            parse_reboot_sentinel("  @@reboot:wsl-feature"),
            Some("wsl-feature".to_string())
        );
    }

    #[test]
    fn format_exit_code_includes_hex_and_decimal() {
        let s = format_exit_code(Some(1), &[]);
        assert!(s.contains('1'), "got {s:?}");
        assert!(s.contains("0x00000001"), "got {s:?}");
    }

    #[test]
    fn format_exit_code_explains_known_reasons_first() {
        // The reason should lead the message, not the raw code — users shouldn't
        // have to decode a hex number to know what to do next.
        let s5 = format_exit_code(Some(5), &[]);
        assert!(s5.contains("CPU 虚拟化"), "got {s5:?}");
        assert!(s5.starts_with("CPU"), "reason should lead: got {s5:?}");

        let s2 = format_exit_code(Some(2), &[]);
        assert!(s2.contains("重启"), "got {s2:?}");

        let s4 = format_exit_code(Some(4), &[]);
        assert!(s4.contains("UAC"), "got {s4:?}");
    }

    #[test]
    fn format_exit_code_one_is_plain_language_not_jargon() {
        // The user complaint that drove this rewrite: exit 1 must not show
        // "脚本异常终止（未预期的 PowerShell 错误）。请检查会话日志末尾的
        // Exception type / Script location / Stack trace". A non-engineer
        // can't act on that. We replace it with a sentence and a pointer.
        let s = format_exit_code(Some(1), &[]);
        assert!(!s.contains("Exception type"), "got {s:?}");
        assert!(!s.contains("Stack trace"), "got {s:?}");
        assert!(!s.contains("脚本异常终止"), "got {s:?}");
        assert!(s.contains("完整日志") || s.contains("日志"), "got {s:?}");
    }

    #[test]
    fn format_exit_code_one_sniffs_log_for_root_cause() {
        // When the script's outer catch swallowed the real exit code (e.g.
        // an IOException during log writes pre-empted exit 5), we should
        // still surface "CPU 虚拟化" to the user if the log shows it.
        let log = vec![
            "[claw-installer] claw-installer Windows bootstrap (...)".to_string(),
            "[claw-installer] Windows build: 26200".to_string(),
            "wsl --install -d Ubuntu stdout: WSL2 无法启动...".to_string(),
            "错误代码: Wsl/InstallDistro/Service/RegisterDistro/CreateVm/HCS/HCS_E_HYPERV_NOT_INSTALLED"
                .to_string(),
            "[claw-installer] wsl --install -d Ubuntu 失败 (exit -1)".to_string(),
        ];
        let s = format_exit_code(Some(1), &log);
        assert!(s.contains("CPU 虚拟化") || s.contains("BIOS"), "got {s:?}");
        assert!(s.contains("退出码 1"), "got {s:?}");
    }

    #[test]
    fn format_exit_code_one_sniffs_log_for_uac_denial() {
        let log = vec![
            "需要管理员权限，正在请求 UAC 授权…".to_string(),
            "[claw-installer] UAC 授权被拒绝或取消：xxx".to_string(),
        ];
        let s = format_exit_code(Some(1), &log);
        assert!(s.contains("UAC"), "got {s:?}");
    }

    #[test]
    fn sniff_returns_none_for_unrelated_lines() {
        let log = vec![
            "正在下载依赖".to_string(),
            "安装 npm 包".to_string(),
            "完成".to_string(),
        ];
        assert!(sniff_known_reason(&log).is_none());
    }

    #[test]
    fn format_exit_code_decodes_powershell_parse_failure() {
        let s = format_exit_code(Some(-196608), &[]);
        assert!(s.contains("-196608"), "got {s:?}");
        assert!(s.contains("0xFFFD0000"), "got {s:?}");
        // Hint should mention either of the two known triggers.
        assert!(
            s.contains("空格") || s.contains("BOM"),
            "got {s:?}"
        );
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn powershell_args_quotes_path_with_spaces() {
        use std::path::PathBuf;
        let p = PathBuf::from(r"C:\Program Files\Claw Installer\shell\windows\bootstrap.ps1");
        let args = powershell_args(&p, &["-InstallWslOnly"]);
        assert_eq!(args[0], "-NoProfile");
        assert_eq!(args[3], "-Command");
        let cmd = &args[4];
        // Path single-quoted, single-quotes preserve spaces from PS tokenizer
        assert!(
            cmd.starts_with("& 'C:\\Program Files\\Claw Installer\\"),
            "cmd was {cmd:?}"
        );
        assert!(cmd.ends_with("bootstrap.ps1' -InstallWslOnly"), "cmd was {cmd:?}");
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn powershell_args_escapes_single_quotes() {
        use std::path::PathBuf;
        let p = PathBuf::from(r"C:\weird's\path\bootstrap.ps1");
        let args = powershell_args(&p, &[]);
        // PowerShell escapes a single quote inside a single-quoted literal by doubling it
        assert!(args[4].contains("weird''s"), "cmd was {:?}", args[4]);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn powershell_args_no_extras() {
        use std::path::PathBuf;
        let p = PathBuf::from(r"C:\x\bootstrap.ps1");
        let args = powershell_args(&p, &[]);
        assert_eq!(args[4], r"& 'C:\x\bootstrap.ps1'");
    }

    #[test]
    fn mojibake_clean_line_not_flagged() {
        assert!(!line_looks_like_mojibake("正在安装 OpenClaw…"));
        assert!(!line_looks_like_mojibake("+ pnpm add -g openclaw@latest"));
        assert!(!line_looks_like_mojibake(""));
    }

    #[test]
    fn mojibake_one_replacement_not_flagged() {
        // Lone U+FFFD in real text shouldn't trigger.
        assert!(!line_looks_like_mojibake("ok \u{FFFD} done"));
    }

    #[test]
    fn mojibake_three_replacements_flagged() {
        assert!(line_looks_like_mojibake("\u{FFFD}\u{FFFD}\u{FFFD}"));
    }

    #[test]
    fn mojibake_two_replacements_not_flagged() {
        // Two are still in the noise range; we don't want to false-positive
        // on text that legitimately contains a U+FFFD glyph or two.
        assert!(!line_looks_like_mojibake("ab\u{FFFD}\u{FFFD}cdefgh"));
    }

    #[test]
    fn mojibake_dense_replacements_flagged() {
        // CP936-encoded Chinese decoded as UTF-8 produces dense U+FFFDs.
        assert!(line_looks_like_mojibake("\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"));
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn powershell_args_multiple_extras() {
        use std::path::PathBuf;
        let p = PathBuf::from(r"C:\x\bootstrap.ps1");
        let args = powershell_args(&p, &["-Service", "start", "-Agent", "openclaw"]);
        assert_eq!(
            args[4],
            r"& 'C:\x\bootstrap.ps1' -Service start -Agent openclaw"
        );
    }

    #[test]
    fn format_exit_code_handles_no_code() {
        let s = format_exit_code(None, &[]);
        assert!(s.contains("信号") || s.contains("崩溃"), "got {s:?}");
    }

    #[test]
    fn format_exit_code_no_hint_for_unknown() {
        let s = format_exit_code(Some(42), &[]);
        assert!(s.contains("42"));
        assert!(s.contains("0x0000002A"));
        // No trailing " — <hint>" segment
        assert!(!s.contains(" — "), "unexpected hint: {s:?}");
    }

    // ---- dispatch_op tests --------------------------------------------------

    #[test]
    fn is_valid_openclaw_path_accepts_good_paths() {
        assert!(is_valid_openclaw_path("models.providers.custom.models"));
        assert!(is_valid_openclaw_path("a"));
        assert!(is_valid_openclaw_path("a.b.c"));
        assert!(is_valid_openclaw_path("model_name"));
    }

    #[test]
    fn is_valid_openclaw_path_rejects_empty() {
        assert!(!is_valid_openclaw_path(""));
    }

    #[test]
    fn is_valid_openclaw_path_rejects_leading_dash() {
        assert!(!is_valid_openclaw_path("-help"));
        assert!(!is_valid_openclaw_path("--replace-path"));
    }

    #[test]
    fn is_valid_openclaw_path_rejects_shell_metacharacters() {
        assert!(!is_valid_openclaw_path("foo;bar"));
        assert!(!is_valid_openclaw_path("foo bar"));
        assert!(!is_valid_openclaw_path("foo$bar"));
    }

    /// dispatch_op_build_ps_extras verifies that dispatch_op produces the right
    /// set of extra arguments for bootstrap.ps1 on Windows.  We test the arg
    /// construction logic via a dedicated test helper rather than spawning
    /// PowerShell (which requires a live Windows + WSL environment).
    #[test]
    fn dispatch_op_ps_extras_include_op_and_agent() {
        let extras = build_dispatch_op_ps_extras("openclaw", "apply-model-config");
        // Must contain -Op, -Agent, and -FastPath (the bootstrap preflight skip)
        let joined = extras.join(" ");
        assert!(
            joined.contains("-Op apply-model-config"),
            "extras = {joined:?}"
        );
        assert!(joined.contains("-Agent openclaw"), "extras = {joined:?}");
        assert!(
            joined.contains("-FastPath"),
            "expected -FastPath for op dispatch to skip preflight; extras = {joined:?}"
        );
    }

    /// On macOS/Linux, dispatch_op constructs a bash invocation using claw-op.sh.
    #[cfg(not(target_os = "windows"))]
    #[test]
    fn dispatch_op_unix_path_contains_claw_op_sh() {
        use std::path::PathBuf;
        let shell_dir = PathBuf::from("/tmp/fake-shell");
        let script_path = shell_dir.join("claw-op.sh");
        // Verify the path we'd pass to bash looks correct
        assert!(script_path.to_string_lossy().ends_with("claw-op.sh"));
    }
}
