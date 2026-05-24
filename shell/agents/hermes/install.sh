#!/usr/bin/env bash
# install-hermes.sh — agent-layer installer for Hermes (cylingo-group).
#
# Strategy: thin wrapper around the upstream installer at
#   https://gitee.com/cylingo-group/hermes-agent/raw/main/scripts/install.sh
# We download it, sha256 it for the log, and exec it with a fixed set of
# flags + closed stdin so it can never block on a prompt. After it returns,
# we record the directories/binaries it produced into our manifest so
# uninstall.sh can reverse the install.
#
# Hosted on Gitee (rather than GitHub) for faster clones in CN.
#
# Environment toggles:
#   INSTALLER_HERMES_BRANCH         git branch to install (default: main)
#   INSTALLER_HERMES_DIR            override install dir (default: $HERMES_HOME/hermes-agent)
#   INSTALLER_HERMES_HOME           override data dir   (default: $HOME/.hermes)
#   INSTALLER_HERMES_SKIP_BROWSER=1 skip Playwright/Chromium install (saves a lot of time/disk)
#   INSTALLER_HERMES_INSTALL_URL    override upstream URL (useful for pinning to a commit SHA)
#   INSTALLER_FORCE_REINSTALL=1     ignore "already installed" fast-path and
#                                    rerun the upstream installer
#   INSTALLER_HERMES_REPO_URL       override hermes git repo URL for pre-clone
#                                   (default: https://gitee.com/cylingo-group/hermes-agent.git;
#                                    we pre-clone via HTTPS to bypass upstream's SSH-first attempt
#                                    that hangs on networks where the SSH endpoint stalls during KEX)
#   INSTALLER_SKIP_ENV=1            skip our env-deps run (set by install.sh when called from it)

set -euo pipefail

__HE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__HE_DIR/../../lib/common.sh"

# Env-prep steps we pre-run so the upstream hermes installer detects them
# and fast-paths. Order is dependency-correct:
#   base-deps     curl/git/openssl required by everything below
#   system-tools  ripgrep + ffmpeg + (Debian) build-essential / python3-dev / libffi-dev
#   fnm + hermes-node  Node v22 symlinked into ~/.hermes/node/bin/
#   uv + python   uv installed, then Python 3.11 via uv
ENV_STEPS=(base-deps system-tools fnm hermes-node uv python)

HERMES_INSTALL_URL="${INSTALLER_HERMES_INSTALL_URL:-https://gitee.com/cylingo-group/hermes-agent/raw/main/scripts/install.sh}"
HERMES_BRANCH="${INSTALLER_HERMES_BRANCH:-main}"
HERMES_HOME_DIR="${INSTALLER_HERMES_HOME:-${HERMES_HOME:-$HOME/.hermes}}"
HERMES_INSTALL_DIR="${INSTALLER_HERMES_DIR:-$HERMES_HOME_DIR/hermes-agent}"
HERMES_REPO_HTTPS="${INSTALLER_HERMES_REPO_URL:-https://gitee.com/cylingo-group/hermes-agent.git}"
HERMES_BIN="$HOME/.local/bin/hermes"
DEBUG_MODE="${DEBUG_MODE:-0}"

prepare_hermes_repo() {
  display "@@step:hermes-repo:Pre-cloning Hermes repository…"
  # Workaround for upstream's SSH-first clone strategy. On restricted networks
  # the TCP handshake to github.com:22 succeeds but the SSH protocol negotiation
  # hangs; upstream's GIT_SSH_COMMAND sets ConnectTimeout=5 which only covers
  # the TCP phase, not key exchange. Pre-cloning via HTTPS makes upstream's
  # clone_repo() take its "Existing installation found, updating" branch and
  # skip the SSH attempt entirely.
  if [[ -d "$HERMES_INSTALL_DIR/.git" ]]; then
    display "Hermes repo already present; skipping clone"
    log "Hermes repo already present at $HERMES_INSTALL_DIR (upstream will update in-place)"
    return
  fi
  if [[ -e "$HERMES_INSTALL_DIR" ]]; then
    die_step "Pre-clone Hermes repo" "$HERMES_INSTALL_DIR exists but is not a git repo. Remove it, or pick another dir via INSTALLER_HERMES_DIR." 1
  fi
  command -v git >/dev/null 2>&1 || die_step "Pre-clone Hermes repo" "git not on PATH — base-deps step should have installed it" 1
  log "Pre-cloning hermes via HTTPS (shallow, single-branch): $HERMES_REPO_HTTPS (branch=$HERMES_BRANCH) → $HERMES_INSTALL_DIR"
  mkdir -p "$(dirname "$HERMES_INSTALL_DIR")"
  # --single-branch + --depth 1 keep the transfer minimal.
  run git clone --branch "$HERMES_BRANCH" --single-branch --depth 1 \
       "$HERMES_REPO_HTTPS" "$HERMES_INSTALL_DIR" </dev/null \
    || die_step "Pre-clone Hermes repo" "git clone failed for $HERMES_REPO_HTTPS (branch=$HERMES_BRANCH)" 1
}

run_upstream_hermes_installer() {
  display "@@step:hermes-upstream:Running upstream Hermes installer (2–5 min on first run)…"
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
  tmp="$(mktemp -p "$(_claw_tmp_dir)" hermes-install.XXXXXX.sh)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  run curl -fsSL "$HERMES_INSTALL_URL" -o "$tmp"
  local size sha
  size="$(wc -c <"$tmp" | tr -d ' ')"
  sha="$(shasum -a 256 "$tmp" 2>/dev/null | awk '{print $1}')"
  log "Upstream installer: ${size}B sha256=$sha"
  log "Invoking: bash <upstream-install.sh> ${args[*]}"
  log "(stdin closed; upstream prompts will see EOF and fall back to defaults — no gateway/whatsapp pairing in this run)"

  # Run with a generous timeout so a hung upstream step doesn't deadlock us.
  # 30 min covers worst-case Playwright + system-deps install on a slow box.
  run run_with_timeout 1800 bash "$tmp" "${args[@]}" </dev/null
}

install_hermes_agent() {
  # Pre-snapshot: did these paths exist BEFORE the upstream installer ran?
  # We mark created vs preexisting so uninstall doesn't remove a dir the user
  # already had.
  local hh_status="created" id_status="created" bin_status="installed"
  [[ -d "$HERMES_HOME_DIR" ]]    && hh_status="preexisting"
  [[ -d "$HERMES_INSTALL_DIR" ]] && id_status="preexisting"
  [[ -x "$HERMES_BIN" ]]         && bin_status="preexisting"

  # Fast-path: hermes binary + repo already in place. Skip the upstream
  # installer (which is slow even on a no-op rerun: it always re-downloads
  # the script, re-pulls the repo, and re-probes system deps).
  if [[ -x "$HERMES_BIN" && -d "$HERMES_INSTALL_DIR/.git" \
        && -z "${INSTALLER_FORCE_REINSTALL:-}" ]]; then
    local hv
    hv="$("$HERMES_BIN" --version 2>/dev/null || true)"
    # Brace the var so bash 3.2 (macOS /bin/bash) doesn't read the trailing
    # full-width 」 as part of the variable name, which under `set -u` turns
    # into a fatal "hv）: unbound variable" that bypasses the ERR trap.
    display "Hermes already installed; skipping upstream install (version ${hv})"
    log "Hermes already installed at $HERMES_BIN${hv:+ ($hv)} — skipping upstream installer (set INSTALLER_FORCE_REINSTALL=1 to redo)"
    manifest_record hermes_install_dir "$HERMES_INSTALL_DIR" "$id_status"
    manifest_record hermes_home        "$HERMES_HOME_DIR"    "$hh_status"
    manifest_record hermes_bin         "$HERMES_BIN"         "$bin_status"
    _print_hermes_summary
    return
  fi

  # Pre-clone via HTTPS so the upstream installer doesn't hang on its SSH
  # clone attempt on restricted networks. Must run AFTER the snapshot above —
  # otherwise hermes_install_dir would be marked preexisting and uninstall
  # wouldn't remove it.
  prepare_hermes_repo

  # Run upstream installer; die_step_handler fires on non-zero via ERR trap.
  run_upstream_hermes_installer
  display "✓ Hermes upstream install complete"

  [[ -d "$HERMES_INSTALL_DIR" ]] && manifest_record hermes_install_dir "$HERMES_INSTALL_DIR" "$id_status"
  [[ -d "$HERMES_HOME_DIR"    ]] && manifest_record hermes_home        "$HERMES_HOME_DIR"    "$hh_status"
  [[ -x "$HERMES_BIN"         ]] && manifest_record hermes_bin         "$HERMES_BIN"         "$bin_status"

  register_hermes_gateway_service
  prebuild_hermes_web_ui

  _print_hermes_summary
}

# Pre-build the hermes dashboard's web UI (Vite → hermes_cli/web_dist/).
# Without this, the first `hermes dashboard` open spends ~15-30s running
# `npm install && npm run build` before the server starts. Pre-building
# moves that cost into install where the user already expects a wait, so
# `open-dashboard` later goes hermes-binary-runtime → uvicorn → ready in
# ~2-3s. `_web_ui_build_needed` in hermes_cli/main.py auto-detects a
# fresh dist and short-circuits the runtime build.
#
# Best-effort: build failures don't abort install (the runtime build path
# will retry on first dashboard open). Set INSTALLER_HERMES_SKIP_PREBUILD=1
# to bypass entirely (useful in restricted networks where npm install
# from registry would hang anyway).
prebuild_hermes_web_ui() {
  if [[ -n "${INSTALLER_HERMES_SKIP_PREBUILD:-}" ]]; then
    log "prebuild_hermes_web_ui: INSTALLER_HERMES_SKIP_PREBUILD set — skipping"
    return 0
  fi
  local web_dir="$HERMES_INSTALL_DIR/web"
  local dist_index="$HERMES_INSTALL_DIR/hermes_cli/web_dist/index.html"
  if [[ ! -d "$web_dir" || ! -f "$web_dir/package.json" ]]; then
    log "prebuild_hermes_web_ui: no $web_dir/package.json — skipping"
    return 0
  fi
  if [[ -f "$dist_index" && -z "${INSTALLER_FORCE_REINSTALL:-}" ]]; then
    log "prebuild_hermes_web_ui: $dist_index already present — skipping (set INSTALLER_FORCE_REINSTALL=1 to rebuild)"
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    log "prebuild_hermes_web_ui: npm not on PATH — skipping (dashboard will build on first open)"
    return 0
  fi
  display "@@step:hermes-web-prebuild:Pre-building Hermes Dashboard frontend (30–60s on first run)…"
  if run_with_timeout 600 bash -c "cd '$web_dir' && npm install --silent && npm run build" </dev/null; then
    display "✓ Hermes Dashboard frontend pre-built"
  else
    log "prebuild_hermes_web_ui: build failed — dashboard will retry on first open"
    display "⚠ Hermes Dashboard frontend pre-build failed (will retry on first dashboard open)"
  fi
}

# Register the launchd/systemd service definition for `hermes gateway` so the
# start/stop UI buttons have something to act on. Does NOT start the service —
# user kicks it off via the GUI's start button (gateway requires messaging
# credentials, which the user configures via `hermes setup`).
#
# Idempotent. Recorded in the manifest so uninstall can remove the plist/unit.
register_hermes_gateway_service() {
  display "@@step:hermes-service:Registering Hermes gateway service…"
  command -v hermes >/dev/null 2>&1 \
    || { log "hermes not on PATH after install — skipping gateway service registration"; return; }
  if run run_with_timeout 30 hermes gateway install </dev/null; then
    manifest_record hermes_service gateway installed
    display "✓ Hermes gateway service registered (start it from the GUI)"
  else
    log "hermes gateway install timed out or non-zero — service definition may be missing."
    log "  Run manually: hermes gateway install"
  fi
}

_print_hermes_summary() {
  display "✓ Hermes Agent install complete"
  log "Repo           : $HERMES_INSTALL_DIR (branch=$HERMES_BRANCH)"
  log "Data dir       : $HERMES_HOME_DIR"
  log "Command        : $HERMES_BIN"
  log ""
  log "Next steps:"
  log "  1. Reopen your shell (or 'source ~/.bashrc') so PATH takes effect"
  log "  2. hermes setup    # interactive: API key / model / channel"
  log "  3. hermes          # start chatting"
  log ""
  log "Notes:"
  log "  - System-level deps (uv / Python 3.11 / Node v22 / ripgrep / ffmpeg / Playwright)"
  log "    are installed by the upstream script; they don't clash with this repo's"
  log "    fnm-managed Node 24."
  log "  - The upstream script writes PATH lines into ~/.bashrc / ~/.zshrc / ~/.profile"
  log "    without any sentinel; uninstall.sh leaves those lines alone (avoids"
  log "    deleting unrelated user config)."
}

main() {
  # Parse flags
  for arg in "$@"; do
    case "$arg" in
      --debug) DEBUG_MODE=1 ;;
      --trace) export INSTALLER_TRACE=1 ;;
    esac
  done

  # Activate xtrace if --trace was passed on CLI (env-var path already
  # triggered inside common.sh at source time).
  _claw_enable_trace

  # Start debug tail AFTER fd 3 is open (common.sh opens it at source time)
  if [[ "$DEBUG_MODE" == "1" ]]; then
    display "Log file: $CLAW_SESSION_LOG"
    tail -F "$CLAW_SESSION_LOG" >&2 &
    TAIL_PID=$!
    trap 'kill "$TAIL_PID" 2>/dev/null || true' EXIT
  fi

  trap 'die_step_handler' ERR

  if [[ -z "${INSTALLER_SKIP_ENV:-}" ]]; then
    run_steps "${ENV_STEPS[@]}"
  fi
  install_hermes_agent
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
