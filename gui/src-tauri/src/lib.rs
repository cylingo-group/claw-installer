mod commands;
mod dashboard;
mod login_env;
pub(crate) mod logger;
mod manifest;
mod steps;
mod tray;
mod types;

use std::sync::Arc;
use tokio::sync::Mutex;
use commands::AppState;
// Needed by `app.get_webview_window(..)` in both on_menu_event (cross-platform
// closure even though the matching menu item only exists on macOS) and the
// macOS-gated Reopen branch. Keep unconditional so Windows builds compile.
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Initialise persistent log file first so all subsequent backend code can
    // use log_info!/log_warn!/log_error!. Falls back to stderr-only on failure
    // (never panics).
    let _log_path = logger::log_init();

    // Dev guard: warn if INSTALLER_REPO_DIR is not set in debug builds.
    #[cfg(debug_assertions)]
    if std::env::var("INSTALLER_REPO_DIR").is_err() {
        log_warn!(
            "lib::run",
            "INSTALLER_REPO_DIR is not set — backend will use resource_dir. \
             In dev mode, set INSTALLER_REPO_DIR=<path>/shell to point at the working copy."
        );
    }

    // Harvest the user's interactive-login shell env once now, so the first
    // install/start click doesn't pay the shell-spawn latency. macOS GUI apps
    // start with launchd's minimal PATH; without this, bash spawns can't see
    // PNPM_HOME / FNM_DIR / customized PATH from .zshrc / .bashrc.
    login_env::prime();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_http::init())
        .manage(AppState {
            child: Arc::new(Mutex::new(None)),
        })
        // 4.1 — init tray in setup, before invoke_handler
        .setup(|app| {
            tray::init(app.handle())?;
            // macOS: install our app menu so the standard shortcuts route
            // through Tauri (Cmd+W → hide; Cmd+M → minimize; Cmd+Q → quit;
            // Cmd+C/V/A in text inputs). Windows/Linux skip this — a top
            // menu bar on a frameless window would defeat the design.
            #[cfg(target_os = "macos")]
            install_macos_menu(app.handle())?;
            Ok(())
        })
        // Cmd+W on macOS lands here via the custom "hide-window" MenuItem
        // installed in install_macos_menu. Hiding directly bypasses the
        // PredefinedMenuItem::CloseWindow → NSWindow `performClose:` →
        // CloseRequested chain entirely — that chain has been observed to
        // be unreliable on frameless+transparent windows, where the native
        // close action sometimes never fires the Tauri-side delegate.
        .on_menu_event(|app, event| {
            if event.id().as_ref() == "hide-window" {
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.hide();
                }
            }
        })
        // 4.2 — intercept CloseRequested as a defensive net: any other
        // close path (e.g. future tray-driven close, JS calling close())
        // gets translated to hide so the tray icon stays the only quit
        // route. Cmd+W does NOT reach here — it's handled by on_menu_event
        // above.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::read_installer_state,
            commands::read_host_status,
            commands::run_installer,
            commands::cancel_installer,
            commands::run_uninstaller,
            commands::run_service_action,
            commands::install_wsl,
            commands::system_reboot,
            commands::apply_openclaw_model_config,
            commands::apply_hermes_model_config,
            commands::pair_bubbolink,
            commands::read_model_configs,
            commands::write_model_configs,
            commands::get_logs_dir,
            commands::frontend_log,
            // 4.5 — tray commands
            tray::tray_start_all_agents,
            tray::tray_stop_all_agents,
            dashboard::open_agent_dashboard,
        ])
        // 4.3 — switch from .run() to .build()?.run() to handle RunEvent::Reopen
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|_app, _event| {
            // 4.4 — macOS dock icon click restores hidden window
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen {
                has_visible_windows,
                ..
            } = _event
            {
                if !has_visible_windows {
                    if let Some(win) = _app.get_webview_window("main") {
                        let _ = win.show();
                        let _ = win.set_focus();
                    }
                }
            }
        });
}

/// Build the macOS app menu (top-of-screen menu bar) with:
///
/// - **Claw Installer** submenu: About, Hide, Hide Others, Show All, Quit
///   (all standard PredefinedMenuItems — Cmd+H / Cmd+Q come for free).
/// - **Edit** submenu: Undo / Redo / Cut / Copy / Paste / Select All — required
///   for text inputs to support clipboard shortcuts. Without an Edit submenu
///   on macOS, Cmd+C / Cmd+V / Cmd+A do nothing in <input>/<textarea>.
/// - **Window** submenu: Minimize (Cmd+M, native) + a custom "Close Window"
///   item bound to Cmd+W. The Close item is a regular MenuItem (id =
///   "hide-window"), NOT PredefinedMenuItem::close_window — the predefined
///   variant calls NSWindow `performClose:` which is unreliable on
///   frameless+transparent windows. The custom item fires
///   `on_menu_event("hide-window")` in the Builder above, which calls
///   `window.hide()` directly.
#[cfg(target_os = "macos")]
fn install_macos_menu(app: &tauri::AppHandle) -> tauri::Result<()> {
    use tauri::menu::{AboutMetadata, Menu, MenuItem, PredefinedMenuItem, Submenu};

    // ── App submenu ──────────────────────────────────────────────────────
    let about = PredefinedMenuItem::about(
        app,
        Some("About Claw Installer"),
        Some(AboutMetadata::default()),
    )?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let hide = PredefinedMenuItem::hide(app, None)?;
    let hide_others = PredefinedMenuItem::hide_others(app, None)?;
    let show_all = PredefinedMenuItem::show_all(app, None)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let quit = PredefinedMenuItem::quit(app, None)?;
    let app_submenu = Submenu::with_items(
        app,
        "Claw Installer",
        true,
        &[&about, &sep1, &hide, &hide_others, &show_all, &sep2, &quit],
    )?;

    // ── Edit submenu ─────────────────────────────────────────────────────
    let undo = PredefinedMenuItem::undo(app, None)?;
    let redo = PredefinedMenuItem::redo(app, None)?;
    let sep3 = PredefinedMenuItem::separator(app)?;
    let cut = PredefinedMenuItem::cut(app, None)?;
    let copy = PredefinedMenuItem::copy(app, None)?;
    let paste = PredefinedMenuItem::paste(app, None)?;
    let select_all = PredefinedMenuItem::select_all(app, None)?;
    let edit_submenu = Submenu::with_items(
        app,
        "Edit",
        true,
        &[&undo, &redo, &sep3, &cut, &copy, &paste, &select_all],
    )?;

    // ── Window submenu ───────────────────────────────────────────────────
    let minimize = PredefinedMenuItem::minimize(app, None)?;
    let hide_window =
        MenuItem::with_id(app, "hide-window", "Close Window", true, Some("CmdOrCtrl+W"))?;
    let window_submenu =
        Submenu::with_items(app, "Window", true, &[&minimize, &hide_window])?;

    let menu = Menu::with_items(app, &[&app_submenu, &edit_submenu, &window_submenu])?;
    app.set_menu(menu)?;
    Ok(())
}
