import { useRef, useState } from "react";
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
//
// v4: 通道不再是 4 选 1。BubboLink 是 GUI 内可直接完成配对的"动作通道"；
// 微信 / 飞书 / 钉钉 是"参考文档通道"（用户到上游平台自己配）。L1 卡的
// summary 反映 BubboLink 配对状态。详见 .ued/brief.md §v4。

type ChannelId = "wechat" | "feishu" | "dingtalk" | "bubbolink";
const CHANNEL_LABELS: Record<ChannelId, string> = {
  wechat: "微信",
  feishu: "飞书",
  dingtalk: "钉钉",
  bubbolink: "BubboLink",
};

interface DocChannelMeta {
  id: Exclude<ChannelId, "bubbolink">;
  docsUrl: string;
  blurb: string;
}

const DOC_CHANNELS: DocChannelMeta[] = [
  {
    id: "wechat",
    docsUrl: "https://docs.openclaw.ai/channels/wechat",
    blurb: "OpenClaw 个人微信接入指南",
  },
  {
    id: "feishu",
    docsUrl: "https://docs.openclaw.ai/channels/feishu",
    blurb: "OpenClaw 飞书 / Lark 接入指南",
  },
  {
    id: "dingtalk",
    docsUrl: "https://github.com/DingTalk-Real-AI/dingtalk-openclaw-connector",
    blurb: "官方 OpenClaw 钉钉 Channel 插件",
  },
];

const BUBBOLINK_INTRO_URL = "https://www.npmjs.com/package/@bubbolink/cli";

// ---- Navigation ---------------------------------------------------------------

type View =
  | { kind: "root" }
  | { kind: "model" }
  | { kind: "channel" };

// ---- L1: root -----------------------------------------------------------------

function RootPage({
  agentName,
  draft,
  paired,
  go,
}: {
  agentName: string;
  draft: ModelDraft;
  paired: boolean;
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
        summary={paired ? "BubboLink · 已配对" : "BubboLink · 未配对"}
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
//
// Layout (v4): BubboLink on top with accent outline + "推荐" badge — the only
// channel actually configurable in-GUI. Below: 3 doc-link cards (微信/飞书/钉钉)
// that just open external docs in the system browser.

function ChannelPage({
  paired,
  onPair,
}: {
  paired: boolean;
  onPair: () => void;
}) {
  return (
    <div className="space-y-2.5">
      <BubboLinkCard paired={paired} onPair={onPair} />
      {DOC_CHANNELS.map((c) => (
        <DocChannelCard key={c.id} channel={c} />
      ))}
    </div>
  );
}

function DocChannelCard({ channel }: { channel: DocChannelMeta }) {
  return (
    <button
      type="button"
      onClick={() => window.open(channel.docsUrl, "_blank", "noopener")}
      className={cn(
        "flex w-full items-center gap-3 rounded-md border border-border bg-surface px-3.5 py-3 text-left transition-colors",
        "hover:border-foreground/30 hover:bg-background",
      )}
    >
      <span className="min-w-0 flex-1 leading-tight">
        <span className="block text-sm font-medium text-foreground">
          {CHANNEL_LABELS[channel.id]}
        </span>
        <span className="mt-0.5 block truncate text-[11px] text-muted">
          {channel.blurb}
        </span>
      </span>
      <ExternalLink className="h-3.5 w-3.5 shrink-0 text-muted" />
    </button>
  );
}

type PairState =
  | { kind: "idle" }
  | { kind: "pairing" }
  | { kind: "error"; message: string };

function BubboLinkCard({
  paired,
  onPair,
}: {
  paired: boolean;
  onPair: () => void;
}) {
  const [code, setCode] = useState("");
  const [state, setState] = useState<PairState>({ kind: "idle" });

  const canPair = /^\d{4}$/.test(code) && state.kind !== "pairing";

  // Prototype-only stub: simulate the bubbolink CLI roundtrip. Even pairs land
  // as success; odd-sum codes fail so designers can preview the error state.
  async function simulatePair() {
    setState({ kind: "pairing" });
    await new Promise((r) => setTimeout(r, 700));
    const digits = code.split("").map((c) => Number.parseInt(c, 10));
    const sum = digits.reduce((a, b) => a + b, 0);
    if (sum % 2 === 1) {
      setState({
        kind: "error",
        message: "pair-bubbolink: 配对码已过期，请回到 BubboLink App 重新生成",
      });
      return;
    }
    onPair();
    setState({ kind: "idle" });
    setCode("");
  }

  return (
    <div
      className={cn(
        "overflow-hidden rounded-md border-2 transition-colors",
        paired ? "border-success/40" : "border-accent",
      )}
    >
      <div className="bg-gradient-to-r from-accent/[0.10] via-accent/[0.04] to-transparent px-3.5 py-3">
        <div className="flex items-start gap-2">
          <div className="min-w-0 flex-1 leading-tight">
            <div className="flex items-center gap-2">
              <span className="text-sm font-semibold text-foreground">
                {CHANNEL_LABELS.bubbolink}
              </span>
              <span className="inline-flex items-center gap-0.5 rounded-sm bg-accent px-1.5 py-0.5 text-[10px] font-medium text-surface">
                <Sparkles className="h-2.5 w-2.5" />
                推荐
              </span>
              {paired && (
                <span className="rounded-sm bg-success/10 px-1.5 py-0.5 text-[10px] font-medium text-success">
                  已配对
                </span>
              )}
            </div>
            <p className="mt-0.5 text-[11px] leading-relaxed text-muted">
              从 BubboLink App 读取 4 位配对码，在本机完成绑定。
            </p>
            <button
              type="button"
              onClick={() =>
                window.open(BUBBOLINK_INTRO_URL, "_blank", "noopener")
              }
              className="mt-1 inline-flex items-center gap-1 text-[11px] text-accent hover:underline"
            >
              何为 BubboLink？
              <ExternalLink className="h-3 w-3" />
            </button>
          </div>
        </div>
      </div>

      <div className="space-y-3 border-t border-border/60 bg-background/40 px-3.5 py-3.5">
        <label className="block text-[11px] text-muted">
          配对码<span aria-hidden className="ml-0.5 text-danger">*</span>
        </label>
        <div className="flex justify-center">
          <OtpInput
            length={4}
            value={code}
            onChange={(v) => {
              setCode(v);
              if (state.kind === "error") setState({ kind: "idle" });
            }}
            disabled={state.kind === "pairing"}
          />
        </div>
        <button
          type="button"
          onClick={() => void simulatePair()}
          disabled={!canPair}
          className={cn(
            "inline-flex w-full items-center justify-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition-colors",
            canPair
              ? "bg-accent text-surface hover:opacity-90"
              : "cursor-not-allowed bg-foreground/10 text-muted",
          )}
        >
          {state.kind === "pairing" ? (
            <>
              <span className="h-3 w-3 animate-spin rounded-full border border-surface/40 border-t-surface" />
              配对中…
            </>
          ) : paired ? (
            "重新配对"
          ) : (
            "配对"
          )}
        </button>
        {state.kind === "error" && (
          <pre className="mt-1 max-h-28 overflow-auto whitespace-pre-wrap rounded border border-danger/30 bg-danger/[0.04] px-2.5 py-2 font-mono text-[10.5px] leading-snug text-danger">
            {state.message}
          </pre>
        )}
      </div>
    </div>
  );
}

/**
 * Fixed-length OTP input: `length` separate single-digit cells, auto-advance
 * on input, Backspace returns to the previous cell. `value` is the joined
 * digit string (0..length chars). Non-digit input is silently dropped.
 *
 * UED v4: 加大 OTP 格 + 加粗间距 (h-12 w-12 / gap-2.5) per Phase-1 decision.
 */
function OtpInput({
  length,
  value,
  onChange,
  disabled,
}: {
  length: number;
  value: string;
  onChange: (next: string) => void;
  disabled?: boolean;
}) {
  const refs = useRef<(HTMLInputElement | null)[]>([]);
  const digits = Array.from({ length }, (_, i) => value[i] ?? "");

  function setAt(i: number, ch: string) {
    const arr = digits.slice();
    arr[i] = ch;
    onChange(arr.join("").slice(0, length));
  }

  function focusAt(i: number) {
    const el = refs.current[i];
    if (el) {
      el.focus();
      el.select();
    }
  }

  function onCellChange(i: number, raw: string) {
    const d = raw.replace(/\D+/g, "").slice(-1);
    if (!d) return;
    setAt(i, d);
    if (i < length - 1) focusAt(i + 1);
  }

  function onCellKeyDown(
    i: number,
    e: React.KeyboardEvent<HTMLInputElement>,
  ) {
    if (e.key === "Backspace") {
      e.preventDefault();
      if (digits[i]) {
        setAt(i, "");
      } else if (i > 0) {
        setAt(i - 1, "");
        focusAt(i - 1);
      }
    } else if (e.key === "ArrowLeft" && i > 0) {
      e.preventDefault();
      focusAt(i - 1);
    } else if (e.key === "ArrowRight" && i < length - 1) {
      e.preventDefault();
      focusAt(i + 1);
    }
  }

  function onCellPaste(
    i: number,
    e: React.ClipboardEvent<HTMLInputElement>,
  ) {
    const txt = e.clipboardData.getData("text").replace(/\D+/g, "");
    if (!txt) return;
    e.preventDefault();
    const arr = digits.slice();
    let cursor = i;
    for (const ch of txt) {
      if (cursor >= length) break;
      arr[cursor++] = ch;
    }
    onChange(arr.join("").slice(0, length));
    focusAt(Math.min(cursor, length - 1));
  }

  return (
    <div className="flex items-center gap-2.5">
      {digits.map((d, i) => (
        <input
          key={i}
          ref={(el) => {
            refs.current[i] = el;
          }}
          type="text"
          inputMode="numeric"
          autoComplete="one-time-code"
          maxLength={1}
          value={d}
          disabled={disabled}
          onChange={(e) => onCellChange(i, e.target.value)}
          onKeyDown={(e) => onCellKeyDown(i, e)}
          onPaste={(e) => onCellPaste(i, e)}
          onFocus={(e) => e.currentTarget.select()}
          aria-label={`配对码第 ${i + 1} 位`}
          className={cn(
            "h-12 w-12 rounded-xl border-2 bg-background/60 text-center font-mono text-xl text-foreground caret-accent",
            "transition-colors focus:border-accent focus:bg-surface focus:shadow-[0_0_0_4px_rgba(99,102,241,0.15)] focus:outline-none",
            d ? "border-border" : "border-border/60",
            disabled && "cursor-not-allowed opacity-60",
          )}
        />
      ))}
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
  const [bubbolinkPairedAt, setBubbolinkPairedAt] = useState<number | null>(
    null,
  );
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
              paired={bubbolinkPairedAt !== null}
              go={setView}
            />
          )}
          {view.kind === "model" && (
            <ModelPage draft={draft} setDraft={setDraft} />
          )}
          {view.kind === "channel" && (
            <ChannelPage
              paired={bubbolinkPairedAt !== null}
              onPair={() => setBubbolinkPairedAt(Date.now())}
            />
          )}
        </div>
      </div>
    </section>
  );
}
