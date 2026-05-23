# OpenClaw 三大 IM 频道自动化配置调研

**Host**: OpenClaw 2026.5.20 at `/Users/yanxuan.lc/.local/share/pnpm/global/v11/12dfe-19e549e7092/node_modules/openclaw/`
**调研模式**: 只读 + 沙盒 `OPENCLAW_STATE_DIR=$(mktemp -d)`，无真实凭据落盘
**调研日期**: 2026-05-23
**调研范围**: Feishu / 个人微信 (Weixin) / QQ Bot 三个频道的自动化配置可行性

---

## TL;DR — 一键自动配置可行性结论

| Channel | npm 包 | 全自动可行性 | 关键阻塞 |
| --- | --- | --- | --- |
| **QQ Bot** | `@openclaw/qqbot` | ✅ **完全可自动** | 仅外部步骤：用户到 q.qq.com 拿 AppID+AppSecret，本地全无 prompt |
| **Feishu** | `@openclaw/feishu` | ⚠️ **绕过 CLI、直接写 `openclaw.json` 可自动**；走 `channels add/login` CLI **做不到** | CLI `--token / --use-env` 对 feishu 是空操作（已实测），`channels login` 是强交互 wizard |
| **个人微信** | `@tencent-weixin/openclaw-weixin@2.4.3` | ❌ **本质做不到全自动** | 必须扫码登录。CLI 明确返回 `does not support non-interactive add`。GUI 只能"内嵌扫码面板" |

**核心建议**：所有三个频道的"自动配置"统一收敛到 **`plugins install <spec>` → 直接写 `openclaw.json` → `gateway restart`** 这套底座。不要依赖 `openclaw channels add --channel xxx --token ...` 这条 CLI 路径——只有 qqbot 真正实现了它。

---

## Section 1: OpenClaw Channel 架构

### 1.1 频道 = 可下载 npm 插件
OpenClaw 内置的频道只有 `telegram / signal / imessage`（验证：`dist/extensions/` 下只有这三家）。所有其他频道（feishu/qqbot/weixin/discord/whatsapp/slack/…共 26 家）都是按需下载的 npm 插件。可安装清单硬编码在两个地方：
- `dist/channel-catalog.json`（JSON 静态目录）
- `dist/official-external-plugin-catalog-D-Ciwiq2.js`（CLI 运行时读取的同一份数组）

每条目带 `install.npmSpec / defaultChoice / minHostVersion / expectedIntegrity`。

### 1.2 插件安装与持久化
执行 `openclaw plugins install <spec>`（或 `channels add --channel <id>` 会触发同一安装器）后：
- 解包到 `$OPENCLAW_STATE_DIR/npm/node_modules/<pkg>/`（默认 `~/.openclaw`）
- 状态写入 `$OPENCLAW_STATE_DIR/plugins/installs.json`，含 `installRecords.<pluginId>.{spec, installPath, resolvedVersion, integrity, shasum}`
- 通过 `peerDependencies.openclaw` symlink 回到 host
- 安装幂等；重复执行 short-circuit
- 安装走 `--ignore-scripts`（依赖代码不会被 npm preinstall hook 执行）

**npm 镜像注意**：installer 里 `INSTALLER_NPM_REGISTRY=https://registry.npmmirror.com/` 仅影响 host 自身的 `pnpm add -g openclaw` 下载。OpenClaw managed npm root 走哪个 registry 在源码里没找到显式开关，是 follow-up（建议 GUI 至少能透传 npm-related 环境变量）。

### 1.3 `channels add` vs `channels login` vs `configure --section channels`

| 命令 | 用途 | 交互需求 |
| --- | --- | --- |
| `channels add --channel <id> --token ...` | "加账号"，每个 channel 决定自己接受哪些 flag | 取决于插件实现 |
| `channels login --channel <id>` | "链接外部账号"（QR、OAuth、外部 wizard） | 几乎都强交互 |
| `configure --section channels` | 全交互 wizard | 完全交互 |
| `gateway restart` | 凭据变更后必须 | 无 |

CLI flag 字典（host 提供，源码 `dist/channels-cli-CeVturb2.js:297`）：`--account / --token / --token-file / --secret / --secret-file / --app-token / --bot-token / --password / --use-env / --name / …`。**这只是 host 暴露的 flag 集合**，每个 flag 对哪个 channel 有意义、什么含义，由插件内部的 `setup.validateInput / setup.applyAccountConfig` 决定——插件不实现就是空操作（这是 feishu 的坑）。

### 1.4 配置文件结构

主配置：`$STATE_DIR/openclaw.json`。频道部分形如：

```jsonc
{
  "plugins": { "entries": { "<plugin-id>": { "enabled": true } } },
  "channels": {
    "<channel-id>": {
      "enabled": true,
      // ... channel-specific 字段
      "accounts": { "default": { /* 多账号覆盖 */ } }
    }
  }
}
```

`plugins.entries.<id>.enabled` 是必须的，没它就算装了也被视为 disabled。

频道 secret 支持三种形态：明文 string、`{ source: "env"|"file"|"exec", provider, id }` SecretRef 对象、`<channel>SecretFile: "/path"`。

---

## Section 2: Feishu — `@openclaw/feishu`

### 2.1 安装
- npm: `@openclaw/feishu@2026.5.20`
- minHost: `>=2026.4.25`
- 主依赖：`@larksuiteoapi/node-sdk@1.65.0`、`zod`、`typebox`
- 安装实测 OK：`openclaw plugins install @openclaw/feishu` 在沙盒 STATE_DIR 顺利完成

### 2.2 凭据模型（来源：`docs/channels/feishu.md` Configuration Reference + `dist/channel-Bp7ymPWB.js`）

| 字段 | 来源 | 必须 | 说明 |
| --- | --- | --- | --- |
| `channels.feishu.appId` | 飞书开放平台自建应用 | ✅ | `cli_xxx` |
| `channels.feishu.appSecret` | 同上 | ✅ | secret |
| `channels.feishu.encryptKey` | 同上 | 仅 webhook 模式 | WebSocket 模式（默认）不需要 |
| `channels.feishu.verificationToken` | 同上 | 仅 webhook 模式 | 同上 |
| `channels.feishu.domain` | `"feishu"` / `"lark"` | 默认 feishu | 国际版选 lark |
| `channels.feishu.connectionMode` | `"websocket"` / `"webhook"` | 默认 websocket | **推荐保持 websocket** —— 不需要公网回调 |

**WebSocket 模式（默认）+ appId/appSecret 即可工作**。这是 GUI 自动化的关键利好——免去回调 URL/反向代理这一整套外部依赖。

凭据获取入口（用户必须外部手工操作）：
- 国内：<https://open.feishu.cn/> → 开发者后台 → 创建自建应用 → 凭证与基础信息
- 国际：<https://open.larksuite.com/>
- 必须额外勾选事件订阅 `im.message.receive_v1` + 相关权限 scopes（无自动化方案）

### 2.3 自动化可行性 — 关键 negative finding

**实测**（沙盒 STATE_DIR）：

```
$ openclaw channels add --channel feishu --token 'cli_test:fakesecret'
Added Feishu account "default".

# openclaw.json 实际内容：
"channels": { "feishu": { "enabled": true } }   ← token 被静默丢弃
```

`--use-env` 也无效（设 `FEISHU_APP_ID/FEISHU_APP_SECRET` 后跑 `channels add --channel feishu --use-env`，结果同样只有 `enabled:true`）。

**源码佐证**：`@openclaw/feishu/dist/channel-Bp7ymPWB.js:737` 的 `feishuSetupAdapter` 只导出 `resolveAccountId / applyAccountConfig(enabled:true)`，**没有** `validateSetupInput / applySetupAccountConfig` 这两个 host 用来消化 flag 的钩子。对比 `@openclaw/qqbot/dist/config-schema-CfbaUZcI.js:477,485-493` 有完整实现——所以 host 把 `--token` 传过来后 feishu 不知道怎么处理就丢了。

`channels login --channel feishu` 是强交互（`runFeishuLogin → promptFeishuSetupMethod → prompter.select(manual/scan) → prompter.text(appId) → prompter.text(appSecret) → prompter.select(groupPolicy)`），无法 piped stdin。

**可行方案：直接写 `openclaw.json`**

```jsonc
{
  "plugins": { "entries": { "feishu": { "enabled": true } } },
  "channels": {
    "feishu": {
      "enabled": true,
      "appId": "cli_xxxxxxxx",
      "appSecret": "yyyyyyyyy",
      "connectionMode": "websocket"
    }
  }
}
```

**能 work 的证据**：插件运行时 `dist/accounts-CRcvqpsl.js:285-300` `resolveFeishuAccount` 直接从 `cfg.channels.feishu.{appId, appSecret}` 读取，没有"必须经过 setupWizard 才能识别"的状态。写完后 `openclaw gateway restart` 即可。

### 2.4 GUI 字段

| 字段 | UI | 校验 | 帮助文案 |
| --- | --- | --- | --- |
| Domain | 单选 feishu/lark | — | 国内选 feishu，海外选 lark |
| App ID | 文本 | `cli_` 前缀 | open.feishu.cn → 应用 → 凭证与基础信息 |
| App Secret | 密码 | 非空 | 同页 App Secret（仅创建时可见一次） |
| Group Policy | 单选 allowlist/open/disabled | 默认 allowlist | — |
| Allow open_id | 可选文本（逗号分隔） | `ou_` 前缀 | 首次跑起来后 `openclaw logs --follow` 拿 |

**GUI 自动可做**：检查 host ≥ 2026.4.25 → `plugins install @openclaw/feishu` → 写 `openclaw.json` → `gateway restart`。

**GUI 不能做（用户外部）**：到飞书开放平台建自建应用、勾选 `im.message.receive_v1` 权限、选 WebSocket 模式、把机器人加群。GUI 应固定显示"打开飞书开放平台"按钮（`shell.open("https://open.feishu.cn/app")`）。

### 2.5 已知坑
- 飞书国内 App 有时不响应"扫码自动建应用"的二维码（docs 自承认）。GUI 走 manual 路径更稳。
- AppSecret 泄露后只能在后台重置（无法 rotate）；密码框严禁日志打印。

---

## Section 3: QQ Bot — `@openclaw/qqbot`

### 3.1 安装
- npm: `@openclaw/qqbot@2026.5.20`
- minHost: `>=2026.4.10`
- 主依赖：`@tencent-connect/qqbot-connector@1.1.0`、`ws@8.20.1`、`silk-wasm`（语音转码）
- 安装实测 OK

### 3.2 凭据模型（来源：`openclaw.plugin.json` configSchema + `dist/config-schema-CfbaUZcI.js`）

| 字段 | 必须 | 说明 |
| --- | --- | --- |
| `channels.qqbot.appId` | ✅ | QQ 开放平台机器人 AppID（纯数字） |
| `channels.qqbot.clientSecret` | ✅ | AppSecret；可填 string 或 SecretRef 对象 |
| `channels.qqbot.clientSecretFile` | 替代 | 从文件读 secret；**appId 仍需 config 或 `QQBOT_APP_ID`** |

**Env fallback**（仅 default 账号）：`QQBOT_APP_ID` + `QQBOT_CLIENT_SECRET`，源码 `dist/config-schema-CfbaUZcI.js:358-360`。

凭据获取（用户外部）：<https://q.qq.com/> → 手机 QQ 扫码登录 → 创建机器人 → 复制 AppID + AppSecret（**AppSecret 离开页面就不可重看，必须当场存**）。

### 3.3 自动化可行性 — ✅ 完全可自动

**实测**：

```
$ openclaw channels add --channel qqbot --token '11111:fakesecret'
Added QQ Bot account "default".

# openclaw.json:
"channels": {
  "qqbot": { "enabled": true, "allowFrom": ["*"], "appId": "11111", "clientSecret": "fakesecret" }
}
```

非交互 flag 映射（源码 `dist/config-schema-CfbaUZcI.js:388-424` parseInlineToken / validateSetupInput / applySetupAccountConfig）：

| Flag | 含义 |
| --- | --- |
| `--token "AppID:AppSecret"` | 一次性传两个值，冒号分隔 |
| `--token-file <path>` | 文件里只放 AppSecret；AppID 必须另外提供 |
| `--use-env` | 仅 default 账号，读 `QQBOT_APP_ID + QQBOT_CLIENT_SECRET` |
| `--account <id>` | 账号别名（多机器人） |

也可以走"直接写 openclaw.json"路径（和 feishu 一样的底座）。

**扫码绑定** 也存在（`dist/config-schema-CfbaUZcI.js:501-528` `linkViaQrCode`，调 `@tencent-connect/qqbot-connector` 的 `qrConnect`），但只在交互 wizard 内部，flag 进不去；**v1 建议不做扫码，让用户手填 AppID/AppSecret**，100% 可控。

### 3.4 GUI 字段

| 字段 | UI | 校验 | 帮助文案 |
| --- | --- | --- | --- |
| AppID | 文本 | 数字串 | q.qq.com → 沙箱/正式管理 → 设置 → AppID |
| AppSecret | 密码 | 非空 | 同页 AppSecret（离开页面无法重看，请立即复制） |
| Account 别名 | 文本（可选） | 默认 default | 多机器人才填 |

**GUI 自动可做**：检查 host ≥ 2026.4.10 → `channels add --channel qqbot --token "${appId}:${secret}"`（或等价的 plugins install + 写 config）→ `gateway restart`。

**GUI 不能做（用户外部）**：q.qq.com 建机器人、沙箱→正式发布、加群。

### 3.5 已知坑
- AppSecret 不二次明文展示——GUI 帮助文案要强提醒。
- 群里默认要 @机器人才能触发（`groups["*"].requireMention: false` 可关）。
- 主动消息 24h 限频（QQ 平台限制，非 OpenClaw）。
- C2C 私聊需要用户先发起对话。

---

## Section 4: 个人微信 — `@tencent-weixin/openclaw-weixin@2.4.3`

### 4.1 安装
- npm: `@tencent-weixin/openclaw-weixin@2.4.3`（catalog 里**硬钉 2.4.3**，host 升级不会自动升 Weixin）
- minHost: `>=2026.3.22`
- 主依赖：`qrcode-terminal@0.12.0`、`zod`、`silk-wasm`
- channelId 是 `openclaw-weixin`（CLI/config 用这串；GUI 给用户展示可以叫"微信"）
- 安装实测 OK：`openclaw plugins install '@tencent-weixin/openclaw-weixin@2.4.3'`

### 4.2 凭据模型 — 与前两家完全不同

**没有传统"凭据"** ——个人微信不能像企业微信/飞书那样在开发者后台拿 appId/secret。`@tencent-weixin/openclaw-weixin` 通过 Tencent 的 `ilinkai.weixin.qq.com` iLink API 走 QR 扫码登录。

状态存储位置：

```
$STATE_DIR/openclaw-weixin/
  ├── accounts.json                  # 已登录 accountId 列表（数组）
  └── accounts/
      └── <accountId>.json           # { token, baseUrl, userId, ... } 长期会话凭据
```

`openclaw.json` 里 `channels["openclaw-weixin"]` 配置极简（源码 `dist/src/config/config-schema.js`）：

```jsonc
{
  "channels": {
    "openclaw-weixin": {
      "enabled": true,
      "channelConfigUpdatedAt": "2026-05-23T..."  // 插件每次登录成功后自动更新
    }
  }
}
```

允许的字段只有 `baseUrl / cdnBaseUrl / routeTag / name / enabled / accounts`。**token 永远不进 openclaw.json**。

### 4.3 自动化可行性 — ❌ 全自动做不到

**实测**：

```
$ openclaw channels add --channel openclaw-weixin --use-env
Channel "openclaw-weixin" does not support non-interactive add.
```

源码 `dist/src/auth/login-qr.js`：必须调 `ilinkai.weixin.qq.com/ilink/bot/get_bot_qrcode` 拉一张 QR 图，然后 long-poll `get_qrcode_status` 等手机扫码确认；可选还要 stdin 输入 `verify_code`（行 52-69 `readVerifyCodeFromStdin`），是真·必须有 TTY 的交互。

### 4.4 GUI 可做的部分（半自动）

1. **预安装阶段（全自动）**：
   - `openclaw plugins install '@tencent-weixin/openclaw-weixin@2.4.3'`
   - 写 `openclaw.json`：`plugins.entries["openclaw-weixin"].enabled=true` + `channels["openclaw-weixin"].enabled=true`
   - `gateway restart`
2. **登录阶段（半自动）**：
   - **路径 A（推荐）**：GUI spawn `openclaw channels login --channel openclaw-weixin --verbose`，pty 抓 stdout，提取 QR URL，在 GUI Canvas 里重画二维码；用户扫码后插件自己 long-poll 收到状态、写盘 token
   - **路径 B**：README.zh_CN.md 提到插件注册了 `weixin_login` 等 MCP tool。若 GUI 已能通过 gateway HTTP RPC 对话，可以用 RPC 触发登录、拿 QR URL，比 spawn CLI 更可控（**待验证**——见 §7 open question）
3. **会话续期（自动）**：token 落盘后插件每次 gateway 启动自动加载；除非过期/被踢，不需要重登

### 4.5 GUI 字段

| 字段 | UI |
| --- | --- |
| 二维码 | Canvas/Image 渲染 |
| 重新生成 | 按钮 → 重跑 channels login |
| 账号别名 | 文本（可选，多账号才填）|
| 状态 | Badge：等待扫码 / 已扫码待确认 / 已登录 / 失败 |

**注意**：完全没有"输入框让用户粘贴密码"——这是 UX 上和前两个频道最大的不同：feishu/qqbot 是"配置表单"，weixin 是"扫码面板"。

### 4.6 已知坑 / Tencent ToS
- 微信官方对个人号自动化政策长期模糊。`@tencent-weixin/*` 由 Tencent 微信团队自己发布（`author: "Tencent"`、MIT），可视作半官方支持，但不要用于大规模商用。
- token 失效（被踢、长时间未活动）后会回到未配置状态；GUI 需要监听 `channels status` 感知。
- **不支持群聊**（docs 自承认 "Group chats are not advertised by the current plugin capability metadata"）。
- catalog 里 npm spec 硬钉 `@2.4.3`，host 升级不会自动升 Weixin；要升级需 `plugins install '@tencent-weixin/openclaw-weixin' --force`。

---

## Section 5: 横向对比表

| 维度 | Feishu | QQ Bot | Weixin |
| --- | --- | --- | --- |
| npm 包 | `@openclaw/feishu` | `@openclaw/qqbot` | `@tencent-weixin/openclaw-weixin@2.4.3` |
| channelId | `feishu` | `qqbot` | `openclaw-weixin` |
| minHost | 2026.4.25 | 2026.4.10 | 2026.3.22 |
| 凭据形态 | appId+appSecret | appId+clientSecret | QR-login token（本地状态目录） |
| Env fallback | ❌（只作交互默认值） | ✅ `QQBOT_APP_ID/CLIENT_SECRET` | ❌ |
| `channels add --token` | ❌ 静默丢弃 | ✅ `"appId:secret"` | ❌ 返回 "does not support" |
| `channels add --use-env` | ❌ 不持久化 | ✅ default 账号 | ❌ |
| `channels login` | 交互必需 | 可跳过（手填 config 即可） | **唯一入口** |
| 不可自动化步骤 | 飞书开放平台建应用、勾权限、加群 | q.qq.com 建机器人、发布、加群 | 用户手机扫码、确认登录 |
| 配置落盘位置 | `channels.feishu.{appId,appSecret,domain,...}` | `channels.qqbot.{appId,clientSecret,...}` | `channels["openclaw-weixin"].{enabled}` + `$STATE/openclaw-weixin/accounts/*.json` |
| 公网回调 | 不需要（WebSocket 默认） | 不需要 | 不需要 |
| 二次激活 | `gateway restart` | `gateway restart` | `gateway restart`（首次） |
| 文档 | `docs/channels/feishu.md` | `docs/channels/qqbot.md` | `docs/channels/wechat.md` |

---

## Section 6: 推荐的 GUI 设计

### 6.1 统一策略
**不要走"反射 CLI 的非交互能力"路线**（feishu/weixin 都不行）。统一改成：

1. GUI 自己把每个 channel 的配置展平成一份 `openclaw.json` patch
2. `openclaw plugins install <spec>` 装好插件（幂等）
3. 写 `openclaw.json`（GUI 拥有该文件读写权）
4. `openclaw gateway restart`
5. weixin 例外：写完 enabled 后还要 spawn 一次 `channels login`，把 QR 抓到面板

这样每个频道的 UX 是统一的"配置表单 → 应用"，唯独 weixin 在"应用"之后多一步"扫码"。

### 6.2 ASCII Wireframe

```
╔═══════════════════════════════════════════════════════════╗
║  Feishu（飞书）                                            ║
╠═══════════════════════════════════════════════════════════╣
║  ⓘ 先到飞书开放平台建一个自建应用 → [打开飞书后台 ⤴]        ║
║                                                            ║
║  Domain        ◉ feishu (国内)   ○ lark (海外)              ║
║  App ID        [ cli_a1b2c3d4e5f6...                  ]    ║
║  App Secret    [ ************************             ] 👁 ║
║  Group policy  [ allowlist ▾ ]                             ║
║  Allow open_id [ ou_xxx, ou_yyy            (可选, 逗号分隔)║
║                                                            ║
║  [ 取消 ]                            [ 应用并重启 Gateway ] ║
╚═══════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════╗
║  QQ Bot                                                    ║
╠═══════════════════════════════════════════════════════════╣
║  ⓘ 先到 QQ 开放平台建一个机器人 → [打开 q.qq.com ⤴]        ║
║  ⚠ AppSecret 离开网页就无法重看，请当场复制。              ║
║                                                            ║
║  AppID        [ 102000000                             ]    ║
║  AppSecret    [ ***************                       ] 👁 ║
║  Account 别名 [ default                  (多机器人才填) ]   ║
║                                                            ║
║  [ 取消 ]                            [ 应用并重启 Gateway ] ║
╚═══════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════╗
║  个人微信 Weixin                                            ║
╠═══════════════════════════════════════════════════════════╣
║  ⓘ 仅支持私聊。需手机微信扫码登录，登录后会话长期保存。     ║
║                                                            ║
║          ┌────────────────────────┐                        ║
║          │     [ QR 码渲染 ]      │   状态：等待扫码…       ║
║          └────────────────────────┘                        ║
║          [ 重新生成二维码 ]                                 ║
║                                                            ║
║  ⚠ Tencent 自动化政策长期模糊，请勿用于商用大规模场景。     ║
║                                                            ║
║  [ 取消 ]                                                   ║
╚═══════════════════════════════════════════════════════════╝
```

### 6.3 后端动作映射

```bash
# 通用前置（幂等）
openclaw plugins install <npmSpec>

# Feishu / QQ Bot：写 config
openclaw config set channels.feishu.appId <val>
openclaw config set channels.feishu.appSecret <val>
# 或：直接 jq 改 openclaw.json
openclaw gateway restart

# Weixin：额外起 login
openclaw channels login --channel openclaw-weixin --verbose
# GUI 进程 pty 抓 stdout，提取 QR URL，渲染到面板
```

### 6.4 状态显示
`openclaw channels status --json` 给出每个 channel `configured / installed / enabled / works`。卡片上展示徽章。**不要在列表轮询用 `--probe`**——它会真打 API（飞书 token 检查 / QQ Bot 心跳 / 微信 iLink 探测），只在用户点"测试连接"时打。

---

## Section 7: Open Questions / 待验证

1. **OpenClaw managed npm 镜像**：installer 里 `INSTALLER_NPM_REGISTRY` 只控制 host 安装。OpenClaw managed npm root 装频道插件时走哪个 registry？是否有 `OPENCLAW_NPM_REGISTRY` 环境变量？源码 grep 未找到，建议运行时观察 `$STATE_DIR/npm/.npmrc`。
2. **Weixin 走 MCP tool 登录**：README 提到 plugin 注册了 `weixin_login` MCP tool。GUI 若已能与 openclaw gateway HTTP RPC 对话，可能能用 RPC 触发登录、拿 QR URL，UX 比 spawn CLI 好。需要进一步看 `@tencent-weixin/openclaw-weixin/dist/src/api/`。
3. **QQ Bot 扫码绑定独立化**：`@tencent-connect/qqbot-connector.qrConnect` 路径能扫码自动拉回 AppID/AppSecret。如果可以直接从 GUI 调（不走交互 wizard），是比"手填 AppSecret"更顺的 UX。需要看 `@tencent-connect/qqbot-connector` 包能否独立调用。
4. **Feishu webhook 模式**：本调研只覆盖 WebSocket（默认）。webhook 模式需要 `webhookHost/Port/Path` + `encryptKey/verificationToken`，且要让用户回填 callback URL 到飞书后台。**不在 v1 自动化范围**。
5. **domain 自动探测**：是否需要根据用户网络环境自动选 feishu vs lark？v1 让用户自选即可。
6. **多账号 UX**：本报告默认单账号。GUI v1 不暴露 `accounts.<id>` 多账号配置。

---

## References

**本地 OpenClaw 源（host）**
- `/Users/yanxuan.lc/.local/share/pnpm/global/v11/12dfe-19e549e7092/node_modules/openclaw/`
  - `dist/channel-catalog.json`、`dist/official-external-plugin-catalog-D-Ciwiq2.js`：频道目录
  - `dist/channels-cli-CeVturb2.js`：channels add/login/configure CLI 实现
  - `docs/channels/{feishu,qqbot,wechat}.md`：官方频道指南
  - `docs/cli/{channels,configure,plugins}.md`：CLI 文档

**频道插件源码**（沙盒 `mktemp -d` 装出来后读的）
- `@openclaw/feishu/dist/channel-Bp7ymPWB.js`：`feishuSetupAdapter @ 737`、`runFeishuLogin @ 1081`；`accounts-CRcvqpsl.js @ 285-300` 凭据 resolve 逻辑
- `@openclaw/qqbot/dist/config-schema-CfbaUZcI.js`：`qqbotSetupAdapterShared @ 477`、`parseInlineToken @ 388`、`finalizeQQBotSetup @ 546`、`linkViaQrCode @ 501`
- `@tencent-weixin/openclaw-weixin/dist/src/auth/{accounts,login-qr,pairing}.js`、`config/config-schema.js`、`channel.js`

**实测 CLI 交易记录**
- `openclaw channels add --channel qqbot --token '11111:fakesecret'` → ✅ 写入 appId/clientSecret
- `openclaw channels add --channel feishu --token 'cli_test:fakesecret'` → ❌ token 静默丢弃
- `openclaw channels add --channel feishu --use-env` + `FEISHU_APP_ID/SECRET` → ❌ 不持久化
- `openclaw channels add --channel openclaw-weixin --use-env` → ❌ "does not support non-interactive add"

**Vendor portals**
- Feishu: <https://open.feishu.cn/app>（国内）、<https://open.larksuite.com/>（国际）
- QQ Bot: <https://q.qq.com/>
- Weixin: 无开发者后台（个人号 QR 登录）

**项目现状**
- `gui/src/store/installer-store.ts:41`：`ChannelId = "wechat" | "feishu" | "dingtalk" | "bubbolink"`（仅 UI 选择，无 provisioning）
- `shell/agents/openclaw/install.sh`：尚无频道配置逻辑
- 上一轮存档：`openspec/changes/archive/2026-05-23-agent-model-channel-config/`
