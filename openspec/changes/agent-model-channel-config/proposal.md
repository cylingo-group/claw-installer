# Change Proposal: Agent 模型与通道配置 (in-memory)

**Slug**: `agent-model-channel-config`
**Status**: Draft
**Author**: Planner agent
**Date**: 2026-05-21

---

## Problem Statement

After a successful install, users of OpenClaw and Hermes must configure two things before an agent becomes usable: (1) which LLM provider and API key the agent will use, and (2) which IM channel (WeChat, Feishu, DingTalk, or BubboLink) it will relay messages through. Today neither piece of information is captured — the `SettingsPanel` is a placeholder that reads "配置项即将开放", and `AgentConfig` holds vestigial prototype fields (`channel: "stable"/"beta"/"nightly"`, `provider`, `engine`, `userAgent`) that map to nothing real.

The result is that a freshly-installed agent silently awaits configuration that the UI provides no path to supply. Users have no prompt to act, and developers have no place to wire configuration values once the backend is ready to consume them.

This change wires the frontend half: a usable form, a defined in-memory state shape, and an "未配置" guidance row on each card.

---

## Proposed Solution

Three coordinated changes, all frontend-only, no persistence, no Rust changes:

**1. Store — replace `AgentConfig` with a new type**

Remove `OpenclawConfig` and `HermesConfig`. Define a single `AgentConfig` that applies to both agents:

```ts
export type ModelProvider = "deepseek" | "kimi" | "minimax" | "xinyuan";
export type ChannelId     = "wechat" | "feishu" | "dingtalk" | "bubbolink";

export interface ModelConfig {
  provider:  ModelProvider;
  apiKey:    string;
  modelName: string;
}

export interface AgentConfig {
  model:   ModelConfig | null;
  channel: ChannelId | null;
}
```

Both agents share the same config shape. `initialAgents` seeds each agent with `config: { model: null, channel: null }`.

Add a pure selector/utility:

```ts
export function isAgentConfigured(agent: AgentState): boolean {
  const { model, channel } = agent.config;
  return (
    channel !== null &&
    model !== null &&
    model.provider !== null &&
    model.apiKey.trim() !== "" &&
    model.modelName.trim() !== ""
  );
}
```

Update `updateAgentConfig` signature to `(id: AgentId, patch: Partial<AgentConfig>) => void` (structurally unchanged from current signature, but now typed against the new `AgentConfig`).

**2. AgentCard — "未配置" guidance row**

After the existing body block (not-installed / transitioning / error), append a guidance row that is always evaluated independently of `hasBody`. The row is visible when `!isAgentConfigured(agent)`, regardless of install status.

The row is a compact single-line clickable affordance — low-contrast, non-obtrusive — that calls `openSettings(agent.id)` when clicked. Its copy indicates both missing steps: e.g., "完成模型配置 · IM 通道配置 →". When only one step is missing, the copy narrows (e.g., "完成 IM 通道配置 →"). Exact visual treatment (color token, icon, font size) is left to the developer's judgment within the existing design system; `text-muted` / `hover:text-foreground` and an underline-on-hover pattern matches the card's existing micro-typography tier.

The row must not appear while the agent is transitioning (`installing` | `uninstalling`) or when the `SettingsPanel` for this agent is already open — these would create confusing double-entry points during in-flight state.

**3. SettingsPanel — real configuration form**

Rewrite the panel body as two `<fieldset>` sections:

**Section A: 模型配置**

A 4-option radio group (DeepSeek / Kimi / MiniMax / 心元). When an API-key provider is selected (DeepSeek, Kimi, or MiniMax), the section expands to show:
- A hyperlink "获取 API Key →" pointing to the provider's key-management page (opens in default browser via `<a target="_blank" rel="noopener">` or Tauri's `open` shell command if needed).
- An API Key password input with a show/hide toggle.
- A Model text input (free-form; the agent consumes whatever the user types).

When 心元 is selected: show a short placeholder text ("敬请期待"), no inputs.

The section is "complete" when all three of: provider is non-xinyuan, apiKey is non-empty, and modelName is non-empty. For 心元, the section is never "complete" (it cannot satisfy the `isAgentConfigured` check).

**Section B: 通道配置**

A 4-option radio group (微信 / 飞书 / 钉钉 / BubboLink). No sub-inputs. Selecting any option marks channel configuration as complete.

Changes are committed to the store on every input event (no save button needed; the store is in-memory). Closing the panel and reopening it shows the last-entered values.

---

## Scope & Boundaries

### In Scope

- New `AgentConfig`, `ModelConfig`, `ModelProvider`, `ChannelId` types in `installer-store.ts`.
- `isAgentConfigured` exported pure function.
- `initialAgents` seeded with `config: { model: null, channel: null }` for both agents.
- Removal of `OpenclawConfig`, `HermesConfig`, and the 4 vestigial fields (`channel: "stable"/"beta"/"nightly"`, `provider`, `engine`, `userAgent`).
- "未配置" guidance row in `AgentCard`.
- Fully functional `SettingsPanel` with model + channel form sections.
- Guided "获取 API Key →" deep-links for 3 API providers.
- Password-field show/hide toggle on API Key input.
- Both OpenClaw and Hermes use the same form (no agent-specific branching in the UI).

### Explicitly Out of Scope

- Persistence (no `localStorage`, no Tauri `store` plugin, no filesystem write).
- i18n / locale switching (all copy is zh-Hans, consistent with the rest of the app).
- Validation error messages or inline field-level errors (empty fields are silently not-complete).
- Tauri Rust backend changes (no `commands.rs`, `lib.rs`, or shell script modifications).
- Forwarding config values to install scripts or runtime env vars (backend integration is a follow-on change).
- Additional test files beyond what the developer judges necessary to type-check the store.
- Any agent-specific model or channel restrictions (both agents expose the same 4 providers and 4 channels).
- 心元 sub-configuration (placeholder only; "敬请期待" copy).

---

## Key Design Decisions

**D1: Unified `AgentConfig` instead of per-agent types.**
The current per-agent type union (`OpenclawConfig | HermesConfig`) was introduced speculatively in the v1 prototype. Both agents in practice need the same configuration shape (a model and a channel). A single type is simpler, reduces branching, and does not close off per-agent divergence in a future spec (the field can be made `AgentSpecificConfig` later if needed).

**D2: `model: ModelConfig | null` rather than optional fields.**
A `null` model is unambiguously "not configured". Optional fields (`provider?: ...`) create a partial state that is harder to distinguish from "user started filling in but didn't finish". The null-or-complete shape makes `isAgentConfigured` trivial and avoids partial-config states.

**D3: No save button in SettingsPanel.**
The store is in-memory; there is nothing to persist. Each `onChange` event writes directly to the store. This matches Zustand's reactive model and removes a source of "I forgot to click Save" user error. When persistence is added in a future change, a "Save" / "Apply" button can be introduced alongside the storage write without breaking this interaction model.

**D4: Guidance row is independent of `hasBody`.**
`hasBody` governs the install-flow body block (install button, error, progress bar). The "未配置" guidance row is a separate concern: it is about configuration completeness, not install status. Keeping them independent avoids the card's body section becoming a multi-purpose patchwork.

**D5: Guidance row hidden during transition and when SettingsPanel is open.**
During `installing` or `uninstalling`, the body block already dominates the card. Adding a guidance row would compete visually and is irrelevant until the install stabilises. Hiding it when `settingsTarget === agent.id` prevents a redundant call-to-action when the user is already in the settings panel.

---

## Provider API Key URLs

| Provider | Key management URL |
|---|---|
| DeepSeek | `https://platform.deepseek.com/api_keys` |
| Kimi (Moonshot) | `https://platform.moonshot.cn/console/api-keys` |
| MiniMax | `https://platform.minimaxi.com/user-center/basic-information/interface-key` |

---

## Acceptance Criteria

**AC1 — Store type correctness:**
After the change, `tsc --noEmit` in `gui/` produces zero type errors. No reference to `OpenclawConfig`, `HermesConfig`, `channel: "stable"/"beta"/"nightly"`, `provider: "anthropic"/"openai"/"gemini"`, `engine`, or `userAgent` remains in any source file.

**AC2 — Initial state:**
On app load (stub mode or Tauri mode), both agents have `config: { model: null, channel: null }`. The "未配置" guidance row is visible on both cards.

**AC3 — Guidance row appearance:**
When an agent has `model: null` and `channel: null`, the guidance row shows text indicating both steps are needed. When `model` is complete but `channel` is null (or vice versa), the row shows text indicating only the remaining step. When both are complete (`isAgentConfigured` returns `true`), the row is absent.

**AC4 — Guidance row visibility rules:**
The guidance row is NOT shown when the agent's status is `installing` or `uninstalling`. The guidance row is NOT shown when `settingsTarget === agent.id` (settings panel is open for this agent).

**AC5 — Guidance row tap target:**
Clicking the guidance row calls `openSettings(agent.id)`, opening the `SettingsPanel` for that agent. This is identical behaviour to clicking the gear icon.

**AC6 — SettingsPanel model section: provider selection:**
Opening settings for either agent shows a 4-option model provider group. Selecting DeepSeek, Kimi, or MiniMax reveals the API Key input, Model input, and "获取 API Key →" link. Selecting 心元 shows "敬请期待" copy and no inputs. The panel correctly reflects stored state on re-open (previously selected provider and typed values persist across open/close cycles within the session).

**AC7 — SettingsPanel model section: API Key deep-link:**
Each provider's "获取 API Key →" link navigates to the correct URL (DeepSeek: `https://platform.deepseek.com/api_keys`, Kimi: `https://platform.moonshot.cn/console/api-keys`, MiniMax: `https://platform.minimaxi.com/user-center/basic-information/interface-key`). The link opens in an external browser (not the app window).

**AC8 — SettingsPanel model section: show/hide toggle:**
The API Key field defaults to `type="password"` (characters masked). An icon button adjacent to the field toggles it to `type="text"` and back. The toggle state is local to the panel (not stored in Zustand).

**AC9 — SettingsPanel channel section:**
Selecting any of the 4 channel options immediately updates `agent.config.channel` in the store. Re-opening the panel shows the previously selected channel.

**AC10 — `isAgentConfigured` completeness logic:**
`isAgentConfigured` returns `true` only when `channel !== null` AND `model !== null` AND `model.apiKey.trim() !== ""` AND `model.modelName.trim() !== ""`. For any agent with `provider === "xinyuan"` the function always returns `false` (心元 has no inputs to fill in, so configuration can never be "complete").

**AC11 — No Rust changes:**
`git diff HEAD gui/src-tauri/` produces no output. Zero Rust files are modified.

**AC12 — Stub mode visual completeness:**
`cd gui && pnpm dev` (browser, no Tauri) shows both agent cards with the "未配置" guidance row. Opening the settings panel for either agent displays both form sections. Filling in model provider, API key, model name, and channel causes the guidance row to disappear from that card.

---

## Dependencies & Risks

**Risk R1: `updateAgentConfig` type widening.**
`updateAgentConfig` currently accepts `Partial<AgentConfig>` where `AgentConfig = OpenclawConfig | HermesConfig`. After the change, `Partial<AgentConfig>` refers to `{ model?: ModelConfig | null; channel?: ChannelId | null }`. Any callsite that passes old field names (e.g., `{ provider: "anthropic" }`) will become a TypeScript error. There are currently no such callsites outside the store's own `initialAgents` — but the developer must confirm this before removal.

**Risk R2: `SettingsPanel` assumes `agent` is non-null while open.**
The store sets `settingsTarget: AgentId | null`. The panel renders only when `Boolean(target && agent)`. This invariant holds today and is unchanged by this feature. The developer should not introduce any panel-internal state that outlives the agent becoming null.

**Risk R3: External link behaviour in Tauri context.**
In a Tauri webview, `<a target="_blank">` may be blocked or open a new webview window rather than the system browser, depending on the `tauri.conf.json` `openLinksInBrowser` setting. The developer should test deep-links in the Tauri environment and use `@tauri-apps/plugin-shell`'s `open()` function if `<a target="_blank">` does not invoke the system browser.
