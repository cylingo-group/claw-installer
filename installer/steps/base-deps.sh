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
  case "$PLATFORM" in
    macos)
      command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS. Install from https://brew.sh, then rerun."
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
        brew install "${missing[@]}"
        for bin in "${missing[@]}"; do
          manifest_record system_pkg "$bin" brew_installed "brew"
        done
      else
        log "Base deps already present"
      fi
      ;;
    debian)
      log "apt-get update + install: curl unzip git openssl ca-certificates"
      run_as_root apt-get update -y
      run_as_root apt-get install -y --no-install-recommends \
        curl unzip git openssl ca-certificates
      local p
      for p in curl unzip git openssl ca-certificates; do
        manifest_record system_pkg "$p" apt_shared "apt-get"
      done
      ;;
    rhel)
      local pm
      pm="$(command -v dnf || command -v yum)"
      log "$pm install: curl unzip git openssl ca-certificates"
      run_as_root "$pm" install -y curl unzip git openssl ca-certificates
      local p
      for p in curl unzip git openssl ca-certificates; do
        manifest_record system_pkg "$p" rhel_shared "$(basename "$pm")"
      done
      ;;
    *) die "Unknown PLATFORM: $PLATFORM" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_base_deps
fi
