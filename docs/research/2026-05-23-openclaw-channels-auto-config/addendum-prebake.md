# 调研 Addendum：在依赖安装阶段直接预装三个 channel npm 包

**目标**：判断 claw-installer 能否在 `shell/install.sh` 走完依赖步骤后，直接把 `@openclaw/feishu` / `@openclaw/qqbot` / `@tencent-weixin/openclaw-weixin@2.4.3` 三个 channel 插件全部装好，让 GUI 阶段只需要"填表 → 写 config → 重启 gateway"。

**结论：✅ 可行，并且推荐这么做。** 配额 ~53MB 磁盘、~30-90s 网络（取决于 npmmirror 速度），且没有额外的系统级依赖。

---

## TL;DR — 真实沙盒验证结果

在干净的 `OPENCLAW_STATE_DIR=$(mktemp -d)` 跑：

```bash
openclaw plugins install @openclaw/feishu
openclaw plugins install @openclaw/qqbot
openclaw plugins install '@tencent-weixin/openclaw-weixin@2.4.3'
```

| 维度 | 实测值 |
| --- | --- |
| **交互性** | 全部 `</dev/null` 通过，零 TTY 提示（**包括 weixin**——它只在 `channels add/login` 拒绝非交互，`plugins install` 完全 OK） |
| **是否需要 gateway 在跑** | 否。装完显示 "Restart the gateway to load plugins"，但 install 本身不依赖 daemon |
| **磁盘** | `~/.openclaw/npm/node_modules/` 累计 **53MB**（三家共享 npm flat-tree） |
| **每插件本体** | feishu 724K, qqbot 788K, weixin 968K。大头是依赖 |
| **运行时依赖** | 纯 JS + WASM（`silk-wasm` ≈10MB；`@larksuiteoapi/node-sdk` ≈25MB；`axios/protobufjs/ws/zod` 等）。**无 node-gyp，无原生编译** |
| **registry** | 继承 `~/.npmrc` → 已验证全量 tarball 来自 `registry.npmmirror.com`（installer 的 `npmrc` step 已经搞定）|
| **安装后 openclaw.json** | 自动写入 `plugins.entries.{feishu,qqbot,openclaw-weixin}.enabled=true` |
| **discovery 验证** | `openclaw plugins list --json` 三个全部 `status: loaded` |
| **重复执行** | ❌ 不幂等：第二次返回 rc=1 `plugin already exists ... delete it first`。需要 fast-path 跳过，或用 `--force`（但 `--force` 会重新 `npm pack` 下载，浪费 30s+）|
| **可否合并 1 次调用** | ❌ 不行：`Too many arguments`。每个 spec 必须独立一次 `plugins install` |

---

## 1. 关键源码佐证

### 1.1 安装路径与 discovery 机制
（基于本地 `openclaw@2026.5.20`：`/Users/yanxuan.lc/.local/share/pnpm/global/v11/12dfe-19e549e7092/node_modules/openclaw/dist/`）

**Managed npm root 解析**（`install-paths-Co-cP705.js:36-38`）：
```js
function resolveDefaultPluginNpmDir(env, homedir) {
  return path.join(resolveConfigDir(env, homedir), "npm");
}
```
即 `${OPENCLAW_STATE_DIR:-~/.openclaw}/npm/`。

**`OPENCLAW_STATE_DIR` 覆盖**（`utils-1MPEp2CT.js:91-101`）：
```js
function resolveConfigDir(env, homedir) {
  const override = env.OPENCLAW_STATE_DIR?.trim();
  if (override) return resolveUserPath(override, env, homedir);
  // ... fallback to OPENCLAW_CONFIG_PATH dirname, then ~/.openclaw
}
```

**Discovery 找插件的两条路径**（`discovery-BghNqkxD.js:1093-1198`）：
1. `~/.openclaw/extensions/` 整目录扫
2. `installs.json` 里 `installRecords.<id>.installPath`（npm 装的插件不在 extensions/ 而在 `npm/node_modules/<pkg>/`）

**这意味着不能"绕过 openclaw 自己 pnpm 装"**：
- ❌ `pnpm add -g @openclaw/feishu` → 装到 PNPM_HOME，OpenClaw 看不见
- ❌ 手动 `npm install @openclaw/feishu --prefix ~/.openclaw/npm` → 没有 `installs.json` 记录，discovery 不会扫
- ❌ 在构建机预装然后打包带走 → `installs.json` 用绝对路径，搬到用户机就废了
- ✅ 在用户机上调 `openclaw plugins install <spec>` → 唯一受支持路径

### 1.2 安装会做的事（`install-BPKSiY0w.js:331-606`）
1. `npm pack` 下载 tarball 到 `${npmRoot}/.openclaw-pack-archives/`
2. 写入 `${npmRoot}/package.json` 的 `dependencies`、`overrides`、`openclaw.managedOverrides`
3. `npm install --ignore-scripts --omit=dev --omit=peer --legacy-peer-deps --no-audit --no-fund`（args: `safe-package-install-CPk4Tcvw.js:23-34`）
4. 把 host 的 `openclaw` package symlink 到 `npm/node_modules/openclaw`（peer link 修复）
5. 写入 `plugins/installs.json` install record（含 integrity / shasum / 绝对 installPath）
6. 写入 `openclaw.json` 的 `plugins.entries.<id>.enabled=true`

**`--ignore-scripts` 是硬编码的**——不会跑任何 npm preinstall hook。这是 supply-chain 安全考虑，也意味着没有原生模块构建。

### 1.3 已知的依赖树扩展
跑完三家后 `npm/node_modules/` 的 scope 目录：
```
@eshaz @grammyjs @hono @larksuiteoapi @modelcontextprotocol
@openclaw @protobufjs @tencent-connect @tencent-weixin
@types @wasm-audio-decoders
```
最沉的几个：`@larksuiteoapi/node-sdk` (feishu)、`@tencent-connect/qqbot-connector` + `silk-wasm` (qqbot/weixin)、`@grammyjs/*` (telegram，被某依赖牵进来)。

---

## 2. 与 installer 现状的契合度

### 2.1 当前 openclaw agent 流程（`shell/agents/openclaw/install.sh`）
```
install_openclaw_package()    # pnpm add -g openclaw@latest
write_openclaw_config()       # openclaw config set gateway.* / agents.*
start_openclaw_service()      # openclaw gateway install + start
```

ENV_STEPS（依赖步骤，install.sh 集中跑）：
```
base-deps fnm node pnpm npmrc bubbolink shell-rc
```

### 2.2 推荐插桩位置：新增 agent-stage step
**不**放进 ENV_STEPS。ENV_STEPS 在 install.sh **顶层**跑，那时 openclaw 还没装；channel 插件依赖 host openclaw 已存在（要做 peer link）。

**推荐**：在 `agents/openclaw/install.sh` 里 `install_openclaw_package()` 之后、`write_openclaw_config()` 之前，新增 `install_openclaw_channels()`。流程：

```bash
install_openclaw_channels() {
  display "@@step:openclaw-channels:正在预装 OpenClaw 频道插件…"
  local channels=(
    "@openclaw/feishu"
    "@openclaw/qqbot"
    "@tencent-weixin/openclaw-weixin@2.4.3"
  )
  # Fast-path: 已装的 id 集合（避免每次都重新 npm pack）
  local installed_json installed_ids=""
  installed_json="$(openclaw plugins list --json 2>/dev/null </dev/null || echo '{}')"
  installed_ids="$(printf '%s' "$installed_json" \
    | python3 -c 'import json,sys;
d=json.load(sys.stdin)
print(" ".join(p["id"] for p in d.get("plugins",[]) if p.get("status")=="loaded"))' 2>/dev/null || true)"

  local spec id
  for spec in "${channels[@]}"; do
    # 提取 plugin id：去 scope、去版本
    case "$spec" in
      "@openclaw/feishu"*)               id="feishu" ;;
      "@openclaw/qqbot"*)                id="qqbot" ;;
      "@tencent-weixin/openclaw-weixin"*) id="openclaw-weixin" ;;
    esac
    if [[ " $installed_ids " == *" $id "* && -z "${INSTALLER_FORCE_REINSTALL:-}" ]]; then
      display "  $id 已装，跳过"
      manifest_record openclaw_plugin "$id" preexisting
      continue
    fi
    log "openclaw plugins install $spec"
    run openclaw plugins install "$spec" </dev/null
    manifest_record openclaw_plugin "$id" installed "$spec"
  done
}
```

INSTALLER_AGENTS 控制：只有当 `openclaw` 在 AGENTS 列表里时才跑。Hermes-only 安装不受影响。

### 2.3 uninstall 集成
`shell/uninstall.sh` 加一行：
```bash
openclaw_plugin)
  if command -v openclaw >/dev/null 2>&1; then
    run_cmd openclaw plugins uninstall "$target"
  fi
  ;;
```
（`openclaw plugins uninstall <id>` 实测 OK，会清 npm/、installs.json、和 openclaw.json 的 entries）

### 2.4 命令行开关
建议加一个 INSTALLER 环境变量门控：
```
INSTALLER_OPENCLAW_CHANNELS=feishu,qqbot,weixin   # 默认全装
INSTALLER_OPENCLAW_CHANNELS=                       # 不装
INSTALLER_OPENCLAW_CHANNELS=feishu                 # 只装飞书
```
这样未来加新频道（discord/slack/etc.）只改这一处即可。

---

## 3. 风险与边界

### 3.1 ⚠️ 网络与时长
- 三个 spec 三次 `npm pack` + 三次 `npm install` 累计 30-90s（取决于 npmmirror.com 速度）
- 失败时 install 自带 rollback（删 `installs.json` 条目 + `npm/node_modules/<pkg>/`），不会留半成品
- **建议**：每个 spec 套 `run_with_timeout 180` 防卡死

### 3.2 ⚠️ 绑定到 OpenClaw host 版本
- catalog 给每个插件指定 `minHostVersion`（feishu ≥2026.4.25, qqbot ≥2026.4.10, weixin ≥2026.3.22）
- 当前 host 2026.5.20 全部满足
- **如果 INSTALLER 升级 openclaw 主包到不兼容版本，channel 插件加载会失败**。`openclaw doctor` 会报这个；插件可以用 `openclaw plugins update` 重装升级
- weixin 在 catalog 里**硬钉 2.4.3**，host 升级不会自动升 weixin

### 3.3 ⚠️ openclaw.json 副作用
- 装完 openclaw.json 会自动多出 `plugins.entries.{feishu,qqbot,openclaw-weixin}.enabled=true`
- 这个**只**是"插件 enabled" ≠ "channel 已配置"——`channels.<id>` 里没填凭据时插件 loaded 但 inactive
- `openclaw status` 会显示这三个为 "installed, not configured"
- 这个状态是 GUI 期望的——刚好对应"用户还没填表"

### 3.4 ⚠️ Windows / WSL
- WSL Ubuntu 里跑 bash 等价 macOS——同套逻辑
- 唯一注意：`OPENCLAW_STATE_DIR` 默认在 WSL 用户的 `$HOME/.openclaw/`，不是 Windows 侧
- 53MB 落在 WSL ext4，对 Windows 主机无副作用

### 3.5 ⚠️ 离线场景
- claw-installer 本身不支持完全离线（pnpm install openclaw 也要网）
- 一旦三家装完，**channel 凭据配置阶段是真正离线**——GUI 只写本地 openclaw.json + 调 `gateway restart`，不再碰网
- 想做真离线包：需要打 tarball + ship 一个 offline npm cache，超出本次范围

### 3.6 ✅ 不依赖的东西（验证过）
- 不需要 system-level apt/brew 包（pure JS/WASM）
- 不需要 root（全部在用户家目录）
- 不需要 gateway 在跑（install 是离线操作；只要装完后 restart 即可生效）
- 不需要额外环境变量（peer link 走 npm 标准流程）
- 不需要 `--dangerously-force-unsafe-install`（三个都是官方/受信源）

---

## 4. 建议的最小改动清单

| 文件 | 变更 |
| --- | --- |
| `shell/agents/openclaw/install.sh` | 新增 `install_openclaw_channels()`，在 `install_openclaw_package` 之后调用；读取 `INSTALLER_OPENCLAW_CHANNELS` env（默认 `feishu,qqbot,weixin`） |
| `shell/uninstall.sh` | 加 `openclaw_plugin` 分支调 `openclaw plugins uninstall` |
| `shell/agents/openclaw/install.sh` 顶部注释 | 加 `INSTALLER_OPENCLAW_CHANNELS=...` 文档 |
| `docs/research/2026-05-23-openclaw-channels-auto-config/report.md` §1.2 | 增补"managed npm root 继承 `~/.npmrc` registry"——回答原 open question #1 |

**不需要**改动：
- `steps/*.sh`（不入 ENV_STEPS）
- `windows/bootstrap.ps1`（透传 bash 即可）
- `gui/`（这一步纯 shell；GUI 的 channel 配置功能在另一个 spec 里做）

---

## 5. 回答原报告里的 open question

| 原 Q# | 内容 | 本次结论 |
| --- | --- | --- |
| #1 | OpenClaw managed npm 镜像配置 | **解决**：继承 `~/.npmrc`，installer 的 `npmrc` step 已经把 `registry.npmmirror.com` 写进去。lockfile 实测全量 mirror 域名 |
| #2 | Weixin MCP tool 登录 | 未本次验证，下一轮 |
| #3 | QQ Bot 扫码绑定独立化 | 未本次验证，下一轮 |
| #4 | Feishu webhook 模式 | 不在本次范围 |
| #5 | domain 自动探测 | 不在本次范围 |
| #6 | 多账号 UX | 不在本次范围 |

---

## 6. 推荐下一步

1. **接受这个方案** → 我去改 `shell/agents/openclaw/install.sh` + uninstall.sh，约 60 行 bash。
2. **打开 openspec change** 设计 GUI 那一头的 channel-config 表单 + Tauri command 桥接（读写 openclaw.json、跑 `openclaw gateway restart`、weixin 的 QR 扫码面板）。

是否推进？
