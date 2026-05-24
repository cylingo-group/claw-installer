import { useTranslation } from "react-i18next";
import { useInstaller, type AgentId } from "@/store/installer-store";
import { AgentCard } from "./AgentCard";
import { HostStatusBanner } from "./HostStatusBanner";
import { LogStrip } from "./LogStrip";
import { cn } from "@/lib/utils";
import clawLogo from "@/assets/claw-installer-logo-v2.png";

export function Sidebar() {
  const { t } = useTranslation();
  const agents = useInstaller((s) => s.agents);
  const installQueue = useInstaller((s) => s.installQueue);
  const startInstall = useInstaller((s) => s.startInstall);
  const hostStatus = useInstaller((s) => s.hostStatus);
  const isBootstrapping = useInstaller((s) => s.isBootstrapping);
  const serviceActionAgent = useInstaller((s) => s.serviceActionAgent);
  const openAppSettings = useInstaller((s) => s.openAppSettings);

  const list = Object.values(agents);
  const installing = installQueue.length > 0;
  const uninstalling = list.some((a) => a.status === "uninstalling");
  const pending = list
    .filter((a) => a.status === "not-installed" || a.status === "error")
    .map((a) => a.id) as AgentId[];
  const hostBlocked = hostStatus !== "ok" || isBootstrapping;
  const disabled =
    installing || uninstalling || pending.length === 0 || hostBlocked || serviceActionAgent !== null;
  const label = installing
    ? t("sidebar.installing")
    : uninstalling
    ? t("sidebar.busy")
    : pending.length === 0
    ? t("sidebar.allInstalled")
    : t("sidebar.installAll");

  return (
    <aside className="flex h-full w-full flex-col bg-surface">
      <div className="flex items-center gap-3 pl-3 pr-3 pt-5 pb-4">
        <ClawMark />
        <div className="flex min-w-0 flex-1 flex-col justify-center leading-tight">
          <div className="text-sm font-semibold tracking-tight">Claw Installer</div>
          <div className="text-[11px] text-muted" lang="en">
            v1.0.0 · macOS / Linux / Windows
          </div>
        </div>
        <button
          onClick={openAppSettings}
          aria-label={t("sidebar.appSettings")}
          title={t("sidebar.appSettings")}
          className="grid h-8 w-8 shrink-0 place-items-center rounded text-muted transition-colors hover:bg-background hover:text-foreground"
        >
          <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.86l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.86-.34 1.7 1.7 0 0 0-1.04 1.56V21a2 2 0 0 1-4 0v-.09a1.7 1.7 0 0 0-1.1-1.56 1.7 1.7 0 0 0-1.86.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.86 1.7 1.7 0 0 0-1.56-1.04H3a2 2 0 0 1 0-4h.09a1.7 1.7 0 0 0 1.56-1.1 1.7 1.7 0 0 0-.34-1.86l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.86.34h.04A1.7 1.7 0 0 0 10 3.09V3a2 2 0 0 1 4 0v.09a1.7 1.7 0 0 0 1.04 1.56 1.7 1.7 0 0 0 1.86-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.86v.04a1.7 1.7 0 0 0 1.56 1.04H21a2 2 0 0 1 0 4h-.09a1.7 1.7 0 0 0-1.56 1.04Z" />
          </svg>
        </button>
      </div>

      <HostStatusBanner />

      <div className="flex-1 overflow-y-auto px-3 pb-3">
        <div className="px-1 pt-2 pb-2 text-[11px] font-medium uppercase tracking-wide text-muted">
          Agents
        </div>
        {isBootstrapping ? (
          <AgentCardSkeletons count={list.length || 2} />
        ) : (
          <ul className="space-y-2">
            {list.map((a) => (
              <li key={a.id}>
                <AgentCard agent={a} />
              </li>
            ))}
          </ul>
        )}
      </div>

      <LogStrip />

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

// Skeleton placeholders for the agent cards, shown while `isBootstrapping` is
// true (the initial readInstallerState + readHostStatus IPC round-trip).
// Shape mirrors AgentCard's collapsed layout (icon + name row) so the user's
// eye doesn't jump when real cards appear.
function AgentCardSkeletons({ count }: { count: number }) {
  return (
    <ul className="space-y-2">
      {Array.from({ length: count }).map((_, i) => (
        <li key={i}>
          <div className="rounded-lg border border-border bg-surface px-3 py-2.5">
            <div className="flex items-center gap-2.5">
              <div className="h-5 w-5 shrink-0 rounded-sm bg-background ued-pulse" />
              <div className="min-w-0 flex-1">
                <div className="h-3 w-24 rounded bg-background ued-pulse" />
              </div>
            </div>
          </div>
        </li>
      ))}
    </ul>
  );
}

function ClawMark() {
  return (
    <img
      src={clawLogo}
      alt="Claw Installer"
      className="h-11 w-11 shrink-0 rounded-lg object-contain"
      draggable={false}
    />
  );
}
