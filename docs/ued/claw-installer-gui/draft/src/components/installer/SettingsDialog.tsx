import {
  useInstaller,
  type AgentState,
  type HermesConfig,
  type OpenclawConfig,
} from "@/store/installer-store";
import { cn } from "@/lib/utils";

export function SettingsDialog() {
  const target = useInstaller((s) => s.settingsTarget);
  const agent = useInstaller((s) => (target ? s.agents[target] : null));
  const close = useInstaller((s) => s.closeSettings);

  if (!target || !agent) return null;

  return (
    <div className="fixed inset-0 z-40 grid place-items-center bg-foreground/30 px-6">
      <div className="w-full max-w-md overflow-hidden rounded-lg border border-border bg-surface">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <div>
            <h2 className="text-sm font-semibold">{agent.name} 配置</h2>
            <p className="text-[11px] text-muted">{agent.tagline} · 修改后立即生效</p>
          </div>
          <button
            onClick={close}
            aria-label="关闭"
            className="rounded p-1 text-muted hover:bg-background hover:text-foreground"
          >
            <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M6 6l12 12M18 6l-12 12" strokeLinecap="round" />
            </svg>
          </button>
        </header>
        <div className="max-h-[60vh] overflow-y-auto px-4 py-4">
          {agent.id === "openclaw" ? <OpenclawFields agent={agent} /> : <HermesFields agent={agent} />}
        </div>
        <footer className="flex items-center justify-end gap-2 border-t border-border px-4 py-3">
          <button
            onClick={close}
            className="rounded bg-accent px-3 py-1.5 text-sm font-medium text-white hover:opacity-90"
          >
            完成
          </button>
        </footer>
      </div>
    </div>
  );
}

function OpenclawFields({ agent }: { agent: AgentState }) {
  const update = useInstaller((s) => s.updateAgentConfig);
  const c = agent.config as OpenclawConfig;
  return (
    <div className="space-y-4">
      <ChoiceGroup
        label="Channel"
        hint="更新通道"
        value={c.channel}
        onChange={(v) => update(agent.id, { channel: v as OpenclawConfig["channel"] })}
        options={[
          { value: "stable", label: "Stable", note: "推荐 · 稳定版本" },
          { value: "beta", label: "Beta", note: "预览功能" },
          { value: "nightly", label: "Nightly", note: "每日构建" },
        ]}
      />
      <ChoiceGroup
        label="默认模型供应商"
        hint="default model provider"
        value={c.provider}
        onChange={(v) => update(agent.id, { provider: v as OpenclawConfig["provider"] })}
        options={[
          { value: "anthropic", label: "Anthropic", note: "Claude" },
          { value: "openai", label: "OpenAI", note: "GPT" },
          { value: "gemini", label: "Google", note: "Gemini" },
        ]}
      />
    </div>
  );
}

function HermesFields({ agent }: { agent: AgentState }) {
  const update = useInstaller((s) => s.updateAgentConfig);
  const c = agent.config as HermesConfig;
  return (
    <div className="space-y-4">
      <ChoiceGroup
        label="浏览器引擎"
        hint="browser engine"
        value={c.engine}
        onChange={(v) => update(agent.id, { engine: v as HermesConfig["engine"] })}
        options={[
          { value: "chromium", label: "Chromium", note: "默认" },
          { value: "firefox", label: "Firefox" },
          { value: "webkit", label: "WebKit", note: "Safari 内核" },
        ]}
      />
      <ChoiceGroup
        label="默认设备"
        hint="default user agent"
        value={c.userAgent}
        onChange={(v) => update(agent.id, { userAgent: v as HermesConfig["userAgent"] })}
        options={[
          { value: "desktop", label: "桌面" },
          { value: "mobile", label: "移动" },
        ]}
      />
    </div>
  );
}

function ChoiceGroup({
  label,
  hint,
  value,
  onChange,
  options,
}: {
  label: string;
  hint: string;
  value: string;
  onChange: (v: string) => void;
  options: ReadonlyArray<{ value: string; label: string; note?: string }>;
}) {
  return (
    <div className="space-y-1.5">
      <div className="flex items-baseline justify-between gap-2">
        <span className="text-xs font-medium text-foreground">{label}</span>
        <span className="text-[10px] text-muted" lang="en">
          {hint}
        </span>
      </div>
      <div className="grid gap-1.5">
        {options.map((o) => {
          const active = o.value === value;
          return (
            <button
              key={o.value}
              onClick={() => onChange(o.value)}
              className={cn(
                "flex items-center justify-between gap-3 rounded border px-3 py-2 text-left transition-colors",
                active
                  ? "border-accent bg-accent/5"
                  : "border-border bg-background hover:border-foreground/30"
              )}
            >
              <span className="flex flex-col">
                <span className="text-sm font-medium text-foreground">{o.label}</span>
                {o.note && <span className="text-[11px] text-muted">{o.note}</span>}
              </span>
              <span
                className={cn(
                  "grid h-4 w-4 shrink-0 place-items-center rounded-full border",
                  active ? "border-accent" : "border-border"
                )}
              >
                {active && <span className="h-2 w-2 rounded-full bg-accent" />}
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
