#!/usr/bin/env bash
# steps/system-tools.sh — install OS packages that hermes's upstream
# install.sh otherwise installs itself (ripgrep, ffmpeg, and the Debian
# build chain). Pre-installing them lets the upstream's `command -v rg`
# and `dpkg -s gcc` checks pass and skip apt/brew.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_system_tools() {
  : "${PLATFORM:?PLATFORM not set — call detect_platform first}"
  display "@@step:system-tools:正在安装系统工具（ripgrep / ffmpeg）…"
  case "$PLATFORM" in
    macos)
      command -v brew >/dev/null 2>&1 || die_step "安装系统工具" "Homebrew required on macOS." 1
      local want=(ripgrep ffmpeg)
      local missing=() bin pkg
      for pkg in "${want[@]}"; do
        case "$pkg" in ripgrep) bin=rg ;; *) bin="$pkg" ;; esac
        if command -v "$bin" >/dev/null 2>&1; then
          manifest_record system_pkg "$pkg" preexisting "brew"
        else
          missing+=("$pkg")
        fi
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        log "brew install: ${missing[*]}"
        run brew install "${missing[@]}"
        for pkg in "${missing[@]}"; do
          manifest_record system_pkg "$pkg" brew_installed "brew"
        done
      else
        display "系统工具已就绪，跳过安装"
      fi
      ;;
    debian)
      # ripgrep + ffmpeg + the Debian build chain hermes checks for via
      # `dpkg -s gcc && dpkg -s python3-dev && dpkg -s libffi-dev`.
      local pkgs=(ripgrep ffmpeg build-essential python3-dev libffi-dev)
      local missing=() p
      for p in "${pkgs[@]}"; do
        if dpkg -s "$p" >/dev/null 2>&1; then
          manifest_record system_pkg "$p" preexisting "apt-get"
        else
          missing+=("$p")
        fi
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        log "apt-get install: ${missing[*]}"
        run run_as_root apt-get update -y
        run run_as_root apt-get install -y --no-install-recommends "${missing[@]}"
        for p in "${missing[@]}"; do
          manifest_record system_pkg "$p" apt_shared "apt-get"
        done
      else
        display "系统工具已就绪，跳过安装"
      fi
      ;;
    rhel)
      local pm
      pm="$(command -v dnf || command -v yum)"
      # RHEL package names differ for the build chain.
      local pkgs=(ripgrep ffmpeg gcc python3-devel libffi-devel)
      local missing=() p
      for p in "${pkgs[@]}"; do
        if rpm -q "$p" >/dev/null 2>&1; then
          manifest_record system_pkg "$p" preexisting "$(basename "$pm")"
        else
          missing+=("$p")
        fi
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        log "$pm install: ${missing[*]}"
        run run_as_root "$pm" install -y "${missing[@]}"
        for p in "${missing[@]}"; do
          manifest_record system_pkg "$p" rhel_shared "$(basename "$pm")"
        done
      else
        display "系统工具已就绪，跳过安装"
      fi
      ;;
    *) die_step "安装系统工具" "Unknown PLATFORM: $PLATFORM" 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_system_tools
fi
