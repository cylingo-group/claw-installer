//! System tray icon and menu for Claw Installer.
//!
//! Initialised once in the `setup` closure of `lib.rs`. The tray persists for
//! the lifetime of the process; only "Quit Claw Installer" removes it via
//! `app.exit(0)`.

use tauri::{
    image::Image,
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager,
};
use tauri_plugin_notification::NotificationExt;

use crate::commands::{apply_login_env, build_service_command};
use crate::manifest::{parse_manifest, InstallStatus};

/// Show and focus the main window. No-op if the window does not exist.
fn show_main_window(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.set_focus();
    }
}

/// Initialise the system tray icon with a context menu and event handlers.
///
/// Must be called once from `setup`. Returns an error if the icon or menu
/// cannot be created (e.g., on platforms that don't support tray icons).
pub fn init(app: &AppHandle) -> tauri::Result<()> {
    // ── Build menu items ──────────────────────────────────────────────────
    let open_item = MenuItem::with_id(app, "open", "Open Claw Installer", true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let start_all_item =
        MenuItem::with_id(app, "start-all", "Start All Agents", true, None::<&str>)?;
    let stop_all_item =
        MenuItem::with_id(app, "stop-all", "Stop All Agents", true, None::<&str>)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let quit_item =
        MenuItem::with_id(app, "quit", "Quit Claw Installer", true, None::<&str>)?;

    let menu = Menu::with_items(
        app,
        &[
            &open_item,
            &sep1,
            &start_all_item,
            &stop_all_item,
            &sep2,
            &quit_item,
        ],
    )?;

    // ── Build tray icon ───────────────────────────────────────────────────
    // show_menu_on_left_click: true on macOS (menu-bar convention),
    //                          false on Windows (right-click convention).
    let tray_icon = round_image_corners(app.default_window_icon().unwrap());

    TrayIconBuilder::new()
        .icon(tray_icon)
        .menu(&menu)
        .show_menu_on_left_click(cfg!(target_os = "macos"))
        .on_menu_event({
            let app = app.clone();
            move |_tray_app, event| match event.id.as_ref() {
                "open" => show_main_window(&app),
                "start-all" => tray_start_all_agents_inner(&app),
                "stop-all" => tray_stop_all_agents_inner(&app),
                "quit" => app.exit(0),
                _ => {}
            }
        })
        .on_tray_icon_event({
            let app = app.clone();
            move |_tray, event| {
                match &event {
                    // DoubleClick is Windows-only per Tauri docs.
                    // On macOS the menu appears on left-click (show_menu_on_left_click(true))
                    // and the "Open Claw Installer" item handles the open-window flow.
                    TrayIconEvent::DoubleClick {
                        button: MouseButton::Left,
                        ..
                    } => {
                        show_main_window(&app);
                    }
                    _ => {}
                }
            }
        })
        .build(app)?;

    Ok(())
}

// ── Tray icon rounding ───────────────────────────────────────────────────────

/// Apply a rounded-rectangle alpha mask to the source icon and return a new
/// `Image` owning its RGBA buffer.
///
/// The corner radius is 10 % of the shorter side — a mild round, distinctly
/// less than the macOS app-icon squircle (22 %). Anti-aliasing is done with a
/// 1-pixel-wide alpha gradient at the corner edge so it looks smooth at both
/// 22-pt (macOS menu-bar) and 16/32-px (Windows tray) sizes.
fn round_image_corners(src: &Image<'_>) -> Image<'static> {
    let w = src.width();
    let h = src.height();
    let rgba = src.rgba();
    let mut out: Vec<u8> = rgba.to_vec();
    let radius = ((w.min(h) as f32) * 0.10).round() as i32;
    let wi = w as i32;
    let hi = h as i32;

    for y in 0..hi {
        for x in 0..wi {
            // Distance from the nearest corner-arc center, in pixels.
            // The pixel sits inside the rounded rect iff that distance ≤ radius.
            let cx = if x < radius {
                radius - x
            } else if x >= wi - radius {
                x - (wi - radius - 1)
            } else {
                0
            };
            let cy = if y < radius {
                radius - y
            } else if y >= hi - radius {
                y - (hi - radius - 1)
            } else {
                0
            };
            if cx == 0 || cy == 0 {
                continue; // straight edge — leave pixel alone
            }
            let d2 = (cx * cx + cy * cy) as f32;
            let r2 = (radius * radius) as f32;
            let idx = ((y as u32 * w + x as u32) * 4 + 3) as usize;
            if d2 > r2 {
                // Outside the rounded rect — fully transparent.
                out[idx] = 0;
            } else {
                // 1-pixel feathering at the arc boundary for soft edges.
                let d = d2.sqrt();
                let edge = (radius as f32) - d;
                if edge < 1.0 {
                    out[idx] = ((out[idx] as f32) * edge.max(0.0)).round() as u8;
                }
            }
        }
    }
    Image::new_owned(out, w, h)
}

// ── Internal helpers for tray actions ────────────────────────────────────────

/// Determine which agents are currently installed by reading the manifest file.
/// Returns a Vec of installed agent ID strings.
#[cfg(not(target_os = "windows"))]
fn installed_agents(app: &AppHandle) -> Vec<&'static str> {
    use crate::commands::manifest_path;
    let path = manifest_path(app);
    match std::fs::read_to_string(&path) {
        Ok(content) => agents_from_manifest(&content),
        Err(_) => vec![],
    }
}

#[cfg(target_os = "windows")]
fn installed_agents(_app: &AppHandle) -> Vec<&'static str> {
    // Lightweight read: `wsl.exe -- cat ~/.claw-installer/manifest.tsv`. Honor
    // INSTALLER_WSL_DISTRO if set; otherwise let wsl.exe target its default
    // distro. Hardcoded "Ubuntu" silently fails for users with Ubuntu-24.04 etc.,
    // since wsl.exe's -d does not do the fuzzy matching bootstrap.ps1 does.
    let distro_override = std::env::var("INSTALLER_WSL_DISTRO").ok();
    let content = {
        let mut cmd = std::process::Command::new("wsl.exe");
        if let Some(ref d) = distro_override {
            cmd.args(["-d", d.as_str()]);
        }
        cmd.args(["--", "cat", "~/.claw-installer/manifest.tsv"]);
        cmd.env("WSL_UTF8", "1");
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
        match cmd.output() {
            Ok(out) if out.status.success() => {
                String::from_utf8_lossy(&out.stdout).to_string()
            }
            _ => {
                // UNC fallback only when we have an explicit distro name to use.
                if let Some(distro) = distro_override.as_deref() {
                    let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".to_string());
                    let unc = format!(
                        r"\\wsl.localhost\{}\home\{}\.claw-installer\manifest.tsv",
                        distro, user
                    );
                    std::fs::read_to_string(unc).unwrap_or_default()
                } else {
                    String::new()
                }
            }
        }
    };
    agents_from_manifest(&content)
}

fn agents_from_manifest(content: &str) -> Vec<&'static str> {
    let status = parse_manifest(content);
    let mut agents = Vec::new();
    if status.openclaw == InstallStatus::Installed {
        agents.push("openclaw");
    }
    if status.hermes == InstallStatus::Installed {
        agents.push("hermes");
    }
    agents
}

/// Run a service action (start/stop) for all installed agents, then notify.
fn run_tray_service_action(app: &AppHandle, action: &str) {
    let agents = installed_agents(app);

    if agents.is_empty() {
        let _ = app
            .notification()
            .builder()
            .title("Claw Installer")
            .body("未检测到已安装的 Agent")
            .show();
        return;
    }

    let mut failures: Vec<String> = Vec::new();

    for agent in &agents {
        let cmd = apply_login_env(build_service_command(app, agent, action));
        match cmd.spawn() {
            Ok((mut rx, child)) => {
                let pid = child.pid();
                crate::log_info!(
                    "tray::run_service_action",
                    "{action} {agent}: spawned pid={pid}"
                );
                // Drain the channel to completion so the process exits cleanly.
                // We don't stream events to the UI — this is a fire-and-forget
                // tray action; result is surfaced via system notification only.
                tauri::async_runtime::block_on(async {
                    use tauri_plugin_shell::process::CommandEvent;
                    loop {
                        match rx.recv().await {
                            Some(CommandEvent::Terminated(payload)) => {
                                if payload.code != Some(0) {
                                    failures.push(format!("{agent}: exit {:?}", payload.code));
                                }
                                break;
                            }
                            Some(CommandEvent::Error(e)) => {
                                failures.push(format!("{agent}: {e}"));
                                break;
                            }
                            None => break,
                            _ => {}
                        }
                    }
                });
            }
            Err(e) => {
                crate::log_error!(
                    "tray::run_service_action",
                    "{action} {agent}: spawn failed: {e}"
                );
                failures.push(format!("{agent}: {e}"));
            }
        }
    }

    let action_label = if action == "start" { "启动" } else { "停止" };
    let body = if failures.is_empty() {
        format!("所有 Agent 已{action_label}")
    } else {
        format!(
            "部分 Agent {action_label}失败：{}",
            failures.join(", ")
        )
    };

    let _ = app
        .notification()
        .builder()
        .title("Claw Installer")
        .body(&body)
        .show();
}

/// Start all installed agents. Called by the tray menu "Start All Agents" item.
pub(crate) fn tray_start_all_agents_inner(app: &AppHandle) {
    run_tray_service_action(app, "start");
}

/// Stop all installed agents. Called by the tray menu "Stop All Agents" item.
pub(crate) fn tray_stop_all_agents_inner(app: &AppHandle) {
    run_tray_service_action(app, "stop");
}

// ── Tauri commands (thin wrappers) ────────────────────────────────────────────

#[tauri::command]
pub async fn tray_start_all_agents(app: AppHandle) -> Result<(), String> {
    tray_start_all_agents_inner(&app);
    Ok(())
}

#[tauri::command]
pub async fn tray_stop_all_agents(app: AppHandle) -> Result<(), String> {
    tray_stop_all_agents_inner(&app);
    Ok(())
}
