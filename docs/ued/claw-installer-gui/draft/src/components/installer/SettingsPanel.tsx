import { useState } from "react";
import {
  BrainCircuit,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ExternalLink,
  Eye,
  EyeOff,
  Flame,
  Gift,
  MessageSquare,
  Sparkles,
} from "lucide-react";
import { useInstaller } from "@/store/installer-store";
import { cn } from "@/lib/utils";

// ---- Provider taxonomy --------------------------------------------------------

type ProviderId =
  | "xinyuan"
  | "deepseek"
  | "kimi"
  | "minimax"
  | "custom";

interface KnownProvider {
  id: Exclude<ProviderId, "xinyuan" | "custom">;
  label: string;
  modelPlaceholder: string;
  docsUrl: string;
}

const KNOWN_PROVIDERS: KnownProvider[] = [
  {
    id: "deepseek",
    label: "DeepSeek",
    modelPlaceholder: "e.g. deepseek-chat",
    docsUrl: "https://api-docs.deepseek.com/zh-cn/",
  },
  {
    id: "kimi",
    label: "Kimi",
    modelPlaceholder: "e.g. moonshot-v1-8k",
    docsUrl: "https://www.kimi.com/code/docs/",
  },
  {
    id: "minimax",
    label: "MiniMax",
    modelPlaceholder: "e.g. abab6.5s-chat",
    docsUrl: "https://platform.minimaxi.com/docs/guides/quickstart-preparation",
  },
];

const PROVIDER_LABEL: Record<ProviderId, string> = {
  xinyuan: "心元",
  deepseek: "DeepSeek",
  kimi: "Kimi",
  minimax: "MiniMax",
  custom: "自定义模型供应商",
};

// ---- Data shape ---------------------------------------------------------------

type ApiStyle = "openai" | "anthropic";

const API_STYLE_LABEL: Record<ApiStyle, string> = {
  openai: "OpenAI-compatible",
  anthropic: "Anthropic-compatible",
};

interface KnownCreds {
  apiKey: string;
  modelName: string;
}

interface CustomCreds {
  apiStyle: ApiStyle;
  name: string;
  baseUrl: string;
  apiKey: string;
  modelName: string;
  headers: string;
}

interface ModelDraft {
  active: ProviderId;
  deepseek: KnownCreds;
  kimi: KnownCreds;
  minimax: KnownCreds;
  custom: CustomCreds;
}

const emptyKnown = (): KnownCreds => ({ apiKey: "", modelName: "" });
const emptyCustom = (): CustomCreds => ({
  apiStyle: "openai",
  name: "",
  baseUrl: "",
  apiKey: "",
  modelName: "",
  headers: "",
});

function isKnownFilled(c: KnownCreds) {
  return c.apiKey.trim() !== "" && c.modelName.trim() !== "";
}

function isCustomFilled(c: CustomCreds) {
  return (
    c.name.trim() !== "" &&
    c.baseUrl.trim() !== "" &&
    c.apiKey.trim() !== "" &&
    c.modelName.trim() !== ""
  );
}

function activeProviderSummary(draft: ModelDraft): string {
  switch (draft.active) {
    case "xinyuan":
      return "心元 · 新用户免费用";
    case "custom": {
      const c = draft.custom;
      if (isCustomFilled(c)) return c.name || "自定义模型供应商";
      return "自定义模型供应商 · 未填写";
    }
    default: {
      const creds = draft[draft.active];
      if (isKnownFilled(creds))
        return `${PROVIDER_LABEL[draft.active]} · ${creds.modelName}`;
      return `${PROVIDER_LABEL[draft.active]} · 未填写`;
    }
  }
}

// ---- Channel shape ------------------------------------------------------------

type ChannelId = "wechat" | "feishu" | "dingtalk" | "bubbolink";
const CHANNEL_IDS: ChannelId[] = ["wechat", "feishu", "dingtalk", "bubbolink"];
const CHANNEL_LABELS: Record<ChannelId, string> = {
  wechat: "微信",
  feishu: "飞书",
  dingtalk: "钉钉",
  bubbolink: "BubboLink",
};

// ---- Navigation ---------------------------------------------------------------

type View =
  | { kind: "root" }
  | { kind: "model" }
  | { kind: "channel" };

// ---- L1: root -----------------------------------------------------------------

function RootPage({
  agentName,
  draft,
  channel,
  go,
}: {
  agentName: string;
  draft: ModelDraft;
  channel: ChannelId;
  go: (v: View) => void;
}) {
  return (
    <div className="space-y-2.5">
      <SectionCard
        icon={<BrainCircuit className="h-3.5 w-3.5" />}
        title="模型配置"
        summary={activeProviderSummary(draft)}
        accent
        onClick={() => go({ kind: "model" })}
      />
      <SectionCard
        icon={<MessageSquare className="h-3.5 w-3.5" />}
        title="通道配置"
        summary={`当前：${CHANNEL_LABELS[channel]}`}
        onClick={() => go({ kind: "channel" })}
      />
      <p className="pt-1 text-[10px] text-muted" lang="en">
        Configure {agentName} agent.
      </p>
    </div>
  );
}

function SectionCard({
  icon,
  title,
  summary,
  accent,
  onClick,
}: {
  icon: React.ReactNode;
  title: string;
  summary: string;
  accent?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex w-full items-center gap-3 rounded-md border border-border bg-surface px-3.5 py-3 text-left transition-colors",
        "hover:border-foreground/30 hover:bg-background",
      )}
    >
      <span
        className={cn(
          "grid h-7 w-7 shrink-0 place-items-center rounded-md",
          accent ? "bg-accent/10 text-accent" : "bg-foreground/[0.06] text-muted",
        )}
      >
        {icon}
      </span>
      <span className="min-w-0 flex-1 leading-tight">
        <span className="block text-sm font-semibold text-foreground">
          {title}
        </span>
        <span className="mt-0.5 block truncate text-[11px] text-muted">
          {summary}
        </span>
      </span>
      <ChevronRight className="h-3.5 w-3.5 shrink-0 text-muted" />
    </button>
  );
}

// ---- L2: model page (provider list, inline expansion) -------------------------

function ModelPage({
  draft,
  setDraft,
}: {
  draft: ModelDraft;
  setDraft: React.Dispatch<React.SetStateAction<ModelDraft>>;
}) {
  const setActive = (id: ProviderId) =>
    setDraft((d) => ({ ...d, active: id }));

  return (
    <div className="space-y-2">
      <XinyuanCard
          active={draft.active === "xinyuan"}
          onActivate={() => setActive("xinyuan")}
        />
        {KNOWN_PROVIDERS.map((p) => (
          <KnownProviderCard
            key={p.id}
            provider={p}
            creds={draft[p.id]}
            active={draft.active === p.id}
            onActivate={() => setActive(p.id)}
            onChange={(patch) =>
              setDraft((d) => ({ ...d, [p.id]: { ...d[p.id], ...patch } }))
            }
          />
        ))}
      <CustomProviderCard
        creds={draft.custom}
        active={draft.active === "custom"}
        onActivate={() => setActive("custom")}
        onChange={(patch) =>
          setDraft((d) => ({ ...d, custom: { ...d.custom, ...patch } }))
        }
      />
    </div>
  );
}

// ---- Xinyuan card -------------------------------------------------------------

function XinyuanCard({
  active,
  onActivate,
}: {
  active: boolean;
  onActivate: () => void;
}) {
  return (
    <div
      className={cn(
        "overflow-hidden rounded-md border transition-colors",
        active ? "border-accent" : "border-accent/40",
      )}
    >
      <div className="relative flex items-center gap-2 bg-gradient-to-r from-accent/[0.18] via-accent/[0.10] to-accent/[0.04] px-3.5 py-2.5">
        <span className="grid h-7 w-7 shrink-0 place-items-center rounded-md bg-accent text-surface">
          <Gift className="h-3.5 w-3.5" />
        </span>
        <div className="min-w-0 flex-1 leading-tight">
          <div className="text-[13px] font-semibold text-foreground">
            新用户免费用
          </div>
          <div className="mt-0.5 text-[10.5px] text-accent/90">
            扫码即享 · 心元大模型限时福利
          </div>
        </div>
        <span className="inline-flex shrink-0 items-center gap-1 rounded-sm bg-accent px-1.5 py-0.5 text-[10px] font-medium text-surface">
          <Flame className="h-3 w-3" />
          优惠
        </span>
      </div>

      <button
        type="button"
        onClick={onActivate}
        aria-pressed={active}
        className={cn(
          "flex w-full items-center gap-2 border-t border-border/60 px-3.5 py-2.5 text-left transition-colors",
          active ? "bg-accent/[0.04]" : "hover:bg-background",
        )}
      >
        <ProviderDot active={active} />
        <span
          className={cn(
            "flex-1 text-sm font-medium",
            active ? "text-accent" : "text-foreground",
          )}
        >
          心元
        </span>
        <span className="rounded-sm bg-accent/15 px-1.5 py-0.5 text-[10px] font-medium text-accent">
          推荐
        </span>
        <ChevronDown
          className={cn(
            "h-3.5 w-3.5 text-muted transition-transform",
            active ? "rotate-0" : "-rotate-90",
          )}
        />
      </button>

      {active && (
        <div className="border-t border-border/60 px-3.5 py-3">
          <p className="text-[11px] leading-relaxed text-muted">
            心元 Provider 配置即将开放。届时新用户可在此一键领取 500M tokens
            额度。
          </p>
          <button
            type="button"
            disabled
            className="mt-2 inline-flex cursor-not-allowed items-center gap-1.5 rounded border border-border bg-background px-2.5 py-1 text-[11px] font-medium text-muted"
          >
            <Sparkles className="h-3 w-3" />
            敬请期待
          </button>
        </div>
      )}
    </div>
  );
}

// ---- Known provider card ------------------------------------------------------

function KnownProviderCard({
  provider,
  creds,
  active,
  onActivate,
  onChange,
}: {
  provider: KnownProvider;
  creds: KnownCreds;
  active: boolean;
  onActivate: () => void;
  onChange: (patch: Partial<KnownCreds>) => void;
}) {
  const [showKey, setShowKey] = useState(false);
  const filled = isKnownFilled(creds);

  return (
    <div
      className={cn(
        "overflow-hidden rounded-md border transition-colors",
        active ? "border-accent" : "border-border",
      )}
    >
      <button
        type="button"
        onClick={onActivate}
        aria-pressed={active}
        className={cn(
          "flex w-full items-center gap-2 px-3.5 py-2.5 text-left transition-colors",
          active ? "bg-accent/[0.04]" : "hover:bg-background",
        )}
      >
        <ProviderDot active={active} />
        <span
          className={cn(
            "flex-1 text-sm font-medium",
            active ? "text-accent" : "text-foreground",
          )}
        >
          {provider.label}
        </span>
        {filled && (
          <span className="rounded-sm bg-success/10 px-1.5 py-0.5 text-[10px] font-medium text-success">
            已配置
          </span>
        )}
        <ChevronDown
          className={cn(
            "h-3.5 w-3.5 text-muted transition-transform",
            active ? "rotate-0" : "-rotate-90",
          )}
        />
      </button>

      {active && (
        <div className="space-y-3 border-t border-border/60 px-3.5 py-3">
          <a
            href={provider.docsUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1 text-[11px] text-accent hover:underline"
          >
            查看 {provider.label} API 文档
            <ExternalLink className="h-3 w-3" />
          </a>

          <div className="space-y-1">
            <div className="flex items-center justify-between">
              <label className="text-[11px] text-muted">API Key</label>
              <button
                type="button"
                onClick={() => setShowKey((v) => !v)}
                aria-label={showKey ? "隐藏 API Key" : "显示 API Key"}
                className="inline-flex items-center gap-1 text-[11px] text-muted transition-colors hover:text-foreground"
              >
                {showKey ? (
                  <>
                    <EyeOff className="h-3 w-3" /> 隐藏
                  </>
                ) : (
                  <>
                    <Eye className="h-3 w-3" /> 显示
                  </>
                )}
              </button>
            </div>
            <textarea
              rows={2}
              value={creds.apiKey}
              onChange={(e) => onChange({ apiKey: e.target.value })}
              placeholder="sk-..."
              spellCheck={false}
              className={cn(
                "block w-full max-w-full resize-y rounded border border-border bg-background px-2.5 py-1.5",
                "font-mono text-xs leading-relaxed placeholder:text-muted",
                "focus:border-accent focus:outline-none",
                !showKey && "[-webkit-text-security:disc] [text-security:disc]",
              )}
            />
          </div>

          <div className="space-y-1">
            <label className="text-[11px] text-muted">模型名称</label>
            <input
              type="text"
              value={creds.modelName}
              onChange={(e) => onChange({ modelName: e.target.value })}
              placeholder={provider.modelPlaceholder}
              className="block w-full max-w-full rounded border border-border bg-background px-2.5 py-1.5 text-sm text-foreground placeholder:text-muted focus:border-accent focus:outline-none"
            />
          </div>
        </div>
      )}
    </div>
  );
}

// ---- Custom provider card -----------------------------------------------------

function CustomProviderCard({
  creds,
  active,
  onActivate,
  onChange,
}: {
  creds: CustomCreds;
  active: boolean;
  onActivate: () => void;
  onChange: (patch: Partial<CustomCreds>) => void;
}) {
  const [showKey, setShowKey] = useState(false);
  const [headersOpen, setHeadersOpen] = useState(false);
  const filled = isCustomFilled(creds);

  return (
    <div
      className={cn(
        "overflow-hidden rounded-md border border-dashed transition-colors",
        active
          ? "border-accent border-solid"
          : "border-border hover:border-foreground/30",
      )}
    >
      <button
        type="button"
        onClick={onActivate}
        aria-pressed={active}
        className={cn(
          "flex w-full items-center gap-2 px-3.5 py-2.5 text-left transition-colors",
          active ? "bg-accent/[0.04]" : "hover:bg-background",
        )}
      >
        <ProviderDot active={active} />
        <span
          className={cn(
            "flex-1 text-sm font-medium",
            active ? "text-accent" : "text-foreground",
          )}
        >
          {creds.name.trim() || "自定义模型供应商"}
        </span>
        {filled && (
          <span className="rounded-sm bg-success/10 px-1.5 py-0.5 text-[10px] font-medium text-success">
            已配置
          </span>
        )}
        <ChevronDown
          className={cn(
            "h-3.5 w-3.5 text-muted transition-transform",
            active ? "rotate-0" : "-rotate-90",
          )}
        />
      </button>

      {active && (
        <div className="space-y-3 border-t border-border/60 px-3.5 py-3">
          <div className="space-y-1">
            <label className="text-[11px] text-muted">API 风格</label>
            <div
              role="radiogroup"
              aria-label="API 风格"
              className="grid grid-cols-2 gap-1 rounded border border-border bg-background p-0.5"
            >
              {(["openai", "anthropic"] as ApiStyle[]).map((style) => {
                const selected = creds.apiStyle === style;
                return (
                  <button
                    key={style}
                    type="button"
                    role="radio"
                    aria-checked={selected}
                    onClick={() => onChange({ apiStyle: style })}
                    className={cn(
                      "rounded-sm px-2.5 py-1.5 text-[11px] font-medium transition-colors",
                      selected
                        ? "bg-accent text-surface"
                        : "text-muted hover:text-foreground",
                    )}
                  >
                    <span lang="en">{API_STYLE_LABEL[style]}</span>
                  </button>
                );
              })}
            </div>
          </div>

          <div className="space-y-1">
            <label className="text-[11px] text-muted">名称（用于本机识别）</label>
            <input
              type="text"
              value={creds.name}
              onChange={(e) => onChange({ name: e.target.value })}
              placeholder="e.g. 内部网关"
              className="block w-full max-w-full rounded border border-border bg-background px-2.5 py-1.5 text-sm text-foreground placeholder:text-muted focus:border-accent focus:outline-none"
            />
          </div>

          <div className="space-y-1">
            <label className="text-[11px] text-muted" lang="en">
              Base URL
            </label>
            <input
              type="text"
              value={creds.baseUrl}
              onChange={(e) => onChange({ baseUrl: e.target.value })}
              placeholder={
                creds.apiStyle === "anthropic"
                  ? "https://api.example.com"
                  : "https://api.example.com/v1"
              }
              spellCheck={false}
              className="block w-full max-w-full rounded border border-border bg-background px-2.5 py-1.5 font-mono text-xs text-foreground placeholder:text-muted focus:border-accent focus:outline-none"
            />
          </div>

          <div className="space-y-1">
            <div className="flex items-center justify-between">
              <label className="text-[11px] text-muted">API Key</label>
              <button
                type="button"
                onClick={() => setShowKey((v) => !v)}
                className="inline-flex items-center gap-1 text-[11px] text-muted transition-colors hover:text-foreground"
              >
                {showKey ? (
                  <>
                    <EyeOff className="h-3 w-3" /> 隐藏
                  </>
                ) : (
                  <>
                    <Eye className="h-3 w-3" /> 显示
                  </>
                )}
              </button>
            </div>
            <textarea
              rows={2}
              value={creds.apiKey}
              onChange={(e) => onChange({ apiKey: e.target.value })}
              placeholder="sk-..."
              spellCheck={false}
              className={cn(
                "block w-full max-w-full resize-y rounded border border-border bg-background px-2.5 py-1.5",
                "font-mono text-xs leading-relaxed placeholder:text-muted",
                "focus:border-accent focus:outline-none",
                !showKey && "[-webkit-text-security:disc] [text-security:disc]",
              )}
            />
          </div>

          <div className="space-y-1">
            <label className="text-[11px] text-muted">模型名称</label>
            <input
              type="text"
              value={creds.modelName}
              onChange={(e) => onChange({ modelName: e.target.value })}
              placeholder={
                creds.apiStyle === "anthropic"
                  ? "e.g. claude-sonnet-4-6"
                  : "e.g. gpt-4o-mini"
              }
              className="block w-full max-w-full rounded border border-border bg-background px-2.5 py-1.5 text-sm text-foreground placeholder:text-muted focus:border-accent focus:outline-none"
            />
          </div>

          <div>
            <button
              type="button"
              onClick={() => setHeadersOpen((v) => !v)}
              className="inline-flex items-center gap-1 text-[11px] text-muted transition-colors hover:text-foreground"
            >
              {headersOpen ? (
                <ChevronDown className="h-3 w-3" />
              ) : (
                <ChevronRight className="h-3 w-3" />
              )}
              附加 Headers（可选）
            </button>
            {headersOpen && (
              <textarea
                rows={3}
                value={creds.headers}
                onChange={(e) => onChange({ headers: e.target.value })}
                placeholder={"X-Org-Id: acme\nX-Trace: 1"}
                spellCheck={false}
                className="mt-2 block w-full max-w-full resize-y rounded border border-border bg-background px-2.5 py-1.5 font-mono text-xs leading-relaxed text-foreground placeholder:text-muted focus:border-accent focus:outline-none"
              />
            )}
          </div>
        </div>
      )}
    </div>
  );
}

// ---- Shared: radio dot --------------------------------------------------------

function ProviderDot({ active }: { active: boolean }) {
  return (
    <span
      className={cn(
        "grid h-3.5 w-3.5 shrink-0 place-items-center rounded-full border",
        active ? "border-accent" : "border-border",
      )}
    >
      {active && <span className="h-1.5 w-1.5 rounded-full bg-accent" />}
    </span>
  );
}

// ---- L2: channel page ---------------------------------------------------------

function ChannelPage({
  channel,
  setChannel,
}: {
  channel: ChannelId;
  setChannel: (c: ChannelId) => void;
}) {
  return (
    <div role="radiogroup" aria-label="IM 通道" className="space-y-2">
      {CHANNEL_IDS.map((id) => {
        const selected = channel === id;
        return (
          <label
            key={id}
            className={cn(
              "flex cursor-pointer items-center gap-3 rounded-md border px-3.5 py-2.5 transition-colors",
              selected
                ? "border-accent bg-accent/[0.04]"
                : "border-border hover:border-foreground/30",
            )}
          >
            <input
              type="radio"
              name="channel"
              value={id}
              checked={selected}
              onChange={() => setChannel(id)}
              className="h-3.5 w-3.5 shrink-0 accent-accent"
            />
            <span
              className={cn(
                "text-sm font-medium",
                selected ? "text-accent" : "text-foreground",
              )}
            >
              {CHANNEL_LABELS[id]}
            </span>
          </label>
        );
      })}
    </div>
  );
}

// ---- Main component -----------------------------------------------------------

const initialDraft: ModelDraft = {
  active: "xinyuan",
  deepseek: emptyKnown(),
  kimi: emptyKnown(),
  minimax: emptyKnown(),
  custom: emptyCustom(),
};

export function SettingsPanel() {
  const target = useInstaller((s) => s.settingsTarget);
  const agent = useInstaller((s) => (target ? s.agents[target] : null));
  const close = useInstaller((s) => s.closeSettings);

  const open = Boolean(target && agent);

  const [draft, setDraft] = useState<ModelDraft>(initialDraft);
  const [channel, setChannel] = useState<ChannelId>("wechat");
  const [view, setView] = useState<View>({ kind: "root" });

  const agentName = agent?.name ?? "Agent";

  let title: string;
  switch (view.kind) {
    case "root":
      title = `${agentName} 配置`;
      break;
    case "model":
      title = "模型配置";
      break;
    case "channel":
      title = "通道配置";
      break;
  }

  function handleBack() {
    if (view.kind === "root") {
      close();
      setView({ kind: "root" });
    } else {
      setView({ kind: "root" });
    }
  }

  return (
    <section
      aria-hidden={!open}
      className={cn(
        "absolute inset-0 z-20 flex flex-col bg-surface",
        "transition-transform duration-200 ease-out",
        open ? "translate-x-0" : "translate-x-full pointer-events-none",
      )}
    >
      <header className="flex items-center gap-2 border-b border-border px-3 py-3">
        <button
          onClick={handleBack}
          aria-label="返回"
          className="grid h-7 w-7 shrink-0 place-items-center rounded text-muted transition-colors hover:bg-background hover:text-foreground"
        >
          <ChevronLeft className="h-4 w-4" />
        </button>
        <div className="min-w-0 flex-1 leading-tight">
          <div className="truncate text-sm font-semibold">{title}</div>
          {view.kind !== "root" && (
            <div className="mt-0.5 truncate text-[10px] text-muted">
              {agentName} 配置
            </div>
          )}
        </div>
      </header>

      <div className="flex-1 overflow-y-auto ued-scroll-thin">
        <div className="mx-auto w-full max-w-md space-y-4 px-4 py-5">
          {view.kind === "root" && (
            <RootPage
              agentName={agentName}
              draft={draft}
              channel={channel}
              go={setView}
            />
          )}
          {view.kind === "model" && (
            <ModelPage draft={draft} setDraft={setDraft} />
          )}
          {view.kind === "channel" && (
            <ChannelPage channel={channel} setChannel={setChannel} />
          )}
        </div>
      </div>
    </section>
  );
}
