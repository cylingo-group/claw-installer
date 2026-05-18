#!/usr/bin/env bash
# install-hermes.sh — agent-layer installer for Hermes (NousResearch).
#
# Strategy: thin wrapper around the upstream installer at
#   https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh
# We download it, sha256 it for the log, and exec it with a fixed set of
# flags + closed stdin so it can never block on a prompt. After it returns,
# we record the directories/binaries it produced into our manifest so
# uninstall.sh can reverse the install.
#
# Environment toggles:
#   INSTALLER_HERMES_BRANCH         git branch to install (default: main)
#   INSTALLER_HERMES_DIR            override install dir (default: $HERMES_HOME/hermes-agent)
#   INSTALLER_HERMES_HOME           override data dir   (default: $HOME/.hermes)
#   INSTALLER_HERMES_SKIP_BROWSER=1 skip Playwright/Chromium install (saves a lot of time/disk)
#   INSTALLER_HERMES_INSTALL_URL    override upstream URL (useful for pinning to a commit SHA)
#   INSTALLER_HERMES_REPO_URL       override hermes git repo URL for pre-clone
#                                   (default: https://github.com/NousResearch/hermes-agent.git;
#                                    we pre-clone via HTTPS to bypass upstream's SSH-first attempt
#                                    that hangs on networks where github.com:22 stalls during KEX)
#   INSTALLER_SKIP_ENV=1            skip our env-deps run (set by install.sh when called from it)

set -euo pipefail

__HE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$__HE_DIR/lib/common.sh"

# Env-prep steps we pre-run so the upstream hermes installer detects them
# and fast-paths. Order is dependency-correct:
#   base-deps     curl/git/openssl required by everything below
#   system-tools  ripgrep + ffmpeg + (Debian) build-essential / python3-dev / libffi-dev
#   fnm + hermes-node  Node v22 symlinked into ~/.hermes/node/bin/
#   uv + python   uv installed, then Python 3.11 via uv
ENV_STEPS=(base-deps system-tools fnm hermes-node uv python)

HERMES_INSTALL_URL="${INSTALLER_HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh}"
HERMES_BRANCH="${INSTALLER_HERMES_BRANCH:-main}"
HERMES_HOME_DIR="${INSTALLER_HERMES_HOME:-${HERMES_HOME:-$HOME/.hermes}}"
HERMES_INSTALL_DIR="${INSTALLER_HERMES_DIR:-$HERMES_HOME_DIR/hermes-agent}"
HERMES_REPO_HTTPS="${INSTALLER_HERMES_REPO_URL:-https://github.com/NousResearch/hermes-agent.git}"
HERMES_BIN="$HOME/.local/bin/hermes"

prepare_hermes_repo() {
  # Workaround for upstream's SSH-first clone strategy. On restricted networks
  # the TCP handshake to github.com:22 succeeds but the SSH protocol negotiation
  # hangs; upstream's GIT_SSH_COMMAND sets ConnectTimeout=5 which only covers
  # the TCP phase, not key exchange. Pre-cloning via HTTPS makes upstream's
  # clone_repo() take its "Existing installation found, updating" branch and
  # skip the SSH attempt entirely.
  if [[ -d "$HERMES_INSTALL_DIR/.git" ]]; then
    log "Hermes repo already present at $HERMES_INSTALL_DIR (upstream will update in-place)"
    return
  fi
  if [[ -e "$HERMES_INSTALL_DIR" ]]; then
    die "$HERMES_INSTALL_DIR exists but is not a git repo. Remove it, or pick another dir via INSTALLER_HERMES_DIR."
  fi
  command -v git >/dev/null 2>&1 || die "git not on PATH — base-deps step should have installed it"
  log "Pre-cloning hermes via HTTPS: $HERMES_REPO_HTTPS (branch=$HERMES_BRANCH) → $HERMES_INSTALL_DIR"
  mkdir -p "$(dirname "$HERMES_INSTALL_DIR")"
  if ! git clone --branch "$HERMES_BRANCH" "$HERMES_REPO_HTTPS" "$HERMES_INSTALL_DIR" </dev/null; then
    die "git clone failed for $HERMES_REPO_HTTPS (branch=$HERMES_BRANCH)"
  fi
}

run_upstream_hermes_installer() {
  # Always pass --skip-setup: the wizard reads from /dev/tty and would block
  # in non-interactive contexts (CI, the future GUI). Users run `hermes setup`
  # themselves after the installer returns.
  local args=(--skip-setup
              --branch "$HERMES_BRANCH"
              --dir "$HERMES_INSTALL_DIR"
              --hermes-home "$HERMES_HOME_DIR")
  [[ -n "${INSTALLER_HERMES_SKIP_BROWSER:-}" ]] && args+=(--skip-browser)

  log "Fetching upstream installer: $HERMES_INSTALL_URL"
  local tmp
  tmp="$(mktemp -t hermes-install.XXXXXX.sh)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  if ! curl -fsSL "$HERMES_INSTALL_URL" -o "$tmp"; then
    die "Failed to download upstream installer from $HERMES_INSTALL_URL"
  fi
  local size sha
  size="$(wc -c <"$tmp" | tr -d ' ')"
  sha="$(shasum -a 256 "$tmp" 2>/dev/null | awk '{print $1}')"
  log "Upstream installer: ${size}B sha256=$sha"
  log "Invoking: bash <upstream-install.sh> ${args[*]}"
  log "(stdin closed; upstream prompts will see EOF and fall back to defaults — no gateway/whatsapp pairing in this run)"

  # Run with a generous timeout so a hung upstream step doesn't deadlock us.
  # 30 min covers worst-case Playwright + system-deps install on a slow box.
  if ! run_with_timeout 1800 bash "$tmp" "${args[@]}" </dev/null; then
    warn "upstream hermes installer exited non-zero or timed out — manifest will still record whatever it created."
    return 1
  fi
}

install_hermes_agent() {
  # Pre-snapshot: did these paths exist BEFORE the upstream installer ran?
  # We mark created vs preexisting so uninstall doesn't remove a dir the user
  # already had.
  local hh_status="created" id_status="created" bin_status="installed"
  [[ -d "$HERMES_HOME_DIR" ]]    && hh_status="preexisting"
  [[ -d "$HERMES_INSTALL_DIR" ]] && id_status="preexisting"
  [[ -x "$HERMES_BIN" ]]         && bin_status="preexisting"

  # Pre-clone via HTTPS so the upstream installer doesn't hang on its SSH
  # clone attempt on restricted networks. Must run AFTER the snapshot above —
  # otherwise hermes_install_dir would be marked preexisting and uninstall
  # wouldn't remove it.
  prepare_hermes_repo

  # If anything fails inside the upstream installer we still want to record
  # whatever directories it managed to create — partial-install cleanup
  # matters more than success-only logging.
  local upstream_rc=0
  run_upstream_hermes_installer || upstream_rc=$?

  [[ -d "$HERMES_INSTALL_DIR" ]] && manifest_record hermes_install_dir "$HERMES_INSTALL_DIR" "$id_status"
  [[ -d "$HERMES_HOME_DIR"    ]] && manifest_record hermes_home        "$HERMES_HOME_DIR"    "$hh_status"
  [[ -x "$HERMES_BIN"         ]] && manifest_record hermes_bin         "$HERMES_BIN"         "$bin_status"

  if (( upstream_rc != 0 )); then
    die "Hermes installer failed (upstream exit=$upstream_rc). See the install log for upstream output."
  fi
  print_hermes_summary
}

print_hermes_summary() {
  cat <<EOF

==============================================================================
  Hermes Agent 安装完成

  Repo           : $HERMES_INSTALL_DIR (branch=$HERMES_BRANCH)
  Data dir       : $HERMES_HOME_DIR
  Command        : $HERMES_BIN

  下一步:
    1. 重新打开 shell（或 source ~/.bashrc）让 PATH 生效
    2. hermes setup    # 交互式配置 API key / 模型 / 通信渠道
    3. hermes          # 进入对话

  说明:
    - 系统层依赖 (uv / Python3.11 / Node v22 / ripgrep / ffmpeg / Playwright)
      由上游脚本安装；与本仓库 fnm 管理的 Node 24 互不冲突。
    - 上游会把 PATH 写进 ~/.bashrc / ~/.zshrc / ~/.profile，行内无 sentinel；
      uninstall.sh 不会自动剥离这些行（避免误删用户其它配置）。
==============================================================================
EOF
}

main() {
  setup_install_log
  if [[ -z "${INSTALLER_SKIP_ENV:-}" ]]; then
    run_steps "${ENV_STEPS[@]}"
  fi
  install_hermes_agent
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
