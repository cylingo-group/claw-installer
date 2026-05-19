import type { ReactNode } from "react";
import { useInstaller, type AgentId, type AgentState } from "@/store/installer-store";
import { cn } from "@/lib/utils";
import openclawLogo from "@/assets/agents/openclaw.svg";
import hermesLogo from "@/assets/agents/hermes.png";

const AGENT_LOGOS: Record<AgentId, string> = {
  openclaw: openclawLogo,
  hermes: hermesLogo,
};

export function AgentCard({ agent }: { agent: AgentState }) {
  const startInstall = useInstaller((s) => s.startInstall);
  const startService = useInstaller((s) => s.startService);
  const stopService = useInstaller((s) => s.stopService);
  const restart = useInstaller((s) => s.restartService);
  const openUninstall = useInstaller((s) => s.openUninstall);
  const openSettings = useInstaller((s) => s.openSettings);
  const isBootstrapping = useInstaller((s) => s.isBootstrapping);
  const hostStatus = useInstaller((s) => s.hostStatus);
  const anyTransitioning = useInstaller((s) =>
    Object.values(s.agents).some(
      (a) => a.status === "installing" || a.status === "uninstalling"
    )
  );

  const serviceActionAgent = useInstaller((s) => s.serviceActionAgent);
  const serviceActionKind = useInstaller((s) => s.serviceActionKind);
  const lifecycleBusy = serviceActionAgent === agent.id;
  const otherLifecycleBusy = serviceActionAgent !== null && !lifecycleBusy;

  const installed = agent.status !== "not-installed" && agent.status !== "error";
  const isError = agent.status === "error";
  const transitioning = agent.status === "installing" || agent.status === "uninstalling";
  const otherTransitioning = anyTransitioning && !transitioning;
  // Disable destructive/long-running actions while *any* other agent is in flight.
  const installDisabled = isBootstrapping || hostStatus !== "ok" || otherTransitioning || otherLifecycleBusy;

  return (
    <article className="rounded-lg border border-border bg-surface px-3 py-3">
      <header className="flex items-start gap-2.5">
        <AgentIcon id={agent.id} />
        <div className="min-w-0 flex-1">
          <div className="truncate text-sm font-medium leading-tight">{agent.name}</div>
        </div>
        {installed && !transitioning && (
          <div className="-mr-1 -mt-1 flex shrink-0 items-center gap-0.5">
            <IconBtn label="配置" onClick={() => openSettings(agent.id)} disabled={lifecycleBusy}>
              <GearIcon />
            </IconBtn>
            <IconBtn
              label="卸载"
              tone="danger"
              disabled={otherTransitioning || lifecycleBusy || otherLifecycleBusy}
              onClick={() => openUninstall(agent.id)}
            >
              <TrashIcon />
            </IconBtn>
          </div>
        )}
      </header>

      <div className="mt-3">
        {(agent.status === "not-installed") && (
          <button
            onClick={() => startInstall([agent.id])}
            disabled={installDisabled}
            className={cn(
              "w-full rounded bg-accent px-3 py-1.5 text-xs font-medium text-white hover:opacity-90",
              "disabled:cursor-not-allowed disabled:opacity-50"
            )}
          >
            立即安装
          </button>
        )}

        {isError && (
          <div className="space-y-1.5">
            <div className="rounded bg-danger/5 px-2 py-1.5 text-[11px] text-danger leading-relaxed">
              {agent.errorMessage ?? "安装失败"}
              <LogPathHint />
            </div>
            <button
              onClick={() => startInstall([agent.id])}
              disabled={installDisabled}
              className={cn(
                "w-full rounded border border-danger/40 px-3 py-1.5 text-xs font-medium text-danger hover:bg-danger/5",
                "disabled:cursor-not-allowed disabled:opacity-50"
              )}
            >
              重新安装
            </button>
          </div>
        )}

        {transitioning && (
          <ProgressBar
            label={agent.status === "installing" ? "安装中…" : "卸载中…"}
            hint={agent.status === "installing" ? "installing" : "uninstalling"}
            tone={agent.status === "installing" ? "accent" : "danger"}
            currentStep={agent.currentStep}
          />
        )}

        {installed && !transitioning && (
          <div className="grid grid-cols-2 gap-1.5">
            {agent.status === "ready" ? (
              <ActionBtn
                label={lifecycleBusy && serviceActionKind === "stop" ? "停止中…" : "停止"}
                icon={lifecycleBusy && serviceActionKind === "stop" ? <SpinnerIcon /> : <StopIcon />}
                onClick={() => stopService(agent.id)}
                disabled={lifecycleBusy || otherLifecycleBusy || otherTransitioning}
              />
            ) : (
              <ActionBtn
                label={lifecycleBusy && serviceActionKind === "start" ? "启动中…" : "启动"}
                icon={lifecycleBusy && serviceActionKind === "start" ? <SpinnerIcon /> : <PlayIcon />}
                onClick={() => startService(agent.id)}
                disabled={lifecycleBusy || otherLifecycleBusy || otherTransitioning}
              />
            )}
            <ActionBtn
              label={lifecycleBusy && serviceActionKind === "restart" ? "重启中…" : "重启"}
              icon={lifecycleBusy && serviceActionKind === "restart" ? <SpinnerIcon /> : <RestartIcon />}
              onClick={() => restart(agent.id)}
              disabled={lifecycleBusy || otherLifecycleBusy || otherTransitioning}
            />
          </div>
        )}
      </div>
    </article>
  );
}

function ProgressBar({
  label,
  hint,
  tone,
  currentStep,
}: {
  label: string;
  hint: string;
  tone: "accent" | "danger";
  currentStep?: string | null;
}) {
  const dot = tone === "danger" ? "bg-danger" : "bg-accent";
  const bar = tone === "danger" ? "bg-danger" : "bg-accent";
  return (
    <div className="w-full">
      <div className="flex items-center justify-between text-[11px] text-muted">
        <span className="flex items-center gap-1.5">
          <span className="relative flex h-1.5 w-1.5">
            <span className={cn("absolute inline-flex h-full w-full animate-ping rounded-full opacity-60", dot)} />
            <span className={cn("relative inline-flex h-1.5 w-1.5 rounded-full", dot)} />
          </span>
          {label}
        </span>
        <span className="font-mono text-[10px]" lang="en">
          {hint}
        </span>
      </div>
      <div className="mt-1.5 h-1 w-full overflow-hidden rounded-full bg-background">
        <div className={cn("ued-indeterminate-bar h-full w-1/3 rounded-full", bar)} />
      </div>
      {currentStep && (
        <div className="mt-1 text-[11px] text-muted truncate" title={currentStep}>
          {currentStep}
        </div>
      )}
    </div>
  );
}

function LogPathHint() {
  const path = useInstaller((s) => s.currentLogPath);
  if (!path) return null;
  return (
    <div className="mt-1 truncate font-mono text-[10px] text-muted" title={path} lang="en">
      完整日志：{path}
    </div>
  );
}

function ActionBtn({
  label,
  icon,
  onClick,
  disabled = false,
}: {
  label: string;
  icon: ReactNode;
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={cn(
        "flex items-center justify-center gap-1 rounded border border-border bg-background px-1.5 py-1.5 text-xs font-medium text-foreground transition-colors",
        "hover:border-foreground/40",
        "disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:border-border"
      )}
    >
      <span className="grid h-3 w-3 shrink-0 place-items-center">{icon}</span>
      {label}
    </button>
  );
}

function SpinnerIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      className="h-3 w-3 animate-spin"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.4"
      strokeLinecap="round"
    >
      <path d="M21 12a9 9 0 1 1-3-6.7" />
    </svg>
  );
}

function IconBtn({
  label,
  onClick,
  tone = "neutral",
  disabled = false,
  children,
}: {
  label: string;
  onClick: () => void;
  tone?: "neutral" | "danger";
  disabled?: boolean;
  children: ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      title={label}
      className={cn(
        "grid h-7 w-7 place-items-center rounded transition-colors",
        "disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:bg-transparent",
        tone === "danger"
          ? "text-muted hover:bg-danger/10 hover:text-danger"
          : "text-muted hover:bg-background hover:text-foreground"
      )}
    >
      {children}
    </button>
  );
}

function PlayIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-3 w-3" fill="currentColor">
      <path d="M7 5.5v13a.5.5 0 0 0 .77.42l10.4-6.5a.5.5 0 0 0 0-.84l-10.4-6.5A.5.5 0 0 0 7 5.5z" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-3 w-3" fill="currentColor">
      <rect x="6" y="6" width="12" height="12" rx="1.5" />
    </svg>
  );
}

function RestartIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 12a9 9 0 1 0 2.64-6.36" />
      <path d="M3 4v5h5" />
    </svg>
  );
}

function GearIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.86l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.86-.34 1.7 1.7 0 0 0-1.04 1.56V21a2 2 0 0 1-4 0v-.09a1.7 1.7 0 0 0-1.1-1.56 1.7 1.7 0 0 0-1.86.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.86 1.7 1.7 0 0 0-1.56-1.04H3a2 2 0 0 1 0-4h.09a1.7 1.7 0 0 0 1.56-1.1 1.7 1.7 0 0 0-.34-1.86l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.86.34h.04A1.7 1.7 0 0 0 10 3.09V3a2 2 0 0 1 4 0v.09a1.7 1.7 0 0 0 1.04 1.56 1.7 1.7 0 0 0 1.86-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.86v.04a1.7 1.7 0 0 0 1.56 1.04H21a2 2 0 0 1 0 4h-.09a1.7 1.7 0 0 0-1.56 1.04Z" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 7h16" />
      <path d="M9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2" />
      <path d="M6 7l1 13a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-13" />
    </svg>
  );
}

function AgentIcon({ id }: { id: AgentId }) {
  return (
    <img
      src={AGENT_LOGOS[id]}
      alt={`${id} logo`}
      className="mt-0.5 h-5 w-5 shrink-0 rounded-sm object-contain"
      draggable={false}
    />
  );
}
