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

---

## v4 — 通道配置改版（2026-05-23 起）

### 背景
经 OpenClaw IM channel 调研（docs/research/2026-05-23-openclaw-channels-auto-config/report.md）
得出：飞书 `channels add --token` 静默丢弃凭据；微信只能扫码；钉钉无
docs.openclaw.ai 官方页。**只有 BubboLink 能在 GUI 内真正一键配对**，其他
三个通道用户必须自己到外部平台配。

继续把四个通道当成对等 radio 会误导用户："勾上飞书"什么都不会发生。改版
要把这种语义差异显式表达出来。

### 目标
1. **BubboLink** 是真正可在本 GUI 完成配置的通道 → 突出展示，提供 4 位 OTP
   配对码输入 + 配对按钮（调 `bubbolink pair <code> --runtime <agent>`）。
2. **微信 / 飞书 / 钉钉** 改为「参考官方文档」入口卡片，点击在系统浏览器打开。
3. L1 通道卡 summary 反映 BubboLink 配对状态（"已配对" / "未配对"）。

### 对齐结论（Phase 1）

| 维度 | 决定 |
|---|---|
| 层级策略 | **平铺四卡**：BubboLink 在最上、用 accent border + "推荐" 角标加强；下方依序 微信 / 飞书 / 钉钉，纯文档链接卡。无小标题分区。 |
| BubboLink 卡 | 标题 "BubboLink" + 副标 "从 BubboLink App 读取 4 位配对码，在本机完成绑定" + 内联小号「何为 BubboLink?」外链。已配对时右上角 success 角标。 |
| OTP 输入 | 4 个独立单字格，**加大尺寸 + 加粗间距**（h-12 w-12 / gap-2.5），rounded-xl 圆角，accent focus border。输入数字自动跳下一格；Backspace 回退；ArrowLeft/Right 导航；paste 多位数字自动分配。不自动提交——手动点"配对"。 |
| 配对按钮 | 位于 OTP 行下方，full-width；4 位齐时启用，否则灰态。配对成功 → "已配对" 角标 + 按钮变 "重新配对"。失败 → 内联红色错误框。 |
| 其他通道卡 | 标题 + 一行 blurb（"OpenClaw 官方接入指南"）+ 右侧 ExternalLink 图标；onClick 打开外部 URL。**不带 radio、无选中态**——纯导航卡。 |
| 文档 URL | 微信 → docs.openclaw.ai/channels/wechat；飞书 → docs.openclaw.ai/channels/feishu；钉钉 → github.com/DingTalk-Real-AI/dingtalk-openclaw-connector（docs.openclaw.ai 暂无钉钉页）。 |
| L1 summary | `BubboLink · 已配对` / `BubboLink · 未配对` 而非"当前：BubboLink"——更精确反映 "channel 不是 4 选 1，是 BubboLink 配没配"。 |

### 不在本轮范围
- 微信 / 飞书 / 钉钉的 in-GUI 配置流（这是 OpenClaw 上游 channel 插件的事，不归 installer 管）。
- BubboLink 多账号 / 重新生成配对码 / 在 GUI 内显示 BubboLink App 的二维码或推送。
- "测试连接" 按钮——配对成功 = 已生效，不需要二次健康检查。
- 配对状态持久化：bubbolink CLI 自己保管 session，本 GUI 只做 in-memory 徽章。
