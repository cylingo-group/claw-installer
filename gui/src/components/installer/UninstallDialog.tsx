import { useInstaller } from "@/store/installer-store";
import { cn } from "@/lib/utils";

export function UninstallDialog() {
  const target = useInstaller((s) => s.uninstallTarget);
  const agent = useInstaller((s) => (target ? s.agents[target] : null));
  const close = useInstaller((s) => s.closeUninstall);
  const confirm = useInstaller((s) => s.confirmUninstall);

  // Also show while uninstalling (the dialog stays visible but non-interactive)
  const uninstallingAgent = useInstaller((s) => {
    for (const a of Object.values(s.agents)) {
      if (a.status === "uninstalling") return a;
    }
    return null;
  });

  const displayAgent = agent ?? uninstallingAgent;
  const isUninstalling = displayAgent?.status === "uninstalling";

  if (!displayAgent && !target) return null;

  return (
    <div className="fixed inset-0 z-40 grid place-items-center bg-foreground/30 px-6">
      <div className="w-full max-w-md rounded-lg border border-border bg-surface p-5">
        <div className="flex items-start gap-3">
          <span className="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-danger/10">
            <svg viewBox="0 0 24 24" className="h-5 w-5 text-danger" fill="none" stroke="currentColor" strokeWidth="1.8">
              <path d="M4 7h16M9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2M6 7l1 13a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-13" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </span>
          <div className="flex-1">
            <h2 className="text-base font-semibold">
              {isUninstalling ? `正在卸载 ${displayAgent.name}…` : `卸载 ${displayAgent?.name}？`}
            </h2>
            {!isUninstalling && (
              <p className="mt-1.5 text-sm text-muted">
                将按照安装清单逆序回滚 {displayAgent?.name} 的所有改动。已存在的系统包（标记为 preexisting 的项）不会被移除。
              </p>
            )}
            {isUninstalling && (
              <p className="mt-1.5 text-sm text-muted">
                {displayAgent.currentStep ?? "卸载中，请稍候…"}
              </p>
            )}
          </div>
        </div>

        {isUninstalling ? (
          // Non-cancellable progress state (AC3)
          <div className="mt-5">
            <DangerProgressBar />
            <p className="mt-2 text-center text-[11px] text-muted">卸载中，请稍候…</p>
          </div>
        ) : (
          <div className="mt-5 flex items-center justify-end gap-2">
            <button
              onClick={close}
              className="rounded border border-border bg-background px-3 py-1.5 text-sm text-foreground hover:border-foreground/40"
            >
              取消
            </button>
            <button
              onClick={confirm}
              className="rounded bg-danger px-3 py-1.5 text-sm font-medium text-white hover:opacity-90"
            >
              确认卸载
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

function DangerProgressBar() {
  return (
    <div className="h-1.5 w-full overflow-hidden rounded-full bg-background">
      <div
        className={cn("ued-indeterminate-bar h-full w-1/3 rounded-full bg-danger")}
      />
    </div>
  );
}
