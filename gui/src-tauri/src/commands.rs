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

use crate::manifest::parse_manifest;
use crate::steps::parse_step_sentinel;
use crate::types::{HostStatusPayload, InstallerEvent, InstallerStatePayload};

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
fn resolve_installer_dir(app: &tauri::AppHandle) -> PathBuf {
    if let Ok(repo_dir) = std::env::var("INSTALLER_REPO_DIR") {
        return PathBuf::from(repo_dir);
    }
    app.path()
        .resource_dir()
        .expect("resource_dir unavailable")
        .join("shell")
}

/// Resolve a specific installer file path.
pub fn resolve_installer_path(app: &tauri::AppHandle, rel: &str) -> PathBuf {
    resolve_installer_dir(app).join(rel)
}

/// Determine the path to the manifest file.
fn manifest_path(app: &tauri::AppHandle) -> PathBuf {
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
    // Per OQ-3: read manifest via `wsl.exe -d $DISTRO -- cat ~/.claw-installer/manifest.tsv`
    let distro = std::env::var("INSTALLER_WSL_DISTRO").unwrap_or_else(|_| "Ubuntu".to_string());
    let output = std::process::Command::new("wsl.exe")
        .args(["-d", &distro, "--", "cat", "~/.claw-installer/manifest.tsv"])
        .output();

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
fn read_installer_state_windows_unc(app: &tauri::AppHandle) -> Result<InstallerStatePayload, String> {
    let distro = std::env::var("INSTALLER_WSL_DISTRO").unwrap_or_else(|_| "Ubuntu".to_string());
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
    let ps_path = resolve_installer_path(&app, r"windows\bootstrap.ps1");
    let output = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            &ps_path.to_string_lossy(),
            "-Preflight",
        ])
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
        let mut args = vec![
            "-NoProfile".to_string(),
            "-ExecutionPolicy".to_string(),
            "Bypass".to_string(),
            "-File".to_string(),
            ps_path.to_string_lossy().to_string(),
        ];
        if agents.len() == 1 {
            args.push("-Agent".to_string());
            args.push(agents[0].clone());
        }
        shell.command("powershell.exe").args(args)
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
        shell.command("powershell.exe").args([
            "-NoProfile".to_string(),
            "-ExecutionPolicy".to_string(),
            "Bypass".to_string(),
            "-File".to_string(),
            ps_path.to_string_lossy().to_string(),
            "-Uninstall".to_string(),
        ])
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
fn build_service_command(
    app: &tauri::AppHandle,
    agent: &str,
    action: &str,
) -> tauri_plugin_shell::process::Command {
    let shell = app.shell();

    #[cfg(target_os = "windows")]
    {
        let ps_path = resolve_installer_path(app, r"windows\bootstrap.ps1");
        shell.command("powershell.exe").args([
            "-NoProfile".to_string(),
            "-ExecutionPolicy".to_string(),
            "Bypass".to_string(),
            "-File".to_string(),
            ps_path.to_string_lossy().to_string(),
            "-Service".to_string(),
            action.to_string(),
            "-Agent".to_string(),
            agent.to_string(),
        ])
    }

    #[cfg(not(target_os = "windows"))]
    {
        let script = resolve_installer_path(app, &format!("agents/{}/{}.sh", agent, action));
        shell.command("bash").args([script.to_string_lossy().to_string()])
    }
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

    loop {
        match rx.recv().await {
            Some(CommandEvent::Stdout(bytes)) => {
                let raw = String::from_utf8_lossy(&bytes).to_string();

                // Process line by line (a single recv() may deliver multiple
                // newline-separated lines if the OS buffers output).
                for piece in raw.split_inclusive('\n') {
                    let line = piece
                        .trim_end_matches(|c| c == '\n' || c == '\r')
                        .to_string();
                    if line.is_empty() {
                        continue;
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
                            message: Some(format!("脚本退出码 {}", code.unwrap_or(-1))),
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
    eprintln!(
        "[claw-installer] run_installer: agents={:?} repo_dir={:?} log={:?}",
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

    let mut cmd = build_command(&app, &agents);
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
            eprintln!("[claw-installer] run_installer spawn FAILED: {}", e);
            return Err(e.to_string());
        }
    };
    eprintln!("[claw-installer] run_installer spawned pid={}", child.pid());
    let child_arc = Arc::clone(&state.child);
    *child_arc.lock().await = Some(child);
    run_event_loop(rx, on_event, child_arc).await;
    eprintln!("[claw-installer] run_installer: event loop finished");
    Ok(())
}

#[tauri::command]
pub async fn cancel_installer(state: tauri::State<'_, AppState>) -> Result<(), String> {
    if let Some(child) = state.child.lock().await.take() {
        eprintln!("[claw-installer] cancel_installer: killing pid={}", child.pid());
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
    eprintln!(
        "[claw-installer] run_uninstaller: agent={} repo_dir={:?} log={:?}",
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

    let mut cmd = build_uninstall_command(&app, &_agent);
    cmd = cmd.env("CLAW_SESSION_LOG", log_path.to_string_lossy().as_ref());
    #[cfg(target_os = "windows")]
    if _agent == "openclaw" || _agent == "hermes" {
        cmd = cmd.env("CLAW_UNINSTALL_AGENT", &_agent);
    }

    let (rx, child) = match cmd.spawn() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[claw-installer] run_uninstaller spawn FAILED: {}", e);
            return Err(e.to_string());
        }
    };
    eprintln!("[claw-installer] run_uninstaller spawned pid={}", child.pid());
    let child_arc = Arc::clone(&state.child);
    *child_arc.lock().await = Some(child);
    run_event_loop(rx, on_event, child_arc).await;
    eprintln!("[claw-installer] run_uninstaller: event loop finished");
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
        "start" | "stop" | "restart" => {}
        _ => return Err(format!("unknown action: {}", action)),
    }

    let log_path = build_session_log_path(&format!("{}-{}", action, agent));
    eprintln!(
        "[claw-installer] run_service_action: agent={} action={} log={:?}",
        agent, action, log_path
    );
    let _ = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&log_path);

    let _ = on_event.send(InstallerEvent::LogPath {
        path: log_path.to_string_lossy().to_string(),
    });

    let mut cmd = build_service_command(&app, &agent, &action);
    cmd = cmd.env("CLAW_SESSION_LOG", log_path.to_string_lossy().as_ref());

    let (rx, child) = match cmd.spawn() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[claw-installer] run_service_action spawn FAILED: {}", e);
            return Err(e.to_string());
        }
    };
    eprintln!("[claw-installer] run_service_action spawned pid={}", child.pid());
    let child_arc = Arc::clone(&state.child);
    *child_arc.lock().await = Some(child);
    run_event_loop(rx, on_event, child_arc).await;
    eprintln!("[claw-installer] run_service_action: event loop finished");
    Ok(())
}

/// Trigger an immediate system reboot (Windows only).
/// On non-Windows this returns an error so the frontend can handle it gracefully.
#[cfg(target_os = "windows")]
#[tauri::command]
pub async fn system_reboot() -> Result<(), String> {
    std::process::Command::new("shutdown")
        .args(["/r", "/t", "0"])
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(not(target_os = "windows"))]
#[tauri::command]
pub async fn system_reboot() -> Result<(), String> {
    Err("system_reboot is only supported on Windows".into())
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
}
