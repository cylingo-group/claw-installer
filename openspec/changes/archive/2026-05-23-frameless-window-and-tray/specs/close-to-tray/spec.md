## ADDED Requirements

### Requirement: Close-to-tray behavior
When the user triggers a window close (via titlebar close button, Alt+F4 on Windows, Cmd+W on macOS, or any OS-level close signal), the app SHALL hide the main window rather than destroy it or quit the process.

The app process SHALL remain running after the window is hidden. The system tray icon SHALL remain visible and functional.

#### Scenario: Window close hides to tray — not quit
- **WHEN** the user triggers a window close via any mechanism (custom close button, Alt+F4, Cmd+Q does not apply here)
- **THEN** the window becomes invisible, the process continues running, and the tray icon remains in the system tray / menu bar

#### Scenario: No quit-on-last-window-close
- **WHEN** the main window is hidden and there are no other visible windows
- **THEN** the app process does NOT exit

---

### Requirement: System tray icon
A system tray icon SHALL be present on both macOS (menu bar, right side) and Windows (notification area) for the lifetime of the app process. The icon SHALL use the app's bundled icon asset (from `app.default_window_icon()`).

The tray icon SHALL be initialized in the Tauri `setup` closure via `tray::init(app)` in `gui/src-tauri/src/tray.rs`.

#### Scenario: Tray icon present after launch
- **WHEN** the app launches on macOS or Windows
- **THEN** the tray icon appears in the menu bar (macOS) or notification area (Windows) within 2 seconds of launch

#### Scenario: Tray icon persists when window hidden
- **WHEN** the user hides the window via the close button
- **THEN** the tray icon remains visible and interactive

#### Scenario: Tray icon removed on quit
- **WHEN** the user selects "Quit Claw Installer" from the tray menu
- **THEN** the tray icon is removed and the process exits cleanly

---

### Requirement: Tray menu structure
The tray icon SHALL expose a context menu with the following items in order:

1. **"Open Claw Installer"** — default item (bold on Windows); shows and focuses the main window.
2. *separator*
3. **"Start All Agents"** — triggers `tray_start_all_agents` Tauri command.
4. **"Stop All Agents"** — triggers `tray_stop_all_agents` Tauri command.
5. *separator*
6. **"Quit Claw Installer"** — calls `app.exit(0)` to fully terminate the process.

#### Scenario: Tray menu shows correct items
- **WHEN** the user opens the tray context menu
- **THEN** all six items (Open, separator, Start All, Stop All, separator, Quit) appear in order

#### Scenario: Open menu item shows window
- **WHEN** the user clicks "Open Claw Installer" in the tray menu
- **THEN** the main window becomes visible and gains focus

#### Scenario: Quit menu item exits process
- **WHEN** the user clicks "Quit Claw Installer"
- **THEN** the app process terminates cleanly (tray icon removed, process exits)

---

### Requirement: Tray click behavior — macOS
On macOS, a left-click on the tray icon SHALL show the tray menu (`show_menu_on_left_click(true)`). A double-click on the tray icon SHALL show and focus the main window.

#### Scenario: macOS left-click opens menu
- **WHEN** the user single-left-clicks the tray icon on macOS
- **THEN** the tray context menu appears

#### Scenario: macOS double-click opens window
- **WHEN** the user double-clicks the tray icon on macOS
- **THEN** the main window becomes visible and gains focus (equivalent to clicking "Open Claw Installer")

---

### Requirement: Tray click behavior — Windows
On Windows, a double-click on the tray icon SHALL show and focus the main window. A right-click SHALL show the tray context menu. Left-click (single) has no default action.

#### Scenario: Windows double-click opens window
- **WHEN** the user double-clicks the tray icon on Windows
- **THEN** the main window becomes visible and gains focus

#### Scenario: Windows right-click opens menu
- **WHEN** the user right-clicks the tray icon on Windows
- **THEN** the tray context menu appears

---

### Requirement: macOS Reopen event restores window
When the user clicks the macOS Dock icon while the main window is hidden, the app SHALL show and focus the main window (equivalent to `window.show()` + `window.set_focus()`).

This is handled via `RunEvent::Reopen { has_visible_windows: false, .. }` in the Tauri run-loop callback.

#### Scenario: Dock click restores hidden window
- **WHEN** the main window is hidden and the user clicks the app icon in the macOS Dock
- **THEN** the main window becomes visible and focused

#### Scenario: Dock click does nothing when window visible
- **WHEN** the main window is already visible and the user clicks the Dock icon
- **THEN** no duplicate window is opened (the existing window is focused at most)

---

### Requirement: Tray Start All / Stop All actions
The tray "Start All Agents" and "Stop All Agents" commands SHALL:

1. Read the installation manifest to determine which agents are currently installed (status = "installed" in the manifest TSV).
2. Skip agents that are not installed — do not attempt to start/stop them.
3. For each installed agent, invoke `build_service_command(app, agent_id, action)` (reusing the existing code path from `run_service_action`).
4. After all agents are processed, emit a system notification indicating success or failure via `tauri-plugin-notification`.

The commands SHALL be registered as `tray_start_all_agents` and `tray_stop_all_agents` in `lib.rs`'s `invoke_handler`.

#### Scenario: Start All skips not-installed agents
- **WHEN** the user clicks "Start All Agents" and only one of two agents is installed
- **THEN** only the installed agent's start script is invoked; no error is thrown for the not-installed agent

#### Scenario: Start All emits success notification
- **WHEN** all installed agents start successfully
- **THEN** a system notification appears with a success message (e.g., "所有 Agent 已启动")

#### Scenario: Stop All emits failure notification on error
- **WHEN** one or more agents fail to stop (non-zero exit code)
- **THEN** a system notification appears indicating partial or full failure

#### Scenario: Start All is a no-op when no agents installed
- **WHEN** the user clicks "Start All Agents" and no agents are installed
- **THEN** no scripts are spawned and a neutral notification informs the user that no agents are installed

---

### Requirement: Tray commands reuse existing `run_service_action` infrastructure
The `tray_start_all_agents` and `tray_stop_all_agents` commands SHALL reuse `build_service_command` from `commands.rs` and the manifest reading logic from `manifest_path` + `parse_manifest`. These functions SHALL be made `pub(crate)` (or moved to a shared module) so `tray.rs` can call them without duplication.

#### Scenario: Tray start uses same shell script as GUI start
- **WHEN** the tray "Start All Agents" command runs for agent "openclaw"
- **THEN** the command executed is `agents/openclaw/start.sh` (Unix) or `bootstrap.ps1 -Service start -Agent openclaw` (Windows), identical to what the GUI "启动" button runs
