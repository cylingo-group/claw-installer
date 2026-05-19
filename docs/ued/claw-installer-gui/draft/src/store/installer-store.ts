import { create } from "zustand";
import { openclawLogScript, hermesLogScript } from "@/stub/log-lines";

export type AgentId = "openclaw" | "hermes";

export type AgentStatus =
  | "not-installed"
  | "installing"
  | "uninstalling"
  | "ready"
  | "stopped"
  | "error";

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
  /** index into the per-agent log script when installing/installed */
  progress: number;
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

export interface LogLine {
  ts: string;
  step: string;
  line: string;
  level?: "info" | "error";
}

interface State {
  agents: Record<AgentId, AgentState>;
  selectedAgent: AgentId;
  /** which agents are currently being processed */
  installQueue: AgentId[];
  /** rolling tail of stdout, last ~200 lines */
  logTail: LogLine[];
  logDrawerOpen: boolean;
  settings: InstallerSettings;
  showAdvanced: boolean;
  settingsTarget: AgentId | null;
  uninstallTarget: AgentId | null;
  installStartedAt: number | null;
  installEndedAt: number | null;

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
  toggleLogDrawer: () => void;
  toggleAdvanced: () => void;
  updateSettings: <K extends keyof InstallerSettings>(
    key: K,
    value: InstallerSettings[K]
  ) => void;
}

const initialAgents: Record<AgentId, AgentState> = {
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
    progress: 0,
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
    progress: 0,
    config: { engine: "chromium", userAgent: "desktop" },
  },
};

const SCRIPTS: Record<AgentId, ReadonlyArray<{ step: string; line: string }>> = {
  openclaw: openclawLogScript,
  hermes: hermesLogScript,
};

const VERSIONS: Record<AgentId, string> = {
  openclaw: "1.4.2",
  hermes: "0.18.0",
};

const TICK_MS = 350;
let tickHandle: ReturnType<typeof setInterval> | null = null;

function nowIso() {
  return new Date().toISOString().slice(11, 19);
}

export const useInstaller = create<State>((set, get) => ({
  agents: initialAgents,
  selectedAgent: "openclaw",
  installQueue: [],
  logTail: [],
  logDrawerOpen: false,
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

  selectAgent: (id) => set({ selectedAgent: id }),

  startInstall: (ids) => {
    if (tickHandle) return;
    const queue = ids.length ? ids : (Object.keys(initialAgents) as AgentId[]);
    set((s) => {
      const agents = { ...s.agents };
      for (const id of queue) {
        agents[id] = { ...agents[id], status: "installing", progress: 0, errorMessage: undefined };
      }
      return {
        agents,
        installQueue: queue,
        installStartedAt: Date.now(),
        installEndedAt: null,
        logTail: [{ ts: nowIso(), step: "init", line: `▶ 开始安装 ${queue.join(", ")}…` }],
        selectedAgent: queue[0],
        logDrawerOpen: true,
      };
    });

    tickHandle = setInterval(() => {
      const { installQueue, agents, logTail } = get();
      if (!installQueue.length) {
        if (tickHandle) clearInterval(tickHandle);
        tickHandle = null;
        return;
      }
      const head = installQueue[0];
      const script = SCRIPTS[head];
      const agent = agents[head];
      const next = agent.progress;

      if (next >= script.length) {
        // advance to the next agent in queue
        set((s) => ({
          agents: {
            ...s.agents,
            [head]: {
              ...s.agents[head],
              status: "ready",
              version: VERSIONS[head],
              installedAt: new Date().toISOString(),
            },
          },
          installQueue: s.installQueue.slice(1),
          installEndedAt: s.installQueue.length === 1 ? Date.now() : s.installEndedAt,
        }));
        return;
      }

      const entry = script[next];
      set((s) => ({
        agents: {
          ...s.agents,
          [head]: { ...s.agents[head], progress: next + 1 },
        },
        logTail: [
          ...logTail,
          { ts: nowIso(), step: entry.step, line: entry.line },
        ].slice(-200),
      }));
    }, TICK_MS);
  },

  cancelInstall: () => {
    if (tickHandle) clearInterval(tickHandle);
    tickHandle = null;
    set((s) => {
      const agents = { ...s.agents };
      for (const id of s.installQueue) {
        agents[id] = {
          ...agents[id],
          status: agents[id].progress > 0 ? "error" : "not-installed",
          errorMessage: "已被用户中止",
        };
      }
      return {
        agents,
        installQueue: [],
        logTail: [...s.logTail, { ts: nowIso(), step: "abort", line: "✗ 已中止当前安装。", level: "error" }],
        installEndedAt: Date.now(),
      };
    });
  },

  restartService: (id) =>
    set((s) => ({
      agents: { ...s.agents, [id]: { ...s.agents[id], status: "ready" } },
      logTail: [...s.logTail, { ts: nowIso(), step: id, line: `↻ 已重启 ${id} 后台服务。` }],
    })),

  stopService: (id) =>
    set((s) => ({
      agents: { ...s.agents, [id]: { ...s.agents[id], status: "stopped" } },
      logTail: [...s.logTail, { ts: nowIso(), step: id, line: `■ 已停止 ${id} 后台服务。` }],
    })),

  startService: (id) =>
    set((s) => ({
      agents: { ...s.agents, [id]: { ...s.agents[id], status: "ready" } },
      logTail: [...s.logTail, { ts: nowIso(), step: id, line: `▶ 已启动 ${id} 后台服务。` }],
    })),

  openUninstall: (id) => set({ uninstallTarget: id }),
  closeUninstall: () => set({ uninstallTarget: null }),
  confirmUninstall: () => {
    const id = get().uninstallTarget;
    if (!id) return;
    set((s) => ({
      agents: {
        ...s.agents,
        [id]: { ...s.agents[id], status: "uninstalling" },
      },
      uninstallTarget: null,
      logTail: [
        ...s.logTail,
        { ts: nowIso(), step: id, line: `↺ 正在按 manifest 逆序回滚 ${id}…` },
      ],
    }));
    setTimeout(() => {
      set((s) => ({
        agents: { ...s.agents, [id]: { ...initialAgents[id] } },
        logTail: [
          ...s.logTail,
          { ts: nowIso(), step: id, line: `✗ 已卸载 ${id}，manifest 已回滚。` },
        ],
      }));
    }, 4500);
  },

  openSettings: (id) => set({ settingsTarget: id }),
  closeSettings: () => set({ settingsTarget: null }),
  updateAgentConfig: (id, patch) =>
    set((s) => ({
      agents: {
        ...s.agents,
        [id]: { ...s.agents[id], config: { ...s.agents[id].config, ...patch } as AgentConfig },
      },
    })),

  toggleLogDrawer: () => set((s) => ({ logDrawerOpen: !s.logDrawerOpen })),
  toggleAdvanced: () => set((s) => ({ showAdvanced: !s.showAdvanced })),
  updateSettings: (key, value) =>
    set((s) => ({ settings: { ...s.settings, [key]: value } })),
}));

export function isAnyInstalling(state: State): boolean {
  return state.installQueue.length > 0;
}
