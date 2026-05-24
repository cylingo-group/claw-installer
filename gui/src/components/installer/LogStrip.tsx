import { useEffect, useRef, useState } from "react";
import { useInstaller, IS_TAURI_ENV } from "@/store/installer-store";
import { cn } from "@/lib/utils";

/**
 * Bottom log panel.
 *
 * Layout: a persistent header bar pinned at the bottom that's always visible.
 * Click the header (or the chevron) to expand into a scrollable body that
 * holds the last ~50 log lines. The body slides in/out with a cubic-bezier
 * height + opacity transition.
 *
 * Auto-behaviors:
 *  - `startInstall` / `confirmUninstall` flip `logExpanded = true` so the
 *    panel pops open the moment work starts.
 *  - After completion (success or error) the panel stays in whatever state
 *    the user last set, so they can review the tail.
 *
 * The body auto-scrolls to bottom on every new line. Scrollbar styled via
 * `.ued-scroll-thin` from `index.css`.
 */
const VISIBLE_LINES = 12;
const LINE_HEIGHT = 14;
const BODY_HEIGHT = VISIBLE_LINES * LINE_HEIGHT; // 168px
const PATH_REGEX = /((?:\/|[A-Z]:\\)[^\s]+\.log)/g;

export function LogStrip() {
  const logTail = useInstaller((s) => s.logTail);
  const logPath = useInstaller((s) => s.currentLogPath);
  const logExpanded = useInstaller((s) => s.logExpanded);
  const toggleExpanded = useInstaller((s) => s.toggleLogExpanded);
  const transitioning = useInstaller(
    (s) =>
      s.installQueue.length > 0 ||
      Object.values(s.agents).some(
        (a) => a.status === "installing" || a.status === "uninstalling"
      )
  );
  // Resolve "which agent owns the current step" once per render. Mirrors
  // `handleInstallerEvent`'s "step belongs to queue[0]" rule; falls back to
  // whichever agent is currently transitioning when no install queue exists
  // (lifecycle start/stop also emits StepChanged via runLifecycle).
  // Selectors return primitives only so zustand's Object.is comparison
  // doesn't trigger spurious re-renders.
  const activeStepLabel = useInstaller((s) => {
    const headId =
      s.installQueue[0] ??
      (Object.keys(s.agents).find(
        (id) =>
          s.agents[id as keyof typeof s.agents].status === "installing" ||
          s.agents[id as keyof typeof s.agents].status === "uninstalling"
      ) as keyof typeof s.agents | undefined);
    return headId ? s.agents[headId].currentStep : null;
  });
  const activeStepStartedAt = useInstaller((s) => {
    const headId =
      s.installQueue[0] ??
      (Object.keys(s.agents).find(
        (id) =>
          s.agents[id as keyof typeof s.agents].status === "installing" ||
          s.agents[id as keyof typeof s.agents].status === "uninstalling"
      ) as keyof typeof s.agents | undefined);
    return headId ? s.agents[headId].currentStepStartedAt : null;
  });

  const scrollRef = useRef<HTMLDivElement>(null);
  const [copyHint, setCopyHint] = useState<"idle" | "ok" | "err">("idle");
  // 1Hz tick to refresh the elapsed-time chip. Only schedules an interval
  // while there IS a step in progress, so idle sessions don't pay for it.
  const [, setTickNow] = useState(Date.now());
  useEffect(() => {
    if (!activeStepLabel || activeStepStartedAt === null) return;
    const id = setInterval(() => setTickNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [activeStepLabel, activeStepStartedAt]);

  // Auto-scroll to bottom whenever a new line arrives and the panel is open.
  useEffect(() => {
    if (logExpanded && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [logTail.length, logExpanded]);

  const handleCopy = async (e: React.MouseEvent) => {
    e.stopPropagation();
    const text = logTail.join("\n");
    if (!text) return;
    try {
      if (IS_TAURI_ENV) {
        const { copyToClipboard } = await import("@/api/installer");
        await copyToClipboard(text);
      } else {
        await navigator.clipboard.writeText(text);
      }
      setCopyHint("ok");
    } catch (err) {
      console.error("[LogStrip] copy failed:", err);
      setCopyHint("err");
    } finally {
      setTimeout(() => setCopyHint("idle"), 1400);
    }
  };

  const handleOpenFolder = async (e: React.MouseEvent) => {
    e.stopPropagation();
    if (!logPath || !IS_TAURI_ENV) return;
    try {
      const { revealInFolder } = await import("@/api/installer");
      await revealInFolder(logPath);
    } catch (err) {
      console.error("[LogStrip] open folder failed:", err);
    }
  };

  return (
    <div className="flex flex-col border-t border-border bg-foreground/[0.04]">
      {/* Header: always visible. Whole row clickable to toggle. */}
      <button
        type="button"
        onClick={toggleExpanded}
        aria-expanded={logExpanded}
        aria-label={logExpanded ? "收起执行日志" : "展开执行日志"}
        className="flex w-full items-center justify-between px-3 py-1.5 transition-colors hover:bg-foreground/[0.02]"
      >
        <span className="flex min-w-0 flex-1 items-center gap-2">
          <Chevron open={logExpanded} />
          <span className="shrink-0 text-[10px] font-medium uppercase tracking-wide text-muted" lang="en">
            执行日志
          </span>
          {transitioning && (
            <span className="relative inline-flex h-1.5 w-1.5 shrink-0">
              <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-accent opacity-60" />
              <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-accent" />
            </span>
          )}
          {activeStepLabel && (
            <span
              className="min-w-0 truncate text-[11px] text-foreground/90"
              title={activeStepLabel}
            >
              {activeStepLabel}
            </span>
          )}
          {activeStepLabel && activeStepStartedAt !== null && (
            <span className="shrink-0 text-[10px] text-muted tabular-nums" lang="en">
              <ElapsedSince startedAt={activeStepStartedAt} />
            </span>
          )}
          {logTail.length > 0 && (
            <span className="shrink-0 text-[10px] text-muted/70 tabular-nums" lang="en">
              · {logTail.length} 行
            </span>
          )}
        </span>
        <div className="flex items-center gap-0.5">
          <ToolbarBtn
            label={copyHint === "ok" ? "已复制" : copyHint === "err" ? "复制失败" : "复制日志"}
            onClick={handleCopy}
            disabled={logTail.length === 0}
            tone={copyHint === "ok" ? "success" : copyHint === "err" ? "danger" : "neutral"}
          >
            {copyHint === "ok" ? <CheckIcon /> : <CopyIcon />}
          </ToolbarBtn>
          <ToolbarBtn
            label="打开日志所在文件夹"
            onClick={handleOpenFolder}
            disabled={!logPath}
          >
            <FolderIcon />
          </ToolbarBtn>
        </div>
      </button>

      {/* Body: animated max-height + opacity. */}
      <div
        className={cn(
          "overflow-hidden transition-[max-height,opacity] duration-300",
          logExpanded ? "opacity-100" : "opacity-0"
        )}
        style={{
          maxHeight: logExpanded ? `${BODY_HEIGHT + 8}px` : "0px",
          transitionTimingFunction: "cubic-bezier(0.4, 0, 0.2, 1)",
        }}
      >
        <div
          ref={scrollRef}
          className="ued-scroll-thin overflow-y-auto px-3 pb-2 font-mono text-[10px] leading-[14px] text-foreground/75"
          style={{ height: `${BODY_HEIGHT}px` }}
          lang="en"
        >
          {logTail.length === 0 ? (
            <div className="grid h-full place-items-center text-center text-[11px] text-muted/60">
              等待输出…
            </div>
          ) : (
            <ul>
              {logTail.map((line, i) => (
                <li key={i} className="whitespace-pre-wrap break-all">
                  {renderWithPathLinks(line)}
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}

/**
 * Live-updating elapsed-time text for the LogStrip header chip. Formats as
 * `Ns` under 60s, `Mm Ss` for 60s–60min, and `Hh Mm` beyond an hour — keeps
 * the chip narrow even on very long install steps. Refresh cadence is driven
 * by the parent's 1Hz tick (so we don't schedule a second timer here).
 */
function ElapsedSince({ startedAt }: { startedAt: number }) {
  const sec = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
  let text: string;
  if (sec < 60) text = `${sec}s`;
  else if (sec < 3600) text = `${Math.floor(sec / 60)}m ${sec % 60}s`;
  else text = `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m`;
  return <>{text}</>;
}

/** Tokenize a line and wrap *.log absolute paths in a click-to-open button. */
function renderWithPathLinks(line: string) {
  const matches: { text: string; start: number; end: number }[] = [];
  for (const m of line.matchAll(PATH_REGEX)) {
    if (m.index === undefined) continue;
    matches.push({ text: m[0], start: m.index, end: m.index + m[0].length });
  }
  if (matches.length === 0) return line;

  const nodes: React.ReactNode[] = [];
  let cursor = 0;
  for (const [i, m] of matches.entries()) {
    if (m.start > cursor) nodes.push(line.slice(cursor, m.start));
    nodes.push(<PathLink key={`p-${i}-${m.start}`} path={m.text} />);
    cursor = m.end;
  }
  if (cursor < line.length) nodes.push(line.slice(cursor));
  return nodes;
}

function PathLink({ path }: { path: string }) {
  const onClick = async (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    if (!IS_TAURI_ENV) return;
    try {
      const { openPath } = await import("@/api/installer");
      await openPath(path);
    } catch (err) {
      console.error("[PathLink] open failed:", err);
    }
  };
  return (
    <button
      onClick={onClick}
      title={path}
      className="underline decoration-dotted underline-offset-2 text-accent hover:text-foreground"
    >
      {path}
    </button>
  );
}

function ToolbarBtn({
  label,
  onClick,
  disabled,
  tone = "neutral",
  children,
}: {
  label: string;
  onClick: (e: React.MouseEvent) => void;
  disabled?: boolean;
  tone?: "neutral" | "success" | "danger";
  children: React.ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      aria-label={label}
      title={label}
      disabled={disabled}
      className={cn(
        "grid h-6 w-6 place-items-center rounded transition-colors",
        "disabled:cursor-not-allowed disabled:opacity-30",
        tone === "success" && "text-success",
        tone === "danger" && "text-danger",
        tone === "neutral" && "text-muted hover:bg-foreground/[0.06] hover:text-foreground"
      )}
    >
      {children}
    </button>
  );
}

function Chevron({ open }: { open: boolean }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={cn("h-3 w-3 text-muted transition-transform duration-200", !open && "rotate-180")}
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M6 9l6 6 6-6" />
    </svg>
  );
}

function CopyIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <rect x="9" y="9" width="11" height="11" rx="2" />
      <path d="M5 15V6a2 2 0 0 1 2-2h9" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 12l5 5 9-11" />
    </svg>
  );
}

function FolderIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 6.5a2 2 0 0 1 2-2h3.6c.5 0 1 .2 1.4.6L11.4 6H19a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6.5z" />
    </svg>
  );
}
