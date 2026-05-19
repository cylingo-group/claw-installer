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

  local out
  if out=$(osascript <<'OSA' 2>&1
do shell script "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"" with administrator privileges
OSA
  ); then
    log "Homebrew installer output:"
    log "$out"
    display "✓ Homebrew 安装完成"
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    manifest_record homebrew_install brew installed "auto-install"
    return 0
  else
    log "Homebrew installer failed:"
    log "$out"
    return 1
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
