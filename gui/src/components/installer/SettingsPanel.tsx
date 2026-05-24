import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from "react";
import { createPortal } from "react-dom";
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
  RefreshCw,
  Sparkles,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import {
  useInstaller,
  isProviderConfigured,
  isCustomConfigured,
  type AgentState,
  type ApiStyle,
  type ChannelId,
  type CustomCredentials,
  type KnownProvider,
  type ModelConfig,
  type ModelProvider,
  type ProviderCredentials,
} from "@/store/installer-store";
import {
  applyHermesModelConfig,
  applyOpenclawModelConfig,
  openExternalUrl,
  pairBubbolink,
  writeModelConfigs,
} from "@/api/installer";
import {
  buildHermesPlan,
  buildOpenclawPatch,
  isActiveProviderSavable,
} from "@/lib/model-config-apply";
import {
  fetchProviderModels,
  getKnownDefaultModels,
  hasFixedModels,
  type ProviderFetchKind,
} from "@/lib/provider-models";
import { cn } from "@/lib/utils";

// ---- Provider taxonomy --------------------------------------------------------

type TFn = (key: string, options?: Record<string, unknown>) => string;

interface KnownProviderMeta {
  id: KnownProvider;
  /** English display label — short, ASCII brand names that don't need i18n. */
  label: string;
  /** i18n key for the input placeholder ("e.g. deepseek-chat"). */
  modelPlaceholderKey: string;
  docsUrl: string;
}

const KNOWN_PROVIDERS: KnownProviderMeta[] = [
  {
    id: "deepseek",
    label: "DeepSeek",
    modelPlaceholderKey: "settings.modelPresets.deepseekPlaceholder",
    docsUrl: "https://api-docs.deepseek.com/zh-cn/",
  },
  {
    id: "kimi",
    label: "Kimi",
    modelPlaceholderKey: "settings.modelPresets.moonshotPlaceholder",
    docsUrl: "https://www.kimi.com/code/docs/",
  },
  {
    // Coding plan is a separate Moonshot product line: distinct endpoint
    // (api.kimi.com/coding/v1), `sk-kimi-…` key prefix, and a fixed
    // `kimi-for-coding` model — surface it as its own card so users with a
    // coding-plan key don't hit 401s against the standard Kimi base URL.
    id: "kimi-coding",
    label: "Kimi coding plan",
    modelPlaceholderKey: "settings.modelPresets.kimiCodingLabel",
    docsUrl: "https://platform.kimi.ai/",
  },
  {
    id: "minimax",
    label: "MiniMax",
    modelPlaceholderKey: "settings.modelPresets.minimaxPlaceholder",
    docsUrl: "https://platform.minimaxi.com/docs/guides/quickstart-preparation",
  },
];

/** Resolve a localized label for any provider. ASCII-only brand names are
 *  returned as-is; xinyuan / kimi-coding / custom have i18n keys. */
function providerLabel(t: TFn, p: ModelProvider): string {
  switch (p) {
    case "xinyuan":
      return t("settings.providerLabels.xinyuan");
    case "kimi-coding":
      return t("settings.providerLabels.kimiCoding");
    case "custom":
      return t("settings.providerLabels.custom");
    default:
      return p === "deepseek"
        ? "DeepSeek"
        : p === "kimi"
        ? "Kimi"
        : p === "minimax"
        ? "MiniMax"
        : p;
  }
}

function apiStyleLabel(t: TFn, s: ApiStyle): string {
  return s === "anthropic"
    ? t("settings.apiStyleAnthropic")
    : t("settings.apiStyleOpenai");
}

function channelLabel(t: TFn, c: ChannelId): string {
  return c === "bubbolink" ? "BubboLink" : t(`settings.channelLabels.${c}`);
}

interface DocChannelMeta {
  id: Exclude<ChannelId, "bubbolink">;
  docsUrl: string;
}

// WeChat/Feishu/DingTalk are not auto-configurable from this GUI — see
// docs/research/2026-05-23-openclaw-channels-auto-config/report.md (TL;DR:
// feishu silently drops --token, weixin requires interactive QR, dingtalk
// has no official docs.openclaw.ai page yet). v1 simply links to each
// channel's integration docs and lets the user follow them externally.
const DOC_CHANNELS: DocChannelMeta[] = [
  { id: "wechat",   docsUrl: "https://docs.openclaw.ai/channels/wechat" },
  { id: "feishu",   docsUrl: "https://docs.openclaw.ai/channels/feishu" },
  { id: "dingtalk", docsUrl: "https://github.com/DingTalk-Real-AI/dingtalk-openclaw-connector" },
];

// "What is BubboLink?" link target — npm page is the safest stable URL we can
// surface today. Swap to a product landing page once one exists.
const BUBBOLINK_INTRO_URL = "https://www.npmjs.com/package/@bubbolink/cli";

function activeProviderSummary(t: TFn, model: ModelConfig): string {
  switch (model.active) {
    case "xinyuan":
      return t("settings.xinyuanSummary");
    case "custom":
      return isCustomConfigured(model.custom)
        ? model.custom.name || t("settings.providerLabels.custom")
        : t("settings.customNotFilled");
    default: {
      const creds = model[model.active];
      const label = providerLabel(t, model.active);
      return isProviderConfigured(creds)
        ? `${label} · ${creds.modelName}`
        : t("settings.summarySuffixNotFilled", { label });
    }
  }
}

// ---- Navigation ---------------------------------------------------------------

type View =
  | { kind: "root" }
  | { kind: "model" }
  | { kind: "channel" };

// ---- L1: root page ------------------------------------------------------------

function RootPage({
  model,
  paired,
  go,
}: {
  model: ModelConfig;
  paired: boolean;
  go: (v: View) => void;
}) {
  const { t } = useTranslation();
  return (
    <div className="space-y-2.5">
      <SectionCard
        icon={<BrainCircuit className="h-3.5 w-3.5" />}
        title={t("settings.rootModelTitle")}
        summary={activeProviderSummary(t, model)}
        accent
        onClick={() => go({ kind: "model" })}
      />
      <SectionCard
        icon={<MessageSquare className="h-3.5 w-3.5" />}
        title={t("settings.rootChannelTitle")}
        summary={paired ? t("settings.channelSummaryPaired") : t("settings.channelSummaryUnpaired")}
        onClick={() => go({ kind: "channel" })}
      />
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

// ---- L2: model page (provider list with inline expansion) ---------------------

type SaveState =
  | { kind: "idle" }
  | { kind: "saving" }
  | { kind: "saved"; at: number }
  | { kind: "error"; message: string };

function ModelPage({ agent }: { agent: AgentState }) {
  const agentId = agent.id;
  const model = agent.config.model;
  const updateAgentConfig = useInstaller((s) => s.updateAgentConfig);

  function setActive(active: ModelProvider) {
    updateAgentConfig(agentId, { model: { ...model, active } });
  }

  // Any field edit invalidates the "saved" stamp — the form no longer matches
  // what the agent CLI has. The user must Save again to re-stamp.
  function patchKnown(id: KnownProvider, patch: Partial<ProviderCredentials>) {
    updateAgentConfig(agentId, {
      model: {
        ...model,
        [id]: { ...model[id], ...patch, savedAt: null },
      },
    });
  }

  function patchCustom(patch: Partial<CustomCredentials>) {
    updateAgentConfig(agentId, {
      model: {
        ...model,
        custom: { ...model.custom, ...patch, savedAt: null },
      },
    });
  }

  return (
    <div className="space-y-2">
      <XinyuanCard
        active={model.active === "xinyuan"}
        onActivate={() => setActive("xinyuan")}
      />
      {KNOWN_PROVIDERS.map((p) => (
        <KnownProviderCard
          key={p.id}
          provider={p}
          creds={model[p.id]}
          active={model.active === p.id}
          onActivate={() => setActive(p.id)}
          onChange={(patch) => patchKnown(p.id, patch)}
        />
      ))}
      <CustomProviderCard
        creds={model.custom}
        active={model.active === "custom"}
        onActivate={() => setActive("custom")}
        onChange={patchCustom}
      />
    </div>
  );
}

/**
 * Compute save state, gating, and the apply handler for the current agent's
 * model config. Lifted out of ModelPage so the Save button can live as a
 * permanent footer at the panel level (not affected by content height).
 */
function useModelSaveController(agent: AgentState) {
  const { t } = useTranslation();
  const updateAgentConfig = useInstaller((s) => s.updateAgentConfig);
  const [saveState, setSaveState] = useState<SaveState>({ kind: "idle" });
  const model = agent.config.model;

  const savable = isActiveProviderSavable(model);
  const statusAllowsSave =
    agent.status === "ready" || agent.status === "stopped";

  let disabledReason: string | null = null;
  if (model.active === "xinyuan") {
    disabledReason = t("settings.saveBlockedXinyuanComingSoon");
  } else if (!savable) {
    disabledReason = t("settings.saveBlockedFillRequired");
  } else if (!statusAllowsSave) {
    switch (agent.status) {
      case "not-installed":
        disabledReason = t("settings.saveBlockedInstallFirst", { name: agent.name });
        break;
      case "installing":
      case "uninstalling":
        disabledReason = t("settings.saveBlockedAgentBusy");
        break;
      case "error":
        disabledReason = t("settings.saveBlockedAgentErrored", { name: agent.name });
        break;
      default:
        disabledReason = t("settings.saveBlockedAgentUnsupported");
    }
  }

  const isSaving = saveState.kind === "saving";
  const canSave = !disabledReason && !isSaving;

  async function onSave() {
    setSaveState({ kind: "saving" });
    try {
      if (agent.id === "openclaw") {
        const plan = buildOpenclawPatch(model);
        await applyOpenclawModelConfig(
          JSON.stringify(plan.patch),
          plan.replacePaths,
        );
      } else {
        const plan = buildHermesPlan(model);
        await applyHermesModelConfig({
          provider: plan.provider,
          defaultModel: plan.defaultModel,
          baseUrl: plan.baseUrl,
          envVarName: plan.envVarName,
          apiKey: plan.apiKey,
        });
      }
      // Stamp savedAt on the provider we just committed so the "configured" badge
      // appears (and survives navigating away and back).
      const now = Date.now();
      const activeId = model.active;
      if (activeId !== "xinyuan") {
        updateAgentConfig(agent.id, {
          model: {
            ...model,
            [activeId]: { ...model[activeId], savedAt: now },
          },
        });
      }
      // Persist the GUI's per-agent AgentConfig snapshot so a restart doesn't
      // wipe badges, input fields, or the active channel / pair-at timestamp.
      // Read fresh state from the store after the updateAgentConfig above
      // (Zustand set is synchronous).
      try {
        const agents = useInstaller.getState().agents;
        await writeModelConfigs({
          version: 2,
          agents: {
            openclaw: agents.openclaw.config,
            hermes: agents.hermes.config,
          },
        });
      } catch (persistErr) {
        // Persistence failure shouldn't block the save success path — the
        // CLI write already succeeded. Surface it in the console so we can
        // find it during dev without disrupting the user.
        console.warn("[onSave] writeModelConfigs failed:", persistErr);
      }
      setSaveState({ kind: "saved", at: now });
    } catch (err) {
      const message =
        err instanceof Error
          ? err.message
          : typeof err === "string"
            ? err
            : t("common.unknownError");
      setSaveState({ kind: "error", message });
    }
  }

  return { saveState, disabledReason, canSave, onSave };
}

function ModelSaveFooter({
  agent,
  controller,
}: {
  agent: AgentState;
  controller: ReturnType<typeof useModelSaveController>;
}) {
  const { t } = useTranslation();
  const { saveState, disabledReason, canSave, onSave } = controller;
  const isSaving = saveState.kind === "saving";
  return (
    <div className="shrink-0 border-t border-border bg-surface px-4 pb-4 pt-3">
      <button
        type="button"
        onClick={onSave}
        disabled={!canSave}
        title={disabledReason ?? undefined}
        className={cn(
          "inline-flex w-full items-center justify-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition-colors",
          canSave
            ? "bg-accent text-surface hover:opacity-90"
            : "cursor-not-allowed bg-foreground/10 text-muted",
        )}
      >
        {isSaving ? (
          <>
            <span className="h-3 w-3 animate-spin rounded-full border border-surface/40 border-t-surface" />
            {t("common.saving")}
          </>
        ) : (
          t("settings.saveToAgent", { name: agent.name })
        )}
      </button>

      {saveState.kind === "error" && (
        <pre className="ued-scroll-thin mt-2 max-h-32 overflow-auto whitespace-pre-wrap rounded border border-danger/30 bg-danger/[0.04] px-2.5 py-2 font-mono text-[10.5px] leading-snug text-danger">
          {saveState.message}
        </pre>
      )}
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
  const { t } = useTranslation();
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
            {t("settings.xinyuanCardFreeForNewUsers")}
          </div>
          <div className="mt-0.5 text-[10.5px] text-accent/90">
            {t("settings.xinyuanCardScanToClaim")}
          </div>
        </div>
        <span className="inline-flex shrink-0 items-center gap-1 rounded-sm bg-accent px-1.5 py-0.5 text-[10px] font-medium text-surface">
          <Flame className="h-3 w-3" />
          {t("settings.xinyuanCardOffer")}
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
          {t("settings.xinyuanCardTitle")}
        </span>
        <span className="rounded-sm bg-accent/15 px-1.5 py-0.5 text-[10px] font-medium text-accent">
          {t("settings.xinyuanCardRecommended")}
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
            {t("settings.xinyuanComingSoonBody")}
          </p>
          <button
            type="button"
            disabled
            className="mt-2 inline-flex cursor-not-allowed items-center gap-1.5 rounded border border-border bg-background px-2.5 py-1 text-[11px] font-medium text-muted"
          >
            <Sparkles className="h-3 w-3" />
            {t("settings.xinyuanComingSoonCta")}
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
  provider: KnownProviderMeta;
  creds: ProviderCredentials;
  active: boolean;
  onActivate: () => void;
  onChange: (patch: Partial<ProviderCredentials>) => void;
}) {
  const { t } = useTranslation();
  const [showKey, setShowKey] = useState(false);
  const filled = isProviderConfigured(creds);

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
            {t("settings.configured")}
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
            <div className="flex items-center justify-between">
              <label className="text-[11px] text-muted">
                {t("settings.apiKeyLabel")}<RequiredMark />
              </label>
              <button
                type="button"
                onClick={() => setShowKey((v) => !v)}
                aria-label={showKey ? t("common.hideApiKey") : t("common.showApiKey")}
                className="inline-flex items-center gap-1 text-[11px] text-muted transition-colors hover:text-foreground"
              >
                {showKey ? (
                  <>
                    <EyeOff className="h-3 w-3" /> {t("common.hide")}
                  </>
                ) : (
                  <>
                    <Eye className="h-3 w-3" /> {t("common.show")}
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

          <ModelNameField
            fetchKind={{ kind: "known", id: provider.id }}
            apiKey={creds.apiKey}
            value={creds.modelName}
            onChange={(v) => onChange({ modelName: v })}
            placeholder={t(provider.modelPlaceholderKey)}
          />

          <button
            type="button"
            onClick={() => void openExternalUrl(provider.docsUrl)}
            className="inline-flex items-center gap-1 text-[11px] text-accent hover:underline"
          >
            {t("settings.apiDocsLink", { label: provider.label })}
            <ExternalLink className="h-3 w-3" />
          </button>
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
  creds: CustomCredentials;
  active: boolean;
  onActivate: () => void;
  onChange: (patch: Partial<CustomCredentials>) => void;
}) {
  const { t } = useTranslation();
  const [showKey, setShowKey] = useState(false);
  const [headersOpen, setHeadersOpen] = useState(false);
  const filled = isCustomConfigured(creds);

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
          {creds.name.trim() || t("settings.providerLabels.custom")}
        </span>
        {filled && (
          <span className="rounded-sm bg-success/10 px-1.5 py-0.5 text-[10px] font-medium text-success">
            {t("settings.configured")}
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
            <label className="text-[11px] text-muted">{t("settings.apiStyleLabel")}</label>
            <div
              role="radiogroup"
              aria-label={t("settings.apiStyleAria")}
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
                    <span>{apiStyleLabel(t, style)}</span>
                  </button>
                );
              })}
            </div>
          </div>

          <div className="space-y-1">
            <label className="text-[11px] text-muted">
              {t("settings.customDisplayNameLabel")}<RequiredMark />
            </label>
            <input
              type="text"
              value={creds.name}
              onChange={(e) => onChange({ name: e.target.value })}
              placeholder={t("settings.customDisplayNamePlaceholder")}
              className="block w-full max-w-full rounded border border-border bg-background px-2.5 py-1.5 text-sm text-foreground placeholder:text-muted focus:border-accent focus:outline-none"
            />
          </div>

          <div className="space-y-1">
            <label className="text-[11px] text-muted">
              <span lang="en">Base URL</span>
              <RequiredMark />
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
              <label className="text-[11px] text-muted">
                {t("settings.apiKeyLabel")}<RequiredMark />
              </label>
              <button
                type="button"
                onClick={() => setShowKey((v) => !v)}
                className="inline-flex items-center gap-1 text-[11px] text-muted transition-colors hover:text-foreground"
              >
                {showKey ? (
                  <>
                    <EyeOff className="h-3 w-3" /> {t("common.hide")}
                  </>
                ) : (
                  <>
                    <Eye className="h-3 w-3" /> {t("common.show")}
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

          <ModelNameField
            fetchKind={{
              kind: "custom",
              baseUrl: creds.baseUrl,
              apiStyle: creds.apiStyle,
            }}
            apiKey={creds.apiKey}
            value={creds.modelName}
            onChange={(v) => onChange({ modelName: v })}
            placeholder={
              creds.apiStyle === "anthropic"
                ? t("settings.modelPlaceholderAnthropic")
                : t("settings.modelPlaceholderOpenAI")
            }
          />

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
              {t("settings.extraHeaders")}
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

function RequiredMark() {
  return (
    <span aria-hidden className="ml-0.5 text-danger">
      *
    </span>
  );
}

// ---- Shared: model-name combobox (with auto-fetch) ----------------------------

/**
 * Combobox of available models for a provider:
 *
 *   - Known providers expose a hardcoded "popular models" list immediately —
 *     no API key required. When the user does supply an API key, the live
 *     `/models` response replaces the defaults.
 *   - Custom provider needs at least Base URL (and API key — the call itself
 *     is authenticated). Until then the dropdown is empty.
 *
 * The dropdown is a portal-anchored popover (not the native `<datalist>`),
 * styled in-app and keyboard-navigable.
 */
function ModelNameField({
  fetchKind,
  apiKey,
  value,
  onChange,
  placeholder,
}: {
  fetchKind: ProviderFetchKind;
  apiKey: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
}) {
  const { t } = useTranslation();
  const [liveModels, setLiveModels] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const customBaseUrl =
    fetchKind.kind === "custom" ? fetchKind.baseUrl.trim() : "";
  const customApiStyle =
    fetchKind.kind === "custom" ? fetchKind.apiStyle : "";
  // Some providers ship a single fixed model (e.g. Kimi coding plan) and don't
  // expose /models for typical user keys — skip the network round-trip and
  // surface the curated list directly.
  const fixedModels =
    fetchKind.kind === "known" && hasFixedModels(fetchKind.id);
  const canFetch =
    !fixedModels &&
    apiKey.trim() !== "" &&
    (fetchKind.kind !== "custom" || customBaseUrl !== "");

  // Default fallback when API key is empty or fetch fails (known providers
  // ship a curated short-list; custom has none).
  const defaults =
    fetchKind.kind === "known" ? getKnownDefaultModels(fetchKind.id) : [];
  const displayed = liveModels.length > 0 ? liveModels : defaults;

  async function doFetch() {
    if (!canFetch) return;
    abortRef.current?.abort();
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    setLoading(true);
    setError(null);
    try {
      const ids = await fetchProviderModels(fetchKind, apiKey, {
        signal: ctrl.signal,
      });
      if (!ctrl.signal.aborted) setLiveModels(ids);
    } catch (err) {
      if (!ctrl.signal.aborted) {
        setLiveModels([]);
        setError(err instanceof Error ? err.message : String(err));
      }
    } finally {
      if (!ctrl.signal.aborted) setLoading(false);
    }
  }

  // Auto-fetch (debounced) whenever inputs change. Known providers refetch
  // on apiKey changes only; custom also on baseUrl / apiStyle.
  useEffect(() => {
    if (!canFetch) {
      setLiveModels([]);
      setError(null);
      return;
    }
    const t = setTimeout(() => {
      void doFetch();
    }, 400);
    return () => {
      clearTimeout(t);
      abortRef.current?.abort();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [apiKey, customBaseUrl, customApiStyle, fetchKind.kind]);

  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between">
        <label className="text-[11px] text-muted">
          {t("settings.modelLabel")}<RequiredMark />
        </label>
        {!fixedModels && (
          <button
            type="button"
            onClick={() => void doFetch()}
            disabled={!canFetch || loading}
            aria-label={t("settings.modelLabelRefreshAria")}
            title={
              canFetch
                ? undefined
                : fetchKind.kind === "custom"
                  ? t("settings.refreshModelTipNeedBoth")
                  : t("settings.refreshModelTipNeedKey")
            }
            className={cn(
              "inline-flex items-center gap-1 text-[11px] transition-colors",
              canFetch && !loading
                ? "text-muted hover:text-foreground"
                : "cursor-not-allowed text-muted/60",
            )}
          >
            <RefreshCw className={cn("h-3 w-3", loading && "animate-spin")} />
            {loading ? t("settings.fetchingModels") : t("common.refresh")}
          </button>
        )}
      </div>
      <Combobox
        value={value}
        onChange={onChange}
        options={displayed}
        placeholder={placeholder}
        loading={loading}
      />
      {!loading && error && (
        <p className="text-[10.5px] text-muted">
          {t("settings.modelFetchFailed", { error })}
        </p>
      )}
    </div>
  );
}

// ---- Combobox primitive -------------------------------------------------------

/**
 * Custom combobox: an `<input>` with a portal-anchored popover listing
 * `options`. The user can free-type any value (the input is the source of
 * truth) or click/keyboard-select from the popover. ESC closes; arrow keys
 * move the highlight; Enter commits.
 */
function Combobox({
  value,
  onChange,
  options,
  placeholder,
  loading,
}: {
  value: string;
  onChange: (v: string) => void;
  options: string[];
  placeholder?: string;
  loading?: boolean;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [highlight, setHighlight] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  // Reset highlight to the current value (if present) when options change.
  useEffect(() => {
    const idx = options.indexOf(value);
    setHighlight(idx >= 0 ? idx : 0);
  }, [options, value]);

  function commit(idx: number) {
    const opt = options[idx];
    if (opt !== undefined) {
      onChange(opt);
      setOpen(false);
      inputRef.current?.blur();
    }
  }

  function onKeyDown(e: ReactKeyboardEvent<HTMLInputElement>) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      if (!open && options.length > 0) {
        setOpen(true);
        return;
      }
      setHighlight((h) => Math.min(options.length - 1, h + 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      if (!open && options.length > 0) {
        setOpen(true);
        return;
      }
      setHighlight((h) => Math.max(0, h - 1));
    } else if (e.key === "Enter") {
      if (open && options.length > 0) {
        e.preventDefault();
        commit(highlight);
      }
    } else if (e.key === "Escape") {
      if (open) {
        e.preventDefault();
        setOpen(false);
      }
    }
  }

  // Close on scroll anywhere (popover uses fixed coords).
  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    window.addEventListener("scroll", close, true);
    return () => window.removeEventListener("scroll", close, true);
  }, [open]);

  return (
    <div className="relative">
      <input
        ref={inputRef}
        type="text"
        role="combobox"
        aria-expanded={open}
        aria-autocomplete="list"
        value={value}
        onChange={(e) => {
          onChange(e.target.value);
          if (options.length > 0) setOpen(true);
        }}
        onFocus={() => {
          if (options.length > 0) setOpen(true);
        }}
        onBlur={() => {
          // Delay so a click on a popover option lands before close.
          setTimeout(() => setOpen(false), 120);
        }}
        onKeyDown={onKeyDown}
        placeholder={placeholder}
        className="block w-full max-w-full rounded border border-border bg-background px-2.5 py-1.5 pr-7 text-sm text-foreground placeholder:text-muted focus:border-accent focus:outline-none"
      />
      <button
        type="button"
        tabIndex={-1}
        onMouseDown={(e) => {
          e.preventDefault();
          if (options.length > 0) {
            if (open) {
              setOpen(false);
            } else {
              setOpen(true);
              inputRef.current?.focus();
            }
          }
        }}
        aria-label={open ? t("settings.collapseList") : t("settings.expandList")}
        className={cn(
          "absolute inset-y-0 right-1.5 grid w-5 place-items-center text-muted",
          options.length === 0 && "opacity-40",
        )}
      >
        <ChevronDown
          className={cn(
            "h-3.5 w-3.5 transition-transform",
            open && "rotate-180",
          )}
        />
      </button>
      {open && options.length > 0 && (
        <ComboboxPopover
          anchorRef={inputRef}
          options={options}
          highlight={highlight}
          onHighlight={setHighlight}
          onSelect={commit}
          currentValue={value}
          loading={loading}
        />
      )}
    </div>
  );
}

function ComboboxPopover({
  anchorRef,
  options,
  highlight,
  onHighlight,
  onSelect,
  currentValue,
  loading,
}: {
  anchorRef: React.RefObject<HTMLInputElement | null>;
  options: string[];
  highlight: number;
  // (next: i18n) `t` is captured via useTranslation inside the body
  onHighlight: (i: number) => void;
  onSelect: (i: number) => void;
  currentValue: string;
  loading?: boolean;
}) {
  const { t } = useTranslation();
  const [rect, setRect] = useState<{
    top: number;
    left: number;
    width: number;
  } | null>(null);

  useLayoutEffect(() => {
    function update() {
      const el = anchorRef.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      setRect({ top: r.bottom + 4, left: r.left, width: r.width });
    }
    update();
    window.addEventListener("resize", update);
    return () => window.removeEventListener("resize", update);
  }, [anchorRef]);

  if (!rect) return null;
  return createPortal(
    <div
      role="listbox"
      style={{
        position: "fixed",
        top: rect.top,
        left: rect.left,
        width: rect.width,
        zIndex: 50,
      }}
      className="ued-scroll-thin max-h-44 overflow-y-auto rounded-md border border-border bg-surface shadow-md"
    >
      {options.map((opt, i) => {
        const isHighlight = i === highlight;
        const isCurrent = opt === currentValue;
        return (
          <div
            key={opt}
            role="option"
            aria-selected={isCurrent}
            onMouseDown={(e) => {
              e.preventDefault();
              onSelect(i);
            }}
            onMouseEnter={() => onHighlight(i)}
            className={cn(
              "cursor-pointer px-2.5 py-1.5 text-xs",
              isHighlight && "bg-accent/[0.08]",
              isCurrent ? "font-medium text-accent" : "text-foreground",
            )}
          >
            {opt}
          </div>
        );
      })}
      {loading && (
        <div className="px-2.5 py-1.5 text-[10.5px] text-muted">{t("settings.fetchingModels")}</div>
      )}
    </div>,
    document.body,
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

function ChannelPage({ agent }: { agent: AgentState }) {
  return (
    <div className="space-y-2.5">
      <BubboLinkCard agent={agent} />
      {DOC_CHANNELS.map((c) => (
        <DocChannelCard key={c.id} channel={c} />
      ))}
    </div>
  );
}

function DocChannelCard({ channel }: { channel: DocChannelMeta }) {
  const { t } = useTranslation();
  return (
    <button
      type="button"
      onClick={() => void openExternalUrl(channel.docsUrl)}
      className={cn(
        "flex w-full items-center gap-3 rounded-md border border-border bg-surface px-3.5 py-3 text-left transition-colors",
        "hover:border-foreground/30 hover:bg-background",
      )}
    >
      <span className="min-w-0 flex-1 leading-tight">
        <span className="block text-sm font-medium text-foreground">
          {channelLabel(t, channel.id)}
        </span>
        <span className="mt-0.5 block truncate text-[11px] text-muted">
          {t(`settings.docChannels.${channel.id}`)}
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

function BubboLinkCard({ agent }: { agent: AgentState }) {
  const { t } = useTranslation();
  const updateAgentConfig = useInstaller((s) => s.updateAgentConfig);
  const [code, setCode] = useState("");
  const [state, setState] = useState<PairState>({ kind: "idle" });

  const paired = agent.config.bubbolinkPairedAt !== null;
  const canPair = /^\d{4}$/.test(code) && state.kind !== "pairing";

  async function onPair() {
    setState({ kind: "pairing" });
    try {
      await pairBubbolink(code, agent.id);
      // `bubbolink pair` (without --runtime) binds the relay account to every
      // runtime on the host, so stamp pairedAt on both agents — otherwise the
      // other agent's "paired" badge would lie.
      const now = Date.now();
      updateAgentConfig("openclaw", {
        channel: "bubbolink",
        bubbolinkPairedAt: now,
      });
      updateAgentConfig("hermes", {
        channel: "bubbolink",
        bubbolinkPairedAt: now,
      });
      // Persist immediately so a crash before the next Save doesn't lose the
      // pair state. Read fresh store snapshot (Zustand set is synchronous).
      try {
        const agents = useInstaller.getState().agents;
        await writeModelConfigs({
          version: 2,
          agents: {
            openclaw: agents.openclaw.config,
            hermes: agents.hermes.config,
          },
        });
      } catch (persistErr) {
        console.warn("[onPair] writeModelConfigs failed:", persistErr);
      }
      setState({ kind: "idle" });
      setCode("");
    } catch (err) {
      const message =
        err instanceof Error
          ? err.message
          : typeof err === "string"
            ? err
            : t("common.unknownError");
      setState({ kind: "error", message });
    }
  }

  return (
    <div
      className={cn(
        "overflow-hidden rounded-md border-2 transition-colors",
        paired ? "border-success/40" : "border-accent",
      )}
    >
      <div className="bg-gradient-to-r from-accent/[0.10] via-accent/[0.04] to-transparent px-3.5 py-3">
        <div className="min-w-0 flex-1 leading-tight">
          <div className="flex items-center gap-2">
            <span className="text-sm font-semibold text-foreground">
              {t("settings.bubboLinkInteractive")}
            </span>
            <span className="inline-flex items-center gap-0.5 rounded-sm bg-accent px-1.5 py-0.5 text-[10px] font-medium text-surface">
              <Sparkles className="h-2.5 w-2.5" />
              {t("settings.bubboLinkRecommended")}
            </span>
            {paired && (
              <span className="rounded-sm bg-success/10 px-1.5 py-0.5 text-[10px] font-medium text-success">
                {t("settings.bubboLinkPaired")}
              </span>
            )}
          </div>
          <p className="mt-0.5 text-[11px] leading-relaxed text-muted">
            {t("settings.bubboLinkBlurb")}
          </p>
          <button
            type="button"
            onClick={() => void openExternalUrl(BUBBOLINK_INTRO_URL)}
            className="mt-1 inline-flex items-center gap-1 text-[11px] text-accent hover:underline"
          >
            {t("settings.whatIsBubboLink")}
            <ExternalLink className="h-3 w-3" />
          </button>
        </div>
      </div>

      <div className="space-y-3 border-t border-border/60 bg-background/40 px-3.5 py-3.5">
        <label className="block text-[11px] text-muted">
          {t("settings.pairCode")}<RequiredMark />
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
          onClick={() => void onPair()}
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
              {t("settings.pairing")}
            </>
          ) : paired ? (
            t("settings.repair")
          ) : (
            t("settings.pair")
          )}
        </button>
        {state.kind === "error" && (
          <pre className="ued-scroll-thin mt-1 max-h-28 overflow-auto whitespace-pre-wrap rounded border border-danger/30 bg-danger/[0.04] px-2.5 py-2 font-mono text-[10.5px] leading-snug text-danger">
            {state.message}
          </pre>
        )}
      </div>
    </div>
  );
}

/**
 * Fixed-length OTP input: `length` separate single-digit cells, auto-advance
 * on input, backspace returns to the previous cell. `value` is the joined
 * digit string (0..length chars). Non-digit input is silently dropped.
 *
 * Behavior:
 *   - Typing a digit overwrites the current cell and moves focus forward.
 *   - Backspace on an empty cell focuses (and clears) the previous cell.
 *   - ArrowLeft / ArrowRight navigate without modifying values.
 *   - Pasting a numeric string fills cells starting at the focused index.
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
  const { t } = useTranslation();
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
    // Take the last digit typed — covers IMEs that deliver multiple chars at once.
    const d = raw.replace(/\D+/g, "").slice(-1);
    if (!d) {
      // Non-digit input: keep current value, do nothing.
      return;
    }
    setAt(i, d);
    if (i < length - 1) focusAt(i + 1);
  }

  function onCellKeyDown(i: number, e: ReactKeyboardEvent<HTMLInputElement>) {
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

  function onCellPaste(i: number, e: React.ClipboardEvent<HTMLInputElement>) {
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
          aria-label={t("settings.pairCodePositionAria", { pos: i + 1 })}
          className={cn(
            "h-12 w-12 rounded-xl border-2 bg-background/60 text-center font-mono text-xl text-foreground caret-accent",
            "transition-[colors,box-shadow] focus:border-accent focus:bg-surface focus:shadow-[0_0_0_4px_rgba(99,102,241,0.15)] focus:outline-none",
            d ? "border-border" : "border-border/60",
            disabled && "cursor-not-allowed opacity-60",
          )}
        />
      ))}
    </div>
  );
}

// ---- Main component -----------------------------------------------------------

export function SettingsPanel() {
  const { t } = useTranslation();
  const target = useInstaller((s) => s.settingsTarget);
  const agent = useInstaller((s) => (target ? s.agents[target] : null));
  const close = useInstaller((s) => s.closeSettings);

  const open = Boolean(target && agent);

  const [view, setView] = useState<View>({ kind: "root" });

  const agentName = agent?.name ?? "Agent";

  let title: string;
  switch (view.kind) {
    case "root":
      title = t("settings.titleAgentConfig", { name: agentName });
      break;
    case "model":
      title = t("settings.titleModel");
      break;
    case "channel":
      title = t("settings.titleChannel");
      break;
  }

  function handleBack() {
    if (view.kind === "root") {
      close();
      // reset for next open
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
          aria-label={t("common.back")}
          className="grid h-7 w-7 shrink-0 place-items-center rounded text-muted transition-colors hover:bg-background hover:text-foreground"
        >
          <ChevronLeft className="h-4 w-4" />
        </button>
        <div className="min-w-0 flex-1 leading-tight">
          <div className="truncate text-sm font-semibold">{title}</div>
          {view.kind !== "root" && (
            <div className="mt-0.5 truncate text-[10px] text-muted">
              {t("settings.titleAgentConfig", { name: agentName })}
            </div>
          )}
        </div>
      </header>

      {agent && target && (
        <SettingsPanelBody agent={agent} view={view} go={setView} />
      )}
    </section>
  );
}

function SettingsPanelBody({
  agent,
  view,
  go,
}: {
  agent: AgentState;
  view: View;
  go: (v: View) => void;
}) {
  const controller = useModelSaveController(agent);

  return (
    <>
      <div className="flex-1 overflow-y-auto ued-scroll-thin">
        <div className="mx-auto w-full max-w-md space-y-4 px-4 py-5">
          {view.kind === "root" && (
            <RootPage
              model={agent.config.model}
              paired={agent.config.bubbolinkPairedAt !== null}
              go={go}
            />
          )}
          {view.kind === "model" && <ModelPage agent={agent} />}
          {view.kind === "channel" && <ChannelPage agent={agent} />}
        </div>
      </div>
      {view.kind === "model" && (
        <ModelSaveFooter agent={agent} controller={controller} />
      )}
    </>
  );
}
