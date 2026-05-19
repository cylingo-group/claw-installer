import { useInstaller } from "@/store/installer-store";
import { cn } from "@/lib/utils";

export function SettingsPanel() {
  const target = useInstaller((s) => s.settingsTarget);
  const agent = useInstaller((s) => (target ? s.agents[target] : null));
  const close = useInstaller((s) => s.closeSettings);

  const open = Boolean(target && agent);

  return (
    <section
      aria-hidden={!open}
      className={cn(
        "absolute inset-0 z-20 flex flex-col bg-surface",
        "transition-transform duration-200 ease-out",
        open ? "translate-x-0" : "translate-x-full pointer-events-none"
      )}
    >
      <header className="flex items-center gap-2 border-b border-border px-3 py-3">
        <button
          onClick={close}
          aria-label="返回"
          className="grid h-7 w-7 shrink-0 place-items-center rounded text-muted transition-colors hover:bg-background hover:text-foreground"
        >
          <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <path d="M15 6l-6 6 6 6" />
          </svg>
        </button>
        <div className="min-w-0 flex-1 leading-tight">
          <div className="truncate text-sm font-semibold">{agent?.name ?? ""} 配置</div>
        </div>
      </header>

      <div className="flex flex-1 flex-col items-center justify-center px-6 py-10 text-center">
        <span className="grid h-10 w-10 place-items-center rounded-full bg-background text-muted">
          <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.86l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.86-.34 1.7 1.7 0 0 0-1.04 1.56V21a2 2 0 0 1-4 0v-.09a1.7 1.7 0 0 0-1.1-1.56 1.7 1.7 0 0 0-1.86.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.86 1.7 1.7 0 0 0-1.56-1.04H3a2 2 0 0 1 0-4h.09a1.7 1.7 0 0 0 1.56-1.1 1.7 1.7 0 0 0-.34-1.86l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.86.34h.04A1.7 1.7 0 0 0 10 3.09V3a2 2 0 0 1 4 0v.09a1.7 1.7 0 0 0 1.04 1.56 1.7 1.7 0 0 0 1.86-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.86v.04a1.7 1.7 0 0 0 1.56 1.04H21a2 2 0 0 1 0 4h-.09a1.7 1.7 0 0 0-1.56 1.04Z" />
          </svg>
        </span>
        <h2 className="mt-4 text-sm font-medium text-foreground">配置项即将开放</h2>
        <p className="mt-1.5 text-[11px] leading-relaxed text-muted">
          这里之后会用来配置 {agent?.name ?? "Agent"} 的运行选项 ——
          Channel、模型供应商、网络代理等。
        </p>
        <p className="mt-1 text-[10px] text-muted" lang="en">
          coming soon
        </p>
      </div>
    </section>
  );
}
