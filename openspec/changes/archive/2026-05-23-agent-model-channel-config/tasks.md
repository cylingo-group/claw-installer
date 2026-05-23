# Tasks: agent-model-channel-config

Ordered implementation sequence. Each task is independently verifiable via `tsc --noEmit` or visual inspection in stub mode (`cd gui && pnpm dev`). No Rust build required at any point.

---

## Phase 1: Store — type replacement

**T1.1 — Remove old config types and seed values** [x]

- Delete the `OpenclawConfig` interface.
- Delete the `HermesConfig` interface.
- Delete the `export type AgentConfig = OpenclawConfig | HermesConfig` union.
- In `initialAgents.openclaw`: replace `config: { channel: "stable", provider: "anthropic" }` with `config: { model: null, channel: null }`.
- In `initialAgents.hermes`: replace `config: { engine: "chromium", userAgent: "desktop" }` with `config: { model: null, channel: null }`.
- Verify: `tsc --noEmit` in `gui/` fails with type errors (expected: `AgentConfig` is now undefined). This failure is the expected pre-condition for T1.2.

**T1.2 — Add new config types** [x]

- Add `export type ModelProvider = "deepseek" | "kimi" | "minimax" | "xinyuan"`.
- Add `export type ChannelId = "wechat" | "feishu" | "dingtalk" | "bubbolink"`.
- Add `export interface ModelConfig { provider: ModelProvider; apiKey: string; modelName: string; }`.
- Add `export interface AgentConfig { model: ModelConfig | null; channel: ChannelId | null; }`.
- Verify: `tsc --noEmit` now passes (or reveals only pre-existing errors unrelated to this change).

**T1.3 — Add `isAgentConfigured` utility** [x]

- Export `isAgentConfigured(agent: AgentState): boolean` with the logic from the design doc (§1.5).
- Place it near the bottom of the type-declaration section, before the `MIRROR_TABLE` or similar constants.
- Verify: function is callable with a mock `AgentState` in the TypeScript playground or test — logically: `isAgentConfigured({ ...agent, config: { model: null, channel: null } })` → `false`; `isAgentConfigured({ ...agent, config: { model: { provider: "deepseek", apiKey: "sk-x", modelName: "deepseek-chat" }, channel: "feishu" } })` → `true`.

---

## Phase 2: AgentCard — "未配置" guidance row

**T2.1 — Add `settingsTarget` selector to `AgentCard`** [x]

- Import `useInstaller` already exists. Add:
  ```ts
  const settingsTarget = useInstaller((s) => s.settingsTarget);
  ```
  alongside the existing `openSettings` selector.
- No visual change yet; this is purely additive.

**T2.2 — Implement `UnconfiguredHint` inline component** [x]

Define a named function inside `AgentCard.tsx`:

```ts
function UnconfiguredHint({ agent, onOpen }: { agent: AgentState; onOpen: () => void }) {
  // compute modelMissing, channelMissing
  // derive copy string
  // render a compact <button> that calls onOpen()
}
```

See design doc §3.2 for the copy lookup table and §3.4 for visual constraints.

**T2.3 — Render `UnconfiguredHint` in `AgentCard`** [x]

After the `{hasBody && (...)}` block, add:

```tsx
{!isAgentConfigured(agent)
  && !transitioning
  && settingsTarget !== agent.id
  && <UnconfiguredHint agent={agent} onOpen={() => openSettings(agent.id)} />}
```

- Verify (stub mode): both cards show the guidance row on initial load.
- Verify: clicking the row opens the SettingsPanel for that agent (panel slides in).
- Verify: during simulated install (click "一键安装全部"), the guidance row disappears while agents are `installing`.

---

## Phase 3: SettingsPanel — rewrite form body

**T3.1 — Define provider constants and URL map** [x]

At the top of `SettingsPanel.tsx` (or in a co-located constants block), define:

```ts
const PROVIDER_LABELS: Record<ModelProvider, string> = {
  deepseek: "DeepSeek",
  kimi:     "Kimi",
  minimax:  "MiniMax",
  xinyuan:  "心元",
};

const PROVIDER_API_KEY_URLS: Record<Exclude<ModelProvider, "xinyuan">, string> = {
  deepseek: "https://platform.deepseek.com/api_keys",
  kimi:     "https://platform.moonshot.cn/console/api-keys",
  minimax:  "https://platform.minimaxi.com/user-center/basic-information/interface-key",
};

const CHANNEL_LABELS: Record<ChannelId, string> = {
  wechat:    "微信",
  feishu:    "飞书",
  dingtalk:  "钉钉",
  bubbolink: "BubboLink",
};
```

Import `ModelProvider`, `ChannelId` from the store.

**T3.2 — Implement `ModelSection` sub-component or inline section** [x]

- Read `agent.config.model` from props/store.
- Render a 4-option radio group matching the design doc §4.2.
- When non-心元 selected: render API Key input (password + show/hide toggle) + Model Name input + deep-link.
- When 心元 selected: render placeholder text.
- Each `onChange` calls `updateAgentConfig` as specified in design doc §4.3.
- Local `useState<boolean>` for the show/hide toggle.

**T3.3 — Implement `ChannelSection` sub-component or inline section** [x]

- Read `agent.config.channel` from props/store.
- Render a 4-option radio group matching the design doc §4.4.
- Each selection calls `updateAgentConfig(id, { channel: value })`.

**T3.4 — Wire `ModelSection` and `ChannelSection` into panel body** [x]

Replace the placeholder empty-state `<div className="flex flex-1 flex-col items-center justify-center ...">` with:

```tsx
<div className="flex-1 overflow-y-auto px-5 py-5 space-y-6">
  <ModelSection ... />
  <ChannelSection ... />
</div>
```

The `<header>` (back button + agent name + " 配置" title) is unchanged.

**T3.5 — Smoke test in stub mode** [x]

- Open the SettingsPanel for either agent.
- Select DeepSeek → API Key field and Model Name field appear; "获取 API Key →" link appears.
- Type an API key → masked by default; show/hide toggle works.
- Select 心元 → inputs disappear; placeholder text shows.
- Select a channel → selection persists on close/reopen.
- Fill in all fields for DeepSeek + pick a channel → close panel → guidance row disappears from that card.

---

## Phase 4: TypeScript build verification

**T4.1 — Full type check** [x] — zero errors

Run `tsc --noEmit` from `gui/`. Zero errors expected.

Confirm no references remain to:
- `OpenclawConfig`
- `HermesConfig`
- `channel: "stable" | "beta" | "nightly"` (the old string union)
- `provider: "anthropic" | "openai" | "gemini"` (the old provider enum)
- `engine: "chromium" | "firefox" | "webkit"`
- `userAgent: "desktop" | "mobile"`

**T4.2 — Confirm zero Rust changes** [x] — no Rust files modified by this task

```sh
git diff HEAD -- gui/src-tauri/
```

Output must be empty.
