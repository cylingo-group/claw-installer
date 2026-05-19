#!/usr/bin/env bash
# steps/base-deps.sh — install OS-level base dependencies
# (curl / unzip / git / openssl / ca-certificates).
#
# Can be sourced (defines step_base_deps) or executed directly.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_base_deps() {
  : "${PLATFORM:?PLATFORM not set — call detect_platform first}"
  display "@@step:base-deps:正在安装基础依赖…"
  case "$PLATFORM" in
    macos)
      command -v brew >/dev/null 2>&1 \
        || die_step "基础依赖检查" "Homebrew not found — install from https://brew.sh then rerun" 1
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
