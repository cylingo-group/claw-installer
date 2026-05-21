#!/usr/bin/env bash
# steps/node.sh — install + activate Node.js via fnm. Requires fnm on PATH.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_node() {
  display "@@step:node:正在配置 Node ${NODE_VERSION} 运行时…"
  command -v fnm >/dev/null 2>&1 || die_step "配置 Node" "fnm not on PATH — run steps/fnm.sh first" 1

  local req_major node_status="installed"
  req_major="${NODE_VERSION%%.*}"

  # Detect existing version. fnm may have a half-broken install on disk
  # (truncated tarball, wrong arch, signature failure on first exec, etc.)
  # that `fnm list` still reports as present — verify the binary actually
  # runs before we trust the fast-path.
  local fnm_dir found_version=""
  fnm_dir="$(resolve_fnm_dir)"
  log "fnm dir: $fnm_dir"
  log "fnm list output (raw):"
  fnm list >&3 2>&1 || true
  found_version="$(fnm list 2>/dev/null \
                    | grep -oE "v${req_major}\\.[0-9]+\\.[0-9]+" \
                    | head -n1 || true)"
  log "Detected existing v${req_major}.* candidate: ${found_version:-<none>}"

  if [[ -n "$found_version" ]]; then
    local candidate="$fnm_dir/node-versions/$found_version/installation/bin/node"
    log "Probing candidate binary: $candidate"
    if [[ -x "$candidate" ]]; then
      local probe_rc=0 probe_out=""
      probe_out="$("$candidate" --version 2>&1)" || probe_rc=$?
      log "  probe: rc=$probe_rc out=$probe_out"
      if [[ "$probe_rc" -eq 0 ]]; then
        node_status="preexisting"
      else
        # Don't trust this install. Delete and re-download.
        log "  ⚠ candidate binary failed --version (rc=$probe_rc); removing and reinstalling"
        run rm -rf "$fnm_dir/node-versions/$found_version"
        found_version=""
      fi
    else
      log "  ⚠ candidate binary missing or not executable; removing dir for reinstall"
      run rm -rf "$fnm_dir/node-versions/$found_version"
      found_version=""
    fi
  fi

  # Fast-path: requested version is installed AND already active in this shell.
  local active_major="" active_path=""
  if command -v node >/dev/null 2>&1; then
    active_path="$(command -v node)"
    # `|| true` swallows abort/signal kills — but log the rc explicitly first
    # so we can spot a broken `node` on PATH that earlier code would silently
    # paper over.
    local am_rc=0
    active_major="$(node -e 'process.stdout.write(process.versions.node.split(".")[0])' 2>&3)" || am_rc=$?
    log "Active node before install: path=$active_path major=$active_major (rc=$am_rc)"

    # Helpful surfaced warning when the node on PATH is broken (e.g. brew
    # node after `brew upgrade llhttp` without `brew reinstall node`).
    # We don't fail — fnm's symlinks will shadow this once `fnm use` runs —
    # but the user should know their brew install is corrupt so they can
    # repair it for non-installer use (interactive shell, other tools).
    if [[ "$am_rc" -ne 0 && -n "$active_path" ]]; then
      display "⚠ 检测到 PATH 上的 node 已损坏：$active_path (退出码 $am_rc)"
      display "  ↳ 安装程序会用 fnm 管理的 Node 覆盖；但建议在终端里手动修复："
      display "    brew reinstall node          # 或 brew unlink node 让 fnm 接管"
    fi
  else
    log "Active node before install: <not on PATH>"
  fi

  if [[ "$node_status" == "preexisting" && "$active_major" == "$req_major" \
        && -z "${INSTALLER_FORCE_REINSTALL:-}" ]]; then
    display "Node v$NODE_VERSION 已安装并激活，跳过"
  else
    log "Installing Node.js v$NODE_VERSION via fnm"
    run fnm install "$NODE_VERSION"
    run fnm default "$NODE_VERSION"
    run fnm use "$NODE_VERSION"
    hash -r 2>/dev/null || true
  fi

  # Capture `node --version` explicitly so SIGABRT / wrong-arch crashes are
  # surfaced with a useful error instead of vanishing through `set -e`. The
  # ERR trap occasionally loses fd-3 buffered output when a child dies from
  # an uncaught signal (134/138/139), so we route every byte to fd 3 via
  # `2>&3` and check the rc directly — die_step then writes synchronously
  # and force-flushes fd 3 before exit.
  local node_v="" probe_rc=0
  log "Probing 'node --version' — resolved path: $(command -v node 2>/dev/null || echo MISSING)"
  log "PATH (head 200 chars): ${PATH:0:200}"
  node_v="$(node --version 2>&1)" || probe_rc=$?
  log "node --version: rc=$probe_rc out=$node_v"
  if [[ "$probe_rc" -ne 0 ]]; then
    local node_path bin_info=""
    node_path="$(command -v node 2>/dev/null || echo unknown)"
    if [[ -e "$node_path" ]]; then
      bin_info="$(file "$node_path" 2>/dev/null || true)"
    fi
    die_step "配置 Node 运行时" \
      "node --version 退出码 $probe_rc — 二进制不可执行 (path=$node_path; info=${bin_info:-N/A}; output=$node_v). 请删除 $fnm_dir/node-versions/ 后重试，或改用 INSTALLER_NODE_VERSION=22。" \
      "$probe_rc"
  fi
  display "✓ Node $node_v 已激活"

  # Version-gate check. Capture rc explicitly (don't rely on `if !` which
  # disables the ERR trap, *and* don't rely on the ERR trap fd-3 flush quirks).
  local check_rc=0
  node -e 'const v=process.versions.node.split(".").map(Number); process.exit((v[0]>22)||(v[0]===22&&v[1]>=16)?0:1)' >&3 2>&3 \
    || check_rc=$?
  log "Node version gate check: rc=$check_rc (required >= 22.16)"
  if [[ "$check_rc" -ne 0 ]]; then
    die_step "配置 Node 运行时" \
      "Node $node_v 低于 22.16 最低版本 (退出码 $check_rc)。请设 INSTALLER_NODE_VERSION=24。" \
      "$check_rc"
  fi
  manifest_record fnm_node "$NODE_VERSION" "$node_status" "active=$node_v"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  # Activate fnm if it's installed but not yet sourced in this shell.
  if ! command -v fnm >/dev/null 2>&1; then
    source "$__STEP_DIR/fnm.sh"
    step_fnm
  fi
  step_node
fi
