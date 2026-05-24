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
  { key: "base-deps",  label: "Installing base dependencies…", detail: "curl / git / openssl" },
  { key: "fnm",        label: "Installing fnm…",               detail: "Node version manager" },
  { key: "node",       label: "Configuring Node runtime…",     detail: "Node v24" },
  { key: "pnpm",       label: "Preparing pnpm…",               detail: "via corepack" },
  { key: "npmrc",      label: "Writing npm registry mirror…",  detail: "~/.npmrc" },
  { key: "openclaw",   label: "Installing OpenClaw…",          detail: "pnpm add -g openclaw" },
  { key: "done",       label: "✓ Done",                        detail: "" },
];

const STEP_SEQUENCE_HERMES: StepEntry[] = [
  { key: "base-deps",     label: "Installing base dependencies…", detail: "" },
  { key: "system-tools",  label: "Installing system tools…",      detail: "ripgrep / ffmpeg" },
  { key: "hermes",        label: "Installing Hermes…",            detail: "Cloning repository" },
  { key: "done",          label: "✓ Done",                        detail: "" },
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
    { key: "uninstall", label: "Uninstalling…", detail: "Reversing manifest entries" },
    { key: "done",      label: "✓ Uninstall complete", detail: "" },
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
