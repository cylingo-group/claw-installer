import { useState } from "react";
import {
  BrainCircuit,
  ChevronDown,
  ChevronRight,
  ExternalLink,
  Eye,
  EyeOff,
  MessageSquare,
} from "lucide-react";
import {
  useInstaller,
  type ModelProvider,
  type CredentialedProvider,
  type ChannelId,
  type ModelConfig,
  type ProviderCredentials,
  type AgentId,
} from "@/store/installer-store";
import { cn } from "@/lib/utils";

// ---- Constants ----------------------------------------------------------------

const PROVIDER_LABELS: Record<ModelProvider, string> = {
  deepseek: "DeepSeek",
  kimi: "Kimi",
  minimax: "MiniMax",
  xinyuan: "心元",
};

const PROVIDER_API_KEY_URLS: Record<CredentialedProvider, string> = {
  deepseek: "https://platform.deepseek.com/api_keys",
  kimi: "https://platform.moonshot.cn/console/api-keys",
  minimax: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
};

const CHANNEL_LABELS: Record<ChannelId, string> = {
  wechat: "微信",
  feishu: "飞书",
  dingtalk: "钉钉",
  bubbolink: "BubboLink",
};

const MODEL_PROVIDERS: ModelProvider[] = ["deepseek", "kimi", "minimax", "xinyuan"];
const CHANNEL_IDS: ChannelId[] = ["wechat", "feishu", "dingtalk", "bubbolink"];

// ---- Model section ------------------------------------------------------------

function ModelSection({ agentId, model }: { agentId: AgentId; model: ModelConfig }) {
  const updateAgentConfig = useInstaller((s) => s.updateAgentConfig);
  const [expanded, setExpanded] = useState<ModelProvider | null>(null);

  function patchProvider(
    provider: CredentialedProvider,
    patch: Partial<ProviderCredentials>,
  ) {
    updateAgentConfig(agentId, {
      model: {
        ...model,
        [provider]: { ...model[provider], ...patch },
      },
    });
  }

  return (
    <fieldset>
      <legend className="flex items-center gap-2">
        <span className="grid h-6 w-6 shrink-0 place-items-center rounded-md bg-accent/10 text-accent">
          <BrainCircuit className="h-3.5 w-3.5" />
        </span>
        <span className="text-sm font-semibold text-foreground">模型配置</span>
      </legend>

      <div className="mt-3 space-y-2">
        {MODEL_PROVIDERS.map((provider) => {
          const isOpen = expanded === provider;
          const onToggle = () => setExpanded(isOpen ? null : provider);
          return (
            <ProviderCard
              key={provider}
              provider={provider}
              open={isOpen}
              onToggle={onToggle}
              credentials={
                provider === "xinyuan"
                  ? null
                  : model[provider as CredentialedProvider]
              }
              onApiKeyChange={(v) =>
                patchProvider(provider as CredentialedProvider, { apiKey: v })
              }
              onModelNameChange={(v) =>
                patchProvider(provider as CredentialedProvider, { modelName: v })
              }
            />
          );
        })}
      </div>
    </fieldset>
  );
}

function ProviderCard({
  provider,
  open,
  onToggle,
  credentials,
  onApiKeyChange,
  onModelNameChange,
}: {
  provider: ModelProvider;
  open: boolean;
  onToggle: () => void;
  /** null for 心元 (no inputs yet). */
  credentials: ProviderCredentials | null;
  onApiKeyChange: (value: string) => void;
  onModelNameChange: (value: string) => void;
}) {
  const [showKey, setShowKey] = useState(false);
  const filled =
    credentials !== null &&
    credentials.apiKey.trim() !== "" &&
    credentials.modelName.trim() !== "";

  return (
    <div
      className={cn(
        "overflow-hidden rounded-md border transition-colors",
        open ? "border-accent" : "border-border",
      )}
    >
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={open}
        className={cn(
          "flex w-full items-center gap-2 px-3.5 py-2.5 text-left transition-colors",
          open ? "bg-accent/[0.04]" : "hover:bg-background",
        )}
      >
        {open ? (
          <ChevronDown className="h-3.5 w-3.5 shrink-0 text-muted" />
        ) : (
          <ChevronRight className="h-3.5 w-3.5 shrink-0 text-muted" />
        )}
        <span
          className={cn(
            "flex-1 text-sm font-medium",
            open ? "text-accent" : "text-foreground",
          )}
        >
          {PROVIDER_LABELS[provider]}
        </span>
        {filled && (
          <span className="rounded bg-success/10 px-1.5 py-0.5 text-[10px] font-medium text-success">
            已配置
          </span>
        )}
      </button>

      {open && (
        <div className="border-t border-border px-3.5 py-3">
          {provider === "xinyuan" ? (
            <p className="text-[11px] text-muted">心元模型配置敬请期待</p>
          ) : (
            <div className="space-y-3">
              <a
                href={PROVIDER_API_KEY_URLS[provider as CredentialedProvider]}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 text-[11px] text-accent hover:underline"
              >
                获取 {PROVIDER_LABELS[provider]} API Key
                <ExternalLink className="h-3 w-3" />
              </a>

              <div className="space-y-1">
                <div className="flex items-center justify-between">
                  <label className="text-[11px] text-muted">API Key</label>
                  <button
                    type="button"
                    onClick={() => setShowKey((v) => !v)}
                    aria-label={showKey ? "隐藏 API Key" : "显示 API Key"}
                    className="inline-flex items-center gap-1 text-[11px] text-muted hover:text-foreground transition-colors"
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
                  value={credentials?.apiKey ?? ""}
                  onChange={(e) => onApiKeyChange(e.target.value)}
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
                  value={credentials?.modelName ?? ""}
                  onChange={(e) => onModelNameChange(e.target.value)}
                  placeholder={modelPlaceholder(provider as CredentialedProvider)}
                  className={cn(
                    "block w-full max-w-full rounded border border-border bg-background px-2.5 py-1.5",
                    "text-sm text-foreground placeholder:text-muted",
                    "focus:border-accent focus:outline-none",
                  )}
                />
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function modelPlaceholder(p: CredentialedProvider): string {
  switch (p) {
    case "deepseek":
      return "e.g. deepseek-chat";
    case "kimi":
      return "e.g. moonshot-v1-8k";
    case "minimax":
      return "e.g. abab6.5s-chat";
  }
}

// ---- Channel section ----------------------------------------------------------

function ChannelSection({
  agentId,
  channel,
}: {
  agentId: AgentId;
  channel: ChannelId | null;
}) {
  const updateAgentConfig = useInstaller((s) => s.updateAgentConfig);

  function handleChannelChange(value: ChannelId) {
    updateAgentConfig(agentId, { channel: value });
  }

  return (
    <fieldset>
      <legend className="flex items-center gap-2">
        <span className="grid h-6 w-6 shrink-0 place-items-center rounded-md bg-accent/10 text-accent">
          <MessageSquare className="h-3.5 w-3.5" />
        </span>
        <span className="text-sm font-semibold text-foreground">通道配置</span>
      </legend>

      <div role="radiogroup" aria-label="IM 通道" className="mt-3 space-y-2">
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
                name={`channel-${agentId}`}
                value={id}
                checked={selected}
                onChange={() => handleChannelChange(id)}
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
    </fieldset>
  );
}

// ---- Main component -----------------------------------------------------------

export function SettingsPanel() {
  const target = useInstaller((s) => s.settingsTarget);
  const agent = useInstaller((s) => (target ? s.agents[target] : null));
  const close = useInstaller((s) => s.closeSettings);

  const open = Boolean(target && agent);

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
          onClick={close}
          aria-label="返回"
          className="grid h-7 w-7 shrink-0 place-items-center rounded text-muted transition-colors hover:bg-background hover:text-foreground"
        >
          <svg
            viewBox="0 0 24 24"
            className="h-4 w-4"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.8"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M15 6l-6 6 6 6" />
          </svg>
        </button>
        <div className="min-w-0 flex-1 leading-tight">
          <div className="truncate text-sm font-semibold">{agent?.name ?? ""} 配置</div>
        </div>
      </header>

      {agent && target && (
        <div className="flex-1 overflow-y-auto ued-scroll-thin">
          <div className="mx-auto w-full max-w-md space-y-6 px-4 py-5">
            <ModelSection agentId={target} model={agent.config.model} />
            <ChannelSection agentId={target} channel={agent.config.channel} />
          </div>
        </div>
      )}
    </section>
  );
}
