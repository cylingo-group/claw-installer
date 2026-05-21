#!/usr/bin/env bash
# steps/base-deps.sh — install OS-level base dependencies
# (curl / unzip / git / openssl / ca-certificates).
#
# Can be sourced (defines step_base_deps) or executed directly.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

# Auto-install Homebrew on macOS when it's missing. Wraps the official installer
# in `osascript with administrator privileges` so a single GUI password dialog
# elevates the entire installer to root (matches the WSL-on-Windows UX). Returns
# 0 on success, 1 on user cancellation or installer failure.
install_homebrew_macos() {
  display "@@step:install-homebrew:正在安装 Homebrew…"
  display "  首次安装约需 5-10 分钟，期间会弹出系统授权对话框"
  log "Running official Homebrew installer with administrator privileges via osascript"

  # `do shell script ... with administrator privileges` runs under sudo with a
  # scrubbed environment, so any HOMEBREW_* we exported won't survive. Inline
  # the relevant assignments directly into the privileged command so the
  # official install.sh sees them when cloning brew + homebrew-core (and when
  # downloading bottles during downstream `brew install` invocations).
  local env_inline=""
  local v val
  for v in HOMEBREW_BREW_GIT_REMOTE HOMEBREW_CORE_GIT_REMOTE HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN; do
    val="${!v:-}"
    if [[ -n "$val" ]]; then
      env_inline+="$v=$(printf %q "$val") "
    fi
  done
  if [[ -n "$env_inline" ]]; then
    log "Mirror env forwarded into privileged shell: ${env_inline}"
  fi

  # NB: the install.sh URL itself is still fetched from raw.githubusercontent.com.
  # No reliable single-shot mirror covers it; downstream traffic (brew + core
  # clone, bottles) is the bulk and goes through the mirror once the env above
  # takes effect.
  local sh_cmd="${env_inline}NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

  # Escape for AppleScript string literal: backslash first, then double quote.
  local osa_cmd="${sh_cmd//\\/\\\\}"
  osa_cmd="${osa_cmd//\"/\\\"}"

  local out
  if out=$(osascript -e "do shell script \"$osa_cmd\" with administrator privileges" 2>&1); then
    log "Homebrew installer output:"
    log "$out"
    display "✓ Homebrew 安装完成"
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    # `brew shellenv` prepends /opt/homebrew/bin to PATH — re-assert our
    # canonical order so fnm/pnpm (added later) stay ahead of brew.
    _claw_compose_path
    manifest_record homebrew_install brew installed "auto-install"
    return 0
  else
    log "Homebrew installer failed:"
    log "$out"
    return 1
  fi
}

# When brew is already present (i.e. install.sh didn't get a chance to honor
# HOMEBREW_*_GIT_REMOTE during the initial clone), rewrite the `origin` remotes
# of brew and homebrew-core to the mirror — but ONLY if they currently point at
# the canonical upstream URL, so we never clobber a user's pre-existing custom
# remote.
align_brew_remotes_with_mirror_macos() {
  command -v brew >/dev/null 2>&1 || return 0
  local cur

  if [[ -n "${HOMEBREW_BREW_GIT_REMOTE:-}" ]]; then
    local repo
    repo="$(brew --repo 2>/dev/null)" || repo=""
    if [[ -n "$repo" && -d "$repo/.git" ]]; then
      cur="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
      case "$cur" in
        https://github.com/Homebrew/brew|https://github.com/Homebrew/brew.git)
          log "brew: switching origin $cur → $HOMEBREW_BREW_GIT_REMOTE"
          run git -C "$repo" remote set-url origin "$HOMEBREW_BREW_GIT_REMOTE" || true
          ;;
      esac
    fi
  fi

  if [[ -n "${HOMEBREW_CORE_GIT_REMOTE:-}" ]]; then
    local core
    core="$(brew --repo homebrew/core 2>/dev/null)" || core=""
    if [[ -n "$core" && -d "$core/.git" ]]; then
      cur="$(git -C "$core" remote get-url origin 2>/dev/null || true)"
      case "$cur" in
        https://github.com/Homebrew/homebrew-core|https://github.com/Homebrew/homebrew-core.git)
          log "homebrew-core: switching origin $cur → $HOMEBREW_CORE_GIT_REMOTE"
          run git -C "$core" remote set-url origin "$HOMEBREW_CORE_GIT_REMOTE" || true
          ;;
      esac
    fi
  fi
}

step_base_deps() {
  : "${PLATFORM:?PLATFORM not set — call detect_platform first}"
  display "@@step:base-deps:正在安装基础依赖…"
  case "$PLATFORM" in
    macos)
      if ! command -v brew >/dev/null 2>&1; then
        install_homebrew_macos \
          || die_step "基础依赖检查" "Homebrew 自动安装失败或被取消，请手动从 https://brew.sh 安装后重试" 1
        command -v brew >/dev/null 2>&1 \
          || die_step "基础依赖检查" "Homebrew installed but not on PATH" 1
      else
        align_brew_remotes_with_mirror_macos
      fi
      local missing=() bin
      for bin in curl unzip git openssl; do
        if command -v "$bin" >/dev/null 2>&1; then
          manifest_record system_pkg "$bin" preexisting "brew"
        else
          missing+=("$bin")
        fi
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        log "brew install: ${missing[*]}"
        run brew install "${missing[@]}"
        for bin in "${missing[@]}"; do
          manifest_record system_pkg "$bin" brew_installed "brew"
        done
      else
        display "基础依赖已就绪，跳过安装"
      fi
      ;;
    debian)
      local want=(curl unzip git openssl ca-certificates)
      local missing=() p
      for p in "${want[@]}"; do
        # ca-certificates has no binary on PATH; query dpkg for it.
        if [[ "$p" == "ca-certificates" ]]; then
          if dpkg -s ca-certificates >/dev/null 2>&1; then
            manifest_record system_pkg "$p" preexisting "apt-get"
            continue
          fi
        elif command -v "$p" >/dev/null 2>&1; then
          manifest_record system_pkg "$p" preexisting "apt-get"
          continue
        fi
        missing+=("$p")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        log "apt-get install: ${missing[*]}"
        run run_as_root apt-get update -y
        run run_as_root apt-get install -y --no-install-recommends "${missing[@]}"
        for p in "${missing[@]}"; do
          manifest_record system_pkg "$p" apt_shared "apt-get"
        done
      else
        display "基础依赖已就绪，跳过安装"
      fi
      ;;
    rhel)
      local pm
      pm="$(command -v dnf || command -v yum)"
      local want=(curl unzip git openssl ca-certificates)
      local missing=() p
      for p in "${want[@]}"; do
        if [[ "$p" == "ca-certificates" ]]; then
          if rpm -q ca-certificates >/dev/null 2>&1; then
            manifest_record system_pkg "$p" preexisting "$(basename "$pm")"
            continue
          fi
        elif command -v "$p" >/dev/null 2>&1; then
          manifest_record system_pkg "$p" preexisting "$(basename "$pm")"
          continue
        fi
        missing+=("$p")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        log "$pm install: ${missing[*]}"
        run run_as_root "$pm" install -y "${missing[@]}"
        for p in "${missing[@]}"; do
          manifest_record system_pkg "$p" rhel_shared "$(basename "$pm")"
        done
      else
        display "基础依赖已就绪，跳过安装"
      fi
      ;;
    *) die_step "基础依赖检查" "Unknown PLATFORM: $PLATFORM" 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_base_deps
fi
