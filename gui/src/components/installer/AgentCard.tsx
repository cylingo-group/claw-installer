import type { ReactNode } from "react";
import { ChevronRight, LayoutDashboard, Loader2, Play, Settings, Square, Trash2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import {
  useInstaller,
  isAgentConfigured,
  isModelConfigured,
  type AgentId,
  type AgentState,
} from "@/store/installer-store";
import { cn } from "@/lib/utils";
import openclawLogo from "@/assets/agents/openclaw.svg";
import hermesLogo from "@/assets/agents/hermes.png";

const AGENT_LOGOS: Record<AgentId, string> = {
  openclaw: openclawLogo,
  hermes: hermesLogo,
};

export function AgentCard({ agent }: { agent: AgentState }) {
  const { t } = useTranslation();
  const startInstall = useInstaller((s) => s.startInstall);
  const startService = useInstaller((s) => s.startService);
  const stopService = useInstaller((s) => s.stopService);
  const openUninstall = useInstaller((s) => s.openUninstall);
  const openSettings = useInstaller((s) => s.openSettings);
  const openDashboard = useInstaller((s) => s.openDashboard);
  const settingsTarget = useInstaller((s) => s.settingsTarget);
  const isBootstrapping = useInstaller((s) => s.isBootstrapping);
  const hostStatus = useInstaller((s) => s.hostStatus);
  const anyTransitioning = useInstaller((s) =>
    Object.values(s.agents).some(
      (a) => a.status === "installing" || a.status === "uninstalling"
    )
  );

  const serviceActionAgent = useInstaller((s) => s.serviceActionAgent);
  const serviceActionKind = useInstaller((s) => s.serviceActionKind);
  const dashboardActionAgent = useInstaller((s) => s.dashboardActionAgent);
  const lifecycleBusy = serviceActionAgent === agent.id;
  const otherLifecycleBusy = serviceActionAgent !== null && !lifecycleBusy;
  const dashboardBusy = dashboardActionAgent === agent.id;
  const otherDashboardBusy = dashboardActionAgent !== null && !dashboardBusy;

  const installed = agent.status !== "not-installed" && agent.status !== "error";
  const isError = agent.status === "error";
  const transitioning = agent.status === "installing" || agent.status === "uninstalling";
  const otherTransitioning = anyTransitioning && !transitioning;
  // Disable destructive/long-running actions while *any* other agent is in flight.
  const installDisabled = isBootstrapping || hostStatus !== "ok" || otherTransitioning || otherLifecycleBusy;

  // Body content only renders when the card is mid-install / errored / freshly
  // pending install. Once an agent is `ready`/`stopped`, the card collapses to a
  // single-row layout where every action lives in the right-aligned icon group.
  const hasBody = transitioning || isError || agent.status === "not-installed";

  return (
    <article className="rounded-lg border border-border bg-surface px-3 py-2.5">
      <div className="flex items-center gap-2.5">
        <AgentIcon id={agent.id} />
        <div className="min-w-0 flex-1">
          <div className="truncate text-sm font-medium leading-tight">{agent.name}</div>
        </div>
        {installed && !transitioning && (
          <div className="flex shrink-0 items-center gap-0.5">
            {agent.status === "ready" ? (
              <IconBtn
                label={lifecycleBusy && serviceActionKind === "stop" ? t("agentCard.stopping") : t("agentCard.stop")}
                tone="stop"
                onClick={() => stopService(agent.id)}
                disabled={lifecycleBusy || otherLifecycleBusy || otherTransitioning}
              >
                {lifecycleBusy && serviceActionKind === "stop" ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  // Lucide `Square` has the same stroke weight as the other
                  // outline icons; filling it keeps the stop-glyph visually
                  // weighty enough to match the filled Play triangle.
                  <Square className="h-4 w-4" fill="currentColor" strokeWidth={0} />
                )}
              </IconBtn>
            ) : (
              <IconBtn
                label={lifecycleBusy && serviceActionKind === "start" ? t("agentCard.starting") : t("agentCard.start")}
                tone="play"
                onClick={() => startService(agent.id)}
                disabled={lifecycleBusy || otherLifecycleBusy || otherTransitioning}
              >
                {lifecycleBusy && serviceActionKind === "start" ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  <Play className="h-4 w-4" fill="currentColor" strokeWidth={0} />
                )}
              </IconBtn>
            )}
            <IconBtn
              label={dashboardBusy ? t("agentCard.starting") : t("agentCard.openDashboard")}
              onClick={() => openDashboard(agent.id)}
              disabled={lifecycleBusy || dashboardBusy || otherDashboardBusy}
            >
              {dashboardBusy ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <LayoutDashboard className="h-4 w-4" strokeWidth={1.6} />
              )}
            </IconBtn>
            <IconBtn label={t("agentCard.configure")} onClick={() => openSettings(agent.id)} disabled={lifecycleBusy}>
              <Settings className="h-4 w-4" strokeWidth={1.6} />
            </IconBtn>
            <IconBtn
              label={t("agentCard.uninstall")}
              tone="danger"
              disabled={otherTransitioning || lifecycleBusy || otherLifecycleBusy}
              onClick={() => openUninstall(agent.id)}
            >
              <Trash2 className="h-4 w-4" strokeWidth={1.6} />
            </IconBtn>
          </div>
        )}
      </div>

      {hasBody && (
        <div className="mt-2.5">
          {agent.status === "not-installed" && (
            <button
              onClick={() => startInstall([agent.id])}
              disabled={installDisabled}
              className={cn(
                "w-full rounded bg-accent px-3 py-1.5 text-xs font-medium text-white hover:opacity-90",
                "disabled:cursor-not-allowed disabled:opacity-50"
              )}
            >
              {t("agentCard.install")}
            </button>
          )}

          {isError && (
            <div className="space-y-1.5">
              <div className="rounded bg-danger/5 px-2 py-1.5 text-[11px] text-danger leading-relaxed">
                {agent.errorMessage ?? t("agentCard.installFailed")}
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
                {t("agentCard.reinstall")}
              </button>
            </div>
          )}

          {transitioning && (
            <ProgressBar
              label={agent.status === "installing" ? t("agentCard.installing") : t("agentCard.uninstalling")}
              hint={agent.status === "installing" ? "installing" : "uninstalling"}
              tone={agent.status === "installing" ? "accent" : "danger"}
              currentStep={agent.currentStep}
            />
          )}
        </div>
      )}

      {installed
        && !isAgentConfigured(agent)
        && !transitioning
        && settingsTarget !== agent.id
        && <UnconfiguredHint agent={agent} onOpen={() => openSettings(agent.id)} />}
    </article>
  );
}

function UnconfiguredHint({ agent, onOpen }: { agent: AgentState; onOpen: () => void }) {
  const { t } = useTranslation();
  const modelMissing = !isModelConfigured(agent.config.model);
  const channelMissing = agent.config.channel === null;

  let copy: string;
  if (modelMissing && channelMissing) {
    copy = t("agentCard.configIncompleteAll");
  } else if (modelMissing) {
    copy = t("agentCard.configIncompleteModel");
  } else {
    copy = t("agentCard.configIncompleteChannel");
  }

  return (
    <button
      onClick={onOpen}
      className={cn(
        "mt-2 flex w-full items-center justify-between gap-2 rounded px-2.5 py-1.5",
        "border border-amber-200 bg-amber-50 text-[11px] text-amber-800",
        "hover:bg-amber-100 transition-colors"
      )}
    >
      <span className="truncate text-left">{copy}</span>
      <ChevronRight className="h-3.5 w-3.5 shrink-0" />
    </button>
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
  const { t } = useTranslation();
  const path = useInstaller((s) => s.currentLogPath);
  if (!path) return null;
  return (
    <div className="mt-1 truncate font-mono text-[10px] text-muted" title={path}>
      {t("agentCard.fullLog", { path })}
    </div>
  );
}

// IconBtn tones:
// - neutral / danger: muted-by-default, color-on-hover. Used for utility actions
//   whose color should fade into the card (gear, trash) until the user reaches
//   for them.
// - play / stop: always colored. The start/stop service actions are the primary
//   semantic state of an installed agent — green for runnable, red for live —
//   so they read at a glance without needing a hover.
function IconBtn({
  label,
  onClick,
  tone = "neutral",
  disabled = false,
  children,
}: {
  label: string;
  onClick: () => void;
  tone?: "neutral" | "danger" | "play" | "stop";
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
        tone === "play"
          ? "text-success hover:bg-success/10"
          : tone === "stop"
          ? "text-danger hover:bg-danger/10"
          : tone === "danger"
          ? "text-muted hover:bg-danger/10 hover:text-danger"
          : "text-muted hover:bg-background hover:text-foreground"
      )}
    >
      {children}
    </button>
  );
}

function AgentIcon({ id }: { id: AgentId }) {
  return (
    <img
      src={AGENT_LOGOS[id]}
      alt={`${id} logo`}
      className="h-5 w-5 shrink-0 rounded-sm object-contain"
      draggable={false}
    />
  );
}
