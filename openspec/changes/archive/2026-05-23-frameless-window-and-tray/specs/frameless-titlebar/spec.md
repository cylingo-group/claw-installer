## ADDED Requirements

### Requirement: Frameless window configuration
The app window SHALL have native OS decorations disabled (`decorations: false` in `tauri.conf.json`). No native titlebar, no native close/minimize/maximize buttons, and no system-drawn window border SHALL appear.

#### Scenario: No double titlebar on macOS
- **WHEN** the app launches on macOS
- **THEN** only the custom React titlebar is visible at the top of the window, with no native macOS traffic-light buttons above it

#### Scenario: No double titlebar on Windows
- **WHEN** the app launches on Windows
- **THEN** only the custom React titlebar strip is visible at the top of the window, with no native Windows caption buttons above it

---

### Requirement: Custom titlebar component
The app SHALL render a `Titlebar` React component (`gui/src/components/installer/Titlebar.tsx`) as the topmost element inside `App.tsx`, spanning the full window width with a fixed height of 32 px.

#### Scenario: Titlebar is always visible
- **WHEN** any view or panel is open (settings, uninstall dialog, etc.)
- **THEN** the titlebar remains visible and accessible above all other content

#### Scenario: Body content does not overlap titlebar
- **WHEN** the app renders
- **THEN** the main content area begins below the 32 px titlebar with no visual overlap

---

### Requirement: macOS traffic-light style buttons
On macOS, the titlebar SHALL display three circular buttons (12 px diameter, 8 px gap) in the top-left region, horizontally positioned starting at 12 px from the left edge, vertically centered in the 32 px titlebar.

- The red button (leftmost) triggers window hide-to-tray (close).
- The yellow button (middle) triggers window minimize.
- The green button (rightmost) is rendered but visually dimmed/disabled and produces no action on click (maximize is not supported).

Default state: solid colored circles — red `#FF5F57`, yellow `#FEBC2E`, green `#28C840` — with no glyph.

On hover of the traffic-light group (any of the three buttons hovered): the red button shows a `×` glyph, the yellow button shows a `−` glyph, the green button shows a `+` glyph at reduced opacity to indicate it is disabled.

#### Scenario: macOS red button hides to tray
- **WHEN** the user clicks the red traffic-light button on macOS
- **THEN** the window is hidden (not closed/destroyed) and the system tray icon remains present

#### Scenario: macOS yellow button minimizes
- **WHEN** the user clicks the yellow traffic-light button on macOS
- **THEN** `appWindow.minimize()` is called and the window minimizes to the Dock

#### Scenario: macOS green button is inert
- **WHEN** the user clicks the green traffic-light button on macOS
- **THEN** nothing happens (no maximize, no window resize)

#### Scenario: macOS traffic-light hover reveals glyphs
- **WHEN** the user hovers over the traffic-light button group on macOS
- **THEN** all three buttons show their respective glyphs (×, −, +) simultaneously

#### Scenario: macOS traffic-light buttons are keyboard focusable
- **WHEN** the user presses Tab to navigate to a traffic-light button
- **THEN** the button receives focus with a visible focus ring and can be activated via Space/Enter

---

### Requirement: Windows minimize and close buttons
On Windows, the titlebar SHALL display two icon buttons in the top-right region: a minimize button (`−`) and a close button (`×`), each 40 px wide and 32 px tall (matching Windows 11 Snap Layout button sizing).

- The minimize button calls `appWindow.minimize()`.
- The close button triggers window hide-to-tray.
- There is no maximize button.

Hover states:
- Minimize button: subtle background fill on hover (e.g., `rgba(255,255,255,0.08)`).
- Close button: red background fill on hover (`#E81123`, white glyph), matching Windows 11 convention.

#### Scenario: Windows minimize button minimizes
- **WHEN** the user clicks the minimize button on Windows
- **THEN** `appWindow.minimize()` is called and the window minimizes to the taskbar

#### Scenario: Windows close button hides to tray
- **WHEN** the user clicks the close button on Windows
- **THEN** the window is hidden (not closed/destroyed) and the system tray icon remains in the notification area

#### Scenario: Windows close button hover turns red
- **WHEN** the user hovers over the Windows close button
- **THEN** the button background changes to red (`#E81123`) and the glyph turns white

#### Scenario: Windows titlebar buttons are keyboard focusable
- **WHEN** the user presses Tab to navigate to a titlebar button on Windows
- **THEN** the button receives focus with a visible focus ring and can be activated via Space/Enter

---

### Requirement: Draggable titlebar region
The titlebar element SHALL carry `data-tauri-drag-region`, making the entire bar a window-drag handle. Interactive controls (buttons) within the titlebar SHALL override the drag region so they receive pointer events normally.

#### Scenario: Window drags from titlebar
- **WHEN** the user click-drags on the titlebar background (not on any button)
- **THEN** the window moves with the cursor

#### Scenario: Buttons are clickable inside drag region
- **WHEN** the user clicks a titlebar button (minimize, close, traffic-light)
- **THEN** the button click fires normally and the window does not start dragging

---

### Requirement: Platform detection for titlebar layout
The `Titlebar` component SHALL detect the host platform at runtime using `navigator.platform` (falling back to `navigator.userAgentData?.platform` when available) and render the macOS layout on `"Mac"` platforms and the Windows layout on all other platforms.

#### Scenario: macOS layout on macOS
- **WHEN** the app runs on macOS
- **THEN** the traffic-light buttons appear at top-left

#### Scenario: Windows layout on Windows
- **WHEN** the app runs on Windows
- **THEN** the minimize/close buttons appear at top-right
