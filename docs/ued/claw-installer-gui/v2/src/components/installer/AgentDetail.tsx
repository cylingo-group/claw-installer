import { useInstaller } from "@/store/installer-store";
import { StatusPill } from "./StatusPill";
import { ConfigForm } from "./ConfigForm";
import { InstallProgress } from "./InstallProgress";
import { recentRuns } from "@/stub/log-lines";
import { cn } from "@/lib/utils";

export function AgentDetail() {
  const agent = useInstaller((s) => s.agents[s.selectedAgent]);
  const startInstall = useInstaller((s) => s.startInstall);
  const restart = useInstaller((s) => s.restartService);
  const stop = useInstaller((s) => s.stopService);
  const start = useInstaller((s) => s.startService);
  const openUninstall = useInstaller((s) => s.openUninstall);
  const toggleLog = useInstaller((s) => s.toggleLogDrawer);

  return (
    <div className="flex h-full flex-col overflow-y-auto">
      <header className="border-b border-border bg-surface px-8 pt-7 pb-6">
        <div className="flex items-start justify-between gap-6">
          <div className="min-w-0">
            <div className="flex items-center gap-3">
              <h1 className="truncate text-2xl font-semibold tracking-tight">{agent.name}</h1>
              <StatusPill status={agent.status} />
            </div>
            <dl className="mt-4 flex flex-wrap gap-x-6 gap-y-1 text-xs">
              <Meta label="版本" value={agent.version ?? "—"} mono />
              <Meta
                label="安装时间"
                value={
                  agent.installedAt
                    ? new Date(agent.installedAt).toLocaleString("zh-Hans", { hour12: false })
                    : "—"
                }
              />
              {agent.id === "openclaw" && (
                <Meta label="网关地址" value={`http://127.0.0.1:${agent.port}`} mono />
              )}
            </dl>
          </div>
          <ActionGroup
            agent={agent}
            onInstall={() => startInstall([agent.id])}
            onRestart={() => restart(agent.id)}
            onStop={() => stop(agent.id)}
            onStart={() => start(agent.id)}
            onUninstall={() => openUninstall(agent.id)}
          />
        </div>
      </header>

      <main className="flex flex-1 flex-col gap-5 px-8 py-6">
        {agent.status === "error" && agent.errorMessage && (
          <div className="flex items-start gap-3 rounded-lg border border-danger/30 bg-danger/5 px-4 py-3">
            <svg viewBox="0 0 24 24" className="mt-0.5 h-4 w-4 shrink-0 text-danger" fill="none" stroke="currentColor" strokeWidth="2">
              <circle cx="12" cy="12" r="9" />
              <path d="M12 8v5M12 16v.5" strokeLinecap="round" />
            </svg>
            <div className="flex-1">
              <div className="text-sm font-medium text-foreground">安装未完成</div>
              <div className="text-xs text-muted">{agent.errorMessage}</div>
            </div>
            <button
              onClick={() => startInstall([agent.id])}
              className="rounded border border-border bg-surface px-2.5 py-1 text-xs text-foreground hover:border-foreground/40"
            >
              重试
            </button>
          </div>
        )}

        {agent.status === "installing" && <InstallProgress agentId={agent.id} />}

        <ConfigForm />

        <section className="rounded-lg border border-border bg-surface">
          <header className="flex items-center justify-between border-b border-border px-5 py-3.5">
            <div>
              <h3 className="text-sm font-semibold">最近的安装记录</h3>
              <p className="text-[11px] text-muted">
                来自 <code className="font-mono">~/.claw-installer/install-*.log</code>
              </p>
            </div>
            <button
              onClick={toggleLog}
              className="rounded border border-border bg-background px-2.5 py-1 text-xs text-muted hover:border-foreground/40 hover:text-foreground"
            >
              打开日志面板
            </button>
          </header>
          <ul className="divide-y divide-border">
            {recentRuns
              .filter((r) => r.agent === agent.id)
              .map((r) => (
                <li key={r.id} className="flex items-center justify-between px-5 py-2.5 text-sm">
                  <div className="flex items-center gap-3">
                    <span
                      className={cn(
                        "h-1.5 w-1.5 rounded-full",
                        r.outcome === "success" ? "bg-success" : "bg-danger"
                      )}
                    />
                    <span className="font-mono text-[12px] text-foreground">{r.id}</span>
                  </div>
                  <span className="text-xs text-muted">{r.label}</span>
                </li>
              ))}
            {recentRuns.filter((r) => r.agent === agent.id).length === 0 && (
              <li className="px-5 py-4 text-xs text-muted">还没有运行过 {agent.name}。</li>
            )}
          </ul>
        </section>
      </main>
    </div>
  );
}

function Meta({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex items-baseline gap-1.5">
      <dt className="text-muted">{label}</dt>
      <dd className={cn("text-foreground", mono && "font-mono text-[12px]")}>{value}</dd>
    </div>
  );
}

function ActionGroup({
  agent,
  onInstall,
  onRestart,
  onStop,
  onStart,
  onUninstall,
}: {
  agent: ReturnType<typeof useInstaller.getState>["agents"][keyof ReturnType<typeof useInstaller.getState>["agents"]];
  onInstall: () => void;
  onRestart: () => void;
  onStop: () => void;
  onStart: () => void;
  onUninstall: () => void;
}) {
  if (agent.status === "not-installed" || agent.status === "error") {
    return (
      <button
        onClick={onInstall}
        className="rounded bg-accent px-4 py-2 text-sm font-medium text-white hover:opacity-90"
      >
        {agent.status === "error" ? "重新安装" : "立即安装"}
      </button>
    );
  }
  if (agent.status === "installing") {
    return (
      <button
        disabled
        className="cursor-not-allowed rounded border border-border bg-background px-4 py-2 text-sm text-muted"
      >
        安装中…
      </button>
    );
  }
  return (
    <div className="flex items-center gap-2">
      {agent.status === "ready" && (
        <button
          onClick={onRestart}
          className="rounded border border-border bg-surface px-3 py-1.5 text-xs text-foreground hover:border-foreground/40"
        >
          重启服务
        </button>
      )}
      {agent.status === "ready" ? (
        <button
          onClick={onStop}
          className="rounded border border-border bg-surface px-3 py-1.5 text-xs text-foreground hover:border-foreground/40"
        >
          停止
        </button>
      ) : (
        <button
          onClick={onStart}
          className="rounded border border-border bg-surface px-3 py-1.5 text-xs text-foreground hover:border-foreground/40"
        >
          启动
        </button>
      )}
      <button
        onClick={onUninstall}
        className="rounded border border-border bg-surface px-3 py-1.5 text-xs text-muted hover:border-danger/40 hover:text-danger"
      >
        卸载
      </button>
    </div>
  );
}
