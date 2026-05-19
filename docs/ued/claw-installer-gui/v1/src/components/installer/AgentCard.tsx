import type { ReactNode } from "react";
import { useInstaller, type AgentId, type AgentState } from "@/store/installer-store";
import { cn } from "@/lib/utils";

export function AgentCard({ agent }: { agent: AgentState }) {
  const startInstall = useInstaller((s) => s.startInstall);
  const startService = useInstaller((s) => s.startService);
  const stopService = useInstaller((s) => s.stopService);
  const restart = useInstaller((s) => s.restartService);
  const openUninstall = useInstaller((s) => s.openUninstall);
  const openSettings = useInstaller((s) => s.openSettings);

  const installed = agent.status !== "not-installed";
  const transitioning = agent.status === "installing" || agent.status === "uninstalling";

  return (
    <article className="rounded-lg border border-border bg-surface px-3 py-3">
      <header className="flex items-start gap-2.5">
        <AgentIcon id={agent.id} />
        <div className="min-w-0 flex-1">
          <div className="truncate text-sm font-medium leading-tight">{agent.name}</div>
        </div>
        {installed && !transitioning && (
          <div className="-mr-1 -mt-1 flex shrink-0 items-center gap-0.5">
            <IconBtn label="配置" onClick={() => openSettings(agent.id)}>
              <GearIcon />
            </IconBtn>
            <IconBtn label="卸载" tone="danger" onClick={() => openUninstall(agent.id)}>
              <TrashIcon />
            </IconBtn>
          </div>
        )}
      </header>

      <div className="mt-3">
        {!installed && (
          <button
            onClick={() => startInstall([agent.id])}
            className="w-full rounded bg-accent px-3 py-1.5 text-xs font-medium text-white hover:opacity-90"
          >
            立即安装
          </button>
        )}

        {transitioning && (
          <ProgressBar
            label={agent.status === "installing" ? "安装中…" : "卸载中…"}
            hint={agent.status === "installing" ? "installing" : "uninstalling"}
            tone={agent.status === "installing" ? "accent" : "danger"}
          />
        )}

        {installed && !transitioning && (
          <div className="grid grid-cols-3 gap-1.5">
            <ActionBtn label="启动" icon={<PlayIcon />} onClick={() => startService(agent.id)} />
            <ActionBtn label="停止" icon={<StopIcon />} onClick={() => stopService(agent.id)} />
            <ActionBtn label="重启" icon={<RestartIcon />} onClick={() => restart(agent.id)} />
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
}: {
  label: string;
  hint: string;
  tone: "accent" | "danger";
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
    </div>
  );
}

function ActionBtn({
  label,
  icon,
  onClick,
}: {
  label: string;
  icon: ReactNode;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="flex items-center justify-center gap-1 rounded border border-border bg-background px-1.5 py-1.5 text-xs font-medium text-foreground transition-colors hover:border-foreground/40"
    >
      <span className="grid h-3 w-3 shrink-0 place-items-center">{icon}</span>
      {label}
    </button>
  );
}

function IconBtn({
  label,
  onClick,
  tone = "neutral",
  children,
}: {
  label: string;
  onClick: () => void;
  tone?: "neutral" | "danger";
  children: ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      aria-label={label}
      title={label}
      className={cn(
        "grid h-7 w-7 place-items-center rounded transition-colors",
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
  if (id === "openclaw") {
    return (
      <svg viewBox="0 0 24 24" className="mt-0.5 h-4 w-4 shrink-0 text-muted" fill="none" stroke="currentColor" strokeWidth="1.6">
        <path d="M5 12c0-3.866 3.134-7 7-7s7 3.134 7 7" strokeLinecap="round" />
        <path d="M5 12c0 3.866 3.134 7 7 7" strokeLinecap="round" />
        <circle cx="12" cy="12" r="2" fill="currentColor" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 24 24" className="mt-0.5 h-4 w-4 shrink-0 text-muted" fill="none" stroke="currentColor" strokeWidth="1.6">
      <path d="M5 7l7 4 7-4" strokeLinejoin="round" strokeLinecap="round" />
      <path d="M5 7v10l7 4 7-4V7" strokeLinejoin="round" strokeLinecap="round" />
      <path d="M12 11v10" strokeLinecap="round" />
    </svg>
  );
}
