import { useInstaller } from "@/store/installer-store";

export function HostStatusBanner() {
  const hostStatus = useInstaller((s) => s.hostStatus);
  const refreshHostStatus = useInstaller((s) => s.refreshHostStatus);

  if (hostStatus === "ok") return null;

  const isNoWsl = hostStatus === "needs-wsl-install";
  const command = isNoWsl ? "wsl --install" : "wsl --install -d Ubuntu";
  const title = isNoWsl ? "需要安装 WSL" : "需要完成 Ubuntu 初始化";
  const description = isNoWsl
    ? "本机尚未安装 WSL。请在管理员 PowerShell 中运行："
    : "Ubuntu 首次运行尚未完成。请运行：";

  async function copyCommand() {
    try {
      await navigator.clipboard.writeText(command);
    } catch {
      // clipboard API unavailable — no-op
    }
  }

  return (
    <div className="mx-3 mt-3 rounded-lg border border-danger/30 bg-danger/5 p-3">
      <div className="flex items-start gap-2">
        <span className="mt-0.5 grid h-4 w-4 shrink-0 place-items-center text-danger">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" className="h-4 w-4">
            <path d="M12 9v4M12 17h.01" strokeLinecap="round" />
            <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" strokeLinejoin="round" />
          </svg>
        </span>
        <div className="min-w-0 flex-1">
          <div className="text-xs font-semibold text-danger">{title}</div>
          <div className="mt-0.5 text-[11px] leading-relaxed text-muted">{description}</div>
          <div className="mt-1.5 flex items-center gap-1.5">
            <code className="flex-1 truncate rounded bg-background px-2 py-1 font-mono text-[11px] text-foreground" lang="en">
              {command}
            </code>
            <button
              onClick={copyCommand}
              title="复制命令"
              className="shrink-0 rounded border border-border bg-background px-2 py-1 text-[11px] text-muted transition-colors hover:text-foreground"
            >
              复制
            </button>
          </div>
        </div>
      </div>
      <div className="mt-2 flex justify-end">
        <button
          onClick={refreshHostStatus}
          className="rounded border border-border bg-background px-2.5 py-1 text-[11px] text-muted transition-colors hover:border-foreground/40 hover:text-foreground"
        >
          Retry
        </button>
      </div>
    </div>
  );
}
