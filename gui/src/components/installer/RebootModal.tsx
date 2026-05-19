import { useState } from "react";
import { useInstaller, IS_TAURI_ENV } from "@/store/installer-store";

interface ModalContent {
  title: string;
  body: string;
  primaryLabel: string;
  primaryDestructive: boolean;
  showReboot: boolean;
}

function getContent(kind: string): ModalContent {
  if (kind === "distro-firstrun") {
    return {
      title: "需要完成 Ubuntu 首次设置",
      body: "请在弹出的 Ubuntu 窗口中设置 Linux 用户名和密码，然后重新打开安装程序。",
      primaryLabel: "我已完成",
      primaryDestructive: false,
      showReboot: false,
    };
  }
  return {
    title: "需要重启 Windows",
    body: "WSL 2 安装完成，需要重启 Windows 才能继续。重启后重新打开安装程序以完成安装。",
    primaryLabel: "现在重启",
    primaryDestructive: true,
    showReboot: true,
  };
}

export function RebootModal() {
  const open = useInstaller((s) => s.rebootModalOpen);
  const kind = useInstaller((s) => s.rebootModalKind);
  const dismiss = useInstaller((s) => s.dismissRebootModal);
  const [error, setError] = useState<string | null>(null);
  const [rebooting, setRebooting] = useState(false);

  if (!open) return null;

  const content = getContent(kind);

  async function handlePrimary() {
    if (!content.showReboot) {
      dismiss();
      return;
    }
    setRebooting(true);
    setError(null);
    try {
      if (IS_TAURI_ENV) {
        const { systemReboot } = await import("@/api/installer");
        await systemReboot();
      }
      dismiss();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setRebooting(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-foreground/30 px-6">
      <div className="w-full max-w-md rounded-lg border border-border bg-surface p-5">
        <div className="flex items-center gap-3">
          <span className="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-warning/10">
            <svg viewBox="0 0 24 24" className="h-5 w-5 text-warning" fill="none" stroke="currentColor" strokeWidth="1.8">
              <path d="M12 9v4m0 4h.01M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </span>
          <h2 className="text-base font-semibold">{content.title}</h2>
        </div>

        <p className="mt-3 text-sm text-foreground/70">{content.body}</p>

        {/* OQ-1: static banner shown during elevated re-spawn phase */}
        <p className="mt-2 text-xs text-foreground/50">正在安装 WSL 2，请在 UAC 对话框中授权…</p>

        {error && (
          <p className="mt-2 text-xs text-danger">{error}</p>
        )}

        <div className="mt-5 flex items-center justify-end gap-2">
          {content.showReboot && (
            <button
              onClick={dismiss}
              disabled={rebooting}
              className="rounded border border-border bg-background px-3 py-1.5 text-sm text-foreground hover:border-foreground/40 disabled:opacity-50"
            >
              稍后
            </button>
          )}
          <button
            onClick={handlePrimary}
            disabled={rebooting}
            className={
              content.primaryDestructive
                ? "rounded bg-danger px-3 py-1.5 text-sm font-medium text-white hover:opacity-90 disabled:opacity-50"
                : "rounded border border-border bg-background px-3 py-1.5 text-sm text-foreground hover:border-foreground/40 disabled:opacity-50"
            }
          >
            {rebooting ? "正在重启…" : content.primaryLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
