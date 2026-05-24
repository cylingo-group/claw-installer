/**
 * src/api/installer.ts — Tauri IPC wrapper.
 *
 * This is the ONLY module that touches Tauri's invoke/Channel APIs.
 * Never import this module directly in store actions — the store uses
 * dynamic imports gated on IS_TAURI_ENV so this module is never loaded
 * in browser/stub mode.
 */
import { invoke, Channel } from "@tauri-apps/api/core";
import type {
  AgentConfig,
  AgentId,
  InstallerEvent,
} from "@/store/installer-store";

/**
 * Persisted shape mirrored to ~/.claw-installer/config.json (resp.
 * %APPDATA%\claw-installer\config.json on Windows) so the GUI's "已配置" /
 * "已配对" badges + input fields survive across restarts. Owned by the TS
 * side; Rust treats the payload as opaque JSON.
 *
 * v1 (legacy): `agents.<id>` held a bare ModelConfig — read by
 * hydrateAgentConfig's legacy branch.
 * v2 (current): `agents.<id>` holds the full AgentConfig (model + channel +
 * bubbolinkPairedAt).
 */
export interface ModelConfigSnapshot {
  version: 2;
  agents: Partial<Record<AgentId, AgentConfig>>;
}

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

/** Open a URL in the user's default browser. */
export async function openExternalUrl(url: string): Promise<void> {
  const { openUrl } = await import("@tauri-apps/plugin-opener");
  await openUrl(url);
}

/**
 * Write an OpenClaw config patch via `openclaw config patch --file` followed
 * by `openclaw config validate`. `replacePaths` opts into replacing the
 * specific protected paths (e.g. a provider's `models` array when creating
 * a custom provider). Throws with the CLI's stderr on failure.
 */
export async function applyOpenclawModelConfig(
  patchJson: string,
  replacePaths: string[],
): Promise<void> {
  return invoke("apply_openclaw_model_config", { patchJson, replacePaths });
}

/**
 * Apply a Hermes model selection via `hermes config set` and update
 * `~/.hermes/.env` with the API key. Throws with CLI / file-IO errors.
 */
export async function applyHermesModelConfig(params: {
  provider: string;
  defaultModel: string;
  baseUrl: string;
  envVarName: string;
  apiKey: string;
}): Promise<void> {
  return invoke("apply_hermes_model_config", params);
}

/** Read the GUI's persisted ModelConfig snapshot, or null if the file
 *  doesn't exist yet (first launch). */
export async function readModelConfigs(): Promise<ModelConfigSnapshot | null> {
  return invoke<ModelConfigSnapshot | null>("read_model_configs");
}

/**
 * Mirror a frontend log line into the persistent tauri log file (alongside
 * Rust-side log_info!/log_error! output). Use for timing/diagnostic lines
 * that need to survive past the devtools session. Fire-and-forget; failures
 * are swallowed so a broken IPC never derails the calling flow.
 */
export function frontendLog(
  level: "info" | "warn" | "error",
  module: string,
  message: string,
): void {
  if (!IS_TAURI_ENV_LOCAL) return;
  void invoke("frontend_log", { level, module, message }).catch(() => {});
}

// Local IS_TAURI_ENV check to avoid a circular import with the store module
// (which is where IS_TAURI_ENV is canonically defined).
const IS_TAURI_ENV_LOCAL =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

/** Persist the GUI's current ModelConfig per agent. Called after every
 *  successful Save in SettingsPanel. */
export async function writeModelConfigs(
  payload: ModelConfigSnapshot,
): Promise<void> {
  return invoke("write_model_configs", { payload });
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
 * Resolve and open the dashboard URL for `agentId` in the system browser.
 * URL is derived in Rust via the agent's CLI (or its config file as fallback).
 */
export async function openAgentDashboard(agentId: string): Promise<void> {
  return invoke("open_agent_dashboard", { agentId });
}

/**
 * Run `bubbolink pair <code>` so the local BubboLink CLI binds the relay
 * account that produced `code` to **every** installed runtime on this host
 * (openclaw / hermes / claude / codex). `--runtime` is omitted on purpose —
 * the CLI defaults to `all`, so pairing from either agent's settings panel
 * has the same host-wide effect.
 *
 * `agentId` is still required: dispatch_op routes the call through that
 * agent's shell op script (for PATH composition), but the choice doesn't
 * change which runtimes get paired. Throws with stderr on non-zero exit.
 */
export async function pairBubbolink(
  code: string,
  agentId: AgentId,
): Promise<void> {
  return invoke("pair_bubbolink", { code, agentId });
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
