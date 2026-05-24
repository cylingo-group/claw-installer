import { useTranslation } from "react-i18next";
import { useInstaller } from "@/store/installer-store";
import { cn } from "@/lib/utils";

export function HostStatusBanner() {
  const { t } = useTranslation();
  const hostStatus = useInstaller((s) => s.hostStatus);
  const wslInstalling = useInstaller((s) => s.wslInstalling);
  const wslInstallStep = useInstaller((s) => s.wslInstallStep);
  const wslInstallError = useInstaller((s) => s.wslInstallError);
  const installWsl = useInstaller((s) => s.installWsl);
  const refreshHostStatus = useInstaller((s) => s.refreshHostStatus);

  if (hostStatus === "ok") return null;

  // Neutral "detecting" variant: surface the fact that a host probe is in
  // flight (bootstrap.ps1 -Preflight on Windows) so the user isn't left
  // staring at an empty sidebar wondering whether the app is hung.
  if (hostStatus === "detecting") {
    return <HostDetectingBanner />;
  }

  const isNoWsl = hostStatus === "needs-wsl-install";
  const title = isNoWsl ? t("host.noWslTitle") : t("host.noUbuntuTitle");
  const description = isNoWsl ? t("host.noWslBody") : t("host.noUbuntuBody");
  const buttonLabel = isNoWsl ? t("host.installWsl") : t("host.installUbuntu");

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
          {wslInstallError && (
            <div className="mt-1.5 text-[11px] leading-relaxed text-danger">
              {t("host.installFailed", { message: wslInstallError })}
            </div>
          )}
        </div>
      </div>

      {wslInstalling && <WslInstallProgress step={wslInstallStep} />}

      <div className="mt-2 flex items-center justify-end gap-2">
        <button
          onClick={refreshHostStatus}
          disabled={wslInstalling}
          className="rounded border border-border bg-background px-2.5 py-1 text-[11px] text-muted transition-colors hover:border-foreground/40 hover:text-foreground disabled:opacity-50"
        >
          {t("host.recheck")}
        </button>
        <button
          onClick={() => void installWsl()}
          disabled={wslInstalling}
          className="rounded bg-danger px-2.5 py-1 text-[11px] font-medium text-white transition-opacity hover:opacity-90 disabled:opacity-50"
        >
          {wslInstalling ? t("host.installing") : buttonLabel}
        </button>
      </div>
    </div>
  );
}

// Pre-result banner shown while bootstrap.ps1 -Preflight is still running.
// Uses neutral (muted-foreground) styling — not red — because we don't yet
// know whether anything is wrong. Mirrors the layout of HostStatusBanner so
// content doesn't jump when the result resolves.
function HostDetectingBanner() {
  const { t } = useTranslation();
  return (
    <div className="mx-3 mt-3 rounded-lg border border-border bg-background/60 p-3">
      <div className="flex items-start gap-2">
        <span className="mt-1 grid h-3 w-3 shrink-0 place-items-center">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-muted opacity-60" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-muted" />
          </span>
        </span>
        <div className="min-w-0 flex-1">
          <div className="text-xs font-semibold text-foreground">
            {t("host.probing")}
          </div>
          <div className="mt-0.5 text-[11px] leading-relaxed text-muted">
            {t("host.probingDetail")}
          </div>
        </div>
      </div>
      <div className="mt-2.5 h-1 w-full overflow-hidden rounded-full bg-border/60">
        <div className={cn("ued-indeterminate-bar h-full w-1/3 rounded-full bg-muted")} />
      </div>
    </div>
  );
}

function WslInstallProgress({ step }: { step: string | null }) {
  const { t } = useTranslation();
  const fallback = t("host.runningFallback");
  return (
    <div className="mt-2.5 rounded-md border border-danger/20 bg-background/60 px-2.5 py-2">
      <div className="flex items-center gap-2 text-[11px] text-foreground/80">
        <span className="relative flex h-1.5 w-1.5">
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-danger opacity-60" />
          <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-danger" />
        </span>
        <span className="min-w-0 flex-1 truncate" title={step ?? fallback}>
          {step ?? fallback}
        </span>
      </div>
      <div className="mt-1.5 h-1 w-full overflow-hidden rounded-full bg-border/60">
        <div className={cn("ued-indeterminate-bar h-full w-1/3 rounded-full bg-danger")} />
      </div>
    </div>
  );
}
