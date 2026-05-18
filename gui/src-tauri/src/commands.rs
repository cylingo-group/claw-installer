use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tauri::Manager;
use tokio::sync::Mutex;
use tauri_plugin_shell::ShellExt;
use tauri_plugin_shell::process::{CommandEvent, CommandChild};
use tauri::async_runtime::Receiver;

use crate::manifest::parse_manifest;
use crate::steps::{parse_step_line, step_label};
use crate::types::{HostStatusPayload, InstallerEvent, InstallerStatePayload};

pub struct AppState {
    pub child: Arc<Mutex<Option<CommandChild>>>,
}

/// Resolve the installer directory.
/// In dev: use INSTALLER_REPO_DIR env var.
/// In prod: use {resource_dir}/installer/.
fn resolve_installer_dir(app: &tauri::AppHandle) -> PathBuf {
    if let Ok(repo_dir) = std::env::var("INSTALLER_REPO_DIR") {
        return PathBuf::from(repo_dir);
    }
    app.path()
        .resource_dir()
        .expect("resource_dir unavailable")
        .join("installer")
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
        shell
            .command("powershell.exe")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", &ps_path.to_string_lossy().to_string()])
    }

    #[cfg(not(target_os = "windows"))]
    {
        let script = if agents.len() == 1 && agents[0] == "openclaw" {
            resolve_installer_path(app, "install-openclaw.sh")
        } else if agents.len() == 1 && agents[0] == "hermes" {
            resolve_installer_path(app, "install-hermes.sh")
        } else {
            resolve_installer_path(app, "install.sh")
        };
        shell.command("bash").args([script.to_string_lossy().to_string()])
    }
}

fn build_uninstall_command(app: &tauri::AppHandle) -> tauri_plugin_shell::process::Command {
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
            "-Uninstall".to_string(),
        ])
    }

    #[cfg(not(target_os = "windows"))]
    {
        let script = resolve_installer_path(app, "uninstall.sh");
        shell.command("bash").args([script.to_string_lossy().to_string(), "--yes".to_string()])
    }
}

/// Run the event loop for a spawned child process.
async fn run_event_loop(
    mut rx: Receiver<CommandEvent>,
    on_event: tauri::ipc::Channel<InstallerEvent>,
    child_state: Arc<Mutex<Option<CommandChild>>>,
) {
    let mut last_step: Option<String> = None;

    loop {
        match rx.recv().await {
            Some(CommandEvent::Stdout(bytes)) | Some(CommandEvent::Stderr(bytes)) => {
                let line_str = String::from_utf8_lossy(&bytes).to_string();
                // Drain into LogLine (not rendered in UI; prevents pipe buffer saturation)
                let _ = on_event.send(InstallerEvent::LogLine { line: line_str.clone() });

                if let Some(step_key) = parse_step_line(&line_str) {
                    if last_step.as_deref() != Some(step_key) {
                        let key_owned = step_key.to_string();
                        last_step = Some(key_owned.clone());
                        let (label, detail) = step_label(&key_owned);
                        let _ = on_event.send(InstallerEvent::StepChanged {
                            key: key_owned,
                            label,               // already String
                            detail: detail.to_string(),
                        });
                    }
                }
            }
            Some(CommandEvent::Terminated(payload)) => {
                *child_state.lock().await = None;
                let success = payload.code == Some(0);
                if success {
                    let _ = on_event.send(InstallerEvent::StepChanged {
                        key: "done".to_string(),
                        label: "✓ 完成".to_string(),
                        detail: String::new(),
                    });
                }
                let _ = on_event.send(InstallerEvent::Finished {
                    success,
                    message: if !success {
                        Some(format!("脚本退出码 {}", payload.code.unwrap_or(-1)))
                    } else {
                        None
                    },
                });
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
    let mut cmd = build_command(&app, &agents);
    for (k, v) in &env {
        cmd = cmd.env(k, v);
    }
    let (rx, child) = cmd.spawn().map_err(|e| e.to_string())?;
    let child_arc = Arc::clone(&state.child);
    *child_arc.lock().await = Some(child);
    run_event_loop(rx, on_event, child_arc).await;
    Ok(())
}

#[tauri::command]
pub async fn cancel_installer(state: tauri::State<'_, AppState>) -> Result<(), String> {
    if let Some(child) = state.child.lock().await.take() {
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
    // NOTE: cancel_installer is NOT wired to the UI during uninstall (AC3 / proposal §B5)
    let cmd = build_uninstall_command(&app);
    let (rx, child) = cmd.spawn().map_err(|e| e.to_string())?;
    let child_arc = Arc::clone(&state.child);
    *child_arc.lock().await = Some(child);
    run_event_loop(rx, on_event, child_arc).await;
    Ok(())
}
