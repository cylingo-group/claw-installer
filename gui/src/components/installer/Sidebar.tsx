import { useInstaller, type AgentId } from "@/store/installer-store";
import { AgentCard } from "./AgentCard";
import { HostStatusBanner } from "./HostStatusBanner";
import { cn } from "@/lib/utils";

export function Sidebar() {
  const agents = useInstaller((s) => s.agents);
  const installQueue = useInstaller((s) => s.installQueue);
  const startInstall = useInstaller((s) => s.startInstall);
  const hostStatus = useInstaller((s) => s.hostStatus);
  const isBootstrapping = useInstaller((s) => s.isBootstrapping);

  const list = Object.values(agents);
  const installing = installQueue.length > 0;
  const uninstalling = list.some((a) => a.status === "uninstalling");
  const pending = list
    .filter((a) => a.status === "not-installed" || a.status === "error")
    .map((a) => a.id) as AgentId[];
  const hostBlocked = hostStatus !== "ok" || isBootstrapping;
  const disabled = installing || uninstalling || pending.length === 0 || hostBlocked;
  const label = installing
    ? "正在安装…"
    : uninstalling
    ? "处理中…"
    : pending.length === 0
    ? "全部已安装"
    : "一键安装全部";

  return (
    <aside className="flex h-full w-full flex-col bg-surface">
      <div className="flex items-center gap-2.5 px-5 pt-5 pb-4">
        <ClawMark />
        <div className="leading-tight">
          <div className="text-sm font-semibold tracking-tight">Claw Installer</div>
          <div className="text-[11px] text-muted" lang="en">
            v0.1 · macOS / Linux / Windows
          </div>
        </div>
      </div>

      <HostStatusBanner />

      <div className="flex-1 overflow-y-auto px-3 pb-3">
        <div className="px-1 pt-2 pb-2 text-[11px] font-medium uppercase tracking-wide text-muted">
          Agents
        </div>
        <ul className="space-y-2">
          {list.map((a) => (
            <li key={a.id}>
              <AgentCard agent={a} />
            </li>
          ))}
        </ul>
      </div>

      <div className="border-t border-border p-3">
        <button
          onClick={() => startInstall(pending)}
          disabled={disabled}
          className={cn(
            "w-full rounded bg-accent px-3 py-2 text-sm font-medium text-white",
            "transition-opacity disabled:cursor-not-allowed disabled:opacity-50",
            "hover:opacity-90"
          )}
        >
          {label}
        </button>
      </div>
    </aside>
  );
}

function ClawMark() {
  return (
    <span className="grid h-8 w-8 place-items-center rounded-lg bg-foreground text-surface">
      <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="2">
        <path d="M6 4c0 6 3 11 6 14" strokeLinecap="round" />
        <path d="M12 4c0 6 3 11 6 14" strokeLinecap="round" />
        <path d="M18 4c0 6-3 11-6 14" strokeLinecap="round" />
      </svg>
    </span>
  );
}
