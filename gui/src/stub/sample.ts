/**
 * src/stub/sample.ts — Stub installer for browser/dev mode.
 *
 * Emits the same InstallerEvent sequence as the real Rust backend,
 * using setTimeout-based simulation. Active when IS_TAURI_ENV is false.
 */
import type { InstallerEvent } from "@/store/installer-store";

interface StepEntry {
  key: string;
  label: string;
  detail: string;
}

const STEP_SEQUENCE_OPENCLAW: StepEntry[] = [
  { key: "base-deps",  label: "正在安装系统依赖…",     detail: "curl / git / openssl" },
  { key: "fnm",        label: "正在安装 fnm…",          detail: "Node 版本管理器" },
  { key: "node",       label: "正在配置 Node 运行时…",  detail: "Node v24" },
  { key: "pnpm",       label: "正在准备 pnpm…",         detail: "via corepack" },
  { key: "npmrc",      label: "正在写入镜像源…",         detail: "~/.npmrc" },
  { key: "openclaw",   label: "正在安装 OpenClaw…",     detail: "pnpm add -g openclaw" },
  { key: "done",       label: "✓ 完成",                  detail: "" },
];

const STEP_SEQUENCE_HERMES: StepEntry[] = [
  { key: "base-deps",     label: "正在安装系统依赖…",        detail: "" },
  { key: "system-tools",  label: "正在安装系统工具…",        detail: "ripgrep / ffmpeg" },
  { key: "hermes",        label: "正在安装 Hermes…",         detail: "克隆代码仓库" },
  { key: "done",          label: "✓ 完成",                    detail: "" },
];

const STEP_INTERVAL_MS = 1200;

/**
 * Runs the stub installer for given agents. Returns a cancel function.
 */
export function runStubInstaller(
  agents: string[],
  onEvent: (e: InstallerEvent) => void
): () => void {
  let cancelled = false;
  let handle: ReturnType<typeof setTimeout> | null = null;

  async function runSequence() {
    for (const agent of agents) {
      if (cancelled) break;
      const steps =
        agent === "openclaw" ? STEP_SEQUENCE_OPENCLAW : STEP_SEQUENCE_HERMES;
      for (const step of steps) {
        if (cancelled) break;
        await delay(STEP_INTERVAL_MS);
        if (cancelled) break;
        onEvent({
          type: "StepChanged",
          key: step.key,
          label: step.label,
          detail: step.detail,
        });
      }
    }
    if (!cancelled) {
      onEvent({ type: "Finished", success: true, message: null });
    }
  }

  // Use handle to allow cancellation
  handle = setTimeout(() => {
    runSequence();
  }, 200);

  return () => {
    cancelled = true;
    if (handle !== null) clearTimeout(handle);
  };
}

/**
 * Runs the stub uninstaller for a given agent. Simulates a 4.5s delay.
 */
export function runStubUninstaller(
  _agent: string,
  onEvent: (e: InstallerEvent) => void
): () => void {
  let cancelled = false;

  const steps: StepEntry[] = [
    { key: "uninstall", label: "正在卸载…", detail: "按 manifest 逆序回滚" },
    { key: "done",      label: "✓ 卸载完成", detail: "" },
  ];

  async function run() {
    for (const step of steps) {
      if (cancelled) break;
      await delay(1500);
      if (cancelled) break;
      onEvent({
        type: "StepChanged",
        key: step.key,
        label: step.label,
        detail: step.detail,
      });
    }
    await delay(1000);
    if (!cancelled) {
      onEvent({ type: "Finished", success: true, message: null });
    }
  }

  run();

  return () => {
    cancelled = true;
  };
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
