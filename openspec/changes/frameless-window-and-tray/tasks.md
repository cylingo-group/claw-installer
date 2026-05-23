## 1. Rust — Configuration and Dependencies

- [x] 1.1 In `gui/src-tauri/tauri.conf.json`, add `"decorations": false` to the window object inside `app.windows[0]`
- [x] 1.2 In `gui/src-tauri/Cargo.toml`, add `tauri-plugin-notification = "2"` to `[dependencies]`
- [x] 1.3 In `gui/src-tauri/src/lib.rs`, add `mod tray;` at the top alongside the existing `mod commands;` declarations
- [x] 1.4 In `lib.rs`, add `.plugin(tauri_plugin_notification::init())` to the `tauri::Builder` chain

## 2. Rust — Make `commands.rs` Helpers Accessible to `tray.rs`

- [x] 2.1 In `commands.rs`, change `fn manifest_path` to `pub(crate) fn manifest_path` (non-Windows builds only; gate with `#[cfg(not(target_os = "windows"))]` as it already is)
- [x] 2.2 In `commands.rs`, change `fn build_service_command` to `pub(crate) fn build_service_command`
- [x] 2.3 In `commands.rs`, confirm `parse_manifest` is accessible from `tray.rs` via `crate::manifest::parse_manifest` (it already is — verify no re-export needed)
- [x] 2.4 In `commands.rs`, confirm `resolve_installer_dir` is `pub(crate)` (or change it) so tray can call `check_resources` if needed

## 3. Rust — Create `tray.rs` Module

- [x] 3.1 Create `gui/src-tauri/src/tray.rs` with a `pub fn init(app: &tauri::AppHandle) -> tauri::Result<()>` function
- [x] 3.2 Inside `tray::init`: build the tray menu using `tauri::menu::{Menu, MenuItem, PredefinedMenuItem}` with items: "Open Claw Installer", separator, "Start All Agents", "Stop All Agents", separator, "Quit Claw Installer"
- [x] 3.3 Inside `tray::init`: call `TrayIconBuilder::new().icon(app.default_window_icon().unwrap().clone()).menu(&menu).show_menu_on_left_click(cfg!(target_os = "macos")).build(app)?`
- [x] 3.4 Wire `on_menu_event` on the builder: match `"open"` → show/focus main window; match `"start-all"` → call `tray_start_all_agents_inner(app)`; match `"stop-all"` → call `tray_stop_all_agents_inner(app)`; match `"quit"` → `app.exit(0)`
- [x] 3.5 Wire `on_tray_icon_event` on the builder: match `TrayIconEvent::DoubleClick { .. }` → show/focus main window on both platforms; on macOS left-click is already handled by `show_menu_on_left_click`
- [x] 3.6 Implement `fn tray_start_all_agents_inner(app: &AppHandle)` in `tray.rs`: read manifest, collect installed agents, loop `build_service_command(app, agent, "start")`, send system notification on completion
- [x] 3.7 Implement `fn tray_stop_all_agents_inner(app: &AppHandle)` in `tray.rs`: same pattern as 3.6 but with `"stop"` action
- [x] 3.8 Use `tauri_plugin_notification::NotificationExt` to emit success/failure system notifications in 3.6 and 3.7

## 4. Rust — Wire Lifecycle Events in `lib.rs`

- [x] 4.1 In `lib.rs`, add a `.setup(|app| { tray::init(app.handle())?; Ok(()) })` call on the builder chain before `.invoke_handler`
- [x] 4.2 In `lib.rs`, add `.on_window_event(|window, event| { if let tauri::WindowEvent::CloseRequested { api, .. } = event { api.prevent_default(); let _ = window.hide(); } })` to the builder chain
- [x] 4.3 Change `.run(tauri::generate_context!()).expect(...)` to capture the app with `.build(tauri::generate_context!()).expect(...).run(|app, event| { ... })` to handle `RunEvent::Reopen`
- [x] 4.4 Inside the `run` callback: match `RunEvent::Reopen { has_visible_windows, .. }` where `has_visible_windows` is false → get the `"main"` webview window, call `show()` and `set_focus()`
- [x] 4.5 Add `tray_start_all_agents` and `tray_stop_all_agents` to the `tauri::generate_handler![...]` macro in `invoke_handler` (these will be thin wrappers in `commands.rs` that call `tray::tray_start_all_agents_inner` / `tray::tray_stop_all_agents_inner` — or implement them directly as `#[tauri::command]` in `tray.rs` and register from there)

## 5. Rust — Capability Config for Notifications

- [x] 5.1 Locate or create `gui/src-tauri/capabilities/default.json` and add `"notification:default"` to the `permissions` array
- [x] 5.2 If `NSUserNotificationUsageDescription` is not present in `tauri.conf.json`'s `bundle.macOS.infoPlist`, add `"NSUserNotificationUsageDescription": "Claw Installer uses notifications to report agent start/stop status."` there

## 6. Frontend — Titlebar React Component

- [x] 6.1 Create `gui/src/components/installer/Titlebar.tsx` with a `Titlebar` React component that:
  - Derives `isMac` via `navigator.platform.startsWith("Mac")` (with fallback to `navigator.userAgentData?.platform`)
  - Renders the macOS traffic-light layout when `isMac` is true, the Windows layout otherwise
- [x] 6.2 Implement macOS traffic-light JSX: three `<button>` elements (12 × 12 px circles, left-aligned), red/yellow/green colored, with `aria-label` values ("关闭", "最小化", "最大化（不可用）")
- [x] 6.3 Implement macOS traffic-light hover state: CSS group-hover (Tailwind `group`/`group-hover`) or React state to show `×`, `−`, `+` glyphs on hover; green `+` glyph at `opacity-30`
- [x] 6.4 Implement macOS button handlers: red → `import { getCurrentWindow } from '@tauri-apps/api/window'; getCurrentWindow().hide()`; yellow → `getCurrentWindow().minimize()`; green → no-op
- [x] 6.5 Implement Windows layout JSX: two `<button>` elements (40 × 32 px) right-aligned — minimize (`−`) and close (`×`) — with hover state classes
- [x] 6.6 Implement Windows close button red-on-hover using Tailwind `hover:bg-[#E81123] hover:text-white` (or equivalent CSS variable approach)
- [x] 6.7 Implement Windows button handlers: minimize → `getCurrentWindow().minimize()`; close → `getCurrentWindow().hide()`
- [x] 6.8 Set `data-tauri-drag-region` attribute on the outer `<div>` of `Titlebar`; ensure buttons have `style={{ pointerEvents: 'auto' }}` or `class="pointer-events-auto"` to escape the drag region
- [x] 6.9 Guard all `@tauri-apps/api/window` calls with `IS_TAURI_ENV` (imported from `installer-store`) so the component renders safely in browser dev mode without throwing

## 7. Frontend — Integrate Titlebar into App

- [x] 7.1 In `gui/src/App.tsx`, import `Titlebar` and render it as the first child of the outermost `<div>`, before `<Sidebar />`
- [x] 7.2 Change the outermost `<div>` to `flex-col` layout (it is currently `flex` horizontally) or wrap: the `Titlebar` spans full width at top; below it the existing horizontal flex row (`<Sidebar />` + panels) fills the remaining height via `flex-1`
- [x] 7.3 In `gui/src/styles/index.css`, add CSS for `[data-tauri-drag-region] { -webkit-app-region: drag; app-region: drag; }` and `button, a, [data-tauri-no-drag] { -webkit-app-region: no-drag; app-region: no-drag; }` in the `@layer base` block to prevent drag capture on all interactive elements

## 8. Verification — macOS Manual Checks

- [x] 8.1 Launch app on macOS: confirm no native traffic-light buttons, no native titlebar; custom traffic-light dots visible top-left
- [x] 8.2 Hover over traffic-light group: glyphs (×, −, +) appear on all three dots simultaneously
- [x] 8.3 Click red dot: window hides; tray icon remains in menu bar
- [x] 8.4 Click yellow dot: window minimizes to Dock
- [x] 8.5 Click green dot: nothing happens (no resize, no maximize)
- [x] 8.6 Click-drag titlebar background: window moves freely
- [x] 8.7 Click tray icon (left-click): menu appears with all six items
- [x] 8.8 Double-click tray icon: window shows and gains focus
- [x] 8.9 Click "Open Claw Installer" in menu: window shows
- [x] 8.10 With window hidden, click Dock icon: window restores
- [x] 8.11 Click "Start All Agents": system notification appears; installed agents start
- [x] 8.12 Click "Stop All Agents": system notification appears; installed agents stop
- [x] 8.13 Click "Quit Claw Installer": process exits, tray icon disappears
- [x] 8.14 Press Cmd+W (if bound): window hides to tray (does not quit) — fix: lib.rs::install_macos_menu installs a custom "Close Window" MenuItem (id="hide-window") bound to Cmd+W; on_menu_event matches that id and calls window.hide() directly, bypassing the PredefinedMenuItem::close_window path that was unreliable for frameless+transparent windows.

## 9. Verification — Windows Manual Checks

- [ ] 9.1 Launch app on Windows: confirm no native caption buttons; custom `−` and `×` buttons visible top-right
- [ ] 9.2 Hover over `−` button: subtle background fill appears
- [ ] 9.3 Hover over `×` button: red background (#E81123) and white glyph appear
- [ ] 9.4 Click `−` button: window minimizes to taskbar
- [ ] 9.5 Click `×` button: window hides; tray icon remains in notification area
- [ ] 9.6 Press Alt+F4: window hides (does not quit)
- [ ] 9.7 Click-drag titlebar background: window moves
- [ ] 9.8 Right-click tray icon: menu appears with all six items
- [ ] 9.9 Double-click tray icon: window shows and gains focus
- [ ] 9.10 Click "Open Claw Installer": window shows
- [ ] 9.11 Click "Start All Agents" with agents installed: notification confirms start
- [ ] 9.12 Click "Quit Claw Installer": process exits, tray icon disappears
