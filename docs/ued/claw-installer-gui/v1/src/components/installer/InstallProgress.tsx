import { useInstaller, type AgentId } from "@/store/installer-store";
import { openclawLogScript, hermesLogScript } from "@/stub/log-lines";
import { cn } from "@/lib/utils";

const SCRIPTS: Record<AgentId, ReadonlyArray<{ step: string; line: string }>> = {
  openclaw: openclawLogScript,
  hermes: hermesLogScript,
};

const STEP_LABEL: Record<string, string> = {
  "base-deps": "系统依赖",
  fnm: "Node 版本管理",
  node: "Node 运行时",
  pnpm: "pnpm",
  npmrc: "镜像配置",
  openclaw: "OpenClaw CLI",
  hermes: "Hermes Agent",
  done: "完成",
  init: "准备",
  abort: "中止",
};

export function InstallProgress({ agentId }: { agentId: AgentId }) {
  const agent = useInstaller((s) => s.agents[agentId]);
  const cancel = useInstaller((s) => s.cancelInstall);

  const script = SCRIPTS[agentId];
  const steps = uniqueSteps(script);
  const currentStep = script[Math.min(agent.progress, script.length - 1)]?.step ?? "init";
  const completedSteps = new Set<string>();
  for (let i = 0; i < agent.progress && i < script.length; i++) {
    if (i < agent.progress - 1) completedSteps.add(script[i].step);
  }
  const pct = Math.round((agent.progress / script.length) * 100);

  return (
    <section className="rounded-lg border border-border bg-surface">
      <header className="flex items-center justify-between border-b border-border px-5 py-3.5">
        <div>
          <h3 className="text-sm font-semibold">正在安装</h3>
          <p className="text-[11px] text-muted">
            {pct}% · 第 {Math.min(agent.progress, script.length)} / {script.length} 步
          </p>
        </div>
        <button
          onClick={cancel}
          className="rounded border border-border bg-background px-2.5 py-1 text-xs text-muted hover:border-danger/40 hover:text-danger"
        >
          中止
        </button>
      </header>

      <div className="px-5 pt-4">
        <div className="h-1.5 w-full overflow-hidden rounded-full bg-background">
          <div
            className="h-full rounded-full bg-accent transition-all duration-200"
            style={{ width: `${pct}%` }}
          />
        </div>
      </div>

      <ol className="grid gap-1 px-5 py-4 sm:grid-cols-2">
        {steps.map((step) => {
          const state =
            completedSteps.has(step) || (step === "done" && agent.status === "ready")
              ? "done"
              : step === currentStep
              ? "active"
              : "pending";
          return (
            <li
              key={step}
              className={cn(
                "flex items-center gap-2 rounded px-2 py-1.5 text-xs",
                state === "active" && "bg-accent/10 text-foreground",
                state === "done" && "text-foreground",
                state === "pending" && "text-muted"
              )}
            >
              <StepDot state={state} />
              <span className="flex-1 truncate font-medium">{STEP_LABEL[step] ?? step}</span>
              <span className="text-[10px] text-muted" lang="en">
                {step}
              </span>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

function StepDot({ state }: { state: "done" | "active" | "pending" }) {
  if (state === "done") {
    return (
      <svg viewBox="0 0 24 24" className="h-3.5 w-3.5 text-success" fill="none" stroke="currentColor" strokeWidth="2.5">
        <path d="M5 12l5 5 9-11" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  }
  if (state === "active") {
    return (
      <span className="relative flex h-2 w-2">
        <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-accent opacity-70" />
        <span className="relative inline-flex h-2 w-2 rounded-full bg-accent" />
      </span>
    );
  }
  return <span className="h-2 w-2 rounded-full border border-border" />;
}

function uniqueSteps(script: ReadonlyArray<{ step: string }>): string[] {
  const seen: string[] = [];
  for (const { step } of script) if (!seen.includes(step)) seen.push(step);
  return seen;
}
