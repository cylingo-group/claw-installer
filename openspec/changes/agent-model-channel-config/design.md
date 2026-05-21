# Design: Agent 模型与通道配置 (in-memory)

**Change**: `agent-model-channel-config`
**Date**: 2026-05-21

---

## 1. Type Contracts

### 1.1 New types in `installer-store.ts`

```ts
// ---- Agent config types (replaces OpenclawConfig / HermesConfig) -------------

export type ModelProvider = "deepseek" | "kimi" | "minimax" | "xinyuan";

export type ChannelId = "wechat" | "feishu" | "dingtalk" | "bubbolink";

export interface ModelConfig {
  provider:  ModelProvider;
  apiKey:    string;       // raw string; empty string = not provided
  modelName: string;       // raw string; empty string = not provided
}

export interface AgentConfig {
  model:   ModelConfig | null;  // null = model section untouched
  channel: ChannelId | null;    // null = channel section untouched
}
```

### 1.2 Types removed

```ts
// DELETE:
export interface OpenclawConfig { channel: "stable" | "beta" | "nightly"; provider: ... }
export interface HermesConfig   { engine: ...; userAgent: ... }
export type AgentConfig = OpenclawConfig | HermesConfig;  // old union
```

### 1.3 Updated `AgentState`

`config: AgentConfig` field type changes from the old union to the new interface. No field rename.

### 1.4 `initialAgents` seed values

```ts
// Both agents:
config: { model: null, channel: null }
```

### 1.5 `isAgentConfigured` utility

```ts
export function isAgentConfigured(agent: AgentState): boolean {
  const { model, channel } = agent.config;
  if (channel === null) return false;
  if (model === null) return false;
  if (model.provider === "xinyuan") return false;  // 心元 has no inputs
  if (model.apiKey.trim() === "") return false;
  if (model.modelName.trim() === "") return false;
  return true;
}
```

### 1.6 `updateAgentConfig` — no signature change

```ts
updateAgentConfig: (id: AgentId, patch: Partial<AgentConfig>) => void
```

The implementation remains a shallow merge: `{ ...current.config, ...patch }`. This correctly handles partial updates like `updateAgentConfig(id, { channel: "feishu" })` without clobbering `model`.

---

## 2. Component Tree

```
App.tsx
├── Sidebar
│   └── AgentCard (×2)
│       └── [NEW] UnconfiguredHint  ← rendered conditionally after body block
├── SettingsPanel                   ← rewritten body; header unchanged
│   ├── ModelSection                ← new sub-component (inline or extracted)
│   │   ├── ProviderRadioGroup
│   │   ├── ApiKeyField             ← shown for deepseek/kimi/minimax
│   │   ├── ModelNameField          ← shown for deepseek/kimi/minimax
│   │   └── XinyuanPlaceholder      ← shown for xinyuan
│   └── ChannelSection              ← new sub-component (inline or extracted)
│       └── ChannelRadioGroup
├── AppSettingsPanel                ← unchanged
├── UninstallDialog                 ← unchanged
└── RebootModal                     ← unchanged
```

Sub-components `ModelSection` and `ChannelSection` may be implemented inline within `SettingsPanel.tsx` or extracted as named functions in the same file. The developer chooses; extraction is preferred if either section exceeds ~60 lines.

`UnconfiguredHint` may be an inline named function inside `AgentCard.tsx`. It is not a separate file.

---

## 3. `AgentCard` — "未配置" Guidance Row

### 3.1 Visibility predicate

```
show = !isAgentConfigured(agent)
    && agent.status !== "installing"
    && agent.status !== "uninstalling"
    && settingsTarget !== agent.id
```

All four conditions must hold. The check uses the `isAgentConfigured` utility and reads `settingsTarget` from the store.

### 3.2 Copy strategy

Determine which steps are missing:

```
modelMissing   = agent.config.model === null
               || agent.config.model.provider === "xinyuan"
               || agent.config.model.apiKey.trim() === ""
               || agent.config.model.modelName.trim() === ""

channelMissing = agent.config.channel === null
```

| modelMissing | channelMissing | Copy |
|---|---|---|
| true | true | `完成模型配置 · IM 通道配置 →` |
| true | false | `完成模型配置 →` |
| false | true | `完成 IM 通道配置 →` |
| false | false | (row hidden — `isAgentConfigured` returns true) |

### 3.3 Interaction

The entire row is wrapped in a `<button>` element that calls `openSettings(agent.id)`. No other action.

### 3.4 Visual spec

The developer has latitude within these constraints:
- Font size: `text-[11px]` (same as `LogPathHint` and other micro-typography in the card).
- Color: `text-muted` by default, `text-foreground/80` on hover.
- Padding: consistent with the card's existing body block (`mt-2` from the body block above).
- No border, no background fill. The row should recede visually; it is a hint, not a call-to-action.
- The `→` arrow (or a Lucide `ChevronRight` icon at `h-3 w-3`) anchors the right edge, signalling interactivity.

---

## 4. `SettingsPanel` Form

### 4.1 Layout

The panel's `<header>` and slide-in animation are unchanged. The placeholder center-aligned empty state is replaced by a scrollable form body:

```
<div class="flex-1 overflow-y-auto px-5 py-5 space-y-6">
  <ModelSection />
  <ChannelSection />
</div>
```

### 4.2 Model section — provider radio group

```
Label: "模型配置"
Icon: CPU / chip icon (Lucide `Cpu` or `BrainCircuit`, developer's choice)

Options (radio, name="model-provider"):
  ○ DeepSeek
  ○ Kimi
  ○ MiniMax
  ○ 心元
```

The option cards follow the same pattern as `AppSettingsPanel`'s mirror-source radio cards:
- `border border-border` default; `border-accent bg-accent/[0.04]` when selected.
- Label text: `text-sm font-medium`; selected: `text-accent`, unselected: `text-foreground`.

When a non-心元 provider is selected, an expansion block slides in below the radio group (or is always visible but conditionally populated):

```
expansion block:
  ┌─ "获取 API Key →" link ──────────────────────────────────────────────────┐
  │  text-[11px] text-accent underline; opens external browser               │
  └──────────────────────────────────────────────────────────────────────────┘
  API Key: [input type="password"               ] [show/hide toggle]
  模型名称: [input type="text" placeholder="e.g. deepseek-chat"]
```

When 心元 is selected:

```
  ┌── placeholder text ───────────────────────────────────────────────────────┐
  │  "心元模型配置敬请期待"  (text-[11px] text-muted, centered or left-aligned)  │
  └──────────────────────────────────────────────────────────────────────────┘
```

### 4.3 Model section — store writes

| User action | Store call |
|---|---|
| Select provider X | `updateAgentConfig(id, { model: { provider: X, apiKey: current.apiKey \|\| "", modelName: current.modelName \|\| "" } })` |
| Type in API Key field | `updateAgentConfig(id, { model: { ...current.model!, apiKey: value } })` |
| Type in Model Name field | `updateAgentConfig(id, { model: { ...current.model!, modelName: value } })` |

When switching providers, the existing `apiKey` and `modelName` values are preserved (the user may be testing providers; wiping their key would be disruptive). The developer may choose to clear them on provider change if UX testing suggests otherwise — this is a judgment call.

### 4.4 Channel section

```
Label: "通道配置"
Icon: Lucide `MessageSquare` or `Plug` (developer's choice)

Options (radio, name="channel"):
  ○ 微信
  ○ 飞书
  ○ 钉钉
  ○ BubboLink
```

Selecting any option immediately calls `updateAgentConfig(id, { channel: value })`. No sub-inputs.

The option cards follow the same style as the model provider radio group.

### 4.5 API Key deep-links

```ts
const PROVIDER_API_KEY_URLS: Record<Exclude<ModelProvider, "xinyuan">, string> = {
  deepseek: "https://platform.deepseek.com/api_keys",
  kimi:     "https://platform.moonshot.cn/console/api-keys",
  minimax:  "https://platform.minimaxi.com/user-center/basic-information/interface-key",
};
```

Link element: `<a href={url} target="_blank" rel="noopener noreferrer">获取 API Key →</a>`.

If the developer confirms during implementation that Tauri's webview blocks `target="_blank"` links, the link should be replaced with a `<button>` that calls `open(url)` from `@tauri-apps/plugin-shell`. The fallback does not require a proposal amendment — it is an implementation detail.

### 4.6 Show/hide toggle for API Key

Local `useState<boolean>` inside the panel (or section). Toggling it switches the input's `type` attribute between `"password"` and `"text"`. Use a Lucide `Eye` / `EyeOff` icon for the toggle button. The toggle state is NOT persisted to the store.

---

## 5. Store Integration Points

### 5.1 `updateAgentConfig` call sites after this change

The only call site today is the store's own `openSettings` / `confirmUninstall` flow, which does not call `updateAgentConfig`. The action is currently only defined but never called from UI components. After this change, `SettingsPanel` will be the first consumer.

### 5.2 Reading config in `AgentCard`

`AgentCard` already receives the full `agent: AgentState` prop. The guidance row reads `agent.config` directly from the prop — no additional selector needed.

For `settingsTarget`, the card already imports `useInstaller`:

```ts
const settingsTarget = useInstaller((s) => s.settingsTarget);
```

This selector is added alongside the existing `openSettings` selector.

---

## 6. File Change Summary

| File | Change type | Notes |
|---|---|---|
| `gui/src/store/installer-store.ts` | Edit | Replace `OpenclawConfig`/`HermesConfig`, add new types, add `isAgentConfigured`, update `initialAgents`, update `updateAgentConfig` type annotation |
| `gui/src/components/installer/AgentCard.tsx` | Edit | Add `settingsTarget` selector, add `UnconfiguredHint` inline component, render after body block |
| `gui/src/components/installer/SettingsPanel.tsx` | Rewrite | Replace placeholder empty state with `ModelSection` + `ChannelSection` form |

No other files change. Specifically: `Sidebar.tsx`, `AppSettingsPanel.tsx`, `App.tsx`, `api/installer.ts`, all Rust files — untouched.
