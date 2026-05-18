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

export async function runUninstaller(
  agent: string,
  onEvent: (e: InstallerEvent) => void
): Promise<void> {
  const ch = new Channel<InstallerEvent>();
  ch.onmessage = onEvent;
  return invoke("run_uninstaller", { agent, onEvent: ch });
}
