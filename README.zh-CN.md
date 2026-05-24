# Claw Installer

[English](./README.md) · **简体中文**

> 由 **心言集团 (Cylingo Group)** 出品 ——
> [**BubboLink**](https://bubbolink.com) 的研发团队。BubboLink 是我们的
> IM 侧网关，让你在一个聊天会话里同时调度 OpenClaw、Hermes、Claude Code、
> Codex 等多种 Agent。安装结束后只需一次点击执行 `bubbolink pair`，本机
> 已安装的所有 Agent 即可被 BubboLink 接管。

一款面向全新主机的一键安装器，用于部署 **OpenClaw** 与 **Hermes** AI Agent。
支持 macOS、Linux、WSL 2 与 Windows（经 WSL）。底层是一套经过实战打磨的
shell 脚本，外层是轻量的 Tauri 桌面 GUI —— 双击应用与在终端执行
`./shell/install.sh` 走的是同一条流水线。

## 组件清单

| 组件 | 作用 |
| --- | --- |
| **OpenClaw** | 开源的 Agent 运行时，驱动会话式工作流。安装器会固定 Node、pnpm 与 gateway 守护进程，并在 `~/.openclaw/` 下初始化工作区。 |
| **Hermes** | 心言集团托管的模型桥。让本机上每个 Agent 共享统一的 Provider 配置（心元 / DeepSeek / MiniMax / 自定义 OpenAI 兼容接入）。 |
| **BubboLink 配对** | 安装完成后，在 BubboLink App 上获取 4 位配对码，粘贴到 GUI 里点击配对即可完成本机所有 runtime 的绑定。 |
| **通道文档** | 一键打开 OpenClaw 的微信 / 飞书 / 钉钉 接入文档，GUI 内无需任何手动配置。 |

## 快速上手（终端用户）

### macOS

1. 从 [latest release](https://github.com/cylingo-group/claw-installer/releases/latest)
   或公司内部分发渠道下载 `Claw-Installer-<version>-universal.dmg`。
2. 打开 DMG，将 **Claw Installer** 拖入 `/Applications`。
3. 启动应用，按窗口提示完成 选择 Agent → 安装 → 配对。

### Windows 10 / 11

1. 下载 `claw-installer-windows.zip` 并解压到任意目录。
2. 进入 `claw-installer` 文件夹，双击 `claw-installer.exe`。
3. 首次运行会触发 UAC 弹窗，为安装 WSL 2 + Ubuntu 申请权限；如系统提示
   重启，重启后再次启动安装器即可。

### Linux（Ubuntu / Debian）

```bash
sudo apt install ./Claw-Installer-<version>-amd64.deb
# 或者
chmod +x Claw-Installer-<version>-x86_64.AppImage
./Claw-Installer-<version>-x86_64.AppImage
```

### 命令行 / 脚本化

跳过 GUI，直接调起底层 shell 流水线：

```bash
git clone <repo> && cd claw-installer
./shell/install.sh                            # 同时安装两个 Agent
./shell/agents/openclaw/install.sh            # 只装 OpenClaw
INSTALLER_AGENTS=hermes ./shell/install.sh    # 通过环境变量选择
```

## 从源码构建

仓库提供了三个桌面平台的一键构建脚本。环境要求：

- [pnpm](https://pnpm.io) ≥ 9（工作区使用 pnpm）
- [Rust](https://rustup.rs) stable 工具链
- 构建 **macOS universal**：`rustup target add x86_64-apple-darwin`
- **Windows 交叉编译**：`cargo install cargo-xwin`
- **在 macOS 上构建 Linux 包**：本机需启动 Docker Desktop

执行命令：

```bash
make build-mac        # universal .app + .dmg → dist/macos/
make build-linux      # .deb + .AppImage → dist/linux/（基于 Docker，原生架构）
make build-windows    # claw-installer.exe + shell/ → dist/windows/*.zip
make build-all        # 顺序构建以上三种
```

构建产物输出到 `dist/<platform>/`。

> **关于 Linux 架构：** `make build-linux` 产出的是容器原生架构的产物 ——
> 在 Apple Silicon 主机上是 arm64，在 Intel 主机上是 amd64。若需跨架构构建，
> 通过 `LINUX_PLATFORM` 指定：
> ```
> make build-linux LINUX_PLATFORM=linux/amd64    # 在 arm64 mac 上交叉构建 x86_64（慢：qemu 模拟约 2–3 小时）
> make build-linux LINUX_PLATFORM=linux/arm64    # 在 x86_64 主机上构建 arm64
> ```

### 开发环境运行

```bash
make dev              # Tauri 开发模式（推荐 —— 含热更新和 Rust）
make frontend         # 浏览器 stub 模式（不启 Rust，不调 Agent IPC）
```

## License

Apache License 2.0 —— 详见 [LICENSE](./LICENSE)。

---

## 架构（面向贡献者）

下文描述安装器的内部约定，仅在需要修改 shell 脚本或 Rust ↔ TS IPC 层时需要参考。

设计上既可被 shell 调用，也可被 GUI 前端驱动 —— GUI 通过设置 `INSTALLER_*`
环境变量来调起与终端用户相同的入口脚本。

### 目录结构

```
shell/                            CLI 实现：安装 + 生命周期 + 卸载
├─ install.sh                     顶层：环境依赖 + 所有 Agent
├─ uninstall.sh                   依据 manifest 反向回滚已安装项
│                                  （识别 CLAW_UNINSTALL_AGENT，可单 Agent 卸载）
├─ agents/                        每个 Agent 的生命周期脚本
│   ├─ openclaw/{install,start,stop,restart,uninstall}.sh
│   └─ hermes/{install,start,stop,restart,uninstall}.sh
├─ lib/                           共享 helper + manifest 管线
│   ├─ common.sh
│   └─ manifest.sh
├─ steps/                         环境层细粒度原语
│   ├─ base-deps.sh               curl / git / openssl / unzip / ca-certificates
│   ├─ fnm.sh                     fnm（Node 版本管理）
│   ├─ node.sh                    Node via fnm
│   ├─ pnpm.sh                    pnpm via corepack
│   ├─ npmrc.sh                   ~/.npmrc 镜像块
│   └─ shell-rc.sh                ~/.bashrc / ~/.zshrc PATH 持久化
├─ vendor/fnm/                    vendor 一份 fnm installer（离线可用）
├─ windows/bootstrap.ps1          Windows 入口：WSL 预检 → install.sh
└─ docker/                        smoke-test 设施（Ubuntu 24.04 沙箱）
    ├─ Dockerfile
    ├─ docker-compose.yml
    └─ docker-entrypoint.sh

gui/                              Tauri GUI（驱动 shell/ 脚本）
```

### 入口

| 平台              | 命令                                                                         |
| ----------------- | ---------------------------------------------------------------------------- |
| macOS / Linux     | `./shell/install.sh`                                                         |
| WSL 2             | `./shell/install.sh`（与 Linux 相同）                                        |
| Windows（一键）   | `powershell -ExecutionPolicy Bypass -File shell\windows\bootstrap.ps1`       |
| 单 Agent          | `./shell/agents/openclaw/install.sh` 或 `./shell/agents/hermes/install.sh`  |
| 生命周期          | `./shell/agents/<agent>/{start,stop,restart}.sh`                             |
| 卸载（全部）      | `./shell/uninstall.sh`（追加 `--dry-run` 预览）                              |
| 卸载（单 Agent）  | `./shell/agents/<agent>/uninstall.sh`                                        |
| Docker smoke test | `cd shell/docker && docker compose up --build`                               |

### 安装态

所有改动都落在 **`~/.claw-installer/`**（可通过 `CLAW_STATE_DIR` 覆盖）：

- `manifest.tsv` —— 结构化记录每一次副作用，先写为准

会话日志落在 **`$TMPDIR/claw-installer/logs/`**：

- `install-<UTC-unix-ts>.log` —— 单次安装的完整取证记录
- `uninstall-<UTC-unix-ts>.log` —— 单次卸载的完整取证记录

由 Rust 调起时，日志路径通过 `CLAW_SESSION_LOG` 环境变量传递给子进程；
直接终端执行时，脚本会自动落到 `$TMPDIR/claw-installer/logs/cli-<ts>.log`。

`uninstall.sh` 按写入顺序读取 manifest 并逐行反向回滚。状态为
`preexisting` 的条目会被跳过（"非我所装，不予移除"）。

### GUI ↔ installer 协议

#### 双流日志

脚本通过三个原语显式产出所有用户可见字符串：

- **`display "human-readable description"`** —— 写到 stdout（用户可见）并
  同步追加到会话日志文件。5 行日志条所展示的内容均来自 `display`。
- **`log "technical detail"`** —— 仅写到会话日志文件，**不**在用户终端可见。
- **`run <cmd> [args…]`** —— 先 log 一行 `+ <cmd>`，然后执行命令，将
  stdout + stderr 一并落到会话日志，并把命令的退出码原样返回。

#### Step sentinel 协议

每个 step 开始时脚本输出：

```
@@step:<key>:<label>
```

例如 `display "@@step:node:Configuring Node 22 runtime"`。Rust 用
`^@@step:([a-z][a-z0-9-]*):(.+)$` 解析，发出
`InstallerEvent::StepChanged { key, label, detail: "" }`，该行**不会**作为
`LogLine` 转发到 GUI。

其他 stdout 行原样转发为 `LogLine` 事件。Rust **不做过滤、不剥 ANSI、不翻译**
—— 脚本是用户可见字符串的唯一作者。

#### 失败输出

step 失败时脚本在 stdout 输出如下 3 行块（Rust 会原样作为 `LogLine` 转发，
供 GUI 显示）：

```
✗ Failed step:   <当前 step 的英文 label>
✗ Cause:         <command + exit code>
✗ See full log:  <CLAW_SESSION_LOG 绝对路径>
```

#### CLAW_SESSION_LOG 环境变量

Rust 端预创建 `$TMPDIR/claw-installer/logs/<install|uninstall>-<ts>.log`，
然后将 `CLAW_SESSION_LOG=<path>` 注入子进程环境。脚本在 source `common.sh`
时打开 `fd 3` 追加到该文件。子 Agent 脚本（`agents/<agent>/install.sh`）
继承父 `install.sh` 的 `CLAW_SESSION_LOG`，追加到同一个文件。

#### Debug 模式

任意入口脚本传 `--debug`，可在 stderr 实时 tail 会话日志：

```bash
./shell/install.sh --debug
```

后台启动 `tail -F "$CLAW_SESSION_LOG" >&2 &`，并在 EXIT 时清理。适合 CLI
triage 时查看完整取证输出。

#### INSTALLER_* 环境变量

GUI 通过 `INSTALLER_*` 环境变量配置安装行为并调起上述入口。完整变量列表参见
各 `agents/<agent>/install.sh` 头部注释。

| 变量                              | 作用                                                       |
| --------------------------------- | ---------------------------------------------------------- |
| `INSTALLER_AGENTS=openclaw,hermes` | 指定安装哪些 Agent（默认全部）                            |
| `INSTALLER_NPM_REGISTRY`           | npm/pnpm 镜像源                                            |
| `INSTALLER_GATEWAY_*`              | openclaw gateway 的 port / bind / token                    |
| `INSTALLER_SERVICE_MODE`           | `daemon` / `foreground` / `skip`                           |
| `INSTALLER_WORKSPACE`              | openclaw workspace 目录                                    |
| `INSTALLER_HERMES_SKIP_BROWSER=1`  | 跳过 Playwright/Chromium 安装                              |
| `INSTALLER_FORCE_REINSTALL=1`      | 绕过 "已安装" 快速路径，强制全量重装                       |
| `INSTALLER_WSL_DISTRO`             | （Windows）覆盖 WSL 发行版（默认 Ubuntu）                  |
| `INSTALLER_REPO_DIR`               | 覆盖 `shell/` 路径（Rust 后端 dev 模式使用）              |

### 可重入

对一台已安装过的主机重新执行 `install.sh` 是安全且快速的：每个 step
先探测现状再决定是否要执行。

- **系统包**（curl、git、ripgrep、ffmpeg、构建链）：只装缺失的包；已存在的
  包记为 `preexisting`。
- **fnm / Node / pnpm / uv / Python 3.11**：如目标版本已安装且生效，则跳过。
- **`~/.npmrc` 与 `~/.bashrc`/`~/.zshrc` 管控块**：仅当现有内容与目标内容
  不同时才重写。
- **openclaw 包**：`openclaw` 已在 PATH 上时跳过。
- **openclaw 配置**：复用已有的 gateway token（不会静默轮换）；如
  `openclaw config set` 的目标值已匹配则跳过该项。
- **openclaw gateway 服务**：若 `openclaw gateway status` 报告守护进程
  在运行，则跳过 `gateway install` / `doctor --repair` / `gateway start`
  —— 不会在重跑时重启 daemon。
- **hermes**：`$HERMES_HOME/../hermes-agent` 已 checkout 且
  `~/.local/bin/hermes` 可执行时跳过。

需要绕过这些快速路径时设置 `INSTALLER_FORCE_REINSTALL=1`。

在 Windows 上查阅 manifest：

```
\\wsl.localhost\Ubuntu\home\<user>\.claw-installer\manifest.tsv
```
