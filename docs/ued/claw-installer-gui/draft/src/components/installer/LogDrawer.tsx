import { useEffect, useRef } from "react";
import { useInstaller } from "@/store/installer-store";
import { cn } from "@/lib/utils";

export function LogDrawer() {
  const open = useInstaller((s) => s.logDrawerOpen);
  const toggle = useInstaller((s) => s.toggleLogDrawer);
  const lines = useInstaller((s) => s.logTail);
  const queue = useInstaller((s) => s.installQueue);
  const installing = queue.length > 0;
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (open && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [lines.length, open]);

  return (
    <div
      className={cn(
        "pointer-events-none fixed inset-x-0 bottom-0 z-30 flex justify-center px-6 pb-6 transition-transform duration-200",
        !open && "translate-y-full"
      )}
    >
      <section
        className={cn(
          "pointer-events-auto flex h-[42vh] w-full max-w-4xl flex-col rounded-lg border border-border bg-surface",
          "shadow-[0_-12px_32px_-12px_rgba(0,0,0,0.18)]"
        )}
      >
        <header className="flex items-center justify-between border-b border-border px-4 py-2.5">
          <div className="flex items-center gap-2">
            <span className={cn("h-1.5 w-1.5 rounded-full", installing ? "bg-accent animate-pulse" : "bg-muted")} />
            <h3 className="text-xs font-semibold uppercase tracking-wide text-foreground" lang="en">
              Install Log
            </h3>
            <span className="text-[11px] text-muted">
              {installing ? `运行中 · 共 ${lines.length} 行` : `空闲 · 共 ${lines.length} 行`}
            </span>
          </div>
          <button
            onClick={toggle}
            className="rounded p-1 text-muted hover:bg-background hover:text-foreground"
            aria-label="关闭"
          >
            <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M6 6l12 12M18 6l-12 12" strokeLinecap="round" />
            </svg>
          </button>
        </header>
        <div
          ref={scrollRef}
          className="flex-1 overflow-y-auto bg-background px-4 py-3 font-mono text-[12px] leading-relaxed"
        >
          {lines.length === 0 ? (
            <div className="grid h-full place-items-center text-xs text-muted">
              还没有日志。开始一次安装就能看到实时输出。
            </div>
          ) : (
            <ul>
              {lines.map((l, i) => (
                <li
                  key={i}
                  className={cn(
                    "whitespace-pre-wrap",
                    l.level === "error" ? "text-danger" : "text-foreground"
                  )}
                  lang="en"
                >
                  <span className="mr-3 text-muted">{l.ts}</span>
                  <span className="mr-2 text-muted">[{l.step}]</span>
                  {l.line}
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  );
}
