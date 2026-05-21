# Change: agent-model-channel-config

| Field | Value |
|---|---|
| Status | Draft |
| Type | Feature |
| Scope | `gui/src/store/installer-store.ts` (edit), `gui/src/components/installer/AgentCard.tsx` (edit), `gui/src/components/installer/SettingsPanel.tsx` (rewrite) |
| Stack | React 19, TypeScript, Tailwind v4, Zustand |

## Summary

Replaces the placeholder `SettingsPanel` ("配置项即将开放") with a real two-section configuration form (model provider + IM channel). Extends `AgentConfig` in the Zustand store to hold model and channel selections in memory. Adds an "未配置"引导行 at the bottom of `AgentCard` when configuration is incomplete. No Rust/Tauri changes. No persistence.

## Artifacts

- [Proposal](./proposal.md) — problem statement, solution design, AC, scope boundaries
- [Design](./design.md) — type contracts, component tree, interaction flows, state transitions
- [Tasks](./tasks.md) — ordered implementation breakdown

## Top Risks

1. **`AgentConfig` type replacement**: the existing union `OpenclawConfig | HermesConfig` is referenced by `updateAgentConfig` and `initialAgents`. Replacing it must not break in-progress install/uninstall flows.
2. **Placeholder fields**: the old `channel`/`provider`/`engine`/`userAgent` fields are consumed nowhere in the current codebase beyond `initialAgents` — confirmed safe to remove, but warrants a TypeScript build check before and after.
