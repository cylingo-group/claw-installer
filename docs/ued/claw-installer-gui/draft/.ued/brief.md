# claw-installer GUI — Brief

## What this surface is
Tauri-based desktop GUI that drives the claw-installer CLI (`installer/install.sh`
on macOS/Linux, `windows/bootstrap.ps1` on Windows). Sits between an end user
and two agents — **openclaw** and **hermes** — managing their full lifecycle.

The GUI never writes the manifest. It sets `INSTALLER_*` env vars and spawns
the shell entry points; `uninstall.sh` owns rollback.

## Primary jobs
1. **First-run install** — pick agents (default: both), kick off install, show
   live progress + result. Should feel "click button, see it work, done".
2. **Ongoing service control** — start/stop/restart the openclaw gateway
   daemon, see whether it's running, swap config (gateway port, registry
   mirror, workspace dir).
3. **Repair / reinstall / uninstall** — force-reinstall, rerun on a fresh
   host, cleanly uninstall via the manifest.
4. **Logs** — view recent `install-<UTC>.log` files when something goes wrong.

## Audience
**Non-technical end users** (designers, PMs trying out the agents) are the
primary persona. Developers should also be comfortable here — they just won't
need this GUI for most things. Defaults must be sensible; "advanced settings"
should be tucked behind a single fold, not splashed across the surface.

Terminology: avoid `daemon`, `corepack`, `fnm`, `pnpm`. Prefer "background
service", "agent", "ready".

## Platform
Tauri desktop app. Three OS targets — macOS, Linux, Windows. Window size
roughly 1024×720 default, resizable down to ~800×560. **Desktop-first**;
no responsive mobile needed.

## Brand / Vibe
- **Friendly, guided** — Raycast / Arc / Linear-onboarding feel. Warm accent,
  generous spacing, soft shadows, smooth motion. Not corporate, not brutalist,
  not data-dense.
- Existing claw / openclaw brand assets: none surfaced yet — invent a coherent
  theme that suits a "developer tooling, but approachable" product.
- Dark mode: must work; users will run this alongside a terminal. Light is
  default.

## Information architecture
Persistent **Dashboard** model (not a wizard). Probable shape:
- Left: agent list — openclaw, hermes — each with a status pill
  (Not installed / Installing… / Ready / Stopped / Error).
- Right: detail pane per selected agent — install button, configure, restart,
  uninstall, view logs.
- Top-level: a global "install everything" CTA when nothing is installed yet
  (first-run shortcut so the dashboard isn't intimidating empty).

## Constraints
- Status pills + CTAs must be glanceable without scrolling.
- A long-running install must not block other interactions; logs should be
  inspectable while installing.
- Errors must offer a clear next action ("View log", "Retry", "Reinstall").
- A11y: WCAG AA contrast minimum.

## Locales
Default: `en + zh-Hans`, primary `zh-Hans` (most early users are in CN
context, but English copy must coexist for the OSS audience).

## Out of scope (for this design pass)
- Agent functionality itself (chatting with openclaw, hermes tasks). The GUI
  only manages their installation and runtime.
- Account / login / sync.
- In-GUI editing of arbitrary `openclaw config` keys — only the headline ones
  (gateway port, registry mirror, workspace).

---

## v3 — 模型配置改版（2026-05-22 起）

### 目标
现有 SettingsPanel → ModelSection 是 4 个写死厂商的手风琴（DeepSeek / Kimi /
MiniMax / 心元）。需要重构为：
1. 支持选择「知名模型供应商」+「自定义 LLM Provider」
2. 心元 Provider 展示醒目促销标记：新用户免费用

### 对齐结论（Phase 1）

| 维度 | 决定 |
|---|---|
| 交互范式 | **两级页面**：L1 `{Agent} 配置`（两张大卡） → L2 `模型配置` 或 `通道配置`（独立页）。Provider 详情在 L2 模型页**就地展开**（手风琴），不再有 L3。 |
| L1 卡片 | 模型配置 / 通道配置 各一张大卡，副标题显示当前生效项摘要（如「心元 · 新用户免费用」）。 |
| L2 模型配置 | 列出心元（hero promo 卡）/ DeepSeek / Kimi / MiniMax / 自定义模型供应商；点击任一行 → 激活并就地展开编辑区，其他卡片自动收起。单一 active provider per agent。 |
| L2 通道配置 | 4 个 IM 通道的 radio 卡。 |
| 自定义 | 名称改为「**自定义模型供应商**」（虚线边框区分）。列表行不展示 `OpenAI-compatible` 标签。展开后顶部 segmented：`OpenAI-compatible` / `Anthropic-compatible`，Base URL 与模型名 placeholder 跟随风格。字段：API 风格 / 名称 / Base URL / API Key / 模型名 / 可选 Headers。 |
| 心元促销 | hero promo 卡（横幅 + Gift + `PROMO` 角标 + `推荐` chip）。展开后是 disabled `敬请期待` 按钮。 |
| 心元功能完成度 | **仅占位**。展开区只有占位文案 + 不可点的"敬请期待"按钮。 |

### 不在本轮范围
- 心元的 OAuth / 手机号登录流。
- 心元额度展示（剩余 token 数）。
- 多自定义 Provider 管理。
- Provider 按协议族分类（OpenAI / Anthropic / Ollama 等）。
