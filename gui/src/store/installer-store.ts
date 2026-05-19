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
  uninstallTarget: AgentId | null;
  /** Agent currently running a start/stop/restart shell action (null if none). */
  serviceActionAgent: AgentId | null;
  /** Which action is in flight when serviceActionAgent is set. */
  serviceActionKind: "start" | "stop" | "restart" | null;
  installStartedAt: number | null;
  installEndedAt: number | null;
  hostStatus: HostStatus;
  isBootstrapping: boolean;
  /** Whether the reboot-required modal is open (Windows WSL provisioning). */
  rebootModalOpen: boolean;
  /** Discriminates the modal variant: "wsl-feature" | "distro-firstrun". */
  rebootModalKind: string;

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

// Strip ANSI escape codes (CSI sequences) so log output renders cleanly in UI.
// eslint-disable-next-line no-control-regex
const ANSI_RE = /\x1b\[[0-9;]*[A-Za-z]/g;
function stripAnsi(input: string): string {
  return input.replace(ANSI_RE, "").replace(/\r/g, "").replace(/\n$/, "");
}

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
  logTail: [],
  currentLogPath: null,
  logExpanded: false,
  settings: {
    registryMirror: "https://registry.npmmirror.com",
    workspace: "",
    gatewayPort: 7841,
    gatewayBind: "loopback",
    serviceMode: "daemon",
    forceReinstall: false,
    skipBrowser: false,
  },
  showAdvanced: false,
  settingsTarget: null,
  uninstallTarget: null,
  serviceActionAgent: null,
  serviceActionKind: null,
  installStartedAt: null,
  installEndedAt: null,
  hostStatus: "ok",
  isBootstrapping: true,
  rebootModalOpen: false,
  rebootModalKind: "wsl-feature",

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
        runInstaller(queue, env, (event) => handleInstallerEvent(event, queue)).catch((err) => {
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
        };
      }
      return { agents, installQueue: [], installEndedAt: Date.now() };
    });
  },

  restartService: (id) => runLifecycle(id, "restart", set, get),
  stopService:    (id) => runLifecycle(id, "stop",    set, get),
  startService:   (id) => runLifecycle(id, "start",   set, get),

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

// ---- Service lifecycle (start / stop / restart) ------------------------------
// Each action shells out to agents/<id>/<action>.sh via the Tauri backend.
// Status flips:
//   start   → ready    (on success)   | error (on failure)
//   stop    → stopped  (on success)   | error (on failure)
//   restart → ready    (on success)   | error (on failure)
type Setter = (
  partial:
    | Partial<State>
    | ((state: State) => Partial<State>)
) => void;
type Getter = () => State;

function runLifecycle(
  id: AgentId,
  action: "start" | "stop" | "restart",
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
      [id]: { ...cur.agents[id], currentStep: null, currentStepDetail: null },
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
              errorMessage: undefined,
            }
          : {
              ...agent,
              status: "error",
              errorMessage:
                event.message ??
                (action === "start"
                  ? "启动失败"
                  : action === "stop"
                  ? "停止失败"
                  : "重启失败"),
              currentStep: null,
              currentStepDetail: null,
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
