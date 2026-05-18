# gui

Tauri-based front-end for the claw-installer. Drives `../installer/` by
exporting `INSTALLER_*` env vars and spawning the platform-appropriate
entry point:

- macOS / Linux → `../installer/install.sh`
- Windows       → `../installer/windows/bootstrap.ps1`

The GUI does not read or write the install manifest directly — `uninstall.sh`
owns that.
