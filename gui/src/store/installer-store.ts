import { create } from "zustand";

// ---- Detection ---------------------------------------------------------------
// True only when running inside a Tauri webview; false in plain browser.
export const IS_TAURI_ENV =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

// ---- Types -------------------------------------------------------------------
export type AgentId = "openclaw" | "hermes";

export type AgentStatus =
  | "not-installed"
  | "installing"
  | "uninstalling"
  | "ready"
  | "stopped"
  | "error";

export type HostStatus =
  | "detecting"
  | "ok"
  | "needs-wsl-install"
  | "needs-ubuntu-firstrun";

// ---- Agent config types -------------------------------------------------------

export type ModelProvider =
  | "xinyuan"
  | "deepseek"
  | "kimi"
  | "kimi-coding"
  | "minimax"
  | "custom";

/** Built-in providers that accept user-supplied API key + model name. */
export type KnownProvider = Exclude<ModelProvider, "xinyuan" | "custom">;

/** Providers that have user-editable credentials (excludes the coming-soon 心元). */
export type CredentialedProvider = Exclude<ModelProvider, "xinyuan">;

export type ChannelId = "wechat" | "feishu" | "dingtalk" | "bubbolink";

export type ApiStyle = "openai" | "anthropic";

export interface ProviderCredentials {
  apiKey: string;
  modelName: string;
  /** Epoch ms at which these credentials were last successfully written to
   *  the agent's CLI config. Cleared whenever the user edits a field — the
   *  "已配置" badge tracks this, not the locally-filled state. */
  savedAt: number | null;
}

export interface CustomCredentials extends ProviderCredentials {
  apiStyle: ApiStyle;
  name: string;
  baseUrl: string;
  /** Free-form `Key: Value` lines; optional. */
  headers: string;
}

/**
 * Per-provider credential storage plus the user's currently active selection.
 * Each known provider keeps its own apiKey/modelName so switching the active
 * one does not clobber what the user typed elsewhere. 心元 has no input fields
 * yet (it's a marketing placeholder for the new-user promo).
 */
export interface ModelConfig {
  active: ModelProvider;
  deepseek: ProviderCredentials;
  kimi: ProviderCredentials;
  "kimi-coding": ProviderCredentials;
  minimax: ProviderCredentials;
  custom: CustomCredentials;
}

export interface AgentConfig {
  model: ModelConfig;
  channel: ChannelId | null;
  /** Epoch ms of the last successful `bubbolink pair` for this agent. Drives
   *  the "已配对" badge on the BubboLink card. Persisted to
   *  ~/.claw-installer/config.json (resp. %APPDATA%\claw-installer\config.json
   *  on Windows) so the badge survives restarts. */
  bubbolinkPairedAt: number | null;
}

/**
 * Merge a possibly-stale persisted ModelConfig snapshot on top of the empty
 * defaults. Fields not present in the snapshot fall back to defaults — this
 * is what lets us evolve the schema (adding kimi-coding, for example) without
 * crashing on snapshots written by older versions.
 */
export function hydrateModelConfig(
  persisted: Partial<ModelConfig> | undefined | null,
): ModelConfig {
  const base = emptyModelConfig();
  if (!persisted) return base;
  const validActive: ModelProvider[] = [
    "xinyuan",
    "deepseek",
    "kimi",
    "kimi-coding",
    "minimax",
    "custom",
  ];
  return {
    active: validActive.includes(persisted.active as ModelProvider)
      ? (persisted.active as ModelProvider)
      : base.active,
    deepseek: { ...base.deepseek, ...(persisted.deepseek ?? {}) },
    kimi: { ...base.kimi, ...(persisted.kimi ?? {}) },
    "kimi-coding": {
      ...base["kimi-coding"],
      ...(persisted["kimi-coding"] ?? {}),
    },
    minimax: { ...base.minimax, ...(persisted.minimax ?? {}) },
    custom: { ...base.custom, ...(persisted.custom ?? {}) },
  };
}

/**
 * Merge a persisted AgentConfig snapshot on top of empty defaults. Tolerates
 * both the v1 shape (just a ModelConfig at the agent root) and the v2 shape
 * (full AgentConfig with channel + bubbolinkPairedAt). Unknown channel values
 * fall back to null.
 */
export function hydrateAgentConfig(
  persisted:
    | Partial<AgentConfig>
    | Partial<ModelConfig>
    | undefined
    | null,
): AgentConfig {
  if (!persisted) {
    return {
      model: emptyModelConfig(),
      channel: null,
      bubbolinkPairedAt: null,
    };
  }
  // v1 detection: legacy snapshots stored ModelConfig directly at the agent
  // root (no `model` key). Treat any object missing `model` as v1.
  const asAgent = persisted as Partial<AgentConfig>;
  const isLegacy = !("model" in (persisted as object));
  if (isLegacy) {
    return {
      model: hydrateModelConfig(persisted as Partial<ModelConfig>),
      channel: null,
      bubbolinkPairedAt: null,
    };
  }
  const validChannels: ChannelId[] = ["wechat", "feishu", "dingtalk", "bubbolink"];
  const channel =
    asAgent.channel && validChannels.includes(asAgent.channel)
      ? asAgent.channel
      : null;
  const pairedAt =
    typeof asAgent.bubbolinkPairedAt === "number"
      ? asAgent.bubbolinkPairedAt
      : null;
  return {
    model: hydrateModelConfig(asAgent.model),
    channel,
    bubbolinkPairedAt: pairedAt,
  };
}

export function emptyModelConfig(): ModelConfig {
  return {
    active: "xinyuan",
    deepseek: { apiKey: "", modelName: "", savedAt: null },
    kimi: { apiKey: "", modelName: "", savedAt: null },
    "kimi-coding": { apiKey: "", modelName: "kimi-for-coding", savedAt: null },
    minimax: { apiKey: "", modelName: "", savedAt: null },
    custom: {
      apiStyle: "openai",
      name: "",
      baseUrl: "",
      apiKey: "",
      modelName: "",
      headers: "",
      savedAt: null,
    },
  };
}

/** All required fields for a known provider are filled in the form. */
export function isProviderFilled(c: ProviderCredentials): boolean {
  return c.apiKey.trim() !== "" && c.modelName.trim() !== "";
}

/** All required fields for the custom provider are filled in the form. */
export function isCustomFilled(c: CustomCredentials): boolean {
  return (
    c.name.trim() !== "" &&
    c.baseUrl.trim() !== "" &&
    c.apiKey.trim() !== "" &&
    c.modelName.trim() !== ""
  );
}

/**
 * "已配置" = both filled AND committed (savedAt non-null and not invalidated
 * by a subsequent edit). Used to drive the "已配置" badge and the agent-card
 * configuration warning.
 */
export function isProviderConfigured(c: ProviderCredentials): boolean {
  return c.savedAt !== null && isProviderFilled(c);
}

export function isCustomConfigured(c: CustomCredentials): boolean {
  return c.savedAt !== null && isCustomFilled(c);
}

/**
 * The agent's *active* provider must be both filled AND committed.
 * 心元 has no setup flow yet so it never counts as configured.
 */
export function isModelConfigured(model: ModelConfig): boolean {
  switch (model.active) {
    case "xinyuan":
      return false;
    case "custom":
      return isCustomConfigured(model.custom);
    default:
      return isProviderConfigured(model[model.active]);
  }
}

export interface AgentState {
  id: AgentId;
  name: string;
  tagline: string;
  description: string;
  status: AgentStatus;
  version: string | null;
  installedAt: string | null;
  port?: number;
  /** Chinese-translated name of the active install step */
  currentStep: string | null;
  /** Short phrase describing what is happening */
  currentStepDetail: string | null;
  /** Epoch ms when `currentStep` started. Drives the live-elapsed
   *  display in LogStrip's header chip. Cleared (set to null) whenever
   *  currentStep transitions to null. */
  currentStepStartedAt: number | null;
  errorMessage?: string;
  config: AgentConfig;
}

/**
 * Where to fetch packages from. One selector drives every package manager
 * (npm, Homebrew, …) so users in China can swap one knob and have everything
 * route through a domestic mirror.
 */
// Internal name kept generic ("accelerated") because this knob now spans more
// than just one vendor's mirror — npm via npmmirror, Homebrew via aliyun, git
// via gitee. Surfaced to the user as "加速源".
export type MirrorSource = "official" | "accelerated";

export interface InstallerSettings {
  mirrorSource: MirrorSource;
  workspace: string;
  gatewayPort: number;
  gatewayBind: string;
  serviceMode: "daemon" | "foreground" | "skip";
  forceReinstall: boolean;
  skipBrowser: boolean;
}

/**
 * Mapping table — kept in one place so a Chinese mirror change in the wild
 * only touches this object. `null` means: leave that env var unset so the
 * underlying tool uses its own default (official endpoint).
 */
interface MirrorConfig {
  npmRegistry: string;
  brewGitRemote: string | null;
  brewCoreGitRemote: string | null;
  brewBottleDomain: string | null;
  brewApiDomain: string | null;
  /** Hermes repo clone URL (consumed by INSTALLER_HERMES_REPO_URL). */
  hermesRepoUrl: string;
  /** Hermes upstream installer script URL (consumed by INSTALLER_HERMES_INSTALL_URL). */
  hermesInstallUrl: string;
}

const MIRROR_TABLE: Record<MirrorSource, MirrorConfig> = {
  official: {
    npmRegistry: "https://registry.npmjs.org",
    brewGitRemote: null,
    brewCoreGitRemote: null,
    brewBottleDomain: null,
    brewApiDomain: null,
    hermesRepoUrl: "https://github.com/nousresearch/hermes-agent.git",
    hermesInstallUrl:
      "https://raw.githubusercontent.com/nousresearch/hermes-agent/main/scripts/install.sh",
  },
  accelerated: {
    // npmmirror.com is operated by the cnpm team (Alibaba-backed) and is
    // the de-facto Chinese npm registry endpoint.
    npmRegistry: "https://registry.npmmirror.com",
    brewGitRemote: "https://mirrors.aliyun.com/homebrew/brew.git",
    brewCoreGitRemote: "https://mirrors.aliyun.com/homebrew/homebrew-core.git",
    brewBottleDomain: "https://mirrors.aliyun.com/homebrew/homebrew-bottles",
    // Aliyun doesn't currently mirror the formulae.brew.sh JSON API.
    brewApiDomain: null,
    // Gitee mirror of the same project — matches the bash script's pre-existing
    // default, so users of the CLI flow keep working unchanged.
    hermesRepoUrl: "https://gitee.com/cylingo-group/hermes-agent.git",
    hermesInstallUrl:
      "https://gitee.com/cylingo-group/hermes-agent/raw/main/scripts/install.sh",
  },
};

export function resolveMirror(source: MirrorSource): MirrorConfig {
  return MIRROR_TABLE[source];
}

export function isAgentConfigured(agent: AgentState): boolean {
  const { model, channel } = agent.config;
  return channel !== null && isModelConfigured(model);
}

// InstallerEvent is sent over the Channel from the Rust backend.
export type InstallerEvent =
  | { type: "StepChanged"; key: string; label: string; detail: string }
  | { type: "StatusChanged"; agent: string; status: string; message: string | null }
  | { type: "Finished"; success: boolean; message: string | null }
  | { type: "LogLine"; line: string }
  | { type: "LogPath"; path: string }
  | { type: "RebootRequired"; kind: string };

interface State {
  agents: Record<AgentId, AgentState>;
  selectedAgent: AgentId;
  /** which agents are currently being processed */
  installQueue: AgentId[];
  /** rolling tail of user-friendly log lines (filtered subset, last ~50 kept) */
  logTail: string[];
  /** absolute path to the full execution log on disk for the current session */
  currentLogPath: string | null;
  /** whether the bottom log panel is expanded (the header bar is always visible) */
  logExpanded: boolean;
  settings: InstallerSettings;
  showAdvanced: boolean;
  settingsTarget: AgentId | null;
  /** App-level settings panel open state (mirror source, …). */
  appSettingsOpen: boolean;
  uninstallTarget: AgentId | null;
  /** Agent currently running a start/stop shell action (null if none). */
  serviceActionAgent: AgentId | null;
  /** Which action is in flight when serviceActionAgent is set. */
  serviceActionKind: "start" | "stop" | null;
  /** Agent whose Dashboard launch is in flight (null if none). */
  dashboardActionAgent: AgentId | null;
  installStartedAt: number | null;
  installEndedAt: number | null;
  hostStatus: HostStatus;
  isBootstrapping: boolean;
  /** True while the Windows banner is running bootstrap.ps1 -InstallWslOnly. */
  wslInstalling: boolean;
  /** Latest user-facing progress label (e.g. "正在启用 Windows 子系统功能…"),
   *  derived from the most recent `[claw-installer]` line during wslInstalling. */
  wslInstallStep: string | null;
  /** Last error from installWsl, if any (e.g., UAC denied). */
  wslInstallError: string | null;
  /** Whether the reboot-required modal is open (Windows WSL provisioning). */
  rebootModalOpen: boolean;
  /** Discriminates the modal variant: "wsl-feature" | "distro-firstrun". */
  rebootModalKind: string;

  selectAgent: (id: AgentId) => void;
  startInstall: (ids: AgentId[]) => void;
  cancelInstall: () => void;
  stopService: (id: AgentId) => void;
  startService: (id: AgentId) => void;
  openUninstall: (id: AgentId) => void;
  closeUninstall: () => void;
  confirmUninstall: () => void;
  openSettings: (id: AgentId) => void;
  openDashboard: (id: AgentId) => void;
  closeSettings: () => void;
  openAppSettings: () => void;
  closeAppSettings: () => void;
  updateAgentConfig: (id: AgentId, patch: Partial<AgentConfig>) => void;
  toggleAdvanced: () => void;
  updateSettings: <K extends keyof InstallerSettings>(
    key: K,
    value: InstallerSettings[K]
  ) => void;
  // New actions
  appendLog: (line: string) => void;
  clearLog: () => void;
  setLogPath: (path: string | null) => void;
  setLogExpanded: (v: boolean) => void;
  toggleLogExpanded: () => void;
  setCurrentStep: (id: AgentId, step: string | null, detail: string | null) => void;
  setAgentStatus: (
    id: AgentId,
    status: AgentStatus,
    meta?: { version?: string; installedAt?: string; errorMessage?: string }
  ) => void;
  refreshHostStatus: () => Promise<void>;
  bootstrap: () => Promise<void>;
  /** Trigger Windows WSL provisioning via bootstrap.ps1 -InstallWslOnly. */
  installWsl: () => Promise<void>;
  dismissRebootModal: () => void;
  /** Test helper: directly fire the RebootRequired state transition. */
  simulateRebootRequired: (kind: string) => void;
}

export const initialAgents: Record<AgentId, AgentState> = {
  openclaw: {
    id: "openclaw",
    name: "OpenClaw",
    tagline: "本地 Agent 网关",
    description:
      "通过本地 HTTP 网关把 Claude / Codex / Gemini 等模型接入开发工具。包含 CLI 与后台服务。",
    status: "not-installed",
    version: null,
    installedAt: null,
    port: 7841,
    currentStep: null,
    currentStepDetail: null,
    currentStepStartedAt: null,
    config: { model: emptyModelConfig(), channel: null, bubbolinkPairedAt: null },
  },
  hermes: {
    id: "hermes",
    name: "Hermes",
    tagline: "浏览器自动化",
    description:
      "Playwright 驱动的浏览器代理，能让 Agent 真正打开网页、点按钮、抓数据。",
    status: "not-installed",
    version: null,
    installedAt: null,
    currentStep: null,
    currentStepDetail: null,
    currentStepStartedAt: null,
    config: { model: emptyModelConfig(), channel: null, bubbolinkPairedAt: null },
  },
};

// Strip ANSI escape codes (CSI sequences) so log output renders cleanly in UI.
// eslint-disable-next-line no-control-regex
const ANSI_RE = /\x1b\[[0-9;]*[A-Za-z]/g;
function stripAnsi(input: string): string {
  return input.replace(ANSI_RE, "").replace(/\r/g, "").replace(/\n$/, "");
}

// ---- Settings → env var mapping (proposal §C2) -------------------------------
function buildEnv(settings: InstallerSettings): Record<string, string> {
  const env: Record<string, string> = {};
  const mirror = resolveMirror(settings.mirrorSource);
  // Only forward the npm registry override when it diverges from the upstream
  // default — keeps the env block minimal for users on the official source.
  if (mirror.npmRegistry !== "https://registry.npmjs.org") {
    env["INSTALLER_NPM_REGISTRY"] = mirror.npmRegistry;
  }
  // Homebrew env knobs (macOS). All four are individually skipped when null so
  // the bash side falls back to upstream defaults for that specific endpoint.
  if (mirror.brewGitRemote) env["INSTALLER_BREW_GIT_REMOTE"] = mirror.brewGitRemote;
  if (mirror.brewCoreGitRemote) env["INSTALLER_BREW_CORE_GIT_REMOTE"] = mirror.brewCoreGitRemote;
  if (mirror.brewBottleDomain) env["INSTALLER_BREW_BOTTLE_DOMAIN"] = mirror.brewBottleDomain;
  if (mirror.brewApiDomain) env["INSTALLER_BREW_API_DOMAIN"] = mirror.brewApiDomain;
  // Hermes clone + upstream installer URL — always forwarded so the GUI is the
  // single source of truth regardless of what the bash defaults happen to be.
  env["INSTALLER_HERMES_REPO_URL"] = mirror.hermesRepoUrl;
  env["INSTALLER_HERMES_INSTALL_URL"] = mirror.hermesInstallUrl;
  if (settings.gatewayPort !== 18789) {
    env["INSTALLER_GATEWAY_PORT"] = String(settings.gatewayPort);
  }
  if (settings.gatewayBind !== "loopback") {
    env["INSTALLER_GATEWAY_BIND"] = settings.gatewayBind;
  }
  env["INSTALLER_SERVICE_MODE"] = settings.serviceMode;
  if (settings.workspace) {
    env["INSTALLER_WORKSPACE"] = settings.workspace;
  }
  if (settings.skipBrowser) {
    env["INSTALLER_HERMES_SKIP_BROWSER"] = "1";
  }
  if (settings.forceReinstall) {
    env["INSTALLER_FORCE_REINSTALL"] = "1";
  }
  return env;
}

// ---- Store -------------------------------------------------------------------
export const useInstaller = create<State>((set, get) => ({
  agents: { ...initialAgents },
  selectedAgent: "openclaw",
  installQueue: [],
  logTail: [],
  currentLogPath: null,
  logExpanded: false,
  settings: {
    // Default to the accelerated mirror set — fastest in mainland China; users
    // on stable international networks can switch to "official" in app settings.
    mirrorSource: "accelerated",
    workspace: "",
    gatewayPort: 7841,
    gatewayBind: "loopback",
    serviceMode: "daemon",
    forceReinstall: false,
    skipBrowser: false,
  },
  showAdvanced: false,
  settingsTarget: null,
  appSettingsOpen: false,
  uninstallTarget: null,
  serviceActionAgent: null,
  serviceActionKind: null,
  dashboardActionAgent: null,
  installStartedAt: null,
  installEndedAt: null,
  // Start as "detecting" so the host-status banner shows a neutral
  // "正在检测 WSL / 虚拟化…" state instead of nothing while bootstrap.ps1
  // -Preflight runs (a few hundred ms on Windows, instant on macOS/Linux
  // which immediately resolves to "ok").
  hostStatus: "detecting",
  isBootstrapping: true,
  wslInstalling: false,
  wslInstallStep: null,
  wslInstallError: null,
  rebootModalOpen: false,
  rebootModalKind: "wsl-feature",

  selectAgent: (id) => set({ selectedAgent: id }),

  startInstall: (ids) => {
    const queue = ids.length ? ids : (Object.keys(initialAgents) as AgentId[]);
    const t0 = performance.now();
    const timingLog = (msg: string) => {
      console.log(`[claw-timing] ${msg}`);
      // Mirror to tauri log file so devtools-closed sessions still get data.
      // Done via dynamic import to avoid loading api/installer in stub/test mode.
      if (IS_TAURI_ENV) {
        void import("@/api/installer").then(({ frontendLog }) =>
          frontendLog("info", "timing", msg),
        );
      }
    };
    timingLog(`startInstall queue=${JSON.stringify(queue)} t=0ms`);
    set((s) => {
      const agents = { ...s.agents };
      for (const id of queue) {
        agents[id] = {
          ...agents[id],
          status: "installing",
          currentStep: null,
          currentStepDetail: null,
          currentStepStartedAt: null,
          errorMessage: undefined,
        };
      }
      return {
        agents,
        installQueue: queue,
        installStartedAt: Date.now(),
        installEndedAt: null,
        selectedAgent: queue[0],
        logTail: [],
        currentLogPath: null,
        logExpanded: true,
      };
    });

    const { settings } = get();
    const env = buildEnv(settings);

    if (IS_TAURI_ENV) {
      // Deferred import to avoid loading tauri IPC in browser/test environments
      import("@/api/installer").then(({ runInstaller }) => {
        timingLog(`runInstaller invoked at +${Math.round(performance.now() - t0)}ms`);
        let firstEventAt: number | null = null;
        let lastEventAt: number = performance.now();
        let eventCount = 0;
        runInstaller(queue, env, (event) => {
          eventCount++;
          const now = performance.now();
          if (firstEventAt === null) {
            firstEventAt = now;
            timingLog(`first event at +${Math.round(now - t0)}ms, type=${event.type}`);
          }
          if (event.type === "Finished") {
            timingLog(
              `Finished event at +${Math.round(now - t0)}ms ` +
              `(${eventCount} events total, last event +${Math.round(now - lastEventAt)}ms ago), ` +
              `success=${event.success}`,
            );
          }
          lastEventAt = now;
          handleInstallerEvent(event, queue);
        }).then(() => {
          timingLog(
            `runInstaller promise resolved at +${Math.round(performance.now() - t0)}ms ` +
            `(${eventCount} events, lastEvent +${Math.round(performance.now() - lastEventAt)}ms ago)`,
          );
        }).catch((err) => {
          const msg = err instanceof Error ? err.message : String(err);
          console.error("[runInstaller] rejected:", msg);
          set((s) => {
            const agents = { ...s.agents };
            for (const aid of queue) {
              agents[aid] = {
                ...agents[aid],
                status: "error",
                errorMessage: `安装无法启动：${msg}`,
                currentStep: null,
                currentStepDetail: null,
                currentStepStartedAt: null,
              };
            }
            return { agents, installQueue: [], installEndedAt: Date.now() };
          });
        });
      });
    } else {
      import("@/stub/sample").then(({ runStubInstaller }) => {
        runStubInstaller(queue, (event) => handleInstallerEvent(event, queue));
      });
    }
  },

  cancelInstall: () => {
    const queue = get().installQueue;
    if (IS_TAURI_ENV) {
      import("@/api/installer").then(({ cancelInstaller }) => cancelInstaller());
    }
    set((s) => {
      const agents = { ...s.agents };
      for (const id of queue) {
        agents[id] = {
          ...agents[id],
          status: "error",
          errorMessage: "已被用户中止",
          currentStep: null,
          currentStepDetail: null,
          currentStepStartedAt: null,
        };
      }
      return { agents, installQueue: [], installEndedAt: Date.now() };
    });
  },

  stopService:  (id) => runLifecycle(id, "stop",  set, get),
  startService: (id) => runLifecycle(id, "start", set, get),

  openUninstall: (id) => set({ uninstallTarget: id }),
  closeUninstall: () => set({ uninstallTarget: null }),

  confirmUninstall: () => {
    const id = get().uninstallTarget;
    if (!id) return;
    set((s) => ({
      agents: {
        ...s.agents,
        [id]: {
          ...s.agents[id],
          status: "uninstalling",
          currentStep: null,
          currentStepDetail: null,
          currentStepStartedAt: null,
        },
      },
      uninstallTarget: null,
      logTail: [],
      currentLogPath: null,
      logExpanded: true,
    }));

    const handleEvent = (event: InstallerEvent) => {
      if (event.type === "LogLine") {
        get().appendLog(event.line);
        return;
      }
      if (event.type === "LogPath") {
        get().setLogPath(event.path);
        return;
      }
      if (event.type === "RebootRequired") {
        get().simulateRebootRequired(event.kind);
        return;
      }
      if (event.type === "StepChanged") {
        set((s) => ({
          agents: {
            ...s.agents,
            [id]: {
              ...s.agents[id],
              currentStep: event.label,
              currentStepDetail: event.detail,
            },
          },
        }));
      } else if (event.type === "Finished") {
        if (event.success) {
          set((s) => ({
            agents: {
              ...s.agents,
              [id]: { ...initialAgents[id] },
            },
          }));
        } else {
          set((s) => ({
            agents: {
              ...s.agents,
              [id]: {
                ...s.agents[id],
                status: "error",
                errorMessage: event.message ?? "卸载失败",
                currentStep: null,
                currentStepDetail: null,
                currentStepStartedAt: null,
              },
            },
          }));
        }
      }
    };

    if (IS_TAURI_ENV) {
      import("@/api/installer").then(({ runUninstaller }) => {
        runUninstaller(id, handleEvent).catch((err) => {
          const msg = err instanceof Error ? err.message : String(err);
          console.error("[runUninstaller] rejected:", msg);
          set((s) => ({
            agents: {
              ...s.agents,
              [id]: {
                ...s.agents[id],
                status: "error",
                errorMessage: `卸载无法启动：${msg}`,
                currentStep: null,
                currentStepDetail: null,
                currentStepStartedAt: null,
              },
            },
          }));
        });
      });
    } else {
      import("@/stub/sample").then(({ runStubUninstaller }) => {
        runStubUninstaller(id, handleEvent);
      });
    }
  },

  openSettings: (id) => set({ settingsTarget: id }),

  openDashboard: (id) => {
    if (!IS_TAURI_ENV) return;
    // Bail if another dashboard launch is already in flight (the busy IconBtn
    // is disabled, but guard the action anyway in case it's called directly).
    if (get().dashboardActionAgent) return;
    set({ dashboardActionAgent: id });
    void import("@/api/installer")
      .then(({ openAgentDashboard }) => openAgentDashboard(id))
      .catch((e) => {
        get().appendLog(`[dashboard] 打开 ${id} dashboard 失败：${String(e)}`);
      })
      .finally(() => {
        set({ dashboardActionAgent: null });
      });
  },
  closeSettings: () => set({ settingsTarget: null }),
  openAppSettings: () => set({ appSettingsOpen: true }),
  closeAppSettings: () => set({ appSettingsOpen: false }),
  updateAgentConfig: (id, patch) =>
    set((s) => ({
      agents: {
        ...s.agents,
        [id]: {
          ...s.agents[id],
          config: { ...s.agents[id].config, ...patch } as AgentConfig,
        },
      },
    })),

  toggleAdvanced: () => set((s) => ({ showAdvanced: !s.showAdvanced })),
  updateSettings: (key, value) =>
    set((s) => ({ settings: { ...s.settings, [key]: value } })),

  appendLog: (line) =>
    set((s) => ({
      logTail: [...s.logTail, stripAnsi(line)].slice(-50),
    })),
  clearLog: () => set({ logTail: [] }),
  setLogPath: (path) => set({ currentLogPath: path }),
  setLogExpanded: (v) => set({ logExpanded: v }),
  toggleLogExpanded: () => set((s) => ({ logExpanded: !s.logExpanded })),

  setCurrentStep: (id, step, detail) =>
    set((s) => ({
      agents: {
        ...s.agents,
        [id]: {
          ...s.agents[id],
          currentStep: step,
          currentStepDetail: detail,
          currentStepStartedAt: step === null ? null : Date.now(),
        },
      },
    })),

  setAgentStatus: (id, status, meta) =>
    set((s) => ({
      agents: {
        ...s.agents,
        [id]: {
          ...s.agents[id],
          status,
          ...(meta?.version ? { version: meta.version } : {}),
          ...(meta?.installedAt ? { installedAt: meta.installedAt } : {}),
          ...(meta?.errorMessage !== undefined
            ? { errorMessage: meta.errorMessage }
            : {}),
        },
      },
    })),

  dismissRebootModal: () => set({ rebootModalOpen: false }),

  simulateRebootRequired: (kind: string) => {
    set((s) => {
      const agents = { ...s.agents };
      for (const id of s.installQueue) {
        if (agents[id].status === "installing") {
          agents[id] = { ...agents[id], status: "not-installed" };
        }
      }
      return {
        rebootModalOpen: true,
        rebootModalKind: kind,
        agents,
        installQueue: [],
      };
    });
  },

  refreshHostStatus: async () => {
    if (!IS_TAURI_ENV) return;
    // Flip to "detecting" so the banner repaints into its loading state while
    // the (potentially multi-second) preflight is in flight. Without this the
    // "重新检测" button looks unresponsive on Windows hosts.
    set({ hostStatus: "detecting" });
    const { readHostStatus } = await import("@/api/installer");
    const payload = await readHostStatus();
    set({ hostStatus: payload.status as HostStatus });
  },

  installWsl: async () => {
    if (!IS_TAURI_ENV) return;
    if (get().wslInstalling) return;
    set({
      wslInstalling: true,
      wslInstallStep: "正在请求管理员权限…",
      wslInstallError: null,
      logTail: [],
      currentLogPath: null,
      logExpanded: true,
    });

    const onEvent = (event: InstallerEvent) => {
      const store = useInstaller.getState();
      if (event.type === "LogLine") {
        store.appendLog(event.line);
        // Pick the latest meaningful user-facing line as the progress label.
        // The PS script emits two flavors:
        //   • Write-Step → "[claw-installer] <msg>" (banner + section headers)
        //   • Write-Display → "<msg>" raw (the bulk of progress messages)
        // and reserves Write-Log → "[debug] <msg>" for internals we should
        // *not* show. Skip sentinels and the banner line.
        const raw = event.line.trim();
        if (!raw) return;
        if (raw.startsWith("@@")) return;
        if (raw.startsWith("[debug]")) return;
        const bracketed = raw.match(/^\[claw-installer\]\s+(.+)$/);
        const text = bracketed ? bracketed[1].trim() : raw;
        if (text.startsWith("claw-installer Windows bootstrap")) return;
        set({ wslInstallStep: text });
        return;
      }
      if (event.type === "LogPath") { store.setLogPath(event.path); return; }
      if (event.type === "StepChanged") { return; }
      if (event.type === "RebootRequired") {
        store.simulateRebootRequired(event.kind);
        return;
      }
      if (event.type === "Finished") {
        set({
          wslInstalling: false,
          wslInstallStep: null,
          wslInstallError: event.success ? null : (event.message ?? "WSL 安装失败"),
        });
        if (event.success) {
          // Re-check host status so the banner disappears (or transitions to
          // needs-ubuntu-firstrun if WSL is now present but the distro isn't).
          void get().refreshHostStatus();
        }
      }
    };

    try {
      const { installWsl } = await import("@/api/installer");
      await installWsl(onEvent);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error("[installWsl] rejected:", msg);
      set({ wslInstalling: false, wslInstallStep: null, wslInstallError: msg });
    }
  },

  bootstrap: async () => {
    set({ isBootstrapping: true });
    try {
      if (IS_TAURI_ENV) {
        const { readInstallerState, readHostStatus, readModelConfigs } =
          await import("@/api/installer");
        const [statePayload, hostPayload, snapshot] = await Promise.all([
          readInstallerState(),
          readHostStatus(),
          // Don't let a corrupt snapshot break bootstrap — degrade to empty
          // defaults if read/parse fails.
          readModelConfigs().catch((err) => {
            console.warn("[bootstrap] readModelConfigs failed:", err);
            return null;
          }),
        ]);
        const persistedAgents = snapshot?.agents ?? {};
        set((s) => ({
          agents: {
            ...s.agents,
            openclaw: {
              ...s.agents.openclaw,
              status:
                statePayload.openclaw === "installed" ? "ready" : "not-installed",
              config: hydrateAgentConfig(persistedAgents.openclaw),
            },
            hermes: {
              ...s.agents.hermes,
              status:
                statePayload.hermes === "installed" ? "ready" : "not-installed",
              config: hydrateAgentConfig(persistedAgents.hermes),
            },
          },
          hostStatus: hostPayload.status as HostStatus,
        }));
      }
      // In stub/browser mode: agents stay at the default (both not-installed)
      // but flip hostStatus from "detecting" → "ok" so the banner clears.
      else {
        set({ hostStatus: "ok" });
      }
    } finally {
      set({ isBootstrapping: false });
    }
  },
}));

// ---- Event dispatcher --------------------------------------------------------
// Shared handler for both install and cancel flows.
function handleInstallerEvent(event: InstallerEvent, queue: AgentId[]) {
  const store = useInstaller.getState();
  if (event.type === "LogLine") {
    store.appendLog(event.line);
    return;
  }
  if (event.type === "LogPath") {
    store.setLogPath(event.path);
    return;
  }
  if (event.type === "StepChanged") {
    // Apply step to all currently-installing agents (simplified: apply to queue[0])
    const activeId = queue[0];
    if (activeId) {
      store.setCurrentStep(activeId, event.label, event.detail);
    }
  } else if (event.type === "StatusChanged") {
    const id = event.agent as AgentId;
    if (id === "openclaw" || id === "hermes") {
      store.setAgentStatus(id, event.status as AgentStatus);
    }
  } else if (event.type === "RebootRequired") {
    useInstaller.getState().simulateRebootRequired(event.kind);
  } else if (event.type === "Finished") {
    if (event.success) {
      // Transition all queued agents to ready. We deliberately do NOT gate on
      // `status === "installing"` — if the store was reset mid-install (Vite
      // HMR during dev, manual bootstrap re-run, etc.) the queue's agents may
      // be in any other state, and skipping the transition would leave the
      // GUI stuck. The queue itself is the source of truth for "this install
      // run was for these agents".
      const before = useInstaller.getState().agents;
      const beforeStatuses = queue.map((id) => `${id}:${before[id].status}`).join(",");
      useInstaller.setState((s) => {
        const agents = { ...s.agents };
        for (const id of queue) {
          agents[id] = {
            ...agents[id],
            status: "ready",
            currentStep: null,
            currentStepDetail: null,
            currentStepStartedAt: null,
            errorMessage: undefined,
            installedAt: new Date().toISOString(),
          };
        }
        return { agents, installQueue: [], installEndedAt: Date.now() };
      });
      const after = useInstaller.getState().agents;
      const afterStatuses = queue.map((id) => `${id}:${after[id].status}`).join(",");
      const msg = `Finished handled: before={${beforeStatuses}} after={${afterStatuses}}`;
      console.log(`[claw-timing] ${msg}`);
      if (IS_TAURI_ENV) {
        void import("@/api/installer").then(({ frontendLog }) =>
          frontendLog("info", "timing", msg),
        );
      }
    } else {
      useInstaller.setState((s) => {
        const agents = { ...s.agents };
        for (const id of queue) {
          agents[id] = {
            ...agents[id],
            status: "error",
            errorMessage: event.message ?? "安装失败",
            currentStep: null,
            currentStepDetail: null,
            currentStepStartedAt: null,
          };
        }
        return { agents, installQueue: [], installEndedAt: Date.now() };
      });
    }
  }
}

export function isAnyInstalling(state: State): boolean {
  return state.installQueue.length > 0;
}

// ---- Service lifecycle (start / stop) ----------------------------------------
// Each action shells out to agents/<id>/<action>.sh via the Tauri backend.
// Status flips:
//   start → ready   (on success) | error (on failure)
//   stop  → stopped (on success) | error (on failure)
type Setter = (
  partial:
    | Partial<State>
    | ((state: State) => Partial<State>)
) => void;
type Getter = () => State;

function runLifecycle(
  id: AgentId,
  action: "start" | "stop",
  set: Setter,
  get: Getter
) {
  // Guard: don't stack lifecycle actions or run them during install/uninstall.
  const s = get();
  if (s.serviceActionAgent || s.installQueue.length > 0) return;
  if (s.agents[id].status === "installing" || s.agents[id].status === "uninstalling") return;

  set((cur) => ({
    serviceActionAgent: id,
    serviceActionKind: action,
    logTail: [],
    currentLogPath: null,
    logExpanded: true,
    agents: {
      ...cur.agents,
      [id]: { ...cur.agents[id], currentStep: null, currentStepDetail: null, currentStepStartedAt: null },
    },
  }));

  const onEvent = (event: InstallerEvent) => {
    if (event.type === "LogLine") {
      get().appendLog(event.line);
      return;
    }
    if (event.type === "LogPath") {
      get().setLogPath(event.path);
      return;
    }
    if (event.type === "StepChanged") {
      get().setCurrentStep(id, event.label, event.detail);
      return;
    }
    if (event.type === "Finished") {
      set((cur) => {
        const agent = cur.agents[id];
        const next: AgentState = event.success
          ? {
              ...agent,
              status: action === "stop" ? "stopped" : "ready",
              currentStep: null,
              currentStepDetail: null,
              currentStepStartedAt: null,
              errorMessage: undefined,
            }
          : {
              ...agent,
              status: "error",
              errorMessage:
                event.message ?? (action === "start" ? "启动失败" : "停止失败"),
              currentStep: null,
              currentStepDetail: null,
              currentStepStartedAt: null,
            };
        return {
          agents: { ...cur.agents, [id]: next },
          serviceActionAgent: null,
          serviceActionKind: null,
        };
      });
    }
  };

  if (IS_TAURI_ENV) {
    import("@/api/installer").then(({ runServiceAction }) => {
      runServiceAction(id, action, onEvent).catch((err) => {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[runServiceAction:${action}] rejected:`, msg);
        set((cur) => ({
          agents: {
            ...cur.agents,
            [id]: {
              ...cur.agents[id],
              status: "error",
              errorMessage: `${action} 无法启动：${msg}`,
              currentStep: null,
              currentStepDetail: null,
              currentStepStartedAt: null,
            },
          },
          serviceActionAgent: null,
          serviceActionKind: null,
        }));
      });
    });
  } else {
    // Browser/stub: simulate success after a short delay so the UI flow works.
    setTimeout(() => {
      onEvent({ type: "Finished", success: true, message: null });
    }, 600);
  }
}
