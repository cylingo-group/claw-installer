/**
 * src/api/installer.ts — Tauri IPC wrapper.
 *
 * This is the ONLY module that touches Tauri's invoke/Channel APIs.
 * Never import this module directly in store actions — the store uses
 * dynamic imports gated on IS_TAURI_ENV so this module is never loaded
 * in browser/stub mode.
 */
import { invoke, Channel } from "@tauri-apps/api/core";
import type { InstallerEvent } from "@/store/installer-store";

export interface InstallerStatePayload {
  openclaw: "installed" | "not-installed";
  hermes: "installed" | "not-installed";
}

export interface HostStatusPayload {
  status: "ok" | "needs-wsl-install" | "needs-ubuntu-firstrun";
  command?: string;
}

export async function readInstallerState(): Promise<InstallerStatePayload> {
  return invoke<InstallerStatePayload>("read_installer_state");
}

export async function readHostStatus(): Promise<HostStatusPayload> {
  return invoke<HostStatusPayload>("read_host_status");
}

export async function runInstaller(
  agents: string[],
  env: Record<string, string>,
  onEvent: (e: InstallerEvent) => void
): Promise<void> {
  const ch = new Channel<InstallerEvent>();
  ch.onmessage = onEvent;
  return invoke("run_installer", { agents, env, onEvent: ch });
}

export async function cancelInstaller(): Promise<void> {
  return invoke("cancel_installer");
}

/** Copy plain text to the system clipboard via Tauri's clipboard plugin. */
export async function copyToClipboard(text: string): Promise<void> {
  const { writeText } = await import("@tauri-apps/plugin-clipboard-manager");
  await writeText(text);
}

/** Open a file or directory using the platform's default handler. */
export async function openPath(path: string): Promise<void> {
  const { openPath: open } = await import("@tauri-apps/plugin-opener");
  await open(path);
}

/** Reveal a file in Finder / Explorer / file manager (selects it). */
export async function revealInFolder(path: string): Promise<void> {
  const { revealItemInDir } = await import("@tauri-apps/plugin-opener");
  await revealItemInDir(path);
}

export async function runUninstaller(
  agent: string,
  onEvent: (e: InstallerEvent) => void
): Promise<void> {
  const ch = new Channel<InstallerEvent>();
  ch.onmessage = onEvent;
  return invoke("run_uninstaller", { agent, onEvent: ch });
}

/** Run an agent lifecycle action (start / stop) via shell. */
export async function runServiceAction(
  agent: string,
  action: "start" | "stop",
  onEvent: (e: InstallerEvent) => void
): Promise<void> {
  const ch = new Channel<InstallerEvent>();
  ch.onmessage = onEvent;
  return invoke("run_service_action", { agent, action, onEvent: ch });
}

/** Trigger an immediate system reboot (Windows only). Returns Err on non-Windows. */
export async function systemReboot(): Promise<void> {
  return invoke("system_reboot");
}

/**
 * Windows only: run bootstrap.ps1 -InstallWslOnly under UAC to provision WSL
 * features + the target distro. Streams the same InstallerEvent shape so the
 * @@reboot:<kind> sentinel surfaces as a RebootRequired event.
 */
export async function installWsl(
  onEvent: (e: InstallerEvent) => void
): Promise<void> {
  const ch = new Channel<InstallerEvent>();
  ch.onmessage = onEvent;
  return invoke("install_wsl", { onEvent: ch });
}
