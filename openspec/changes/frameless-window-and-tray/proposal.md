## Why

The Claw Installer GUI currently uses system-provided window chrome, which looks generic and mismatches the product's visual identity. At the same time, a user who closes the window dismisses the app entirely — losing any running agents or the ability to quickly restart them from the menu bar or notification area. These two gaps — poor visual ownership of the window shell and absent background-running UX — are addressed together because they share the same Rust window-lifecycle and platform-specific code paths.

## What Changes

- **`decorations: false`** added to `tauri.conf.json`, removing OS-native window chrome on both macOS and Windows.
- New React component `gui/src/components/installer/Titlebar.tsx` renders a platform-appropriate custom titlebar (traffic-light dots on macOS, minimize/close buttons top-right on Windows). The titlebar region uses `data-tauri-drag-region` for window dragging; buttons override the drag region with `pointer-events: auto`.
- `App.tsx` is updated to include `<Titlebar />` above the existing layout and shift body content down by the titlebar height.
- New Rust module `gui/src-tauri/src/tray.rs` initialises a `TrayIconBuilder` with a menu (Open, separator, Start All Agents, Stop All Agents, separator, Quit) and wires event handlers for left-click / double-click / right-click per platform convention.
- New Tauri commands `tray_start_all_agents` and `tray_stop_all_agents` in `commands.rs`, called by the tray menu and emitting notification-style events back to the frontend.
- `lib.rs` is updated to call `tray::init(&app)` in the `setup` closure and register the two new commands. `CloseRequested` is intercepted via `on_window_event` to `prevent_close()` + hide the window instead of quitting.
- macOS `Reopen` app event (dock icon click while window is hidden) is handled to restore the window.
- The app no longer exits when the last window is closed; only the tray "Quit Claw Installer" menu item performs a clean exit.

## Capabilities

### New Capabilities

- `frameless-titlebar`: Custom platform-native titlebar UI (traffic-light on macOS, minimize/close on Windows) with drag region and keyboard accessibility. Green/maximize is explicitly absent.
- `close-to-tray`: Window close routes to hide-to-tray instead of quit. Tray icon present on both platforms with a contextual menu providing Open, Start All, Stop All, Quit actions.

### Modified Capabilities

None. No existing spec-level behavior contracts change — the install/start/stop agent flows are unchanged; the tray merely invokes existing code paths.

## Impact

**Files modified:**
- `gui/src-tauri/tauri.conf.json` — add `decorations: false` to the window config
- `gui/src-tauri/Cargo.toml` — add `tauri-plugin-notification = "2"` for system notifications
- `gui/src-tauri/src/lib.rs` — wire tray init, `CloseRequested` intercept, `Reopen` event
- `gui/src-tauri/src/commands.rs` — add `tray_start_all_agents`, `tray_stop_all_agents`
- `gui/src/App.tsx` — add `<Titlebar />`, adjust layout top padding
- `gui/src/styles/index.css` — add `.titlebar-*` utility classes and `app-region: drag` CSS

**Files created:**
- `gui/src-tauri/src/tray.rs` — Rust tray module
- `gui/src/components/installer/Titlebar.tsx` — React titlebar component

**Dependencies:**
- Tauri 2 core already contains `tauri::tray::TrayIconBuilder` (no extra crate needed for tray icon itself)
- `tauri-plugin-notification` (new) for success/failure system notifications from tray actions

**Risks:**
- macOS traffic-light positioning must account for the existing `macOSPrivateApi: true` config and the app's 320 px fixed width — no safe area inset conflicts expected but needs verification on macOS 14+
- Windows has subtle differences in how `prevent_close` interacts with Alt+F4 — must be tested
- System notifications require `NSUserNotificationUsageDescription` in Info.plist on macOS (handled by `tauri-plugin-notification` capability config)
