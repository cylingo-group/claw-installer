# Change: claw-installer-gui-v1

| Field | Value |
|---|---|
| Status | Draft |
| Type | Feature |
| Scope | `gui/` (new), `installer/windows/bootstrap.ps1` (edit) |
| Stack | Tauri 2.0, React 19, TypeScript, Tailwind v4, Zustand, shadcn/ui, pnpm |

## Summary

Desktop installer GUI for non-technical users. One-click install of OpenClaw and Hermes agents with a translated progress bar, no raw log output. Ports the locked v2 prototype to a Tauri 2.0 shell with a Rust backend that wraps existing shell installers.

## Artifacts

- [Proposal](./proposal.md) — problem statement, solution design, all deliverable specs, AC, risks
- [Tasks](./tasks.md) — ordered implementation breakdown (6 phases, ~20 tasks)

## Top Risks

1. **Manifest format drift** (G2): Rust parser binds to TSV column indices. If `manifest.sh` adds a column, install-state reads silently break. Mitigation: `splitn` assertion + follow-up schema version header.
2. **Windows manifest path** (OQ-3): On Windows the manifest lives inside WSL. Proposed solution (`wsl.exe cat`) must be validated in the dev loop before T4.3 ships; UNC path approach is the fallback.
3. **`bootstrap.ps1 -Preflight` dependency** (G5): `read_host_status` Rust command calls a PS switch that does not yet exist. The script change (T1.1) must ship in the same PR as the Rust command (T4.4); the developer agent must not merge them out of order.
