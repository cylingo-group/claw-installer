## Context

Claw Installer is a fixed-size (320 × 720 px) Tauri 2 desktop app targeting macOS and Windows. It currently uses the OS-native window chrome (`decorations: true`, the default). The Rust backend lives in `gui/src-tauri/src/lib.rs` and `commands.rs`; the React frontend uses zustand at `gui/src/store/installer-store.ts`.

The two features — frameless titlebar and close-to-tray — must be designed together because both require intercepting the window close event in Rust before it reaches the OS. If we only intercept for tray-hiding but leave native chrome, the user sees a double titlebar. If we draw a custom titlebar but do not redirect close to tray, we lose the background-agent value.

Tauri 2 tray support is built into the `tauri` core crate (`tauri::tray::TrayIconBuilder`, `tauri::menu::{Menu, MenuItem, PredefinedMenuItem}`); no separate `tauri-plugin-tray` crate is needed. System notifications for tray-action feedback use `tauri-plugin-notification`.

## Goals / Non-Goals

**Goals:**
- Remove OS window chrome; show a hand-crafted titlebar that matches platform conventions.
- Window close button routes to hide-to-tray on both macOS and Windows. No user prompt.
- Tray icon and menu present on both platforms with Open, Start All, Stop All, Quit items.
- "Start All / Stop All" in the tray invokes the same Rust `run_service_action` code paths as the GUI buttons, scoped to installed agents (skipping not-installed ones).
- App process stays alive when last window closes; only tray "Quit" truly exits.
- macOS dock icon remains visible when window is hidden (no LSUIElement).

**Non-Goals:**
- No maximize button anywhere (window is fixed 320 × 720 with `resizable: false`, `maximizable: false` already in `tauri.conf.json`).
- No "first-time" prompt before hiding to tray — behavior is fixed.
- No tray badge or dynamic icon changes.
- No multi-window management; there is exactly one webview window labelled `"main"`.
- No Windows taskbar grouping changes.

## Decisions

### D1: Tray icon in Rust `setup` closure, not a plugin

**Decision**: Initialize the tray in `lib.rs`'s `.setup(|app| { tray::init(app)?; Ok(()) })` rather than as a Tauri plugin.

**Rationale**: The tray state is app-wide and needs the `AppHandle` to send events and show/hide the window. A standalone function `tray::init(app: &AppHandle) -> tauri::Result<()>` is simpler than a full plugin struct, keeps the module count low, and matches how `login_env::prime()` is already called.

**Alternative considered**: A `tauri::plugin::Builder` plugin. Rejected — adds boilerplate with no benefit for a single-app feature.

---

### D2: `CloseRequested` interception in `on_window_event` builder hook

**Decision**: Use `.on_window_event(|window, event| { ... })` on the `tauri::Builder` chain to catch `WindowEvent::CloseRequested` and call `event.prevent_default()` + `window.hide()`.

**Rationale**: Tauri 2 exposes `on_window_event` as a builder method; it receives every window event before the OS acts on it. `prevent_default()` on `CloseRequested` stops the OS from destroying the window. This is the correct Tauri 2 API (distinct from Tauri 1's `system_tray.on_event`).

**Alternative considered**: Listening for the `tauri://close-requested` JavaScript event in the frontend and calling `appWindow.hide()`. Rejected — the JS event fires after Tauri propagates the event internally and has a race with the `preventDefault` that must happen synchronously on the Rust side.

**Alt+F4 (Windows)**: `CloseRequested` is also triggered by Alt+F4 on Windows. The intercept applies uniformly — Alt+F4 also routes to tray. This is the correct behavior (same as Discord, Slack, etc.).

---

### D3: macOS `Reopen` handled via `RunEvent::Reopen`

**Decision**: In the `tauri::Builder::build()?.run(|app, event| { ... })` callback, match `RunEvent::Reopen { has_visible_windows, .. }` and show/focus the main window when `has_visible_windows` is false.

**Rationale**: This is the standard macOS app-delegate `applicationShouldHandleReopen` hook, surfaced in Tauri 2 as `RunEvent::Reopen`. It fires when the user clicks the dock icon of an app that has no visible windows.

---

### D4: Tray double-click opens window; left-click shows menu (macOS)

**Decision**: On macOS, configure `show_menu_on_left_click(true)` so the menu appears on left-click. Bind a `TrayIconEvent::DoubleClick` branch in `on_tray_icon_event` to show/focus the window.

**Rationale**: The user requested "双击打开应用" explicitly. macOS conventions for menubar-style apps use left-click for the menu. Combining both is achievable because `TrayIconEvent` exposes distinct `Click` and `DoubleClick` variants. The menu's "Open Claw Installer" item provides a single-click path for discoverability.

On Windows, double-click is the primary open gesture (native convention); right-click shows the menu. We configure `show_menu_on_left_click(false)` on Windows and rely on `TrayIconEvent::DoubleClick` for window show.

---

### D5: Tray "Start All / Stop All" runs Rust directly, not via IPC to frontend

**Decision**: `tray_start_all_agents` and `tray_stop_all_agents` are Tauri commands that call a shared helper `run_service_action_for_all_installed(app, action)`. This reads the manifest file directly (reusing `manifest_path()` + `parse_manifest()` already in `commands.rs`) to determine which agents are installed, then loops `build_service_command` for each, spawning processes. Results are communicated back as system notifications via `tauri-plugin-notification`.

**Rationale**: The tray fires from a native OS context with no guarantee the webview is focused or even rendered. Routing through the frontend store (emit event → JS handles it → calls Tauri IPC) would be fragile if the webview is not loaded. Direct Rust execution is more reliable and keeps the webview optional.

**Alternative considered**: Emit a `tray://start-all` event to the frontend and let the store's `startService` action handle it. Rejected because the frontend may not be loaded (window hidden) and because it adds cross-layer coupling.

---

### D6: Platform-native titlebar via CSS `app-region` + `data-tauri-drag-region`

**Decision**: The `Titlebar` React component sets `data-tauri-drag-region` on the bar root element. Button elements inside use `pointer-events: auto` (via Tailwind utility or inline style) to escape the drag capture. On macOS the traffic-light cluster sits at left; on Windows the minimize/close cluster sits at right.

Platform detection in React uses `navigator.userAgent` with a `isMac` boolean derived from `navigator.platform` (or `navigator.userAgentData?.platform` when available). This affects layout only — the Tauri `window.minimize()` / `window.hide()` calls are the same on both platforms.

**Rationale**: `data-tauri-drag-region` is the Tauri 2 documented approach. CSS `app-region: drag` is the underlying WKWebView/WebView2 mechanism it injects. Interactive children need `app-region: no-drag` or equivalently must rely on Tauri's pointer-event passthrough.

---

### D7: No tauri-plugin-tray — tray is built into Tauri 2 core

**Decision**: Add no additional crate for tray support. `tauri::tray::TrayIconBuilder` and `tauri::menu::*` are available in `tauri = { version = "2", ... }` as already declared in `Cargo.toml`.

**Rationale**: Tauri 2 merged the tray API into the core crate. The `tauri-plugin-tray` crate existed only in early v2 alpha builds; current stable v2 users use `tauri::tray` directly.

---

### D8: Tray icon asset

**Decision**: Use the existing bundled icon at `gui/src-tauri/icons/icon.icns` (macOS) and `icons/icon.ico` (Windows), passed to `TrayIconBuilder::new().icon(app.default_window_icon().unwrap().clone())`.

**Rationale**: `app.default_window_icon()` returns the platform-appropriate icon Tauri already bundled, avoiding duplication of icon assets.

---

### D9: `tauri-plugin-notification` for tray action feedback

**Decision**: Add `tauri-plugin-notification = "2"` to `Cargo.toml` and use it to surface success/failure after tray "Start All" / "Stop All" runs.

**Rationale**: System notifications are non-blocking and the appropriate UX when the window may be hidden. A Tauri `emit` to the frontend would require the webview to be visible and would not surface when window is hidden.

**Capability file**: `tauri-plugin-notification` requires `"notification:default"` in `capabilities/default.json`. The developer must create this capability file (or append to the existing one) and add `NSUserNotificationUsageDescription` to the macOS `Info.plist` via `tauri.conf.json`'s `bundle.macOS.infoPlist` key.

---

### D10: Window config changes in `tauri.conf.json`

Set `"decorations": false` on the existing window object. The window is already `"resizable": false` and `"maximizable": false`, so there is no risk of enabling window resize via the custom titlebar (there are no resize handles to worry about).

**macOS vibrancy / transparency**: Not introduced. The window background remains the app's `--ued-surface` color (a solid dark tone from the theme). Adding vibrancy would require `"transparent": true` and significant CSS changes — out of scope.

## Risks / Trade-offs

**[Risk] macOS traffic-light overlaps content** → The app is 320 px wide. The titlebar will be ~32 px tall and the traffic-light cluster occupies ~56 px from the left. The existing `Sidebar` header area has `pt-5` padding. After adding the titlebar, the sidebar content will be shifted down by 32 px. This is small but must be verified not to clip the logo or agent list in the 720 px height.

**[Risk] Windows `prevent_close` + ALT+F4** → Verified as intended: ALT+F4 will hide to tray rather than quit. This is consistent with what users expect from apps with tray icons (Teams, Discord). The tray Quit item is always available for true exit.

**[Risk] `tauri-plugin-notification` macOS entitlement** → On macOS, sending notifications from a non-sandboxed Tauri app typically works without explicit entitlements. However, if the app is code-signed and distributed via a notarization flow, `com.apple.security.network.client` must be present. Notification permissions still require the user to grant them on first use. Mitigation: the tray action falls back gracefully if notification permission is denied (no crash, just no toast).

**[Risk] Icon reuse for tray on Windows** → `app.default_window_icon()` on Windows returns an RGBA bitmap from the `.ico` bundle. WinAPI tray icons have a 32×32 or 16×16 size limit. Tauri handles the downsampling internally. No separate tray-sized icon is needed.

**[Risk] Rust module split** → Adding `tray.rs` means `lib.rs` must declare `mod tray;`. This is straightforward but the developer must ensure `tray.rs` does not create a circular dependency with `commands.rs`. The solution is that `tray.rs` calls the public `commands::AppState` type and the standalone helpers (`manifest_path`, `parse_manifest`, `build_service_command`) — these are `pub(crate)` visibility in `commands.rs`.

## Migration Plan

1. Land the `tauri.conf.json` change and `Titlebar.tsx` together — without both, the user sees a blank area or double chrome.
2. Land the Rust `tray.rs` and `lib.rs` changes together — the `CloseRequested` intercept must coexist with the tray icon (otherwise the window hides but cannot be reopened).
3. No database migration, no user data change, no breaking API change.
4. Rollback: revert `tauri.conf.json` (`"decorations": true`) and remove `tray.rs` + the `on_window_event` hook in `lib.rs`.

## Open Questions

None blocking design. The following are noted for the developer agent:

- **OQ1**: Should the macOS titlebar respect `env::consts::OS` at compile time (`#[cfg(target_os = "macos")]`) or use JS `navigator.platform` at runtime? Given the same binary runs only on one OS, either works. Recommended: use JS runtime detection in React so the component file is platform-agnostic and easier to test in browser dev mode.
- **OQ2**: Should the Titlebar title text show "Claw Installer" or remain empty? The existing Sidebar already shows the product name + version. Recommended: no title text in the titlebar — keep it minimal (buttons only).
