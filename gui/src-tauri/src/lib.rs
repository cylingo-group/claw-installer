mod commands;
mod manifest;
mod steps;
mod types;

use std::sync::Arc;
use tokio::sync::Mutex;
use commands::AppState;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Dev guard: warn if INSTALLER_REPO_DIR is not set in debug builds.
    #[cfg(debug_assertions)]
    if std::env::var("INSTALLER_REPO_DIR").is_err() {
        eprintln!(
            "[claw-installer] WARNING: INSTALLER_REPO_DIR is not set. \
             The Rust backend will use resource_dir to find installer scripts. \
             In dev mode, set INSTALLER_REPO_DIR=<path>/installer to point \
             at the working copy."
        );
    }

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_os::init())
        .manage(AppState {
            child: Arc::new(Mutex::new(None)),
        })
        .invoke_handler(tauri::generate_handler![
            commands::read_installer_state,
            commands::read_host_status,
            commands::run_installer,
            commands::cancel_installer,
            commands::run_uninstaller,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
