# 调研 Addendum：Hermes 这一侧的预装需求

**问题**：上一篇 addendum 只讨论了 OpenClaw 的 npm 插件预装。Hermes agent 这边有没有类似的频道包要装？

**短答**：**几乎不需要做事**。Hermes 的 17 个内置 IM 平台（含 feishu / qqbot / weixin）全部以 Python 模块形式打包在 `hermes-agent` 主包里，安装 Hermes 主包时就跟着进来了。唯一可选的预装动作：飞书的 2 个 lazy-install Python wheels（`lark-oapi`、`qrcode`），~5-10MB。

---

## 1. Hermes 的频道模型 ≠ OpenClaw

| 维度 | OpenClaw | Hermes |
| --- | --- | --- |
| 频道实现形态 | 外置 npm 插件（按需 `openclaw plugins install`） | **内置 Python 模块**（`hermes-agent/gateway/platforms/*.py`） |
| 频道发现 | `installs.json` 记录的 npm 路径 | Python import + `platform_registry.register(...)` |
| 装一个频道需要 | 下载几十 MB npm 树 | 0 字节，已经在硬盘上 |
| feishu/qqbot/weixin 状态 | 都是独立 npm 包，要单独 install | 都是 hermes-agent 主包的一部分，**装完 Hermes 就有了** |
| 配置文件 | `~/.openclaw/openclaw.json` 的 `channels.<id>.*` | `~/.hermes/.env`（凭据）+ `~/.hermes/config.yaml`（启用列表） |
| 配置 CLI | `openclaw channels add / login` | `hermes gateway setup`（交互向导） |
| 扩展机制 | npm 包（受 catalog 管理） | git 仓库 + Python 插件（`hermes plugins install <git-url>`，是社区扩展用的，不是频道） |

**实测**：本机 `/Users/yanxuan.lc/.hermes/hermes-agent/gateway/platforms/` 已经包含：

```
bluebubbles.py  dingtalk.py  discord.py  email.py
feishu.py  homeassistant.py  matrix.py  mattermost.py
msgraph_webhook.py  qqbot/  signal.py  slack.py  sms.py
telegram.py  webhook.py  wecom.py  weixin.py  yuanbao.py
```

`hermes gateway` 的 description 明确：
> Manage the messaging gateway (Telegram, Discord, WhatsApp, **Weixin**, and more)

`hermes_cli/gateway.py:3308` 的 `_PLATFORMS` 列表：
```
telegram, discord, slack, matrix, mattermost, whatsapp, signal,
email, sms, dingtalk, feishu, wecom, wecom_callback, weixin,
bluebubbles, qqbot, yuanbao
```
全部内置。

---

## 2. 三个目标频道的 Python 依赖现状

源码：`hermes-agent/tools/lazy_deps.py:130-150`，加上 `gateway/platforms/{feishu,weixin}.py` + `gateway/platforms/qqbot/*.py` 的 import grep。

| 频道 | Hermes 自带文件 | 外部 Python 依赖 | 状态 |
| --- | --- | --- | --- |
| **feishu** | `gateway/platforms/feishu.py`（含 `feishu_comment*.py`） | `lark-oapi==1.5.3`, `qrcode==7.4.2` | ⚠️ 走 lazy-install (`tools.lazy_deps.ensure("platform.feishu")`)，首次使用时联网 pip。**当前 venv 实测没装** |
| **qqbot** | `gateway/platforms/qqbot/`（adapter / chunked_upload / constants / crypto / keyboards / onboard / utils） | **无**（只用 stdlib：`mimetypes`、`uuid`、`hashlib` 等） | ✅ 装完 hermes-agent 就立即可用 |
| **weixin** | `gateway/platforms/weixin.py` | **无**（只用 stdlib） | ✅ 装完 hermes-agent 就立即可用 |

参考对比：
```python
# tools/lazy_deps.py:147
"platform.feishu": (
    "lark-oapi==1.5.3",
    "qrcode==7.4.2",
),
# qqbot / weixin 在这张表里完全没出现 → 无 lazy deps
```

---

## 3. 推荐方案

### 3.1 选项 A：什么都不做（推荐保留）
- qqbot + weixin 已经齐活，零工作量
- feishu 首次使用时 `tools/lazy_deps.py` 会自动 pip install `lark-oapi` + `qrcode`，~5s 联网
- 缺点：首次启用飞书时用户会看到 "Installing lark-oapi..." 的进度，体感"还要等一下"

### 3.2 选项 B：预装飞书的两个 wheel（推荐做）
在 `shell/agents/hermes/install.sh` 的 hermes 主包装完之后，加一步：

```bash
preinstall_hermes_channel_extras() {
  display "@@step:hermes-channel-extras:正在预装频道额外依赖（feishu）…"
  local hermes_venv="$HERMES_INSTALL_DIR/venv"
  local pip="$hermes_venv/bin/pip"
  [[ -x "$pip" ]] || { log "hermes venv pip not found, skipping"; return; }

  # qqbot / weixin: stdlib only, nothing to do
  # feishu: 2 wheels (~5MB)
  if "$pip" show lark-oapi >/dev/null 2>&1 && "$pip" show qrcode >/dev/null 2>&1 \
       && [[ -z "${INSTALLER_FORCE_REINSTALL:-}" ]]; then
    display "  feishu 依赖已装，跳过"
    manifest_record hermes_pip_pkg lark-oapi preexisting
    manifest_record hermes_pip_pkg qrcode preexisting
    return
  fi
  log "uv pip install lark-oapi==1.5.3 qrcode==7.4.2"
  run "$pip" install "lark-oapi==1.5.3" "qrcode==7.4.2"
  manifest_record hermes_pip_pkg lark-oapi installed
  manifest_record hermes_pip_pkg qrcode installed
}
```

**代价**：~5MB 磁盘、~3-5s 网络（pip.npmmirror 或官方 PyPI），无任何 system-level 副作用。

**好处**：用户在 GUI 选飞书的瞬间，hermes 端是真离线、零等待。

### 3.3 选项 C：不要做的事
- ❌ 不要 `hermes plugins install <something>` —— `hermes plugins` 是给社区扩展用的（git URL 形式），跟内置频道无关
- ❌ 不要去搜 PyPI 上的 `hermes-feishu` / `hermes-qqbot` 包，不存在
- ❌ 不要预装 matrix 的 `mautrix[encryption]`/`python-olm` —— 那个在 Windows 上没 wheel，会让 installer 卡住

---

## 4. INSTALLER 环境变量收敛

跟 OpenClaw addendum 里的 `INSTALLER_OPENCLAW_CHANNELS` 配套，可以加：

```
INSTALLER_HERMES_CHANNELS=feishu,qqbot,weixin      # 默认（仅决定要不要预装 feishu lazy deps）
INSTALLER_HERMES_CHANNELS=                          # 完全跳过预装
```

注意：这只影响 lazy-install 那 2 个 wheel。qqbot / weixin 是 hermes-agent 自带的，永远在。

---

## 5. 跨 agent 的对照表（汇总两份 addendum）

| 频道 | OpenClaw 侧需要做的 | Hermes 侧需要做的 |
| --- | --- | --- |
| **feishu** | `openclaw plugins install @openclaw/feishu`（~30MB，含 `@larksuiteoapi/node-sdk`） | 可选：预装 `lark-oapi==1.5.3 qrcode==7.4.2`（~5MB） |
| **qqbot** | `openclaw plugins install @openclaw/qqbot`（~10MB，含 `@tencent-connect/qqbot-connector` + `silk-wasm`） | **什么都不做**（stdlib only） |
| **weixin** | `openclaw plugins install '@tencent-weixin/openclaw-weixin@2.4.3'`（~10MB） | **什么都不做**（stdlib only） |

OpenClaw 这一侧累计 ~53MB / 30-90s；Hermes 这一侧累计 ~5MB / 3-5s（只装 feishu 的 lazy deps）。

---

## 6. 对 GUI 那一头的影响

`gui/src/store/installer-store.ts` 的 `ChannelId` 当前是 `wechat | feishu | dingtalk | bubbolink` —— **跟两个 agent 实际能 enable 的频道有 mismatch**：

- OpenClaw catalog 里**没有 dingtalk**（钉钉），有 `feishu / qqbot / openclaw-weixin / wecom / yuanbao / line / discord / telegram / ...`
- Hermes 内置**有 dingtalk**，也有 `feishu / qqbot / weixin / wecom / yuanbao / ...`
- 两个 agent 的并集 ≠ 交集；同一个名字（如 weixin）在两侧也是**完全不同的实现**（OpenClaw 走 npm 插件 + iLink；Hermes 走自己实现）

**这是 channel-config GUI 的一个开放设计问题**：让用户先选 agent 再选 channel，还是先选 channel 再过滤 agent？放进下一次 spec 设计讨论。

---

## 7. 最终建议

把两份 addendum 合并成下面这套最小改动：

```diff
shell/agents/openclaw/install.sh
+ install_openclaw_channels()        # 调 plugins install × 3
shell/agents/hermes/install.sh
+ preinstall_hermes_channel_extras() # uv pip install lark-oapi qrcode
shell/uninstall.sh
+ openclaw_plugin) ... ;;            # 跑 openclaw plugins uninstall
+ hermes_pip_pkg) ... ;;             # 跑 pip uninstall
```

总代码量 < 100 行 bash。完成后：
- 装完 installer，**两个 agent 都立刻支持飞书/QQBot/微信**（不需要再触网下任何包）
- GUI 阶段的 channel 配置流程只剩"用户填表 → 写 config → restart agent"

要直接动手吗？
