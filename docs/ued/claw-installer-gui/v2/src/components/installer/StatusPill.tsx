import { cn } from "@/lib/utils";
import type { AgentStatus } from "@/store/installer-store";

const LABEL: Record<AgentStatus, string> = {
  "not-installed": "未安装",
  installing: "安装中",
  ready: "运行中",
  stopped: "已停止",
  error: "出错",
};

const TONE: Record<AgentStatus, string> = {
  "not-installed": "bg-surface text-muted border-border",
  installing: "bg-accent/10 text-accent border-accent/30",
  ready: "bg-success/10 text-success border-success/30",
  stopped: "bg-muted/10 text-muted border-border",
  error: "bg-danger/10 text-danger border-danger/30",
};

export function StatusPill({
  status,
  size = "md",
  className,
}: {
  status: AgentStatus;
  size?: "sm" | "md";
  className?: string;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border font-medium tabular-nums",
        size === "sm" ? "px-2 py-0.5 text-[11px]" : "px-2.5 py-1 text-xs",
        TONE[status],
        className
      )}
    >
      <Dot status={status} />
      {LABEL[status]}
    </span>
  );
}

function Dot({ status }: { status: AgentStatus }) {
  if (status === "installing") {
    return (
      <span className="relative flex h-1.5 w-1.5">
        <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-accent opacity-60" />
        <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-accent" />
      </span>
    );
  }
  const color =
    status === "ready"
      ? "bg-success"
      : status === "error"
      ? "bg-danger"
      : status === "stopped"
      ? "bg-muted"
      : "bg-muted/60";
  return <span className={cn("h-1.5 w-1.5 rounded-full", color)} />;
}
