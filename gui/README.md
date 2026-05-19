# gui

Tauri-based front-end for the claw-installer. Drives `../shell/` by exporting
`INSTALLER_*` env vars and spawning the platform-appropriate entry point:

- macOS / Linux → `../shell/install.sh` (multi-agent),
  `../shell/agents/<agent>/{install,start,stop,restart,uninstall}.sh` (single agent)
- Windows       → `../shell/windows/bootstrap.ps1`

The GUI does not read or write the install manifest directly — `uninstall.sh`
owns that.
