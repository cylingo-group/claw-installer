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
  | "ok"
  | "needs-wsl-install"
  | "needs-ubuntu-firstrun";

export interface OpenclawConfig {
  channel: "stable" | "beta" | "nightly";
  provider: "anthropic" | "openai" | "gemini";
}

export interface HermesConfig {
  engine: "chromium" | "firefox" | "webkit";
  userAgent: "desktop" | "mobile";
}

export type AgentConfig = OpenclawConfig | HermesConfig;

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
  errorMessage?: string;
  config: AgentConfig;
}

export interface InstallerSettings {
  registryMirror: string;
  workspace: string;
  gatewayPort: number;
  gatewayBind: string;
  serviceMode: "daemon" | "foreground" | "skip";
  forceReinstall: boolean;
  skipBrowser: boolean;
}

// InstallerEvent is sent over the Channel from the Rust backend.
export type InstallerEvent =
  | { type: "StepChanged"; key: string; label: string; detail: string }
  | { type: "StatusChanged"; agent: string; status: string; message: string | null }
  | { type: "Finished"; success: boolean; message: string | null }
  | { type: "LogLine"; line: string };

interface State {
  agents: Record<AgentId, AgentState>;
  selectedAgent: AgentId;
  /** which agents are currently being processed */
  installQueue: AgentId[];
  settings: InstallerSettings;
  showAdvanced: boolean;
  settingsTarget: AgentId | null;
  uninstallTarget: AgentId | null;
  installStartedAt: number | null;
  installEndedAt: number | null;
  hostStatus: HostStatus;
  isBootstrapping: boolean;

  selectAgent: (id: AgentId) => void;
  startInstall: (ids: AgentId[]) => void;
  cancelInstall: () => void;
  restartService: (id: AgentId) => void;
  stopService: (id: AgentId) => void;
  startService: (id: AgentId) => void;
  openUninstall: (id: AgentId) => void;
  closeUninstall: () => void;
  confirmUninstall: () => void;
  openSettings: (id: AgentId) => void;
  closeSettings: () => void;
  updateAgentConfig: (id: AgentId, patch: Partial<AgentConfig>) => void;
  toggleAdvanced: () => void;
  updateSettings: <K extends keyof InstallerSettings>(
    key: K,
    value: InstallerSettings[K]
  ) => void;
  // New actions
  setCurrentStep: (id: AgentId, step: string | null, detail: string | null) => void;
  setAgentStatus: (
    id: AgentId,
    status: AgentStatus,
    meta?: { version?: string; installedAt?: string; errorMessage?: string }
  ) => void;
  refreshHostStatus: () => Promise<void>;
  bootstrap: () => Promise<void>;
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
    config: { channel: "stable", provider: "anthropic" },
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
    config: { engine: "chromium", userAgent: "desktop" },
  },
};

// ---- Settings → env var mapping (proposal §C2) -------------------------------
function buildEnv(settings: InstallerSettings): Record<string, string> {
  const env: Record<string, string> = {};
  if (settings.registryMirror && settings.registryMirror !== "https://registry.npmjs.org") {
    env["INSTALLER_NPM_REGISTRY"] = settings.registryMirror;
  }
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
  settings: {
    registryMirror: "https://registry.npmmirror.com",
    workspace: "~/openclaw",
    gatewayPort: 7841,
    gatewayBind: "127.0.0.1",
    serviceMode: "daemon",
    forceReinstall: false,
    skipBrowser: false,
  },
  showAdvanced: false,
  settingsTarget: null,
  uninstallTarget: null,
  installStartedAt: null,
  installEndedAt: null,
  hostStatus: "ok",
  isBootstrapping: true,

  selectAgent: (id) => set({ selectedAgent: id }),

  startInstall: (ids) => {
    const queue = ids.length ? ids : (Object.keys(initialAgents) as AgentId[]);
    set((s) => {
      const agents = { ...s.agents };
      for (const id of queue) {
        agents[id] = {
          ...agents[id],
          status: "installing",
          currentStep: null,
          currentStepDetail: null,
          errorMessage: undefined,
        };
      }
      return {
        agents,
        installQueue: queue,
        installStartedAt: Date.now(),
        installEndedAt: null,
        selectedAgent: queue[0],
      };
    });

    const { settings } = get();
    const env = buildEnv(settings);

    if (IS_TAURI_ENV) {
      // Deferred import to avoid loading tauri IPC in browser/test environments
      import("@/api/installer").then(({ runInstaller }) => {
        runInstaller(queue, env, (event) => handleInstallerEvent(event, queue));
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
        };
      }
      return { agents, installQueue: [], installEndedAt: Date.now() };
    });
  },

  restartService: (_id) => {
    // No-op in v1 (AC10)
  },

  stopService: (_id) => {
    // No-op in v1 (AC10)
  },

  startService: (_id) => {
    // No-op in v1 (AC10)
  },

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
        },
      },
      uninstallTarget: null,
    }));

    const handleEvent = (event: InstallerEvent) => {
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
              },
            },
          }));
        }
      }
    };

    if (IS_TAURI_ENV) {
      import("@/api/installer").then(({ runUninstaller }) => {
        runUninstaller(id, handleEvent);
      });
    } else {
      import("@/stub/sample").then(({ runStubUninstaller }) => {
        runStubUninstaller(id, handleEvent);
      });
    }
  },

  openSettings: (id) => set({ settingsTarget: id }),
  closeSettings: () => set({ settingsTarget: null }),
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

  setCurrentStep: (id, step, detail) =>
    set((s) => ({
      agents: {
        ...s.agents,
        [id]: {
          ...s.agents[id],
          currentStep: step,
          currentStepDetail: detail,
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

  refreshHostStatus: async () => {
    if (!IS_TAURI_ENV) return;
    const { readHostStatus } = await import("@/api/installer");
    const payload = await readHostStatus();
    set({ hostStatus: payload.status as HostStatus });
  },

  bootstrap: async () => {
    set({ isBootstrapping: true });
    try {
      if (IS_TAURI_ENV) {
        const { readInstallerState, readHostStatus } = await import("@/api/installer");
        const [statePayload, hostPayload] = await Promise.all([
          readInstallerState(),
          readHostStatus(),
        ]);
        set((s) => ({
          agents: {
            ...s.agents,
            openclaw: {
              ...s.agents.openclaw,
              status:
                statePayload.openclaw === "installed" ? "ready" : "not-installed",
            },
            hermes: {
              ...s.agents.hermes,
              status:
                statePayload.hermes === "installed" ? "ready" : "not-installed",
            },
          },
          hostStatus: hostPayload.status as HostStatus,
        }));
      }
      // In stub/browser mode: leave default state (both not-installed, hostStatus ok)
    } finally {
      set({ isBootstrapping: false });
    }
  },
}));

// ---- Event dispatcher --------------------------------------------------------
// Shared handler for both install and cancel flows.
function handleInstallerEvent(event: InstallerEvent, queue: AgentId[]) {
  const store = useInstaller.getState();
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
  } else if (event.type === "Finished") {
    if (event.success) {
      // Transition all queued agents to ready
      useInstaller.setState((s) => {
        const agents = { ...s.agents };
        for (const id of queue) {
          if (agents[id].status === "installing") {
            agents[id] = {
              ...agents[id],
              status: "ready",
              currentStep: null,
              currentStepDetail: null,
              installedAt: new Date().toISOString(),
            };
          }
        }
        return { agents, installQueue: [], installEndedAt: Date.now() };
      });
    } else {
      useInstaller.setState((s) => {
        const agents = { ...s.agents };
        for (const id of queue) {
          if (agents[id].status === "installing") {
            agents[id] = {
              ...agents[id],
              status: "error",
              errorMessage: event.message ?? "安装失败",
              currentStep: null,
              currentStepDetail: null,
            };
          }
        }
        return { agents, installQueue: [], installEndedAt: Date.now() };
      });
    }
  }
}

export function isAnyInstalling(state: State): boolean {
  return state.installQueue.length > 0;
}
