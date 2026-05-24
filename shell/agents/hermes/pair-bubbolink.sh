#!/usr/bin/env bash
# shell/agents/hermes/pair-bubbolink.sh
#
# Op contract (per op-dispatch-protocol/spec.md D5):
#   stdin            : ignored
#   env vars read    : INSTALLER_OP_PAIR_CODE (required — 4-digit ASCII string)
#   stdout           : bubbolink CLI output (informational; safe to surface)
#   exit 0           : `bubbolink pair <code>` succeeded (pairs every runtime
#                      installed on this host — openclaw / hermes / claude /
#                      codex — since `--runtime` is omitted)
#   exit non-zero    : bubbolink missing on PATH, code invalid/expired, or
#                      the pair RPC failed (stderr carries the diagnosis)
#
# Note: this script lives under agents/hermes/ only for op-dispatch routing
# (PATH composition via common.sh). The pair command itself is host-wide:
# dispatching from either agent has the same effect.

set -euo pipefail

__SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__SELF_DIR/../../lib/common.sh"

# Compose PATH so the pnpm-global-installed bubbolink CLI is reachable
# (fnm-managed Node + pnpm bin), matching apply-model-config.sh.
_claw_compose_path

if [[ -z "${INSTALLER_OP_PAIR_CODE:-}" ]]; then
  echo "pair-bubbolink: INSTALLER_OP_PAIR_CODE 未设置" >&2
  exit 2
fi

if [[ ! "$INSTALLER_OP_PAIR_CODE" =~ ^[0-9]{4}$ ]]; then
  echo "pair-bubbolink: 配对码必须是 4 位数字" >&2
  exit 2
fi

if ! command -v bubbolink >/dev/null 2>&1; then
  echo "pair-bubbolink: bubbolink 命令未找到，请先完成 Hermes 安装" >&2
  exit 127
fi

exec bubbolink pair "$INSTALLER_OP_PAIR_CODE"
